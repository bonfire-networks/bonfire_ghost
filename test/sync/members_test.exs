defmodule Bonfire.Ghost.Sync.MembersTest do
  # `async: false` because `Sync.Members` touches instance-scoped circles
  # (shared state) and provisions global Accounts.
  use Bonfire.Ghost.DataCase, async: false
  use Repatch.ExUnit
  use Bonfire.Common.Settings
  use Bonfire.Common.E

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

  describe "provision_from_ghost_member/1 — new member (account-only by default)" do
    test "creates an ACCOUNT with NO user — members pick their own handle later" do
      setup_tiers([@tier_free])

      assert {:ok, account} = Members.provision_from_ghost_member(member("new@test.local"))
      assert %Bonfire.Data.Identity.Account{} = account

      # the account exists but no user/username was auto-derived from Ghost
      assert %{} = account = Accounts.get_by_email("new@test.local")
      assert Users.by_account!(account) == []
    end

    test "with create_user: true creates account + user (article-author path)" do
      setup_tiers([@tier_free])

      assert {:ok, user} =
               Members.provision_from_ghost_member(member("author@test.local"), create_user: true)

      assert user.id
      assert user.character.username

      account = Accounts.get_by_email("author@test.local")
      assert [%{id: id} | _] = Users.by_account!(account)
      assert id == user.id
    end

    test "stashes the member's display name on the account (for /create-user prefill)" do
      setup_tiers([@tier_paid])

      {:ok, _account} =
        Members.provision_from_ghost_member(
          member("stash@test.local", name: "Real Name", tiers: [@tier_paid])
        )

      account =
        Accounts.get_by_email("stash@test.local")
        |> Bonfire.Common.Repo.maybe_preload(:settings)

      stashed =
        Bonfire.Common.Settings.get([:bonfire_ghost, :member], nil, current_account: account)

      assert e(stashed, :name, nil) == "Real Name"
    end

    test "reconciles tier circles for ALL profiles when the account already has users" do
      setup_tiers([@tier_paid])

      # an account with two profiles
      {:ok, u1} =
        Members.provision_from_ghost_member(member("multi@test.local"), create_user: true)

      account = Accounts.get_by_email("multi@test.local")

      {:ok, u2} =
        Users.create(
          %{profile: %{name: "Second"}, character: %{username: "multi_second_x"}},
          account
        )

      # an account-only sync/webhook granting the paid tier
      assert {:ok, _account} =
               Members.provision_from_ghost_member(
                 member("multi@test.local", tiers: [@tier_paid])
               )

      assert Circles.is_encircled_by?(u1, tier_circle("paid"))
      assert Circles.is_encircled_by?(u2, tier_circle("paid"))
    end

    test "adds the user to the circles matching the ghost tiers (author/full path)" do
      setup_tiers([@tier_free, @tier_paid])

      {:ok, user} =
        Members.provision_from_ghost_member(member("tiered@test.local", tiers: [@tier_free]),
          create_user: true
        )

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
          member("partial@test.local", tiers: [@tier_free, unsynced]),
          create_user: true
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

      {:ok, account_a} = Members.provision_from_ghost_member(m)
      {:ok, account_b} = Members.provision_from_ghost_member(m)

      assert account_a.id == account_b.id
    end
  end

  # only the AUTHOR path (create_user: true) derives a username; regular members
  # pick their own handle via /create-user
  describe "provision_from_ghost_member/1 — handle priority (author path)" do
    test "uses slug as first-choice username when present" do
      setup_tiers([])

      {:ok, user} =
        Members.provision_from_ghost_member(
          member("slug@test.local", slug: "myslug", name: "My Name"),
          create_user: true
        )

      assert user.character.username == "myslug"
    end

    test "falls back to name-derived handle when no slug" do
      setup_tiers([])

      {:ok, user} =
        Members.provision_from_ghost_member(member("noname@test.local", name: "Jane Doe"),
          create_user: true
        )

      assert user.character.username == "JaneDoe"
    end

    test "falls back to name when slug is taken" do
      setup_tiers([])
      _existing = Fake.fake_user!(%{}, %{username: "takenslug"})

      {:ok, user} =
        Members.provision_from_ghost_member(
          member("fallback@test.local", slug: "takenslug", name: "Jane Doe"),
          create_user: true
        )

      assert user.character.username == "JaneDoe"
    end

    test "appends a random numeric suffix when all base handles are taken" do
      setup_tiers([])
      _existing_slug = Fake.fake_user!(%{}, %{username: "takenslug"})
      _existing_name = Fake.fake_user!(%{}, %{username: "takenname"})

      {:ok, user} =
        Members.provision_from_ghost_member(
          member("collision@test.local", slug: "takenslug", name: "Takenname"),
          create_user: true
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

  describe "reconcile_on_signup/1 — circles attached at profile creation" do
    test "attaches ghost_tier circles to a newly-created profile of a Ghost account" do
      setup_tiers([@tier_paid])

      {:ok, account} =
        Members.provision_from_ghost_member(
          member("hook@test.local", name: "Hooky", tiers: [@tier_paid])
        )

      {:ok, user} =
        Users.create(
          %{profile: %{name: "Hooky"}, character: %{username: "hook_user_zz"}},
          account
        )

      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)

      Repatch.patch(AdminAPI, :get_member_by_email, fn :client, "hook@test.local", _opts ->
        {:ok, %{"members" => [member("hook@test.local", tiers: [@tier_paid])]}}
      end)

      assert :ok = Members.reconcile_on_signup(user)
      assert Circles.is_encircled_by?(user, tier_circle("paid"))
    end

    test "is a no-op for a non-Ghost account (no marker → no Ghost call, no circles)" do
      setup_tiers([@tier_paid])
      user = Fake.fake_user!()

      assert :ok = Members.reconcile_on_signup(user)
      refute Circles.is_encircled_by?(user, tier_circle("paid"))
    end

    test "registered after_signup hook fires on a real Users.create and attaches tier circles" do
      # End-to-end: a Ghost member provisioned account-only picks their handle via the normal
      # profile-creation path; the after_signup_hooks entry (registered in runtime_config.ex)
      # must fire and attach their ghost_tier circles — no direct reconcile_on_signup call here.
      setup_tiers([@tier_paid])

      {:ok, account} =
        Members.provision_from_ghost_member(
          member("e2e@test.local", name: "E2E Member", tiers: [@tier_paid])
        )

      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)

      Repatch.patch(AdminAPI, :get_member_by_email, fn :client, "e2e@test.local", _opts ->
        {:ok, %{"members" => [member("e2e@test.local", tiers: [@tier_paid])]}}
      end)

      {:ok, user} =
        Users.create(
          %{profile: %{name: "Chosen Name"}, character: %{username: "e2e_chosen_zz"}},
          account
        )

      assert Circles.is_encircled_by?(user, tier_circle("paid"))
    end
  end

  describe "reconcile_circles/2 — tier changes" do
    test "moving a member from one tier to another adds the new and removes the old" do
      setup_tiers([@tier_free, @tier_paid])

      {:ok, user} =
        Members.provision_from_ghost_member(member("switch@test.local", tiers: [@tier_free]),
          create_user: true
        )

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
          member("drop@test.local", tiers: [@tier_free, @tier_paid]),
          create_user: true
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
          member("bye@test.local", tiers: [@tier_free, @tier_paid]),
          create_user: true
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

    test "removes tier circles from ALL profiles on the account" do
      setup_tiers([@tier_paid])

      {:ok, u1} =
        Members.provision_from_ghost_member(member("multirem@test.local", tiers: [@tier_paid]),
          create_user: true
        )

      account = Accounts.get_by_email("multirem@test.local")

      {:ok, u2} =
        Users.create(
          %{profile: %{name: "Second"}, character: %{username: "multirem_second_x"}},
          account
        )

      # grant u2 the tier too (account-only reconcile hits all profiles)
      {:ok, _} =
        Members.provision_from_ghost_member(member("multirem@test.local", tiers: [@tier_paid]))

      assert Circles.is_encircled_by?(u2, tier_circle("paid"))

      assert {:ok, %{removed: 2}} = Members.remove_member(%{"email" => "multirem@test.local"})
      refute Circles.is_encircled_by?(u1, tier_circle("paid"))
      refute Circles.is_encircled_by?(u2, tier_circle("paid"))
    end
  end

  describe "sync_all/1 backfill (account-only)" do
    test "provisions all paginated Ghost members into ACCOUNTS (no user/circles yet)" do
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

      # accounts exist for both members …
      assert %{} = free_account = Accounts.get_by_email("free-backfill@test.local")
      assert %{} = Accounts.get_by_email("paid-backfill@test.local")
      # … but no user/username/circle is auto-derived (that happens at /create-user)
      assert Users.by_account!(free_account) == []
    end

    test "member with an existing user still gets their circles reconciled by the backfill" do
      setup_tiers([@tier_free, @tier_paid])

      # a member who already created their Bonfire profile before this backfill run
      {:ok, existing} =
        Members.provision_from_ghost_member(member("existing@test.local", tiers: []),
          create_user: true
        )

      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :ghost_client} end)

      Repatch.patch(AdminAPI, :list_members, fn :ghost_client, _opts ->
        {:ok,
         %{
           "members" => [
             member("existing@test.local", tiers: [@tier_paid])
           ],
           "meta" => %{"pagination" => %{"page" => 1, "next" => nil}}
         }}
      end)

      assert {:ok, %{provisioned: 1, errors: []}} =
               Members.sync_all(tiers: [@tier_free, @tier_paid])

      assert Circles.is_encircled_by?(existing, tier_circle("paid"))
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

  # a Ghost staff payload — note there is NO "tiers" key at all
  defp staff(email, opts \\ []) do
    %{
      "id" => Keyword.get(opts, :id, "ghost_staff_#{email}"),
      "email" => email,
      "name" => Keyword.get(opts, :name, "Ghost Staffer"),
      "slug" => Keyword.get(opts, :slug, "ghost-staffer"),
      "status" => Keyword.get(opts, :status, "active"),
      "roles" => [%{"name" => Keyword.get(opts, :role, "Editor")}]
    }
  end

  describe "sync_all_staff/1 backfill (account-only)" do
    test "provisions all paginated Ghost staff into ACCOUNTS (no user/circles)" do
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :ghost_client} end)

      Repatch.patch(AdminAPI, :list_users, fn :ghost_client, opts ->
        # suspended/locked staff are excluded server-side — the filter must always be sent
        assert Keyword.fetch!(opts, :filter) == AdminAPI.active_staff_filter()

        case Keyword.fetch!(opts, :page) do
          1 ->
            {:ok,
             %{
               "users" => [staff("editor-backfill@test.local")],
               "meta" => %{"pagination" => %{"page" => 1, "next" => 2}}
             }}

          2 ->
            {:ok,
             %{
               "users" => [staff("contributor-backfill@test.local", role: "Contributor")],
               "meta" => %{"pagination" => %{"page" => 2, "next" => nil}}
             }}
        end
      end)

      assert {:ok, %{provisioned: 2, errors: []}} = Members.sync_all_staff()

      assert %{} = editor_account = Accounts.get_by_email("editor-backfill@test.local")
      assert %{} = Accounts.get_by_email("contributor-backfill@test.local")
      # account-only: staff pick their own handle at /create-user, like members
      assert Users.by_account!(editor_account) == []
    end

    test "a staffer with an existing profile keeps their ghost_tier circles (no wipe, no member lookup)" do
      setup_tiers([@tier_paid])

      # a staffer who is ALSO a paying member and already created their profile
      {:ok, user} =
        Members.provision_from_ghost_member(
          member("staffpaid@test.local", tiers: [@tier_paid]),
          create_user: true
        )

      assert Circles.is_encircled_by?(user, tier_circle("paid"))

      test_pid = self()
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :ghost_client} end)

      Repatch.patch(AdminAPI, :list_users, fn :ghost_client, _opts ->
        {:ok,
         %{
           "users" => [staff("staffpaid@test.local")],
           "meta" => %{"pagination" => %{"page" => 1, "next" => nil}}
         }}
      end)

      # reconcile is skipped outright (reconcile_tiers: false) — a tiers-less staff payload
      # must neither wipe circles nor cost an authoritative member-tier lookup per staffer
      Repatch.patch(AdminAPI, :get_member_by_email, fn _c, _e, _o ->
        send(test_pid, :member_lookup)
        {:ok, %{"members" => []}}
      end)

      assert {:ok, %{provisioned: 1, errors: []}} = Members.sync_all_staff()

      assert Circles.is_encircled_by?(user, tier_circle("paid"))
      refute_received :member_lookup
    end

    test "an upstream failure returns an error so the backfill job can retry" do
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :ghost_client} end)
      Repatch.patch(AdminAPI, :list_users, fn :ghost_client, _opts -> {:error, :forbidden} end)

      assert {:error, :forbidden} = Members.sync_all_staff()
    end

    test "does not stamp a pre-existing account that already has a profile as Ghost-provisioned" do
      # e.g. the instance admin, whose email matches the Ghost site owner: their account
      # predates Ghost and must not get the member marker (or a name prefill) re-written
      # on every backfill run
      account = Fake.fake_account!()
      _user = Fake.fake_user!(account)
      email = account.email.email_address

      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :ghost_client} end)

      Repatch.patch(AdminAPI, :list_users, fn :ghost_client, _opts ->
        {:ok,
         %{
           "users" => [staff(email, name: "Ghost Owner")],
           "meta" => %{"pagination" => %{"page" => 1, "next" => nil}}
         }}
      end)

      assert {:ok, %{provisioned: 1, errors: []}} = Members.sync_all_staff()

      account =
        Accounts.get_by_email(email)
        |> Bonfire.Common.Repo.maybe_preload(:settings)

      assert Bonfire.Common.Settings.get([:bonfire_ghost, :member], nil, current_account: account) ==
               nil

      assert Bonfire.Common.Settings.get([Bonfire.Me.Users, :suggested_profile_name], nil,
               current_account: account
             ) == nil
    end
  end
end
