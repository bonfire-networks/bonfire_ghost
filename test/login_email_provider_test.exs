defmodule Bonfire.Ghost.LoginEmailProviderTest do
  @moduledoc """
  Tests the **shipped** gated-login provider.

  The previous version of this file aliased `Bonfire.Ghost.LoginEmailProvider` and then never
  called it: it defined a local `allowed?/2` that re-implemented the private `tier_allowed?/1`
  and asserted against that copy. It read as covered while protecting nothing — the real
  entrypoint (`ensure_account/1`), its Ghost API call, the `required_tier` config → slug
  extraction, provisioning, and the registration-hint branch all had zero coverage.

  This drives `ensure_account/1` itself, with the Ghost Admin API stubbed.
  """
  # `async: false` — patches instance-level Ghost helpers and instance config.
  use Bonfire.Ghost.DataCase, async: false

  import Swoosh.TestAssertions

  alias Bonfire.Ghost
  alias Bonfire.Ghost.AdminAPI
  alias Bonfire.Ghost.LoginEmailProvider

  @email "member@example.test"

  setup do
    # The DB write is rolled back by the sandbox; what leaks between tests (and into other
    # files) is the instance-settings cache in app config. It MUST be restored: since the
    # tier gate moved into `Sync.Members.provision_from_ghost_member/2`, a leaked
    # `required_tier` refuses provisioning in every later test file too (a whole wave of
    # `{:skip, :tier_not_allowed}` in members_test/identities_test). A DB write in
    # `on_exit` would fail anyway — sandbox ownership is already gone by then.
    previous = Application.get_env(:bonfire_ghost, :required_tier)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:bonfire_ghost, :required_tier)
      else
        Application.put_env(:bonfire_ghost, :required_tier, previous)
      end
    end)

    :ok
  end

  defp member(tiers) do
    %{
      "id" => "ghost_member_1",
      "email" => @email,
      "name" => "A Member",
      "tiers" => Enum.map(tiers, &%{"slug" => &1, "name" => &1})
    }
  end

  defp staff(status \\ "active") do
    # a Ghost staff payload has NO "tiers" key at all
    %{
      "id" => "ghost_staff_1",
      "email" => @email,
      "name" => "A Staffer",
      "slug" => "a-staffer",
      "status" => status,
      "roles" => [%{"name" => "Contributor"}]
    }
  end

  # Stub the Admin API so `ensure_account/1` runs its real logic against a known payload.
  # The staff lookup also runs for an allowed member so a dual member/staff identity can
  # resolve through its author link first. It always needs a stub — "no staff" by default.
  defp stub_members(result, staff_result \\ {:ok, %{"users" => []}}) do
    Repatch.patch(Ghost, :admin_configured?, fn -> true end)
    Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)

    Repatch.patch(AdminAPI, :get_member_by_email, fn :client, _email, _opts -> result end)
    Repatch.patch(AdminAPI, :get_user_by_email, fn :client, _email -> staff_result end)
    :ok
  end

  # The settings UI writes this at instance scope, keyed by tier slug
  # (`[:bonfire_ghost, :required_tier, slug] => true`), so write it the same way rather
  # than via `Process.put` — the provider reads it with an `:instance` scope.
  defp require_tiers(slugs), do: put_required_tier(Map.new(slugs, &{&1, true}))

  defp put_required_tier(map) do
    Bonfire.Common.Settings.put([:bonfire_ghost, :required_tier], map,
      scope: :instance,
      skip_boundary_check: true
    )

    :ok
  end

  describe "ensure_account/1 tier gating" do
    test "a member on an allowed tier is provisioned" do
      require_tiers(["paid"])
      stub_members({:ok, %{"members" => [member(["paid"])]}})

      assert {:ok, account} = LoginEmailProvider.ensure_account(@email)
      assert account

      # the local account really exists now — the magic-link flow can pick it up
      assert Bonfire.Me.Accounts.get_by_email(@email)
    end

    test "a member on a disallowed tier is not provisioned" do
      require_tiers(["paid"])
      stub_members({:ok, %{"members" => [member(["free"])]}})

      assert :no_match = LoginEmailProvider.ensure_account(@email)
      refute Bonfire.Me.Accounts.get_by_email(@email)
    end

    test "a member with several tiers is allowed when any one matches" do
      require_tiers(["paid"])
      stub_members({:ok, %{"members" => [member(["free", "paid"])]}})

      assert {:ok, _account} = LoginEmailProvider.ensure_account(@email)
    end

    test "a member with no tiers is denied when a tier is required" do
      require_tiers(["paid"])
      stub_members({:ok, %{"members" => [member([])]}})

      assert :no_match = LoginEmailProvider.ensure_account(@email)
    end

    test "when no tier is marked required, any member is allowed" do
      # Written explicitly (all-false) rather than left unset: instance settings are cached
      # outside the DB sandbox, so a value written by an earlier test in the same run leaks
      # into a test that relies on the setting being absent. Only `true` entries are
      # requirements, so all-false is the same branch as "nothing configured".
      put_required_tier(%{"paid" => false, "free" => false})
      stub_members({:ok, %{"members" => [member(["free"])]}})

      assert {:ok, _account} = LoginEmailProvider.ensure_account(@email)
    end

    test "a required_tier entry set to false does not grant access" do
      # the config is a map of slug => bool; only `true` entries are requirements
      put_required_tier(%{"paid" => true, "free" => false})
      stub_members({:ok, %{"members" => [member(["free"])]}})

      assert :no_match = LoginEmailProvider.ensure_account(@email)
    end
  end

  describe "ensure_account/1 non-member and failure paths" do
    test "an unknown email is not a match" do
      stub_members({:ok, %{"members" => []}})

      assert :no_match = LoginEmailProvider.ensure_account(@email)
      refute Bonfire.Me.Accounts.get_by_email(@email)
    end

    test "a Ghost API error is returned, not raised" do
      stub_members({:error, :unauthorized})

      assert {:error, :unauthorized} = LoginEmailProvider.ensure_account(@email)
    end

    test "when Ghost is not configured, it declines without raising" do
      Repatch.patch(Ghost, :admin_configured?, fn -> false end)
      Repatch.patch(Ghost, :admin_client, fn -> {:error, :not_configured} end)

      assert {:error, :not_configured} = LoginEmailProvider.ensure_account(@email)
    end

    test "a blank or non-binary email declines" do
      assert :no_match = LoginEmailProvider.ensure_account("")
      assert :no_match = LoginEmailProvider.ensure_account(nil)
    end

    test "a malformed email never reaches the Ghost API (M1 defence in depth)" do
      Repatch.patch(Ghost, :admin_configured?, fn -> true end)
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)

      test_pid = self()

      Repatch.patch(AdminAPI, :get_member_by_email, fn :client, _e, _o ->
        send(test_pid, :called_ghost)
        {:ok, %{"members" => []}}
      end)

      assert :no_match = LoginEmailProvider.ensure_account("not-an-email")
      assert :no_match = LoginEmailProvider.ensure_account("two words@example.test")
      assert :no_match = LoginEmailProvider.ensure_account("no-at-sign.example.test")

      refute_received :called_ghost
    end

    test "an apostrophe in the local part is a VALID email and is looked up in Ghost" do
      # Apostrophes are legal (and common: o'brien@...). The shape check must not reject them:
      # injection is already handled by `AdminAPI.escape_nql_string/1`, so excluding quotes here
      # bought nothing and locked real paying members out of gated login entirely.
      apostrophe = "o'brien@example.test"

      require_tiers(["paid"])

      Repatch.patch(Ghost, :admin_configured?, fn -> true end)
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)

      Repatch.patch(AdminAPI, :get_member_by_email, fn :client, ^apostrophe, _opts ->
        {:ok,
         %{
           "members" => [
             %{"email" => apostrophe, "tiers" => [%{"slug" => "paid", "name" => "Paid"}]}
           ]
         }}
      end)

      Repatch.patch(AdminAPI, :get_user_by_email, fn :client, ^apostrophe ->
        {:ok, %{"users" => []}}
      end)

      assert {:ok, _account} = LoginEmailProvider.ensure_account(apostrophe),
             "a paying member with an apostrophe in their address was refused a login"

      assert Bonfire.Me.Accounts.get_by_email(apostrophe)
    end
  end

  describe "ensure_account/1 staff fallback" do
    # Ghost staff (owner/admin/editor/author/contributor) are not members: they never
    # appear in the Members API and Ghost emits no webhooks for them, so the staff
    # lookup at login is their provisioning path.

    test "a staff user who is not a member is provisioned, bypassing the tier gate" do
      require_tiers(["paid"])
      stub_members({:ok, %{"members" => []}}, {:ok, %{"users" => [staff()]}})

      assert {:ok, _account} = LoginEmailProvider.ensure_account(@email)

      # account-only, like members: staff pick their own handle at /create-user
      assert account = Bonfire.Me.Accounts.get_by_email(@email)
      assert Bonfire.Me.Users.by_account!(account) == []
    end

    test "a member failing the tier gate who is ALSO staff is still provisioned" do
      # e.g. an editor subscribed to their own newsletter on the free tier
      require_tiers(["paid"])
      stub_members({:ok, %{"members" => [member(["free"])]}}, {:ok, %{"users" => [staff()]}})

      assert {:ok, _account} = LoginEmailProvider.ensure_account(@email)
      assert Bonfire.Me.Accounts.get_by_email(@email)
    end

    test "an email that is neither member nor staff stays :no_match" do
      stub_members({:ok, %{"members" => []}}, {:ok, %{"users" => []}})

      assert :no_match = LoginEmailProvider.ensure_account(@email)
      refute Bonfire.Me.Accounts.get_by_email(@email)
    end

    test "a staff-lookup API error is returned, not raised" do
      stub_members({:ok, %{"members" => []}}, {:error, :forbidden})

      assert {:error, :forbidden} = LoginEmailProvider.ensure_account(@email)
      refute Bonfire.Me.Accounts.get_by_email(@email)
    end

    test "a SUSPENDED staffer is not provisioned — Ghost-side offboarding is honored" do
      # suspension in Ghost sets status "inactive" and is the only offboarding control
      # for staff (no tiers to revoke), so it must gate the Bonfire side too
      stub_members({:ok, %{"members" => []}}, {:ok, %{"users" => [staff("inactive")]}})

      assert :no_match = LoginEmailProvider.ensure_account(@email)
      refute Bonfire.Me.Accounts.get_by_email(@email)
    end

    test "a LOCKED staffer IS provisioned — 'locked' means imported, not offboarded" do
      # Ghost's own `models/user.js`: "locked user: imported users, they get a random
      # password". It means they never set a GHOST password, which is irrelevant here —
      # Bonfire signs people in with its own magic link. Refusing them turned away 1522 of
      # jacobin.social's 1535 contributors, i.e. every bulk-imported author, who were told
      # to buy a subscription instead of reaching their own author profile.
      stub_members({:ok, %{"members" => []}}, {:ok, %{"users" => [staff("locked")]}})

      assert {:ok, _account} = LoginEmailProvider.ensure_account(@email)
      assert Bonfire.Me.Accounts.get_by_email(@email)
    end

    test "a staff payload with no status field fails closed" do
      stub_members(
        {:ok, %{"members" => []}},
        {:ok, %{"users" => [Map.delete(staff(), "status")]}}
      )

      assert :no_match = LoginEmailProvider.ensure_account(@email)
      refute Bonfire.Me.Accounts.get_by_email(@email)
    end

    test "warn-* statuses count as active (failed-login warnings, not suspension)" do
      stub_members({:ok, %{"members" => []}}, {:ok, %{"users" => [staff("warn-2")]}})

      assert {:ok, _account} = LoginEmailProvider.ensure_account(@email)
    end

    test "a member on an allowed tier is also checked for a staff identity" do
      require_tiers(["paid"])
      test_pid = self()

      Repatch.patch(Ghost, :admin_configured?, fn -> true end)
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)

      Repatch.patch(AdminAPI, :get_member_by_email, fn :client, _email, _opts ->
        {:ok, %{"members" => [member(["paid"])]}}
      end)

      Repatch.patch(AdminAPI, :get_user_by_email, fn :client, _email ->
        send(test_pid, :staff_lookup)
        {:ok, %{"users" => []}}
      end)

      assert {:ok, _account} = LoginEmailProvider.ensure_account(@email)
      assert_received :staff_lookup
    end

    test "a staff lookup failure does not turn away an otherwise allowed member" do
      require_tiers(["paid"])

      stub_members(
        {:ok, %{"members" => [member(["paid"])]}},
        {:error, :staff_endpoint_unavailable}
      )

      assert {:ok, _account} = LoginEmailProvider.ensure_account(@email)
      assert Bonfire.Me.Accounts.get_by_email(@email)
    end
  end

  describe "registration hint (L4)" do
    setup do
      Process.put([:bonfire_ui_me, :login, :external_signup_url], "https://blog.test/signup")
      :ok
    end

    test "a disallowed-tier member gets EXACTLY ONE registration hint through the dispatcher" do
      require_tiers(["paid"])
      stub_members({:ok, %{"members" => [member(["free"])]}})

      # go through the real dispatcher, which is what ForgotPasswordController calls.
      # It ALSO sends a hint when every provider returns :no_match — so if the Ghost
      # provider sends its own, the user is mailed twice for one login attempt.
      assert :no_match = Bonfire.UI.Me.LoginEmailProvider.ensure([LoginEmailProvider], @email)

      assert_email_sent(fn email ->
        assert {_, @email} = hd(email.to)
      end)

      refute_email_sent()
    end

    test "an upstream provider failure does not send a misleading registration hint" do
      stub_members({:error, :upstream_unavailable})

      assert :no_match = Bonfire.UI.Me.LoginEmailProvider.ensure([LoginEmailProvider], @email)
      refute_email_sent()
    end
  end
end
