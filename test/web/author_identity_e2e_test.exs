defmodule Bonfire.Ghost.Web.AuthorIdentityE2eTest do
  @moduledoc """
  End-to-end repro of the author identity chain:

      article import provisions the author (account + profile, keyed on the Ghost
      staff email) → the author requests a magic link → clicks it → must land IN
      the author profile → later imports keep attributing to that same profile.

  Pins both the working chain and the split/takeover bug: when the Ghost staff
  email changes (or merely varies in case), email-keyed provisioning forks a
  SECOND account; the empty new account greets the author with "create a
  profile", and the new profile then captures attribution of subsequent
  imports, stranding the original author profile (observed on jacobin.social
  as @OleRauch vs @OleRauchContributor). The dual-ID identity mapping must turn
  the desired-behavior tests green.
  """

  # `async: false` — flips global login config and patches instance-level Ghost helpers.
  use Bonfire.Ghost.ConnCase, async: false
  use Repatch.ExUnit

  import Swoosh.TestAssertions

  alias Bonfire.Ghost
  alias Bonfire.Ghost.AdminAPI
  alias Bonfire.Ghost.Sync.Members
  alias Bonfire.Me.Accounts
  alias Bonfire.Me.Users

  setup do
    # gated deployments run passwordless; mirror that so the magic-link branch runs
    previous = Application.get_env(:bonfire_ui_me, :login, [])

    Application.put_env(
      :bonfire_ui_me,
      :login,
      Keyword.put(previous, :passwordless_only, true)
    )

    on_exit(fn -> Application.put_env(:bonfire_ui_me, :login, previous) end)

    :ok
  end

  defp staff(email, opts \\ []) do
    %{
      "id" => Keyword.fetch!(opts, :id),
      "email" => email,
      "name" => Keyword.get(opts, :name, "E2E Author"),
      "slug" => Keyword.get(opts, :slug, "e2e-author"),
      "status" => "active"
    }
  end

  # what the sign-in flow will find in Ghost: no member, this staff record
  defp stub_ghost(staff_payload) do
    Repatch.patch(Ghost, :admin_configured?, [force: true], fn -> true end)
    Repatch.patch(Ghost, :admin_client, [force: true], fn -> {:ok, :client} end)

    Repatch.patch(AdminAPI, :get_member_by_email, [force: true], fn :client, _email, _opts ->
      {:ok, %{"members" => []}}
    end)

    Repatch.patch(AdminAPI, :get_user_by_email, [force: true], fn :client, _email ->
      {:ok, %{"users" => [staff_payload]}}
    end)
  end

  # the exact call the article-import author path makes (embed_helper.ex `fetch_and_provision_staff`)
  defp import_author(payload), do: Members.provision_from_ghost_staff(payload, create_user: true)

  defp submit_forgot(email) do
    post(conn(), "/login/forgot-password", %{"forgot_password_fields" => %{"email" => email}})
  end

  # follows the actual link from the actual email — proves the whole delivery chain
  defp click_login_link! do
    assert_received {:email, mail}

    body = mail.text_body || mail.html_body

    assert [_, token] = Regex.run(~r{/login/forgot-password/([^\s?"'<]+)}, body),
           "no login link found in the sent email"

    get(conn(), "/login/forgot-password/#{token}")
  end

  defp unique_email(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}@test.local"

  test "working chain: import → sign-in with the SAME email → lands in the author profile → attribution stable" do
    email = unique_email("author")
    payload = staff(email, id: "s_happy")

    assert {:ok, author} = import_author(payload)
    assert %{} = account = Accounts.get_by_email(email)
    assert [%{id: author_id}] = Users.by_account!(account)
    assert author_id == author.id

    stub_ghost(payload)
    resp = submit_forgot(email)
    assert resp.resp_body =~ "Check your inbox"

    landed = click_login_link!()
    # exactly one profile in the account → auto-selected: the author IS logged in as the author
    assert get_session(landed, :current_user_id) == author.id

    # re-import attributes to the same profile, no duplicate identity
    assert {:ok, again} = import_author(payload)
    assert again.id == author.id
  end

  test "split chain (staff email changed in Ghost): sign-in with the NEW email reaches the SAME author account and imports keep attributing to it" do
    e1 = unique_email("before")
    e2 = unique_email("after")

    assert {:ok, author} = import_author(staff(e1, id: "s_split"))
    assert %{id: original_account_id} = Accounts.get_by_email(e1)

    # the staff record's email changes in Ghost; the author signs in with the new address
    stub_ghost(staff(e2, id: "s_split"))
    resp = submit_forgot(e2)
    assert resp.resp_body =~ "Check your inbox"

    # the identity FOLLOWED the email change instead of forking a second account
    assert %{id: resolved_id} = Accounts.get_by_email(e2)
    assert resolved_id == original_account_id
    refute Accounts.get_by_email(e1)

    landed = click_login_link!()
    assert get_session(landed, :current_user_id) == author.id

    # the takeover bug: a post-change import must still attribute to the original profile
    assert {:ok, again} = import_author(staff(e2, id: "s_split"))
    assert again.id == author.id
  end

  test "case-only email variance in the Ghost payload does not fork the identity" do
    email = unique_email("case")
    assert {:ok, author} = import_author(staff(email, id: "s_case"))

    varied = String.upcase(String.first(email)) <> String.slice(email, 1..-1//1)
    assert {:ok, again} = import_author(staff(varied, id: "s_case"))

    assert again.id == author.id
  end

  test "sign-in typed with different case still delivers the magic link into the author profile" do
    email = unique_email("lower")
    payload = staff(email, id: "s_typed")

    assert {:ok, author} = import_author(payload)

    # Ghost's email filter matches case-insensitively and returns the stored record
    stub_ghost(payload)
    typed = String.upcase(String.first(email)) <> String.slice(email, 1..-1//1)
    resp = submit_forgot(typed)
    assert resp.resp_body =~ "Check your inbox"

    landed = click_login_link!()
    assert get_session(landed, :current_user_id) == author.id
  end
end
