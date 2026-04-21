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

  # Max handle attempts: base then base_2..base_9.
  @handle_suffix_attempts 9

  @type diff :: %{added: non_neg_integer(), removed: non_neg_integer()}

  @doc """
  Creates or updates a local Account/User from a Ghost member payload and
  syncs their ghost-tier circle memberships.
  """
  @spec provision_from_ghost_member(map()) ::
          {:ok, Bonfire.Data.Identity.User.t()} | {:error, term()}
  def provision_from_ghost_member(%{"email" => email} = ghost_member)
      when is_binary(email) and email != "" do
    with {:ok, account} <- ensure_account(email),
         {:ok, user} <- ensure_user(account, ghost_member),
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

        Accounts.signup(params, must_confirm?: false, skip_invite_check: true)

      account ->
        {:ok, account}
    end
  end

  # --- User ----------------------------------------------------------------

  defp ensure_user(account, ghost_member) do
    case Users.by_account!(account) do
      [user | _] ->
        {:ok, user}

      [] ->
        base = derive_handle(ghost_member)
        name = ghost_member["name"] || base
        try_create_user(account, base, name, 1)
    end
  end

  defp try_create_user(account, base, name, attempt)
       when attempt <= @handle_suffix_attempts do
    username = handle_with_suffix(base, attempt)
    params = %{profile: %{name: name}, character: %{username: username}}

    case Users.create(params, account) do
      {:ok, user} ->
        {:ok, user}

      {:error, %Ecto.Changeset{} = cs} ->
        debug(cs, "Users.create failed — retrying with next handle suffix")
        try_create_user(account, base, name, attempt + 1)
    end
  end

  defp try_create_user(_account, base, _name, _attempt) do
    error(base, "Could not find a free handle derived from Ghost email")
    {:error, :handle_exhausted}
  end

  # Username regex is `[a-z0-9_]` — underscores, not dashes, for the suffix.
  defp handle_with_suffix(base, 1), do: base
  defp handle_with_suffix(base, n), do: "#{base}_#{n}"

  defp derive_handle(%{"email" => email}) do
    email
    |> String.split("@", parts: 2)
    |> List.first()
    |> Characters.clean_username()
  end

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
