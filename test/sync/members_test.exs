defmodule Bonfire.Ghost.Sync.MembersTest do
  # `async: false` because `Sync.Members` touches instance-scoped circles
  # (shared state) and provisions global Accounts.
  use Bonfire.Ghost.DataCase, async: false
  use Repatch.ExUnit

  alias Bonfire.Boundaries.Circles
  alias Bonfire.Boundaries.Scaffold.Instance, as: InstanceScaffold
  alias Bonfire.Ghost
  alias Bonfire.Ghost.AdminAPI
  alias Bonfire.Ghost.Sync.Members
  alias Bonfire.Ghost.Sync.Tiers
  alias Bonfire.Me.Accounts
  alias Bonfire.Me.Fake
  alias Bonfire.Me.Users

  @tier_free %{"id" => "t_free", "slug" => "free", "name" => "Free"}
  @tier_paid %{"id" => "t_paid", "slug" => "paid", "name" => "Paid"}

  defp member(email, opts \\ []) do
    base = %{
      "email" => email,
      "name" => Keyword.get(opts, :name, "Ghost Member"),
      "tiers" => Keyword.get(opts, :tiers, [])
    }

    case Keyword.get(opts, :slug) do
      nil -> base
      slug -> Map.put(base, "slug", slug)
    end
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

  describe "provision_from_ghost_member/1 — handle priority" do
    test "uses slug as first-choice username when present" do
      setup_tiers([])

      {:ok, user} =
        Members.provision_from_ghost_member(
          member("slug@test.local", slug: "myslug", name: "My Name")
        )

      assert user.character.username == "myslug"
    end

    test "falls back to name-derived handle when no slug" do
      setup_tiers([])

      {:ok, user} =
        Members.provision_from_ghost_member(member("noname@test.local", name: "Jane Doe"))

      assert user.character.username == "JaneDoe"
    end

    test "falls back to name when slug is taken" do
      setup_tiers([])
      _existing = Fake.fake_user!(%{}, %{username: "takenslug"})

      {:ok, user} =
        Members.provision_from_ghost_member(
          member("fallback@test.local", slug: "takenslug", name: "Jane Doe")
        )

      assert user.character.username == "JaneDoe"
    end

    test "appends a random numeric suffix when all base handles are taken" do
      setup_tiers([])
      _existing_slug = Fake.fake_user!(%{}, %{username: "takenslug"})
      _existing_name = Fake.fake_user!(%{}, %{username: "takenname"})

      {:ok, user} =
        Members.provision_from_ghost_member(
          member("collision@test.local", slug: "takenslug", name: "Takenname")
        )

      username = user.character.username
      refute username in ["takenslug", "takenname"]

      assert String.starts_with?(username, "takenslug") or
               String.starts_with?(username, "takenname")
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

  describe "sync_all/1 backfill" do
    test "provisions all paginated Ghost members into their tier circles" do
      setup_tiers([@tier_free, @tier_paid])

      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :ghost_client} end)

      Repatch.patch(AdminAPI, :list_members, fn :ghost_client, opts ->
        case Keyword.fetch!(opts, :page) do
          1 ->
            {:ok,
             %{
               "members" => [
                 member("free-backfill@test.local", tiers: [@tier_free])
               ],
               "meta" => %{"pagination" => %{"page" => 1, "next" => 2}}
             }}

          2 ->
            {:ok,
             %{
               "members" => [
                 member("paid-backfill@test.local", tiers: [@tier_paid])
               ],
               "meta" => %{"pagination" => %{"page" => 2, "next" => nil}}
             }}
        end
      end)

      assert {:ok, %{provisioned: 2, errors: []}} = Members.sync_all()

      free_user =
        "free-backfill@test.local"
        |> Accounts.get_by_email()
        |> Users.by_account!()
        |> hd()

      paid_user =
        "paid-backfill@test.local"
        |> Accounts.get_by_email()
        |> Users.by_account!()
        |> hd()

      assert Circles.is_encircled_by?(free_user, tier_circle("free"))
      refute Circles.is_encircled_by?(free_user, tier_circle("paid"))
      assert Circles.is_encircled_by?(paid_user, tier_circle("paid"))
    end

    test "resolves tier circles once for the whole run when tiers are passed in" do
      setup_tiers([@tier_free, @tier_paid])

      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :ghost_client} end)

      Repatch.patch(AdminAPI, :list_members, fn :ghost_client, _opts ->
        {:ok,
         %{
           "members" => [
             member("batch-free@test.local", tiers: [@tier_free]),
             member("batch-paid@test.local", tiers: [@tier_paid])
           ],
           "meta" => %{"pagination" => %{"page" => 1, "next" => nil}}
         }}
      end)

      assert {:ok, %{provisioned: 2, errors: []}} =
               Members.sync_all(tiers: [@tier_free, @tier_paid])

      free_user =
        "batch-free@test.local"
        |> Accounts.get_by_email()
        |> Users.by_account!()
        |> hd()

      paid_user =
        "batch-paid@test.local"
        |> Accounts.get_by_email()
        |> Users.by_account!()
        |> hd()

      assert Circles.is_encircled_by?(free_user, tier_circle("free"))
      assert Circles.is_encircled_by?(paid_user, tier_circle("paid"))
      refute Circles.is_encircled_by?(paid_user, tier_circle("free"))
    end

    test "uses a fresh Admin API client for each page" do
      setup_tiers([@tier_free, @tier_paid])
      parent = self()
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Repatch.patch(Ghost, :admin_client, fn ->
        page = Agent.get_and_update(agent, fn count -> {count + 1, count + 1} end)
        send(parent, {:admin_client_created, page})
        {:ok, {:ghost_client, page}}
      end)

      Repatch.patch(AdminAPI, :list_members, fn {:ghost_client, client_page}, opts ->
        page = Keyword.fetch!(opts, :page)
        assert client_page == page

        case page do
          1 ->
            {:ok,
             %{
               "members" => [
                 member("fresh-first@test.local", tiers: [@tier_free])
               ],
               "meta" => %{"pagination" => %{"page" => 1, "next" => 2}}
             }}

          2 ->
            {:ok,
             %{
               "members" => [
                 member("fresh-second@test.local", tiers: [@tier_paid])
               ],
               "meta" => %{"pagination" => %{"page" => 2, "next" => nil}}
             }}
        end
      end)

      assert {:ok, %{provisioned: 2, errors: []}} = Members.sync_all()

      assert_receive {:admin_client_created, 1}
      assert_receive {:admin_client_created, 2}
    end

    test "stops instead of looping when pagination does not advance" do
      setup_tiers([@tier_free])

      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :ghost_client} end)

      Repatch.patch(AdminAPI, :list_members, fn :ghost_client, _opts ->
        {:ok,
         %{
           "members" => [
             member("loop@test.local", tiers: [@tier_free])
           ],
           "meta" => %{"pagination" => %{"page" => 1, "next" => 1}}
         }}
      end)

      assert {:ok, %{provisioned: 1, errors: []}} = Members.sync_all()
    end
  end
end
