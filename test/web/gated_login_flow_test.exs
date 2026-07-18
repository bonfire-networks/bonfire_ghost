defmodule Bonfire.Ghost.Web.GatedLoginFlowTest do
  @moduledoc """
  End-to-end conn tests for tier-gated login through the real entry point:

      POST /login/forgot-password
        → Bonfire.UI.Me.ForgotPasswordController.create/2
        → Bonfire.UI.Me.LoginEmailProvider.ensure/1   (behaviour auto-discovery)
        → Bonfire.Ghost.LoginEmailProvider.ensure_account/1
        → Bonfire.Ghost.Sync.Members.provision_from_ghost_member/1
        → magic-link email

  The provider unit tests call `ensure_account/1` directly and hand the dispatcher an explicit
  provider list, so nothing covered that the Ghost provider is actually discovered at runtime,
  that the controller consults providers only for UNKNOWN emails, or that allow/deny verdicts
  stay externally indistinguishable (the controller's neutral-response guarantee: gated login
  must not become an email-existence/membership oracle).
  """
  # `async: false` — patches instance-level Ghost helpers and flips global login config.
  use Bonfire.Ghost.ConnCase, async: false
  use Repatch.ExUnit

  import Swoosh.TestAssertions

  alias Bonfire.Ghost
  alias Bonfire.Ghost.AdminAPI
  alias Bonfire.Me.Accounts

  setup do
    # gated deployments run passwordless (GHOST_GATED_MODE sets this at startup); mirror
    # that here so the magic-link branch of the controller runs, restoring whatever the
    # test env had rather than deleting the whole :login branch
    previous = Application.get_env(:bonfire_ui_me, :login, [])

    Application.put_env(
      :bonfire_ui_me,
      :login,
      Keyword.put(previous, :passwordless_only, true)
    )

    on_exit(fn -> Application.put_env(:bonfire_ui_me, :login, previous) end)

    # The DB write is rolled back by the sandbox; what leaks into other tests is the
    # instance-settings cache in app config — snapshot and restore that (a DB write in
    # `on_exit` would fail anyway, sandbox ownership is already gone by then).
    previous_gate = Application.get_env(:bonfire_ghost, :required_tier)

    on_exit(fn ->
      if is_nil(previous_gate) do
        Application.delete_env(:bonfire_ghost, :required_tier)
      else
        Application.put_env(:bonfire_ghost, :required_tier, previous_gate)
      end
    end)

    put_required_tier(%{"free" => false, "paid" => true})

    :ok
  end

  defp put_required_tier(map) do
    Bonfire.Common.Settings.put([:bonfire_ghost, :required_tier], map,
      scope: :instance,
      skip_boundary_check: true
    )
  end

  defp stub_member_with_tiers(email, slugs) do
    member = %{
      "id" => "ghost_member_1",
      "email" => email,
      "name" => "A Member",
      "tiers" => Enum.map(slugs, &%{"slug" => &1, "name" => &1})
    }

    Repatch.patch(Ghost, :admin_configured?, fn -> true end)
    Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)

    Repatch.patch(AdminAPI, :get_member_by_email, fn :client, _email, _opts ->
      {:ok, %{"members" => [member]}}
    end)

    # the tier-gated (disallowed) branch falls back to a staff lookup — not staff here
    Repatch.patch(AdminAPI, :get_user_by_email, fn :client, _email ->
      {:ok, %{"users" => []}}
    end)

    :ok
  end

  defp unique_email, do: "gated-#{System.unique_integer([:positive])}@example.test"

  defp submit_forgot(email) do
    post(conn(), "/login/forgot-password", %{"forgot_password_fields" => %{"email" => email}})
  end

  test "an unknown email on an allowed tier is provisioned and mailed a magic link" do
    email = unique_email()
    stub_member_with_tiers(email, ["paid"])

    resp = submit_forgot(email)

    # neutral response...
    assert resp.resp_body =~ "Check your inbox"

    # ...but behind it the local account now exists (account-only: the member picks
    # their own handle at /create-user)...
    assert account = Accounts.get_by_email(email)
    assert Bonfire.Me.Users.by_account!(account) == []

    # ...and the magic sign-in link went out to them
    assert_email_sent(fn mail ->
      assert {_, ^email} = hd(mail.to)
    end)
  end

  test "an unknown email on a disallowed tier gets the SAME neutral response, no account, no email" do
    email = unique_email()
    stub_member_with_tiers(email, ["free"])

    resp = submit_forgot(email)

    # externally indistinguishable from the allowed case — the gate must not leak
    # membership status to whoever is typing emails into the form
    assert resp.resp_body =~ "Check your inbox"

    refute Accounts.get_by_email(email)
    # no external_signup_url is configured here, so not even a registration hint goes out
    refute_email_sent()
  end

  test "a non-member email is declined the same way" do
    email = unique_email()

    Repatch.patch(Ghost, :admin_configured?, fn -> true end)
    Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)

    Repatch.patch(AdminAPI, :get_member_by_email, fn :client, _email, _opts ->
      {:ok, %{"members" => []}}
    end)

    Repatch.patch(AdminAPI, :get_user_by_email, fn :client, _email ->
      {:ok, %{"users" => []}}
    end)

    resp = submit_forgot(email)

    assert resp.resp_body =~ "Check your inbox"
    refute Accounts.get_by_email(email)
    refute_email_sent()
  end

  test "an unknown STAFF email is provisioned and mailed a magic link (no tiers needed)" do
    # staff never appear in the Members API and Ghost sends no webhooks for them,
    # so the login-time staff lookup is their only provisioning path
    email = unique_email()

    Repatch.patch(Ghost, :admin_configured?, fn -> true end)
    Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)

    Repatch.patch(AdminAPI, :get_member_by_email, fn :client, _email, _opts ->
      {:ok, %{"members" => []}}
    end)

    Repatch.patch(AdminAPI, :get_user_by_email, fn :client, ^email ->
      {:ok,
       %{
         "users" => [
           %{
             "id" => "ghost_staff_1",
             "email" => email,
             "name" => "Casual Contributor",
             "status" => "active"
           }
         ]
       }}
    end)

    resp = submit_forgot(email)

    assert resp.resp_body =~ "Check your inbox"

    # account-only, like members — the staffer picks their own handle at /create-user
    assert account = Accounts.get_by_email(email)
    assert Bonfire.Me.Users.by_account!(account) == []

    assert_email_sent(fn mail ->
      assert {_, ^email} = hd(mail.to)
    end)
  end

  test "an existing local account is never gated: no Ghost lookup, magic link still sent" do
    # the tier gate only guards PROVISIONING of unknown emails — a local account
    # (admin, pre-Ghost user, ex-member) must keep its login even when Ghost would
    # deny them, and must not cost a Ghost round-trip on every login
    account = fake_account!()
    fake_user!(account)
    email = account.email.email_address

    test_pid = self()
    Repatch.patch(Ghost, :admin_configured?, fn -> true end)
    Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)

    Repatch.patch(AdminAPI, :get_member_by_email, fn :client, _e, _o ->
      send(test_pid, :ghost_was_consulted)
      {:ok, %{"members" => []}}
    end)

    resp = submit_forgot(email)

    assert resp.resp_body =~ "Check your inbox"
    refute_received :ghost_was_consulted

    assert_email_sent(fn mail ->
      assert {_, ^email} = hd(mail.to)
    end)
  end
end
