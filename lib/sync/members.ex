defmodule Bonfire.Ghost.Sync.Members do
  @moduledoc """
  Syncs Ghost members into Bonfire accounts + users + circle memberships.

  Called from `Bonfire.Ghost.Workers.MemberWebhookWorker` with a verified
  Ghost member payload. The Ghost ID is the primary join key (persisted per
  person via `Bonfire.Ghost.Identities` — staff and member IDs on one row),
  with email as the fallback for identities provisioned before the link
  existed. An email change in Ghost therefore updates the existing account
  instead of forking a duplicate — and an email changed on the Bonfire side is
  respected (the link is ID-based, and sync only follows Ghost's email while
  the local one still tracks it).

  - `provision_from_ghost_member/1` — idempotent upsert. Creates the Account
    (with a random high-entropy password — the member will use passwordless
    login) and the User (handle derived from the email local part, `_2`..`_9`
    suffix on collision) if missing, then reconciles their `ghost_tier:*`
    circle memberships.
  - `reconcile_circles/2` — diffs the user's current `ghost_tier:*` circles
    against the tiers in the Ghost payload. Tiers that haven't been synced
    yet (no local `ghost_tier:<slug>` circle) are silently skipped — the next
    `Bonfire.Ghost.Sync.Tiers.sync_all/1` run picks them up.
  - `remove_member/1` — called on `member.deleted`; removes the user from
    all `ghost_tier:*` circles. The Bonfire account/user is NOT deleted.
  """

  import Untangle
  import Ecto.Query
  use Bonfire.Common.E
  use Bonfire.Common.Settings

  alias Bonfire.Boundaries.Circles
  alias Bonfire.Boundaries.Scaffold.Instance, as: InstanceScaffold
  alias Bonfire.Common.Cache
  alias Bonfire.Common.Text
  alias Bonfire.Me.Accounts
  alias Bonfire.Me.Characters
  alias Bonfire.Me.Users
  alias Bonfire.Data.Identity.Email
  alias Bonfire.Data.ActivityPub.Peered
  alias Bonfire.Data.Social.Created
  alias Bonfire.Ghost
  alias Bonfire.Ghost.AdminAPI
  alias Bonfire.Ghost.Identities

  @circle_prefix "ghost_tier:"

  @handle_suffix_attempts 5
  @page_size 100
  @members_include "tiers,labels,newsletters"

  @type diff :: %{added: non_neg_integer(), removed: non_neg_integer()}
  @type sync_summary :: %{
          provisioned: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: [{String.t() | nil, term()}]
        }

  @empty_summary %{provisioned: 0, skipped: 0, errors: []}

  @status_cache_key "ghost_member_sync_status"
  # long enough that an admin returning the next day still sees the last outcome
  @status_ttl 1_000 * 60 * 60 * 24 * 7
  @max_stored_errors 20

  @doc """
  Status of the last member/staff backfill, for the settings UI, or nil if none ran recently.

  A map with `:state` (`:queued` | `:running` | `:done` | `:failed`), the `:stage` currently running (`:tiers` | `:staff` | `:members`), per-stage counters, a capped `:errors` list, and timestamps — including `:updated_at`, which is refreshed after every API page so a job that died mid-run can be told apart from one still working.

  Without this, the backfill was entirely unobservable: the settings page said "started" and nothing else, so a stage that had not started looked identical to one that was still processing.
  """
  def status, do: Cache.get!(@status_cache_key)

  @doc "Overwrites the backfill status, stamping the `:updated_at` heartbeat."
  def put_status(map) when is_map(map) do
    map = Map.put(map, :updated_at, DateTime.utc_now())
    # `async: false` — read-modify-write, must land in order (see Cache.put docs)
    Cache.put(@status_cache_key, map, expire: @status_ttl, async: false)
    map
  end

  @doc "Forgets the stored backfill status (mainly for tests)."
  def clear_status, do: Cache.remove(@status_cache_key)

  @doc """
  The displayable counters for one stage's summary (`:tiers`, `:members` or `:staff`).

  Pure — the caller accumulates these into the status map and persists once, rather than each stage re-reading the shared cache to append itself (which, across the minutes-long staff pass, could lose the earlier stages and report them as "did not run").

      iex> Bonfire.Ghost.Sync.Members.stage_counts(%{created: 2, errors: nil})
      %{archived: 0, created: 2, errors: [], errors_count: 0, provisioned: 0, skipped: 0, unchanged: 0, updated: 0}
  """
  def stage_counts(summary) when is_map(summary) do
    errors = normalize_errors(Map.get(summary, :errors))

    %{
      provisioned: Map.get(summary, :provisioned, 0),
      skipped: Map.get(summary, :skipped, 0),
      created: Map.get(summary, :created, 0),
      updated: Map.get(summary, :updated, 0),
      unchanged: Map.get(summary, :unchanged, 0),
      archived: Map.get(summary, :archived, 0),
      errors_count: length(errors),
      errors: stored_errors(errors)
    }
  end

  defp normalize_errors(errors) when is_list(errors), do: errors
  defp normalize_errors(nil), do: []
  defp normalize_errors(error), do: [error]

  defp stored_errors(errors) do
    errors
    |> Enum.take(@max_stored_errors)
    |> Enum.map(fn
      {who, reason} ->
        %{who: to_string(who || "?"), reason: inspect(reason) |> String.slice(0, 300)}

      other ->
        %{who: "?", reason: inspect(other) |> String.slice(0, 300)}
    end)
  end

  @doc """
  Backfills all Ghost members into local Bonfire accounts/users and synced `ghost_tier:*` circles.

  Upstream Ghost API failures return `{:error, reason}` so callers such as Oban can retry the whole backfill. Per-member provisioning failures are collected in the returned summary and do not stop later members from being processed.

  Pass the Ghost tier payloads as `tiers:` (e.g. from `Tiers.sync_all/1`) so the
  `ghost_tier:*` circles are resolved in one batch query for the whole run
  instead of per member.
  """
  @spec sync_all(keyword()) :: {:ok, sync_summary()} | {:error, term()}
  def sync_all(opts \\ []) do
    opts = Keyword.put(opts, :circle_map, tier_circle_map(opts[:tiers]))
    sync_members_page(1, @empty_summary, opts)
  end

  @doc """
  Backfills Ghost *staff* users (owner/admin/editor/author/contributor) into local Bonfire accounts.

  Staff are not members: they never arrive via `member.*` webhooks (Ghost has no staff webhook events at all) and are invisible to `sync_all/1`'s member pages, so without this pass existing staff could only get an account by attempting the gated login. Account-only, like the member backfill — staff pick their own handle via `/create-user` — and via `provision_from_ghost_staff/2`, so tier reconciliation is skipped. Staff suspended in Ghost (status `inactive`) are excluded; `locked` staff are NOT — that status only means they were imported and never set a Ghost password, which describes almost every bulk-imported contributor.
  """
  @spec sync_all_staff(keyword()) :: {:ok, sync_summary()} | {:error, term()}
  def sync_all_staff(opts \\ []) do
    sync_staff_page(1, @empty_summary, opts)
  end

  @doc """
  Provisions a local identity from a Ghost *staff* payload (owner/admin/editor/author/contributor) — same contract and options as `provision_from_ghost_member/2`.

  This wrapper owns the staff invariant so call sites can't forget it: a staff payload has no `"tiers"` key, so circle reconciliation is skipped (`reconcile_tiers: false`) instead of coercing to "no tiers" (which would strip paid circles) or costing a futile Members-API lookup per staffer.
  """
  @spec provision_from_ghost_staff(map(), keyword()) ::
          {:ok, Bonfire.Data.Identity.User.t() | Bonfire.Data.Identity.Account.t()}
          | {:error, term()}
  def provision_from_ghost_staff(ghost_staff, opts \\ []) do
    provision_from_ghost_member(
      ghost_staff,
      Keyword.merge(opts, reconcile_tiers: false, ghost_kind: "staff")
    )
  end

  @doc """
  Provisions a local identity from a Ghost member payload.

  By default (regular members) this creates the **Account only** (email +
  passwordless credential) and does NOT derive a `@username` from the member's
  Stripe/Ghost real name — the member picks their own handle via Bonfire's own
  `/create-user` step (with the usual consent acknowledgements), and their
  `ghost_tier:*` circles are attached at that point (see the after-signup hook).
  Returns `{:ok, account}`.

  Pass `create_user: true` (used only by the article-AUTHOR path,
  `Bonfire.Ghost.EmbedHelper`) to eagerly create the Account **and** User (with
  a derived username + profile) and reconcile circles immediately, returning
  `{:ok, user}` — an author needs a full identity to be attributed as a poster.

  If the account already has user(s) (e.g. a member re-logging in after creating
  their profile, or a webhook for an existing member), their tier circles are
  reconciled even on the account-only path.

  Members who do not hold one of the tiers required by
  `Bonfire.Ghost.TierGate` are refused with `{:skip, :tier_not_allowed}`: no
  account is created, and an existing one loses its `ghost_tier:*` circles but is
  kept. Staff bypass the gate (see `provision_from_ghost_staff/2`); pass
  `skip_tier_gate: true` to bypass it deliberately.
  """
  @spec provision_from_ghost_member(map(), keyword()) ::
          {:ok, Bonfire.Data.Identity.User.t() | Bonfire.Data.Identity.Account.t()}
          | {:skip, :tier_not_allowed}
          | {:error, term()}
  def provision_from_ghost_member(ghost_member, opts \\ [])

  def provision_from_ghost_member(%{"email" => email} = ghost_member, opts)
      when is_binary(email) and email != "" do
    cond do
      tier_gated?(ghost_member, opts) ->
        refuse_by_tier(ghost_member, email)

      Keyword.get(opts, :create_user, false) ->
        identity = lookup_identity(ghost_member, opts)

        with {:ok, new?, account} <- resolve_account(identity, email),
             {:ok, user} <- ensure_user(account, ghost_member, new?, e(identity, :user_id, nil)),
             {:ok, _diff} <- maybe_reconcile_circles(user, ghost_member, opts) do
          record_identity(ghost_member, account, user, opts)
          {:ok, user}
        end

      true ->
        provision_account_only(ghost_member, email, opts)
    end
  end

  def provision_from_ghost_member(ghost_member, _opts) do
    error(ghost_member, "Ghost member payload missing email")
    {:error, :missing_email}
  end

  @doc """
  `after_signup_hooks` callback — runs when ANY user finishes creating their profile.

  For a Ghost-provisioned account (one that went through the account-only login flow,
  marked by the stashed `[:bonfire_ghost, :member]` setting), fetches the member's
  current tiers live from Ghost and attaches the matching `ghost_tier:*` circles to the
  freshly-created user. No-op (and no Ghost API call) for non-Ghost accounts.
  """
  def reconcile_on_signup(user) do
    user = Bonfire.Common.Repo.maybe_preload(user, accounted: [account: :settings])
    account = e(user, :accounted, :account, nil)
    email = account_email(account)

    # An account is Ghost-provisioned iff we stashed the member context on it at login.
    stash = ghost_stash(account)

    if not is_nil(stash) do
      complete_identity_link(stash, account, user)

      with email when is_binary(email) and email != "" <- email,
           {:ok, c} <- Ghost.admin_client(),
           {:ok, %{"members" => [member | _]}} <-
             AdminAPI.get_member_by_email(c, email, include: "tiers") do
        reconcile_circles(user, member)
      end
    end

    :ok
  rescue
    e ->
      warn(e, "Ghost after-signup circle reconcile failed")
      :ok
  end

  # The context stashed on an account when Ghost provisioned it (its presence is what
  # marks the account as Ghost-provisioned), or nil.
  defp ghost_stash(account) do
    Settings.get([:bonfire_ghost, :member], nil, current_account: account)
  end

  # Completes the identity link with the freshly-created profile — the person creating
  # it IS the member/staffer the account was provisioned for. Accounts stashed before
  # the identity table existed carry no ghost_id; those get linked on their next
  # provisioning touch instead.
  defp complete_identity_link(stash, account, user) do
    case e(stash, :ghost_id, nil) do
      nil ->
        :ok

      ghost_id ->
        # Settings atomizes stashed string values on read (e.g. "staff" → :staff)
        case to_string(e(stash, :kind, "member")) do
          "staff" -> Identities.link(account, staff_id: to_string(ghost_id), user: user)
          _ -> Identities.link(account, member_id: to_string(ghost_id), user: user)
        end
    end
  end

  defp account_email(account) do
    e(account, :email, :email_address, nil) ||
      account
      |> Bonfire.Common.Repo.maybe_preload(:email)
      |> e(:email, :email_address, nil)
  end

  # --- Tier gate -----------------------------------------------------------

  # Enforced HERE rather than at each call site so a new provisioning path cannot
  # forget it: that omission is exactly what let free Ghost members in via the
  # `member.added` webhook and the "Sync members" backfill while the login path
  # (`Bonfire.Ghost.LoginEmailProvider`) checked correctly.
  #
  # Exempt: Ghost staff (a separate entity, no tiers — `provision_from_ghost_staff/2`
  # owns that invariant) and explicit `skip_tier_gate: true` callers.
  defp tier_gated?(ghost_member, opts) do
    cond do
      ghost_kind(opts) == "staff" -> false
      Keyword.get(opts, :skip_tier_gate, false) -> false
      true -> not Bonfire.Ghost.TierGate.allowed?(ghost_member, opts)
    end
  end

  # No account is created. An account that already exists is NOT deleted — it only
  # loses its `ghost_tier:*` circles, so a downgrade/cancellation revokes gated
  # access without erasing anyone's identity or content.
  defp refuse_by_tier(ghost_member, email) do
    info(email, "Ghost member does not hold a required tier — not provisioning")
    revoke_tier_circles(ghost_member, "tier gate")
    {:skip, :tier_not_allowed}
  end

  # Account-only: no auto-username. Reconcile circles only if a user already exists
  # (and `reconcile_tiers: false` — the staff paths — skips even that).
  defp provision_account_only(ghost_member, email, opts) do
    identity = lookup_identity(ghost_member, opts)

    with {:ok, _new?, account} <- resolve_account(identity, email) do
      case Users.by_account!(account) do
        [] ->
          # Stash only pre-profile: /create-user consumes the prefill, and re-stamping an
          # account that already has profiles would mark pre-existing (e.g. admin) accounts
          # as Ghost-provisioned and overwrite their suggested name on every backfill run.
          stash_member_context(account, ghost_member, opts)

        users ->
          Enum.each(users, &maybe_reconcile_circles(&1, ghost_member, opts))
      end

      record_identity(ghost_member, account, nil, opts)
      {:ok, account}
    end
  end

  # Remember the member's Ghost display name on the account, so the `/create-user` step
  # can prefill the display name. Its presence also marks the account as Ghost-provisioned,
  # which the after-signup hook uses to know whether to look up + attach `ghost_tier:*`
  # circles (tiers are fetched live from Ghost at profile-creation time — Settings drops
  # unregistered keys like a stashed tier list, and live is always current anyway).
  # The Ghost ID + kind ride along so the hook can complete the identity link with the
  # freshly-created user without another Ghost API call.
  defp stash_member_context(account, ghost_member, opts) do
    name = ghost_member["name"]

    Settings.put(
      [:bonfire_ghost, :member],
      %{name: name, ghost_id: ghost_member["id"], kind: ghost_kind(opts)},
      scope: :account,
      current_account: account,
      skip_boundary_check: true
    )

    # Also expose the display name via the generic account setting the `/create-user`
    # step prefills from (keeps bonfire_ui_me Ghost-agnostic). Editable there.
    if is_binary(name) and name != "" do
      Settings.put(
        [Bonfire.Me.Users, :suggested_profile_name],
        name,
        scope: :account,
        current_account: account,
        skip_boundary_check: true
      )
    end
  rescue
    e -> warn(e, "Could not stash Ghost member context on account")
  end

  @doc """
  Best-effort reconnection for identities that split BEFORE the identity link existed: called at sign-in when an active Ghost staff record has no identity link and no local account matches the email — reconnects the stranded Ghost-provisioned account instead of forking a fresh one.

  Deliberately conservative, because a wrong match hands one person's account to another: it rewrites the account's login email and signs the claimant in. ALL of these must hold: the staff slug resolves to a local username, that user's account carries the Ghost-provisioned stash marker, it is the account's only profile, and the account is not a *member's* (a subscriber who picked a colliding handle must never be claimed — checked against the stashed provisioning kind, and for accounts stashed before that kind was recorded, by confirming their address is not a Ghost member's).

  Anything else returns nil and normal provisioning applies. Legacy article-author accounts without a stash marker are only eligible when the staff slug matches the local username and that sole profile authored an object imported from the configured Ghost site. Pass `client:` to enable the ambiguous legacy-stash member check.
  """
  def claim_split_author(staff, opts \\ [])

  def claim_split_author(%{"id" => ghost_id} = staff, opts)
      when is_binary(ghost_id) and ghost_id != "" do
    if is_nil(Identities.get_by_staff_id(ghost_id)) do
      with %{} = user <- find_local_user_by_slug(staff["slug"]),
           user <-
             Bonfire.Common.Repo.maybe_preload(user, accounted: [account: [:email, :settings]]),
           %{} = account <- e(user, :accounted, :account, nil),
           [%{id: only_id}] <- Users.by_account!(account),
           true <- only_id == user.id,
           true <- claimable_staff_account?(account, user, opts) do
        info(
          "Reconnecting Ghost staff #{ghost_id} to the stranded local account of @#{e(user, :character, :username, nil)}"
        )

        current = e(account, :email, :email_address, nil)

        account =
          if is_binary(current) and current != staff["email"],
            do: update_account_email(account, current, staff["email"]),
            else: account

        record_identity(staff, account, user, ghost_kind: "staff")
        {:ok, account}
      else
        _ -> nil
      end
    end
  end

  def claim_split_author(_staff, _opts), do: nil

  # The stash marks an account as Ghost-provisioned; its `kind` says provisioned as
  # WHAT. Only staff accounts may be claimed by a staff sign-in. Accounts stashed
  # before `kind` was recorded are ambiguous, so they are only claimable once Ghost
  # confirms their address belongs to no member — fail closed without a client.
  defp claimable_staff_account?(account, user, opts) do
    case ghost_stash(account) do
      nil ->
        imported_ghost_author?(user)

      stash ->
        case to_string(e(stash, :kind, "")) do
          "staff" ->
            true

          "member" ->
            false

          _ ->
            not member_email?(account_email(account), opts[:client]) ||
              imported_ghost_author?(user)
        end
    end
  end

  # A legacy article-author account predates the Ghost provisioning stash. An exact
  # staff-slug → username match is only safe to claim when the same profile actually
  # authored an imported object from this configured Ghost site.
  defp imported_ghost_author?(%{id: user_id}) when is_binary(user_id) do
    case Ghost.ghost_url() do
      url when is_binary(url) and url != "" ->
        prefix = String.trim_trailing(url, "/") <> "/%"

        Ghost.repo().exists?(
          from(c in Created,
            join: p in Peered,
            on: p.id == c.id,
            where: c.creator_id == ^user_id and like(p.canonical_uri, ^prefix)
          )
        )

      _ ->
        false
    end
  rescue
    e ->
      warn(e, "Could not verify whether the staff candidate authored an imported Ghost article")
      false
  end

  defp imported_ghost_author?(_), do: false

  defp member_email?(email, client)
       when is_binary(email) and email != "" and not is_nil(client) do
    case AdminAPI.get_member_by_email(client, email) do
      {:ok, %{"members" => [_ | _]}} -> true
      {:ok, _} -> false
      # an API error must not be read as "not a member"
      _ -> true
    end
  end

  defp member_email?(_email, _client), do: true

  defp find_local_user_by_slug(slug) when is_binary(slug) and slug != "" do
    slug
    |> staff_slug_candidates()
    |> Enum.find_value(fn candidate ->
      case Users.by_username(candidate) do
        {:ok, user} -> user
        _ -> nil
      end
    end)
  end

  defp find_local_user_by_slug(_), do: nil

  defp staff_slug_candidates(slug) when is_binary(slug) and slug != "" do
    [slug, String.replace(slug, "-", ""), String.replace(slug, "-", "_")]
    |> Enum.uniq()
  end

  defp staff_slug_candidates(_), do: []

  @doc """
  Handles `member.deleted` — removes the user from all `ghost_tier:*` circles.
  The Bonfire Account and User(s) are preserved. Resolves the account by the
  linked Ghost member ID first (so it still works after an email change on
  either side), email as fallback.
  """
  @spec remove_member(map()) :: {:ok, %{removed: non_neg_integer()}} | {:error, term()}
  def remove_member(%{} = ghost_member),
    do: revoke_tier_circles(ghost_member, "member.deleted")

  # Shared by `member.deleted` and by the tier gate (a member who no longer holds a
  # required tier loses the gated circles but keeps their account — see the
  # "Revocation stance" in docs/ghost-and-publishing.md).
  defp revoke_tier_circles(%{} = ghost_member, because) do
    email = ghost_member["email"]

    if (is_binary(email) and email != "") or is_binary(ghost_member["id"]) do
      with account when not is_nil(account) <- removed_member_account(ghost_member),
           [_ | _] = users <- Users.by_account!(account) do
        # remove the tier circles from ALL of the account's profiles (mirrors the add side)
        removed =
          Enum.reduce(users, 0, fn user, acc ->
            {:ok, n} = do_remove(user, Enum.map(current_ghost_circles(user), & &1.id))
            acc + n
          end)

        {:ok, %{removed: removed}}
      else
        nil ->
          info(email, "Ghost #{because} — no local account, nothing to reconcile")
          {:ok, %{removed: 0}}

        [] ->
          info(email, "Ghost #{because} — account has no user, nothing to reconcile")
          {:ok, %{removed: 0}}
      end
    else
      error(ghost_member, "Ghost #{because} payload missing email and id")
      {:error, :missing_email}
    end
  end

  defp removed_member_account(ghost_member) do
    Identities.get_by_member_id(ghost_member["id"]) |> Identities.load_account() ||
      case ghost_member["email"] do
        email when is_binary(email) and email != "" -> Accounts.get_by_email(email)
        _ -> nil
      end
  end

  # `reconcile_tiers: false` skips reconciliation entirely for the article-author path, whose Ghost staff payload has no tiers and should not trigger a Members API round trip.
  defp maybe_reconcile_circles(user, ghost_member, opts) do
    if Keyword.get(opts, :reconcile_tiers, true) do
      reconcile_circles(user, ghost_member, opts)
    else
      {:ok, %{added: 0, removed: 0}}
    end
  end

  @doc """
  Diffs the user's current `ghost_tier:*` circles against the tiers listed in the Ghost payload, leaving non-Ghost circles untouched.

  Tier slugs without a local `ghost_tier:<slug>` circle are skipped and picked up after the next tier sync.
  """
  @spec reconcile_circles(Bonfire.Data.Identity.User.t(), map(), keyword()) :: {:ok, diff()}
  def reconcile_circles(user, ghost_member, opts \\ [])

  def reconcile_circles(user, %{"tiers" => tiers}, opts) when is_list(tiers) do
    target_ids = target_circle_ids(tiers, opts[:circle_map])
    current_ids = MapSet.new(current_ghost_circles(user), & &1.id)

    to_add = MapSet.difference(target_ids, current_ids) |> MapSet.to_list()
    to_remove = MapSet.difference(current_ids, target_ids) |> MapSet.to_list()

    with {:ok, added} <- do_add(user, to_add),
         {:ok, removed} <- do_remove(user, to_remove) do
      {:ok, %{added: added, removed: removed}}
    end
  end

  # No `"tiers"` key means this isn't a complete member payload (a Ghost *staff* user has no
  # tiers field at all; a webhook payload may omit it) — NOT "on no tiers". Coercing it to
  # `%{"tiers" => []}` would remove the user from every `ghost_tier:*` circle, silently stripping
  # paid access. Resolve the real tiers instead, and if we can't, leave their circles alone.
  def reconcile_circles(user, ghost_member, opts) do
    case authoritative_tiers(ghost_member) do
      {:ok, tiers} ->
        reconcile_circles(user, %{"tiers" => tiers}, opts)

      :not_a_member ->
        {:ok, %{added: 0, removed: 0}}

      {:error, reason} ->
        # must NOT report success: the caller is usually MemberWebhookWorker, and `{:ok, _}` here
        # makes Oban mark the job succeeded, dropping the tier change instead of retrying
        warn(reason, "Could not resolve Ghost tiers — failing so the job is retried")
        {:error, reason}
    end
  end

  # `:not_a_member` — no such member, or Ghost unconfigured: permanent, don't retry.
  # `{:error, _}` — Ghost errored/timed out: transient, DO retry.
  defp authoritative_tiers(%{"email" => email}) when is_binary(email) and email != "" do
    case Ghost.admin_client() do
      {:ok, c} ->
        case AdminAPI.get_member_by_email(c, email, include: "tiers") do
          {:ok, %{"members" => [member | _]}} ->
            case e(member, "tiers", nil) do
              tiers when is_list(tiers) -> {:ok, tiers}
              _ -> :not_a_member
            end

          {:ok, _no_members} ->
            :not_a_member

          {:error, reason} ->
            {:error, reason}
        end

      _not_configured ->
        :not_a_member
    end
  end

  defp authoritative_tiers(_), do: :not_a_member

  # --- Backfill ------------------------------------------------------------

  defp sync_members_page(page, summary, opts) do
    # Fresh client per page: the Admin JWT is short-lived (5 min) and a large
    # backfill can outlive it.
    with {:ok, client} <- Ghost.admin_client() do
      case list_members(client, page, opts) do
        {:ok, %{"members" => members, "meta" => meta}} when is_list(members) ->
          summary = Enum.reduce(members, summary, &sync_member(&1, &2, opts))
          report_page_progress(opts, page, summary)

          case next_page(meta) do
            nil ->
              {:ok, summary}

            next when next > page ->
              sync_members_page(next, summary, opts)

            next ->
              warn(
                %{page: page, next: next},
                "Ghost members pagination did not advance, stopping backfill"
              )

              {:ok, summary}
          end

        {:ok, %{"members" => members}} when is_list(members) ->
          summary = Enum.reduce(members, summary, &sync_member(&1, &2, opts))
          report_page_progress(opts, page, summary)
          {:ok, summary}

        {:ok, other} ->
          error(other, "Ghost members backfill returned an unexpected payload")
          {:error, :invalid_members_payload}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp list_members(client, page, opts) do
    AdminAPI.list_members(client,
      limit: Keyword.get(opts, :page_size, @page_size),
      page: page,
      # Bulk imports can give many members the same timestamp. ID breaks ties so
      # page boundaries cannot repeat some members while silently skipping others.
      order: "created_at asc,id asc",
      include: @members_include
    )
  end

  # Same page-walking shape as sync_members_page/3, over `/users/` instead of `/members/`.
  defp sync_staff_page(page, summary, opts) do
    with {:ok, client} <- Ghost.admin_client() do
      case list_users(client, page, opts) do
        {:ok, %{"users" => users, "meta" => meta}} when is_list(users) ->
          summary =
            Enum.reduce(users, summary, fn user, acc ->
              sync_member(user, acc, opts, &provision_from_ghost_staff/2)
            end)

          report_page_progress(opts, page, summary)

          case next_page(meta) do
            nil ->
              {:ok, summary}

            next when next > page ->
              sync_staff_page(next, summary, opts)

            next ->
              warn(
                %{page: page, next: next},
                "Ghost staff pagination did not advance, stopping backfill"
              )

              {:ok, summary}
          end

        {:ok, %{"users" => users}} when is_list(users) ->
          summary =
            Enum.reduce(users, summary, fn user, acc ->
              sync_member(user, acc, opts, &provision_from_ghost_staff/2)
            end)

          report_page_progress(opts, page, summary)
          {:ok, summary}

        {:ok, other} ->
          error(other, "Ghost staff backfill returned an unexpected payload")
          {:error, :invalid_users_payload}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp list_users(client, page, opts) do
    AdminAPI.list_users(client,
      limit: Keyword.get(opts, :page_size, @page_size),
      page: page,
      # Bulk imports share timestamps; ID breaks ties so page boundaries cannot
      # repeat some staff while silently skipping others.
      order: "created_at asc,id asc",
      # staff suspended in Ghost must not get accounts, and Ghost returns them unless filtered
      filter: AdminAPI.signin_staff_filter()
    )
  end

  defp report_page_progress(opts, page, summary) do
    case opts[:on_progress] do
      callback when is_function(callback, 2) -> callback.(page, summary)
      _ -> :ok
    end
  end

  defp sync_member(member, summary, opts, provision \\ &provision_from_ghost_member/2) do
    case provision.(member, opts) do
      {:ok, _user} ->
        Map.update!(summary, :provisioned, &(&1 + 1))

      # refused by the tier gate — expected on a gated instance with free members,
      # so it is counted rather than reported as an error
      {:skip, _reason} ->
        Map.update!(summary, :skipped, &(&1 + 1))

      {:error, reason} ->
        Map.update!(summary, :errors, &[{member_identity(member), reason} | &1])
    end
  end

  defp next_page(%{"pagination" => %{"next" => next}}) when is_integer(next), do: next

  defp next_page(%{"pagination" => %{"next" => next}}) when is_binary(next) do
    case Integer.parse(next) do
      {page, ""} -> page
      _ -> nil
    end
  end

  defp next_page(_), do: nil

  defp member_identity(%{"email" => email}) when is_binary(email), do: email
  defp member_identity(%{"id" => id}) when is_binary(id), do: id
  defp member_identity(_), do: nil

  # --- Account -------------------------------------------------------------

  # Identity resolution for every provisioning path (login, webhooks, backfill,
  # article import): the persisted Ghost-ID link wins over email, so an email
  # change on EITHER side can no longer fork a duplicate identity. Email remains
  # the fallback for identities provisioned before the link existed — which then
  # get linked by `record_identity`.
  defp lookup_identity(%{"id" => ghost_id} = ghost_identity, opts)
       when is_binary(ghost_id) and ghost_id != "" do
    case ghost_kind(opts) do
      "staff" ->
        ghost_id
        |> Identities.get_by_staff_id()
        |> maybe_recover_empty_staff_link(ghost_identity, opts)
        |> maybe_recover_conflicting_staff_account(ghost_identity, opts)

      _ ->
        Identities.get_by_member_id(ghost_id)
    end
  end

  defp lookup_identity(_ghost_member, _opts), do: nil

  # Repairs the precise failure left by an incomplete pre-link backfill: a changed Ghost email created an account-only fork that now owns the staff ID. The normal claim guards still apply; a legacy profile without their newer markers needs corroboration from the fork's exact Ghost provenance plus its own slug, name, age and email shape.
  defp maybe_recover_empty_staff_link(nil, _staff, _opts), do: nil

  defp maybe_recover_empty_staff_link(identity, staff, opts) do
    with %{} = linked_account <- Identities.load_account(identity),
         [] <- Users.by_account!(linked_account),
         %{} = original_user <- find_local_user_by_slug(staff["slug"]),
         original_user <-
           Bonfire.Common.Repo.maybe_preload(original_user,
             accounted: [account: [:email, :settings]]
           ),
         %{} = original_account <- e(original_user, :accounted, :account, nil),
         true <- original_account.id != linked_account.id,
         [%{id: only_id}] <- Users.by_account!(original_account),
         true <- only_id == original_user.id,
         true <-
           recoverable_empty_staff_target?(
             original_account,
             original_user,
             linked_account,
             staff,
             opts
           ),
         {:ok, repaired_identity} <-
           transfer_empty_staff_link(
             identity,
             linked_account,
             original_account,
             original_user,
             staff
           ) do
      info(
        "Recovered Ghost staff #{staff["id"]} from an empty fork and relinked @#{e(original_user, :character, :username, nil)}"
      )

      repaired_identity
    else
      _ -> Identities.get_by_staff_id(staff["id"]) || identity
    end
  end

  defp recoverable_empty_staff_target?(
         original_account,
         original_user,
         linked_account,
         staff,
         opts
       ) do
    claimable_staff_account?(original_account, original_user, opts) ||
      exact_legacy_staff_target?(original_account, original_user, linked_account, staff)
  end

  # Pre-marker author profiles cannot prove their origin themselves. A backfill-created
  # fork can: it is empty, linked by the exact staff ID, and carries the staff stash
  # written while Ghost was authoritative. Requiring the older target's sole profile to
  # match both slug and display name keeps a coincidental username from being claimed.
  defp exact_legacy_staff_target?(original_account, original_user, linked_account, staff) do
    staff_name = normalized_identity_name(staff["name"])
    profile_name = normalized_identity_name(e(original_user, :profile, :name, nil))

    case {ghost_stash(original_account), ghost_stash(linked_account)} do
      {nil, linked_stash} when not is_nil(linked_stash) ->
        is_binary(staff_name) and
          profile_name == staff_name and
          normalized_identity_name(e(linked_stash, :name, nil)) == staff_name and
          to_string(e(linked_stash, :kind, "")) == "staff" and
          to_string(e(linked_stash, :ghost_id, "")) == staff["id"] and
          e(original_user, :character, :username, nil) in staff_slug_candidates(staff["slug"]) and
          older_account?(original_account, linked_account) and
          email_matches?(account_email(linked_account), staff["email"]) and
          not email_matches?(account_email(original_account), staff["email"])

      _ ->
        false
    end
  end

  # Bonfire IDs are ULIDs, whose lexical order is chronological.
  defp older_account?(%{id: older_id}, %{id: newer_id})
       when is_binary(older_id) and is_binary(newer_id),
       do: older_id < newer_id

  defp older_account?(_, _), do: false

  defp normalized_identity_name(name) when is_binary(name) do
    case name |> String.normalize(:nfc) |> String.trim() |> String.replace(~r/\s+/, " ") do
      "" -> nil
      normalized -> String.downcase(normalized)
    end
  end

  defp normalized_identity_name(_), do: nil

  defp email_matches?(left, right) when is_binary(left) and is_binary(right),
    do: String.downcase(left) == String.downcase(right)

  defp email_matches?(_, _), do: false

  defp transfer_empty_staff_link(identity, linked_account, original_account, original_user, staff) do
    ghost_email = staff["email"]
    quarantine_email = "ghost-orphan-#{String.downcase(linked_account.id)}@invalid"

    Ghost.repo().transact_with(fn ->
      with {:ok, _quarantined_account} <-
             persist_account_email(linked_account, quarantine_email),
           {:ok, original_account} <- persist_account_email(original_account, ghost_email),
           {:ok, _deleted_identity} <- Ghost.repo().delete(identity),
           {:ok, repaired_identity} <-
             Identities.link(original_account,
               staff_id: staff["id"],
               member_id: identity.ghost_member_id,
               user: original_user,
               ghost_email: ghost_email
             ) do
        {:ok, repaired_identity}
      end
    end)
  end

  # Repairs the complementary split: the staff ID still points to the original author, but a prior failed sign-in left a different profileless account holding Ghost's new email. The controller supplies that exact account; all author-claim guards still have to pass before its email is quarantined.
  defp maybe_recover_conflicting_staff_account(nil, _staff, _opts), do: nil

  defp maybe_recover_conflicting_staff_account(identity, staff, opts) do
    with %{} = conflicting_account <- opts[:profileless_account],
         conflicting_account <-
           Bonfire.Common.Repo.maybe_preload(conflicting_account, [:email, :settings]),
         true <- account_email(conflicting_account) == staff["email"],
         [] <- Users.by_account!(conflicting_account),
         true <- recoverable_conflicting_staff_account?(conflicting_account, staff),
         %{} = linked_account <- Identities.load_account(identity),
         true <- linked_account.id != conflicting_account.id,
         %{} = linked_user <- find_local_user_by_slug(staff["slug"]),
         linked_user <-
           Bonfire.Common.Repo.maybe_preload(linked_user,
             accounted: [account: [:email, :settings]]
           ),
         %{} = author_account <- e(linked_user, :accounted, :account, nil),
         true <- author_account.id == linked_account.id,
         [%{id: only_id}] <- Users.by_account!(author_account),
         true <- only_id == linked_user.id,
         true <- claimable_staff_account?(author_account, linked_user, opts),
         {:ok, _updated_account} <-
           transfer_conflicting_staff_email(conflicting_account, author_account, staff["email"]) do
      info(
        "Recovered Ghost staff #{staff["id"]} from a conflicting empty account and restored @#{e(linked_user, :character, :username, nil)}"
      )

      identity
    else
      _ -> identity
    end
  end

  defp recoverable_conflicting_staff_account?(account, staff) do
    case {Identities.get_by_account(account), ghost_stash(account)} do
      {nil, stash} when not is_nil(stash) ->
        to_string(e(stash, :kind, "")) == "staff" and
          to_string(e(stash, :ghost_id, "")) == staff["id"]

      _ ->
        false
    end
  end

  defp transfer_conflicting_staff_email(conflicting_account, author_account, ghost_email) do
    quarantine_email = "ghost-orphan-#{String.downcase(conflicting_account.id)}@invalid"

    Ghost.repo().transact_with(fn ->
      with {:ok, _quarantined_account} <-
             persist_account_email(conflicting_account, quarantine_email),
           {:ok, updated_account} <- persist_account_email(author_account, ghost_email) do
        {:ok, updated_account}
      end
    end)
  end

  defp persist_account_email(account, email) do
    account = Bonfire.Common.Repo.maybe_preload(account, :email)

    case account.email
         |> Email.changeset(%{email_address: email}, must_confirm?: false)
         |> Bonfire.Common.Repo.update() do
      {:ok, email_mixin} -> {:ok, %{account | email: email_mixin}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp resolve_account(nil, email), do: ensure_account(email)

  defp resolve_account(identity, email) do
    case Identities.load_account(identity) do
      # the linked account no longer exists (row should have cascaded, but fail safe)
      nil -> ensure_account(email)
      account -> {:ok, false, maybe_follow_ghost_email(account, identity, email)}
    end
  end

  # Ghost changed the email AND the local email still tracks Ghost → follow it
  # (Ghost already verified the new address, so no re-confirmation round).
  # If the person changed their Bonfire email themselves (local ≠ last email seen
  # from Ghost), their choice wins — the link is ID-based and survives regardless.
  defp maybe_follow_ghost_email(account, identity, ghost_email) do
    account = Bonfire.Common.Repo.maybe_preload(account, :email)
    current = e(account, :email, :email_address, nil)
    last_known = e(identity, :ghost_email, nil)

    cond do
      !is_binary(current) or current == ghost_email ->
        account

      # Only follow when the local address is demonstrably still the one Ghost last
      # had. A missing `ghost_email` (a link recorded by id alone, e.g. an operator
      # repair) is NOT consent to overwrite — that would silently undo the repair.
      is_binary(last_known) and current == last_known ->
        update_account_email(account, current, ghost_email)

      true ->
        info(
          "Ghost email differs from the Bonfire account email, which was set locally (or predates the identity link) — keeping the local one"
        )

        account
    end
  end

  # If the new address is taken by ANOTHER local account (e.g. the person also has a
  # personal account — resolving that needs an admin decision), keep the old one.
  defp update_account_email(account, current, new_email) do
    case account.email
         |> Email.changeset(%{email_address: new_email}, must_confirm?: false)
         |> Bonfire.Common.Repo.update() do
      {:ok, email_mixin} ->
        info(
          "Ghost email changed: updated the local account email from #{current} to #{new_email}"
        )

        %{account | email: email_mixin}

      {:error, changeset} ->
        warn(
          changeset,
          "Could not follow the Ghost email change to #{new_email} (already taken by another account?) — keeping #{current}"
        )

        account
    end
  end

  defp record_identity(%{"id" => ghost_id} = ghost_member, account, user, opts)
       when is_binary(ghost_id) and ghost_id != "" do
    id_field = if ghost_kind(opts) == "staff", do: :staff_id, else: :member_id
    ghost_email = ghost_email_to_record(ghost_member, account, opts)

    case Identities.link(account, [
           {id_field, ghost_id},
           {:user, user},
           {:ghost_email, ghost_email}
         ]) do
      {:ok, _} -> :ok
      other -> warn(other, "Could not record the Ghost identity link")
    end
  end

  defp record_identity(_ghost_member, _account, _user, _opts), do: :ok

  # If following a Ghost-side change failed because another account owns the new address, keep the previous marker so a later retry can still recognize that the local email tracks Ghost. A genuine local override differs from the previous marker and continues recording Ghost's latest address.
  defp ghost_email_to_record(%{"email" => ghost_email, "id" => ghost_id}, account, opts) do
    identity =
      if ghost_kind(opts) == "staff",
        do: Identities.get_by_staff_id(ghost_id),
        else: Identities.get_by_member_id(ghost_id)

    current_email = account_email(account)
    last_ghost_email = e(identity, :ghost_email, nil)

    if current_email != ghost_email and current_email == last_ghost_email,
      do: last_ghost_email,
      else: ghost_email
  end

  defp ghost_kind(opts), do: Keyword.get(opts, :ghost_kind, "member")

  defp ensure_account(email) do
    case Accounts.get_by_email(email) do
      nil ->
        # High-entropy random password — members sign in via Ghost's passwordless flow.
        password = Text.random_string(32)

        params = %{
          email: %{email_address: email},
          credential: %{password: password, password_confirmation: password}
        }

        with {:ok, account} <-
               Accounts.signup(params, must_confirm?: false, skip_invite_check: true) do
          {:ok, true, account}
        end

      account ->
        {:ok, false, account}
    end
  end

  # --- User ----------------------------------------------------------------

  # `preferred_user_id` is the identity link's user: on an account with several
  # profiles, attribution must go to the linked author profile, not whichever
  # user happens to come first.
  defp ensure_user(account, ghost_member, new?, preferred_user_id) do
    existing =
      if !new? do
        users = Users.by_account!(account)
        Enum.find(users, &(&1.id == preferred_user_id)) || List.first(users)
      end

    case existing do
      nil ->
        name = ghost_member["name"]
        bases = candidate_handles(ghost_member)
        try_create_user(account, bases, name, 1)

      user ->
        {:ok, user}
    end
  end

  defp try_create_user(_account, _bases, _name, attempt)
       when attempt > @handle_suffix_attempts do
    error("Could not find a free handle from any candidate")
    {:error, :handle_exhausted}
  end

  defp try_create_user(account, bases, name, attempt) do
    suffix = if attempt == 1, do: nil, else: Enum.random(2..99)

    result =
      Enum.find_value(bases, fn base ->
        username = base |> handle_with_suffix(suffix) |> Characters.clean_username("")

        case Users.create(%{profile: %{name: name}, character: %{username: username}}, account) do
          {:ok, user} ->
            {:ok, user}

          {:error, %Ecto.Changeset{} = cs} ->
            debug(cs, "Users.create failed for #{username}")
            nil
        end
      end)

    case result do
      {:ok, user} -> {:ok, user}
      nil -> try_create_user(account, bases, name, attempt + 1)
    end
  end

  # Candidate base usernames in priority order: slug, display name.
  # Suffixes (_2, _3 ...) are added by try_create_user only after all bases fail.
  defp candidate_handles(ghost_member) do
    [ghost_member["slug"], ghost_member["name"]]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp handle_with_suffix(base, nil), do: base
  defp handle_with_suffix(base, n), do: "#{base}_#{n}"

  # --- Circles -------------------------------------------------------------

  # Resolves the run-invariant `ghost_tier:<slug>` circles in one batch query,
  # so the backfill doesn't repeat the lookup per member.
  defp tier_circle_map(tiers) when is_list(tiers) do
    tiers
    |> Enum.flat_map(fn
      %{"slug" => slug} when is_binary(slug) -> [@circle_prefix <> slug]
      _ -> []
    end)
    |> Circles.list_by_names(InstanceScaffold.admin_circle())
    |> Enum.flat_map(fn
      %{id: id, named: %{name: @circle_prefix <> slug}} -> [{slug, id}]
      _ -> []
    end)
    |> Map.new()
  end

  defp tier_circle_map(_), do: nil

  defp target_circle_ids(tiers, circle_map) when is_map(circle_map) do
    tiers
    |> Enum.flat_map(fn
      %{"slug" => slug} when is_binary(slug) ->
        case Map.fetch(circle_map, slug) do
          {:ok, id} -> [id]
          :error -> []
        end

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp target_circle_ids(tiers, _circle_map) do
    caretaker = InstanceScaffold.admin_circle()

    tiers
    |> Enum.flat_map(fn
      %{"slug" => slug} when is_binary(slug) ->
        case Circles.get_by_name(@circle_prefix <> slug, caretaker) do
          {:ok, circle} -> [circle.id]
          _ -> []
        end

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp current_ghost_circles(user) do
    InstanceScaffold.admin_circle()
    |> Circles.circles_containing_subject(user)
    |> Enum.filter(&ghost_tier_circle?/1)
  end

  defp ghost_tier_circle?(%{named: %{name: name}}) when is_binary(name),
    do: String.starts_with?(name, @circle_prefix)

  defp ghost_tier_circle?(_), do: false

  defp do_add(_user, []), do: {:ok, 0}

  defp do_add(user, circle_ids) do
    _ = Circles.add_to_circles(user, circle_ids)
    {:ok, length(circle_ids)}
  end

  defp do_remove(_user, []), do: {:ok, 0}

  defp do_remove(user, circle_ids) do
    case Circles.remove_from_circles(user, circle_ids) do
      {count, _} -> {:ok, count}
      _ -> {:ok, length(circle_ids)}
    end
  end
end
