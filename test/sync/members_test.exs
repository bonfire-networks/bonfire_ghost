defmodule Bonfire.Ghost.Sync.MembersTest do
  # `async: false` because `Sync.Members` touches instance-scoped circles
  # (shared state) and provisions global Accounts.
  use Bonfire.Ghost.DataCase, async: false

  alias Bonfire.Boundaries.Circles
  alias Bonfire.Boundaries.Scaffold.Instance, as: InstanceScaffold
  alias Bonfire.Ghost.Sync.Members
  alias Bonfire.Ghost.Sync.Tiers
  alias Bonfire.Me.Accounts
  alias Bonfire.Me.Fake
  alias Bonfire.Me.Users

  @tier_free %{"id" => "t_free", "slug" => "free", "name" => "Free"}
  @tier_paid %{"id" => "t_paid", "slug" => "paid", "name" => "Paid"}

  defp member(email, opts \\ []) do
    %{
      "email" => email,
      "name" => Keyword.get(opts, :name, "Ghost Member"),
      "tiers" => Keyword.get(opts, :tiers, [])
    }
  end

  defp tier_circle(slug) do
    {:ok, circle} =
      Circles.get_by_name("ghost_tier:#{slug}", InstanceScaffold.admin_circle())

    circle
  end

  defp setup_tiers(tiers), do: Tiers.sync_tiers(tiers, [])

  describe "provision_from_ghost_member/1 — new member" do
    test "creates an account + user for a never-seen email" do
      setup_tiers([@tier_free])

      assert {:ok, user} = Members.provision_from_ghost_member(member("new@test.local"))
      assert user.id

      assert %{} = account = Accounts.get_by_email("new@test.local")
      assert [%{id: id} | _] = Users.by_account!(account)
      assert id == user.id
    end

    test "adds the user to the circles matching the ghost tiers" do
      setup_tiers([@tier_free, @tier_paid])

      {:ok, user} =
        Members.provision_from_ghost_member(member("tiered@test.local", tiers: [@tier_free]))

      circle_ids =
        InstanceScaffold.admin_circle()
        |> Circles.circles_containing_subject(user)
        |> Enum.map(& &1.id)

      assert tier_circle("free").id in circle_ids
      refute tier_circle("paid").id in circle_ids
    end

    test "silently skips tiers that haven't been synced locally yet" do
      setup_tiers([@tier_free])
      unsynced = %{"id" => "t_x", "slug" => "notsynced", "name" => "Not Synced"}

      {:ok, user} =
        Members.provision_from_ghost_member(
          member("partial@test.local", tiers: [@tier_free, unsynced])
        )

      circle_ids =
        InstanceScaffold.admin_circle()
        |> Circles.circles_containing_subject(user)
        |> Enum.map(& &1.id)

      assert tier_circle("free").id in circle_ids
      assert length(circle_ids) == 1
    end
  end

  describe "provision_from_ghost_member/1 — idempotency" do
    test "re-running with the same member does not create a new account" do
      setup_tiers([@tier_free])
      m = member("repeat@test.local", tiers: [@tier_free])

      {:ok, user_a} = Members.provision_from_ghost_member(m)
      {:ok, user_b} = Members.provision_from_ghost_member(m)

      assert user_a.id == user_b.id
    end
  end

  describe "provision_from_ghost_member/1 — handle collisions" do
    test "appends a numeric suffix when the derived handle is taken" do
      setup_tiers([])

      # Use the exact local part of the Ghost email as an existing username;
      # `Characters.clean_username` is identity on plain alphanumerics.
      taken = "taken"
      _existing = Fake.fake_user!(%{}, %{username: taken})

      {:ok, user} = Members.provision_from_ghost_member(member("#{taken}@test.local"))

      refute user.character.username == taken
      assert String.starts_with?(user.character.username, taken)
    end
  end

  describe "provision_from_ghost_member/1 — input validation" do
    test "returns :missing_email when the payload has no email" do
      assert {:error, :missing_email} = Members.provision_from_ghost_member(%{})

      assert {:error, :missing_email} =
               Members.provision_from_ghost_member(%{"email" => ""})
    end
  end

  describe "reconcile_circles/2 — tier changes" do
    test "moving a member from one tier to another adds the new and removes the old" do
      setup_tiers([@tier_free, @tier_paid])

      {:ok, user} =
        Members.provision_from_ghost_member(member("switch@test.local", tiers: [@tier_free]))

      {:ok, diff} =
        Members.reconcile_circles(user, member("switch@test.local", tiers: [@tier_paid]))

      assert diff.added == 1
      assert diff.removed == 1

      circle_ids =
        InstanceScaffold.admin_circle()
        |> Circles.circles_containing_subject(user)
        |> Enum.map(& &1.id)

      assert tier_circle("paid").id in circle_ids
      refute tier_circle("free").id in circle_ids
    end

    test "dropping all tiers removes the user from every ghost_tier circle" do
      setup_tiers([@tier_free, @tier_paid])

      {:ok, user} =
        Members.provision_from_ghost_member(
          member("drop@test.local", tiers: [@tier_free, @tier_paid])
        )

      {:ok, diff} = Members.reconcile_circles(user, member("drop@test.local", tiers: []))

      assert diff.removed == 2
      assert diff.added == 0

      remaining =
        InstanceScaffold.admin_circle()
        |> Circles.circles_containing_subject(user)
        |> Enum.filter(fn %{named: %{name: n}} -> String.starts_with?(n, "ghost_tier:") end)

      assert remaining == []
    end
  end

  describe "remove_member/1" do
    test "removes the user from every ghost_tier circle but keeps the account" do
      setup_tiers([@tier_free, @tier_paid])

      {:ok, user} =
        Members.provision_from_ghost_member(
          member("bye@test.local", tiers: [@tier_free, @tier_paid])
        )

      assert {:ok, %{removed: 2}} = Members.remove_member(%{"email" => "bye@test.local"})

      ghost =
        InstanceScaffold.admin_circle()
        |> Circles.circles_containing_subject(user)
        |> Enum.filter(fn %{named: %{name: n}} -> String.starts_with?(n, "ghost_tier:") end)

      assert ghost == []
      # Account still exists
      assert %{} = Accounts.get_by_email("bye@test.local")
    end

    test "is a no-op when the account doesn't exist" do
      assert {:ok, %{removed: 0}} =
               Members.remove_member(%{"email" => "nobody@test.local"})
    end
  end
end
