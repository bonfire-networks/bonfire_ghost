defmodule Bonfire.Ghost.SplitAuthorRepairTest do
  @moduledoc """
  Consolidating a split Ghost author: a person ended up with TWO accounts — their active/login
  account and a separate import-provisioned "shell" holding the Ghost articles + staff identity.
  The repair moves the ghost-author profile onto the main account and moves/merges its
  `GhostIdentity` there — WITHOUT deleting the profile or its articles (only a redundant duplicate
  identity row is dropped on a merge). Mirrors the jacobin.social cases (@joshua/@joshuastrack,
  @max_hsr/@maxhauser, …).
  """

  use Bonfire.Ghost.DataCase, async: false

  alias Bonfire.Ghost.Identities
  alias Bonfire.Ghost.SplitAuthorRepair
  alias Bonfire.Me.Fake
  alias Bonfire.Me.Users
  import Bonfire.Common.Enums, only: [id: 1]

  defp account_user_ids(account), do: Users.by_account!(account) |> Enum.map(&id/1)

  describe "repair_split_author/2" do
    test "moves the ghost profile + its GID onto the main account (main had no prior identity)" do
      main_account = Fake.fake_account!()
      _main_user = Fake.fake_user!(main_account)

      shell_account = Fake.fake_account!()
      ghost_user = Fake.fake_user!(shell_account)

      {:ok, _} =
        Identities.link(shell_account,
          staff_id: "staff_move",
          user: ghost_user,
          ghost_email: "g@x.test"
        )

      assert {:ok, _} = SplitAuthorRepair.repair_split_author(main_account, ghost_user)

      # profile transferred: the ghost author now lives under the main account
      assert id(ghost_user) in account_user_ids(main_account)

      # identity moved onto the main account, still pointing at the ghost author
      gid = Identities.get_by_account(main_account)
      assert gid.ghost_staff_id == "staff_move"
      assert gid.user_id == id(ghost_user)

      # the shell account no longer carries an identity row; the id resolves to main
      assert Identities.get_by_account(shell_account) == nil
      assert Identities.get_by_staff_id("staff_move").account_id == id(main_account)
    end

    test "merges into the main account's existing identity (dual-id: member on main + staff from shell)" do
      # Max shape: main account already holds a MEMBER identity; the shell holds the STAFF author
      main_account = Fake.fake_account!()
      main_user = Fake.fake_user!(main_account)

      {:ok, _} =
        Identities.link(main_account,
          member_id: "member_main",
          user: main_user,
          ghost_email: "m@x.test"
        )

      shell_account = Fake.fake_account!()
      ghost_user = Fake.fake_user!(shell_account)

      {:ok, _} =
        Identities.link(shell_account,
          staff_id: "staff_dual",
          user: ghost_user,
          ghost_email: "s@x.test"
        )

      assert {:ok, _} = SplitAuthorRepair.repair_split_author(main_account, ghost_user)

      gid = Identities.get_by_account(main_account)
      assert gid.ghost_member_id == "member_main"
      assert gid.ghost_staff_id == "staff_dual"
      # points at the ghost author (where the articles live), so future imports attribute there
      assert gid.user_id == id(ghost_user)

      # exactly ONE identity row for the person now; the shell row is gone; both ids resolve to main
      assert Identities.get_by_account(shell_account) == nil
      assert Identities.get_by_staff_id("staff_dual").account_id == id(main_account)
      assert Identities.get_by_member_id("member_main").account_id == id(main_account)
    end

    test "is idempotent (re-running changes nothing)" do
      main_account = Fake.fake_account!()
      _main = Fake.fake_user!(main_account)
      shell_account = Fake.fake_account!()
      ghost_user = Fake.fake_user!(shell_account)
      {:ok, _} = Identities.link(shell_account, staff_id: "staff_idem", user: ghost_user)

      assert {:ok, _} = SplitAuthorRepair.repair_split_author(main_account, ghost_user)
      assert {:ok, _} = SplitAuthorRepair.repair_split_author(main_account, ghost_user)

      assert id(ghost_user) in account_user_ids(main_account)
      assert Identities.get_by_staff_id("staff_idem").account_id == id(main_account)
      assert Identities.get_by_account(shell_account) == nil
    end

    test "creates the GID on the main account when the ghost author has none (Magdalena shape)" do
      # magdalenaberger_18: holds the articles but was never linked → no GID to move, must be created
      main_account = Fake.fake_account!()
      _main = Fake.fake_user!(main_account)
      shell_account = Fake.fake_account!()
      ghost_user = Fake.fake_user!(shell_account)

      assert {:ok, _} =
               SplitAuthorRepair.repair_split_author(main_account, ghost_user,
                 create_staff_id: "staff_created",
                 create_ghost_email: "mag@x.test"
               )

      assert id(ghost_user) in account_user_ids(main_account)
      gid = Identities.get_by_account(main_account)
      assert gid.ghost_staff_id == "staff_created"
      assert gid.user_id == id(ghost_user)

      # idempotent: the second run finds the freshly created GID and no-ops
      assert {:ok, _} =
               SplitAuthorRepair.repair_split_author(main_account, ghost_user,
                 create_staff_id: "staff_created"
               )

      assert Identities.get_by_staff_id("staff_created").account_id == id(main_account)
    end

    test "co-locates a native-only shell with no identity change (Magdalena's 2nd profile shape)" do
      # a profile with no GID and no articles: just move it under the main account, invent nothing
      main_account = Fake.fake_account!()
      _main = Fake.fake_user!(main_account)
      shell_account = Fake.fake_account!()
      native_user = Fake.fake_user!(shell_account)

      assert {:ok, :no_identity} =
               SplitAuthorRepair.repair_split_author(main_account, native_user)

      assert id(native_user) in account_user_ids(main_account)
      assert Identities.get_by_account(main_account) == nil
    end
  end
end
