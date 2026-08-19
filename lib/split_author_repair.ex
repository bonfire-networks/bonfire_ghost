defmodule Bonfire.Ghost.SplitAuthorRepair do
  @moduledoc """
  One-off repair for split Ghost author identities: on an instance where the import provisioned a separate "shell" account per author (holding the Ghost articles + staff identity) while the person also had their own active/login account, this consolidates a pair.

  It moves the ghost-author profile onto the person's MAIN account (`Users.transfer_to_account/3`) and moves/merges its `Bonfire.Ghost.Identities` row there. Nothing is deleted except a redundant duplicate identity row when two must merge, because `account_id` is the identity table's primary key, we delete the conflicting row(s) and re-`link/2` a single merged row rather than repoint. 

  Articles keep their `creator_id` (they stay under the ghost profile). Idempotent.
  """

  import Untangle
  import Ecto.Query

  alias Bonfire.Common.Types
  alias Bonfire.Ghost
  alias Bonfire.Ghost.Identities
  alias Bonfire.Ghost.Identities.GhostIdentity
  alias Bonfire.Me.Users

  @doc """
  Moves `shell_user` onto `main_account`, then reconciles its Ghost identity. Three cases:

  - the shell already has a `GhostIdentity` → move/merge it onto `main_account` (`consolidate_identity`);
  - the shell has NONE but IS a ghost author → pass `create_staff_id:`/`create_member_id:` (+ optional `create_ghost_email:`) to CREATE the link on `main_account` (e.g. `magdalenaberger_18`);
  - the shell has no identity and no create-opts → pure co-location, returns `{:ok, :no_identity}` (a native-only duplicate profile, e.g. `magdalenaberger` dup).
  """
  def repair_split_author(main_account, shell_user, opts \\ []) do
    with {:ok, _user} <-
           Users.transfer_to_account(shell_user, main_account, skip_max_per_account: true) do
      reconcile_identity(main_account, shell_user, opts)
    end
  end

  defp reconcile_identity(main_account, shell_user, opts) do
    cond do
      Types.uid(shell_user) |> ghost_user_identity() ->
        consolidate_identity(main_account, shell_user)

      is_binary(opts[:create_staff_id]) or is_binary(opts[:create_member_id]) ->
        Identities.link(main_account,
          staff_id: opts[:create_staff_id],
          member_id: opts[:create_member_id],
          user: Types.uid(shell_user),
          ghost_email: opts[:create_ghost_email]
        )

      true ->
        {:ok, :no_identity}
    end
  end

  @doc """
  Moves the `GhostIdentity` for `ghost_user` onto `main_account`, merging with any identity already there (dual staff+member, pointing `user_id` at the ghost author). Idempotent: a no-op once the row already sits on `main_account`.
  """
  def consolidate_identity(main_account, ghost_user) do
    main_id = Types.uid(main_account)
    gu_id = Types.uid(ghost_user)

    shell_gid = gu_id && ghost_user_identity(gu_id)
    main_gid = main_id && Identities.get_by_account(main_id)

    cond do
      is_nil(main_id) or is_nil(gu_id) ->
        error(main_account, "Cannot consolidate identity without a main account and ghost user")

      is_nil(shell_gid) ->
        error(ghost_user, "No Ghost identity found for this author profile to consolidate")

      shell_gid.account_id == main_id ->
        # already consolidated onto the main account
        {:ok, shell_gid}

      true ->
        merge_onto_main(main_account, main_gid, shell_gid, gu_id)
    end
  end

  defp ghost_user_identity(gu_id) do
    Ghost.repo().one(from(gi in GhostIdentity, where: gi.user_id == ^gu_id))
  end

  # `account_id` is the PK, so we can't repoint the row: delete the conflicting row(s) and re-link a single merged row on the main account (staff+member converge, pointing at the ghost author).
  defp merge_onto_main(main_account, main_gid, shell_gid, gu_id) do
    fields = [
      staff_id: (main_gid && main_gid.ghost_staff_id) || shell_gid.ghost_staff_id,
      member_id: (main_gid && main_gid.ghost_member_id) || shell_gid.ghost_member_id,
      user: gu_id,
      ghost_email: (main_gid && main_gid.ghost_email) || shell_gid.ghost_email
    ]

    Ghost.repo().transaction(fn ->
      Ghost.repo().delete!(shell_gid)
      if main_gid, do: Ghost.repo().delete!(main_gid)

      case Identities.link(main_account, fields) do
        {:ok, gid} -> gid
        {:error, reason} -> Ghost.repo().rollback(reason)
      end
    end)
  end
end
