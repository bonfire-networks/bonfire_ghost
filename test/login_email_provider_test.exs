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

  defp member(tiers) do
    %{
      "id" => "ghost_member_1",
      "email" => @email,
      "name" => "A Member",
      "tiers" => Enum.map(tiers, &%{"slug" => &1, "name" => &1})
    }
  end

  # Stub the Admin API so `ensure_account/1` runs its real logic against a known payload.
  defp stub_members(result) do
    Repatch.patch(Ghost, :admin_configured?, fn -> true end)
    Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)

    Repatch.patch(AdminAPI, :get_member_by_email, fn :client, _email, _opts -> result end)
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

      assert {:ok, _account} = LoginEmailProvider.ensure_account(apostrophe),
             "a paying member with an apostrophe in their address was refused a login"

      assert Bonfire.Me.Accounts.get_by_email(apostrophe)
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
  end
end
