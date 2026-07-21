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

  doctest Bonfire.Ghost.AdminAPI,
    import: true,
    only: [escape_nql_string: 1, staff_active?: 1, staff_may_sign_in?: 1]

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

  describe "get_user_by_email/3 (staff lookup)" do
    # A filtered request is the fast path; the page scan is the fallback for addresses an
    # NQL `email:` filter cannot express. `+` is NQL's AND operator, so plus-addressed staff
    # (`berger+gramsci@…`) matched nothing and were told to go subscribe instead of being
    # let in. With hundreds of contributors the scan is expensive, so the tests also pin
    # that it does NOT run for ordinary addresses.
    defp stub_staff(pages) do
      test_pid = self()

      Repatch.patch(AdminAPI, :list_users, fn _client, opts ->
        case Keyword.get(opts, :filter) do
          "email:" <> _ = filter ->
            send(test_pid, {:filtered, filter})
            # a real Ghost cannot match a `+` (or a differing case) this way
            wanted = filter |> String.trim_leading("email:'") |> String.trim_trailing("'")

            found =
              pages
              |> Enum.flat_map(& &1["users"])
              |> Enum.filter(&(&1["email"] == wanted and not String.contains?(wanted, "+")))

            {:ok, %{"users" => found}}

          _ ->
            page = Keyword.get(opts, :page, 1)
            send(test_pid, {:scanned, page})
            {:ok, Enum.at(pages, page - 1, %{"users" => []})}
        end
      end)
    end

    defp page(users, next \\ nil) do
      %{"users" => users, "meta" => %{"pagination" => %{"next" => next}}}
    end

    defp staff(email), do: %{"id" => "s_#{email}", "email" => email, "status" => "active"}

    test "finds a plus-addressed staff user (the jacobin.social case)" do
      stub_staff([page([staff("other@example.com"), staff("berger+gramsci@example.com")])])

      assert {:ok, %{"users" => [%{"email" => "berger+gramsci@example.com"}]}} =
               AdminAPI.get_user_by_email(:client, "berger+gramsci@example.com")

      assert_received {:scanned, 1}
    end

    test "a plain address is still found when Ghost's email filter matches nothing" do
      # the jacobin.social failure: `/users/?filter=email:'…'` returns no rows even for a
      # plain address on an active staff record, so the filter must never be authoritative
      Repatch.patch(AdminAPI, :list_users, fn _client, opts ->
        if Keyword.get(opts, :filter) |> to_string() |> String.starts_with?("email:") do
          {:ok, %{"users" => []}}
        else
          {:ok, page([staff("magdalena.berger1801@gmail.com")])}
        end
      end)

      assert {:ok, %{"users" => [%{"email" => "magdalena.berger1801@gmail.com"}]}} =
               AdminAPI.get_user_by_email(:client, "magdalena.berger1801@gmail.com")
    end

    test "a filter REJECTED by Ghost still resolves via the scan" do
      # if Ghost 400s on the filter param itself, that must not read as "no such staff"
      Repatch.patch(AdminAPI, :list_users, fn _client, opts ->
        if Keyword.get(opts, :filter) |> to_string() |> String.starts_with?("email:") do
          {:error, {:api_error, 400, %{}}}
        else
          {:ok, page([staff("editor@example.com")])}
        end
      end)

      assert {:ok, %{"users" => [%{"email" => "editor@example.com"}]}} =
               AdminAPI.get_user_by_email(:client, "editor@example.com")
    end

    test "the filter is used as a fast path when it does work" do
      stub_staff([page([staff("editor@example.com")])])

      assert {:ok, %{"users" => [%{"email" => "editor@example.com"}]}} =
               AdminAPI.get_user_by_email(:client, "editor@example.com")

      assert_received {:filtered, _}
      refute_received {:scanned, _}
    end

    test "mixed-case input falls back and matches" do
      stub_staff([page([staff("editor@example.com")])])

      assert {:ok, %{"users" => [%{"email" => "editor@example.com"}]}} =
               AdminAPI.get_user_by_email(:client, "Editor@Example.com")
    end

    test "the scan walks pages until it finds the match" do
      stub_staff([
        page([staff("a@example.com")], 2),
        page([staff("wan+ted@example.com")])
      ])

      assert {:ok, %{"users" => [%{"email" => "wan+ted@example.com"}]}} =
               AdminAPI.get_user_by_email(:client, "wan+ted@example.com")

      assert_received {:scanned, 1}
      assert_received {:scanned, 2}
    end

    test "a plus-addressed stranger returns empty once the pages run out" do
      stub_staff([page([staff("someone@example.com")])])

      assert {:ok, %{"users" => []}} =
               AdminAPI.get_user_by_email(:client, "no+body@example.com")
    end

    test "an API error is propagated, never read as 'no such staff'" do
      Repatch.patch(AdminAPI, :list_users, fn _client, _opts -> {:error, :unauthorized} end)

      assert {:error, :unauthorized} = AdminAPI.get_user_by_email(:client, "editor@example.com")
    end

    test "the quote escaping still protects the filter it does use" do
      stub_staff([page([staff("a'b@example.com")])])
      AdminAPI.get_user_by_email(:client, "a'b@example.com")

      assert_received {:filtered, "email:'a\\'b@example.com'"}
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
