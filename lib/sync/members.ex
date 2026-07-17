defmodule Bonfire.Ghost.Sync.Members do
  @moduledoc """
  Syncs Ghost members into Bonfire accounts + users + circle memberships.

  Called from `Bonfire.Ghost.Workers.MemberWebhookWorker` with a verified
  Ghost member payload. Email is the join key — there is no persistent
  Ghost↔Bonfire mapping table.

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
  use Bonfire.Common.E
  use Bonfire.Common.Settings

  alias Bonfire.Boundaries.Circles
  alias Bonfire.Boundaries.Scaffold.Instance, as: InstanceScaffold
  alias Bonfire.Common.Text
  alias Bonfire.Me.Accounts
  alias Bonfire.Me.Characters
  alias Bonfire.Me.Users
  alias Bonfire.Ghost
  alias Bonfire.Ghost.AdminAPI

  @circle_prefix "ghost_tier:"

  @handle_suffix_attempts 5
  @page_size 100
  @members_include "tiers,labels,newsletters"

  @type diff :: %{added: non_neg_integer(), removed: non_neg_integer()}
  @type sync_summary :: %{provisioned: non_neg_integer(), errors: [{String.t() | nil, term()}]}

  @empty_summary %{provisioned: 0, errors: []}

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

  Staff are not members: they never arrive via `member.*` webhooks (Ghost has no staff webhook events at all) and are invisible to `sync_all/1`'s member pages, so without this pass existing staff could only get an account by attempting the gated login. Account-only, like the member backfill — staff pick their own handle via `/create-user` — and via `provision_from_ghost_staff/2`, so tier reconciliation is skipped. Only active staff are fetched: suspended/locked staff must not get login-capable accounts.
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
    provision_from_ghost_member(ghost_staff, Keyword.put(opts, :reconcile_tiers, false))
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
  """
  @spec provision_from_ghost_member(map(), keyword()) ::
          {:ok, Bonfire.Data.Identity.User.t() | Bonfire.Data.Identity.Account.t()}
          | {:error, term()}
  def provision_from_ghost_member(ghost_member, opts \\ [])

  def provision_from_ghost_member(%{"email" => email} = ghost_member, opts)
      when is_binary(email) and email != "" do
    if Keyword.get(opts, :create_user, false) do
      with {:ok, new?, account} <- ensure_account(email),
           {:ok, user} <- ensure_user(account, ghost_member, new?),
           {:ok, _diff} <- maybe_reconcile_circles(user, ghost_member, opts) do
        {:ok, user}
      end
    else
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

    with true <- ghost_provisioned?(account),
         email when is_binary(email) and email != "" <- email,
         {:ok, c} <- Ghost.admin_client(),
         {:ok, %{"members" => [member | _]}} <-
           AdminAPI.get_member_by_email(c, email, include: "tiers") do
      reconcile_circles(user, member)
    end

    :ok
  rescue
    e ->
      warn(e, "Ghost after-signup circle reconcile failed")
      :ok
  end

  # An account is Ghost-provisioned iff we stashed the member context on it at login.
  defp ghost_provisioned?(account) do
    not is_nil(Settings.get([:bonfire_ghost, :member], nil, current_account: account))
  end

  defp account_email(account) do
    e(account, :email, :email_address, nil) ||
      account
      |> Bonfire.Common.Repo.maybe_preload(:email)
      |> e(:email, :email_address, nil)
  end

  # Account-only: no auto-username. Reconcile circles only if a user already exists
  # (and `reconcile_tiers: false` — the staff paths — skips even that).
  defp provision_account_only(ghost_member, email, opts) do
    with {:ok, _new?, account} <- ensure_account(email) do
      case Users.by_account!(account) do
        [] ->
          # Stash only pre-profile: /create-user consumes the prefill, and re-stamping an
          # account that already has profiles would mark pre-existing (e.g. admin) accounts
          # as Ghost-provisioned and overwrite their suggested name on every backfill run.
          stash_member_context(account, ghost_member)

        users ->
          Enum.each(users, &maybe_reconcile_circles(&1, ghost_member, opts))
      end

      {:ok, account}
    end
  end

  # Remember the member's Ghost display name on the account, so the `/create-user` step
  # can prefill the display name. Its presence also marks the account as Ghost-provisioned,
  # which the after-signup hook uses to know whether to look up + attach `ghost_tier:*`
  # circles (tiers are fetched live from Ghost at profile-creation time — Settings drops
  # unregistered keys like a stashed tier list, and live is always current anyway).
  defp stash_member_context(account, ghost_member) do
    name = ghost_member["name"]

    Settings.put(
      [:bonfire_ghost, :member],
      %{name: name},
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
  Handles `member.deleted` — removes the user from all `ghost_tier:*` circles.
  The Bonfire Account and User(s) are preserved.
  """
  @spec remove_member(map()) :: {:ok, %{removed: non_neg_integer()}} | {:error, term()}
  def remove_member(%{"email" => email}) when is_binary(email) and email != "" do
    with account when not is_nil(account) <- Accounts.get_by_email(email),
         [_ | _] = users <- Users.by_account!(account) do
      # a Ghost membership is keyed by email→account, so remove the tier circles
      # from ALL of the account's profiles (mirrors the add side in provisioning)
      removed =
        Enum.reduce(users, 0, fn user, acc ->
          {:ok, n} = do_remove(user, Enum.map(current_ghost_circles(user), & &1.id))
          acc + n
        end)

      {:ok, %{removed: removed}}
    else
      nil ->
        info(email, "Ghost member.deleted — no local account, nothing to reconcile")
        {:ok, %{removed: 0}}

      [] ->
        info(email, "Ghost member.deleted — account has no user, nothing to reconcile")
        {:ok, %{removed: 0}}
    end
  end

  def remove_member(ghost_member) do
    error(ghost_member, "Ghost member.deleted payload missing email")
    {:error, :missing_email}
  end

  @doc """
  Diffs the user's current `ghost_tier:*` circles against the tiers listed in
  the Ghost payload, adding and removing memberships so they match. Non-ghost
  circles are left untouched.

  Tier slugs without a local `ghost_tier:<slug>` circle (i.e. `Sync.Tiers`
  hasn't caught up with Ghost yet) are skipped — reconciliation will pick
  them up on the next member-sync after the tier sync runs.
  """
  # `reconcile_tiers: false` skips reconciliation entirely — used by the article-author path,
  # whose Ghost *staff* payload has no tiers to reconcile (and looking them up as a member would
  # be a usually-futile round-trip on the embed mount's critical path).
  defp maybe_reconcile_circles(user, ghost_member, opts) do
    if Keyword.get(opts, :reconcile_tiers, true) do
      reconcile_circles(user, ghost_member, opts)
    else
      {:ok, %{added: 0, removed: 0}}
    end
  end

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
          {:ok, Enum.reduce(members, summary, &sync_member(&1, &2, opts))}

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
      # Stable ascending order so members deleted mid-run shift already-processed
      # rows instead of silently skipping unfetched ones.
      order: "created_at asc",
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
          {:ok,
           Enum.reduce(users, summary, fn user, acc ->
             sync_member(user, acc, opts, &provision_from_ghost_staff/2)
           end)}

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
      order: "created_at asc",
      # suspended/locked staff must not get accounts, and Ghost returns them unless filtered
      filter: AdminAPI.active_staff_filter()
    )
  end

  defp sync_member(member, summary, opts, provision \\ &provision_from_ghost_member/2) do
    case provision.(member, opts) do
      {:ok, _user} ->
        Map.update!(summary, :provisioned, &(&1 + 1))

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

  defp ensure_user(account, ghost_member, new? \\ false) do
    existing =
      if !new? do
        case Users.by_account!(account) do
          [user | _] -> user
          [] -> nil
        end
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
