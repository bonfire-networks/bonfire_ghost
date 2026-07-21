defmodule Bonfire.Ghost.TierGateEnforcementTest do
  @moduledoc """
  The tier gate must hold on **every** path that can create a login-capable account,
  not just the gated-login one.

  Regression for the hole that let a free Ghost member into a tier-gated instance:
  the gate lived only in `Bonfire.Ghost.LoginEmailProvider`, which
  `ForgotPasswordController.maybe_run_login_email_providers/1` consults *only when no
  local account matches the email*. The `member.added` webhook and the "Sync members"
  backfill provisioned accounts without consulting it — so signing up free on Ghost
  created a Bonfire account, and the next login found that account and never reached
  the gate. `gated_login_flow_test.exs` even asserts that bypass ("an existing local
  account is never gated"), which is only safe while these tests pass.
  """
  # `async: false` — patches instance-level Ghost helpers and writes instance-scoped settings.
  use Bonfire.Ghost.DataCase, async: false
  use Repatch.ExUnit

  alias Bonfire.Boundaries.Circles
  alias Bonfire.Boundaries.Scaffold.Instance, as: InstanceScaffold
  alias Bonfire.Ghost
  alias Bonfire.Ghost.AdminAPI
  alias Bonfire.Ghost.Sync.Members
  alias Bonfire.Ghost.Sync.Tiers
  alias Bonfire.Ghost.TierGate
  alias Bonfire.Ghost.Workers.MemberWebhookWorker
  alias Bonfire.Me.Accounts
  alias Bonfire.Me.Users

  @tier_free %{"id" => "t_free", "slug" => "free", "name" => "Free"}
  @tier_paid %{"id" => "t_paid", "slug" => "paid", "name" => "Paid"}

  setup do
    # The DB write is rolled back by the sandbox; what leaks between tests (and into
    # other files) is the instance-settings cache in app config — snapshot and restore.
    previous = Application.get_env(:bonfire_ghost, :required_tier)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:bonfire_ghost, :required_tier)
      else
        Application.put_env(:bonfire_ghost, :required_tier, previous)
      end
    end)

    Tiers.sync_tiers([@tier_free, @tier_paid], [])
    :ok
  end

  defp require_tiers(slugs) do
    Bonfire.Common.Settings.put([:bonfire_ghost, :required_tier], Map.new(slugs, &{&1, true}),
      scope: :instance,
      skip_boundary_check: true
    )

    :ok
  end

  defp member(email, tiers) do
    %{
      "id" => "ghost_member_#{email}",
      "email" => email,
      "name" => "A Member",
      "tiers" => tiers
    }
  end

  defp staff(email) do
    # a Ghost staff payload has NO "tiers" key at all
    %{
      "id" => "ghost_staff_1",
      "email" => email,
      "name" => "A Staffer",
      "slug" => "a-staffer",
      "status" => "active",
      "roles" => [%{"name" => "Contributor"}]
    }
  end

  defp tier_circle(slug) do
    {:ok, circle} = Circles.get_by_name("ghost_tier:#{slug}", InstanceScaffold.admin_circle())
    circle
  end

  describe "member.added / member.edited webhook" do
    test "a FREE member does not get an account when a paid tier is required" do
      require_tiers(["paid"])

      job = %Oban.Job{
        args: %{"event" => "member.added", "member" => member("free@test.local", [@tier_free])}
      }

      assert {:cancel, :tier_not_allowed} = MemberWebhookWorker.perform(job)
      refute Accounts.get_by_email("free@test.local")
    end

    test "a PAID member still gets an account" do
      require_tiers(["paid"])

      job = %Oban.Job{
        args: %{"event" => "member.added", "member" => member("paid@test.local", [@tier_paid])}
      }

      assert {:ok, _account} = MemberWebhookWorker.perform(job)
      assert Accounts.get_by_email("paid@test.local")
    end

    test "with no tier required, any member gets an account (gate off is the default)" do
      job = %Oban.Job{
        args: %{"event" => "member.added", "member" => member("any@test.local", [@tier_free])}
      }

      assert {:ok, _account} = MemberWebhookWorker.perform(job)
      assert Accounts.get_by_email("any@test.local")
    end

    test "a member who downgrades keeps their account but loses the tier circles" do
      # provisioned while the gate was off, with a profile and the paid circle
      {:ok, user} =
        Members.provision_from_ghost_member(member("downgrade@test.local", [@tier_paid]),
          create_user: true
        )

      assert Circles.is_encircled_by?(user, tier_circle("paid"))

      require_tiers(["paid"])

      job = %Oban.Job{
        args: %{
          "event" => "member.edited",
          "member" => member("downgrade@test.local", [@tier_free])
        }
      }

      assert {:cancel, :tier_not_allowed} = MemberWebhookWorker.perform(job)

      # account and profile survive (see the "Revocation stance" in the docs)…
      assert Accounts.get_by_email("downgrade@test.local")
      assert [_ | _] = Users.by_account!(Accounts.get_by_email("downgrade@test.local"))
      # …but gated access is revoked
      refute Circles.is_encircled_by?(user, tier_circle("paid"))
    end
  end

  describe "\"Sync members\" backfill" do
    setup do
      Repatch.patch(Ghost, :admin_configured?, fn -> true end)
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)

      Repatch.patch(AdminAPI, :list_members, fn :client, _opts ->
        {:ok,
         %{
           "members" => [
             member("backfill-free@test.local", [@tier_free]),
             member("backfill-paid@test.local", [@tier_paid])
           ],
           "meta" => %{"pagination" => %{"next" => nil}}
         }}
      end)

      :ok
    end

    test "provisions only members holding a required tier, counting the rest as skipped" do
      require_tiers(["paid"])

      assert {:ok, summary} = Members.sync_all([])
      assert summary.provisioned == 1
      assert summary.skipped == 1
      assert summary.errors == []

      assert Accounts.get_by_email("backfill-paid@test.local")
      refute Accounts.get_by_email("backfill-free@test.local")
    end

    test "provisions everyone when no tier is required" do
      assert {:ok, summary} = Members.sync_all([])
      assert summary.provisioned == 2
      assert summary.skipped == 0
    end
  end

  describe "exemptions" do
    test "staff are provisioned even when a tier is required (they have no tiers)" do
      require_tiers(["paid"])

      assert {:ok, _account} = Members.provision_from_ghost_staff(staff("staffer@test.local"))
      assert Accounts.get_by_email("staffer@test.local")
    end

    test "an explicit skip_tier_gate: true bypasses the gate" do
      require_tiers(["paid"])

      assert {:ok, _account} =
               Members.provision_from_ghost_member(member("bypass@test.local", [@tier_free]),
                 skip_tier_gate: true
               )
    end
  end

  describe "payloads that carry no tiers" do
    test "the tiers are fetched from Ghost rather than read as 'no tiers'" do
      require_tiers(["paid"])

      Repatch.patch(Ghost, :admin_configured?, fn -> true end)
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)

      Repatch.patch(AdminAPI, :get_member_by_email, fn :client, _email, _opts ->
        {:ok, %{"members" => [member("thin@test.local", [@tier_paid])]}}
      end)

      thin = Map.delete(member("thin@test.local", []), "tiers")

      assert {:ok, _account} = Members.provision_from_ghost_member(thin)
      assert Accounts.get_by_email("thin@test.local")
    end

    test "fails CLOSED when the tiers cannot be fetched" do
      require_tiers(["paid"])

      Repatch.patch(Ghost, :admin_configured?, fn -> true end)
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)

      Repatch.patch(AdminAPI, :get_member_by_email, fn :client, _email, _opts ->
        {:error, :ghost_unreachable}
      end)

      thin = Map.delete(member("unreachable@test.local", []), "tiers")

      assert {:skip, :tier_not_allowed} = Members.provision_from_ghost_member(thin)
      refute Accounts.get_by_email("unreachable@test.local")
    end
  end

  describe "TierGate.required_slugs/0" do
    test "is empty when nothing is toggled, so the gate is off" do
      assert TierGate.required_slugs() == []
      refute TierGate.enabled?()
    end

    test "ignores tiers toggled OFF and accepts the string \"true\" the UI writes" do
      Bonfire.Common.Settings.put(
        [:bonfire_ghost, :required_tier],
        %{"paid" => "true", "free" => "false"},
        scope: :instance,
        skip_boundary_check: true
      )

      assert TierGate.required_slugs() == ["paid"]
      assert TierGate.enabled?()
    end
  end
end
