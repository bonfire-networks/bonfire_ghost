defmodule Bonfire.Ghost.Identities do
  @moduledoc """
  Persistent Ghost↔Bonfire identity links (the `bonfire_ghost_identity` table).

  Email used to be the only join key between Ghost and Bonfire, so any change to
  it (in Ghost, in Bonfire, or a mere case difference) forked a second local
  identity, and the fork then captured attribution of subsequent article
  imports. This table makes the link explicit and stable — one row per person:

  - `account_id` — the local account (primary key; the identity anchor)
  - `user_id` — the author/attribution profile, once known
  - `ghost_staff_id` + `ghost_member_id` — Ghost keeps staff and members as
    separate entities with separate ID spaces, and the same human can be both;
    holding both on one row keeps them converged on one account
  - `ghost_email` — the last email seen from Ghost, so sync can tell "Ghost
    changed the email" (follow it) apart from "the person changed their Bonfire
    email" (respect it — the link is ID-based and survives either way)

  Resolution is id-first with email as fallback; every provisioning path calls
  `link/2` so identities provisioned before this table get their ids backfilled
  on the next touch.
  """

  import Untangle
  import Ecto.Query
  use Bonfire.Common.E

  alias Bonfire.Common.Types
  alias Bonfire.Ghost
  alias Bonfire.Me.Accounts
  alias Bonfire.Me.Users
  alias Ecto.Changeset

  defmodule GhostIdentity do
    use Ecto.Schema

    @primary_key false
    schema "bonfire_ghost_identity" do
      belongs_to(:account, Bonfire.Data.Identity.Account, type: Needle.ULID, primary_key: true)
      belongs_to(:user, Bonfire.Data.Identity.User, type: Needle.ULID)
      field(:ghost_member_id, :string)
      field(:ghost_staff_id, :string)
      field(:ghost_email, :string)
      timestamps()
    end
  end

  @doc """
  Upserts the identity row for an account, attaching whichever of
  `staff_id:`, `member_id:`, `user:`, `ghost_email:` are known (non-nil).

  Never clears an already-set column — account-only re-provisioning (e.g. the
  backfill) must not disconnect the author profile linked at import or
  `/create-user` time. Returns `{:error, changeset}` if a Ghost ID is already
  linked to a DIFFERENT account (partial unique indexes) — resolution is
  id-first, so that indicates a logic error upstream or a repair-in-progress.
  """
  def link(account, fields \\ []) do
    account_id = Types.uid(account)

    if is_binary(account_id) do
      attrs =
        [
          ghost_staff_id: fields[:staff_id],
          ghost_member_id: fields[:member_id],
          user_id: Types.uid(fields[:user]),
          ghost_email: fields[:ghost_email]
        ]
        |> Enum.reject(fn {_, v} -> is_nil(v) end)

      set = attrs ++ [updated_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)]

      %GhostIdentity{account_id: account_id}
      |> Changeset.change(attrs)
      |> Changeset.unique_constraint(:ghost_staff_id,
        name: :bonfire_ghost_identity_ghost_staff_id_index
      )
      |> Changeset.unique_constraint(:ghost_member_id,
        name: :bonfire_ghost_identity_ghost_member_id_index
      )
      |> Ghost.repo().insert(on_conflict: [set: set], conflict_target: [:account_id])
    else
      error(account, "Cannot record a Ghost identity link without a local account")
    end
  end

  @doc "The identity row for a Ghost staff ID, or nil."
  def get_by_staff_id(ghost_id) when is_binary(ghost_id) and ghost_id != "" do
    Ghost.repo().one(from(gi in GhostIdentity, where: gi.ghost_staff_id == ^ghost_id))
  end

  def get_by_staff_id(_), do: nil

  @doc "The identity row for a Ghost member ID, or nil."
  def get_by_member_id(ghost_id) when is_binary(ghost_id) and ghost_id != "" do
    Ghost.repo().one(from(gi in GhostIdentity, where: gi.ghost_member_id == ^ghost_id))
  end

  def get_by_member_id(_), do: nil

  @doc "The identity row for a local account (or anything with its ID), or nil."
  def get_by_account(account) do
    case Types.uid(account) do
      account_id when is_binary(account_id) ->
        Ghost.repo().one(from(gi in GhostIdentity, where: gi.account_id == ^account_id))

      _ ->
        nil
    end
  end

  @doc "Loads the row's account (with current preloads), or nil if it no longer exists."
  def load_account(%GhostIdentity{account_id: account_id}), do: Accounts.get_current(account_id)
  def load_account(_), do: nil

  @doc "The mapped local user for a Ghost staff ID, if one is linked and still exists."
  def staff_user(ghost_id) do
    case get_by_staff_id(ghost_id) do
      %{user_id: user_id} when is_binary(user_id) ->
        case Users.by_id(user_id) do
          {:ok, user} -> user
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Maps each given Ghost id to the `@username` of its linked Bonfire profile, for the
  subset that have created one. `kind` is `:member` or `:staff` (they occupy separate
  columns). Ids with only an account (no profile yet) are simply absent from the result.

  Batched — one identity query plus one user query regardless of list length — so the
  settings page can annotate a whole page of members without an N+1.
  """
  def usernames_by_ghost_id(ghost_ids, kind)
      when is_list(ghost_ids) and kind in [:member, :staff] do
    ids = Enum.filter(ghost_ids, &(is_binary(&1) and &1 != ""))

    if ids == [] do
      %{}
    else
      column = if kind == :staff, do: :ghost_staff_id, else: :ghost_member_id

      rows =
        Ghost.repo().all(
          from(gi in GhostIdentity,
            where: field(gi, ^column) in ^ids and not is_nil(gi.user_id),
            select: {field(gi, ^column), gi.user_id}
          )
        )

      username_by_user =
        rows
        |> Enum.map(&elem(&1, 1))
        |> Users.by_ids(:minimal)
        |> Map.new(fn user -> {user.id, e(user, :character, :username, nil)} end)

      rows
      |> Map.new(fn {ghost_id, user_id} -> {ghost_id, username_by_user[user_id]} end)
      |> Map.reject(fn {_ghost_id, username} -> is_nil(username) end)
    end
  end
end
