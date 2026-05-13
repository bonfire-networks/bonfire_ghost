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

  alias Bonfire.Boundaries.Circles
  alias Bonfire.Boundaries.Scaffold.Instance, as: InstanceScaffold
  alias Bonfire.Common.Text
  alias Bonfire.Me.Accounts
  alias Bonfire.Me.Characters
  alias Bonfire.Me.Users

  @circle_prefix "ghost_tier:"

  @handle_suffix_attempts 5

  @type diff :: %{added: non_neg_integer(), removed: non_neg_integer()}

  @doc """
  Creates or updates a local Account/User from a Ghost member payload and
  syncs their ghost-tier circle memberships.
  """
  @spec provision_from_ghost_member(map()) ::
          {:ok, Bonfire.Data.Identity.User.t()} | {:error, term()}
  def provision_from_ghost_member(%{"email" => email} = ghost_member)
      when is_binary(email) and email != "" do
    with {:ok, new?, account} <- ensure_account(email),
         {:ok, user} <- ensure_user(account, ghost_member, new?),
         {:ok, _diff} <- reconcile_circles(user, ghost_member) do
      {:ok, user}
    end
  end

  def provision_from_ghost_member(ghost_member) do
    error(ghost_member, "Ghost member payload missing email")
    {:error, :missing_email}
  end

  @doc """
  Handles `member.deleted` — removes the user from all `ghost_tier:*` circles.
  The Bonfire Account and User are preserved.
  """
  @spec remove_member(map()) :: {:ok, %{removed: non_neg_integer()}} | {:error, term()}
  def remove_member(%{"email" => email}) when is_binary(email) and email != "" do
    with account when not is_nil(account) <- Accounts.get_by_email(email),
         [user | _] <- Users.by_account!(account) do
      circle_ids = Enum.map(current_ghost_circles(user), & &1.id)
      {:ok, removed} = do_remove(user, circle_ids)
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
  @spec reconcile_circles(Bonfire.Data.Identity.User.t(), map()) :: {:ok, diff()}
  def reconcile_circles(user, %{"tiers" => tiers}) when is_list(tiers) do
    target_ids = target_circle_ids(tiers)
    current_ids = MapSet.new(current_ghost_circles(user), & &1.id)

    to_add = MapSet.difference(target_ids, current_ids) |> MapSet.to_list()
    to_remove = MapSet.difference(current_ids, target_ids) |> MapSet.to_list()

    with {:ok, added} <- do_add(user, to_add),
         {:ok, removed} <- do_remove(user, to_remove) do
      {:ok, %{added: added, removed: removed}}
    end
  end

  def reconcile_circles(user, _ghost_member), do: reconcile_circles(user, %{"tiers" => []})

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

  defp target_circle_ids(tiers) do
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
