defmodule Bonfire.Ghost.AdminAPIFilterTest do
  @moduledoc """
  Regression tests for NQL filter construction in the Ghost Admin API client.

  `get_member_by_email/3` interpolates an email into a Ghost NQL filter string. On the
  gated-login path that email is **unvalidated user input** — `ForgotPasswordController.create/2`
  runs the login-email providers on the raw form field before any changeset validation — so a
  value containing a quote must not be able to break out of the string literal.
  """
  # `async: false` — patches a module function.
  use Bonfire.Ghost.DataCase, async: false

  alias Bonfire.Ghost.AdminAPI

  doctest Bonfire.Ghost.AdminAPI, import: true, only: [escape_nql_string: 1]

  # Capture the filter `get_member_by_email/3` hands to `list_members/2`, without HTTP.
  defp captured_filter(email) do
    Repatch.patch(AdminAPI, :list_members, fn _client, opts ->
      send(self(), {:filter, Keyword.get(opts, :filter)})
      {:ok, %{"members" => []}}
    end)

    AdminAPI.get_member_by_email(:client, email)

    receive do
      {:filter, filter} -> filter
    after
      0 -> flunk("list_members was never called")
    end
  end

  describe "get_member_by_email/3 NQL escaping (M1)" do
    test "a plain email produces the expected filter" do
      assert captured_filter("user@example.com") == "email:'user@example.com'"
    end

    test "a quote in the email cannot break out of the NQL string literal" do
      filter = captured_filter("a'b@example.com")

      refute filter == "email:'a'b@example.com'",
             "unescaped quote broke out of the NQL string literal — filter is injectable"

      assert filter == "email:'a\\'b@example.com'"
    end

    test "a backslash is escaped (so it can't escape the escaping)" do
      filter = captured_filter("a\\'b@example.com")

      assert filter == "email:'a\\\\\\'b@example.com'"
    end

    test "an injection attempt that would alter the filter is neutralised" do
      # would otherwise close the literal and append a disjunction matching every member
      filter = captured_filter("x' + status:paid,email:~'")

      refute filter =~ ~r/[^\\]' \+ status:paid/,
             "injected NQL operators reached the filter unescaped"
    end
  end
end
