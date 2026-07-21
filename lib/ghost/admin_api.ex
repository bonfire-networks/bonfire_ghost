defmodule Bonfire.Ghost.AdminAPI do
  @moduledoc """
  Ghost Admin API client.

  The Admin API provides full access to Ghost data including members,
  posts (draft/scheduled), users, and more. Authentication uses JWT tokens
  generated from an Admin API key.

  ## Admin API Key Format

  Admin API keys have the format `id:secret` where:
  - `id` is used as the JWT `kid` header
  - `secret` is hex-encoded and used to sign the JWT

  See: https://docs.ghost.org/admin-api/
  """

  import Untangle

  @token_expiry_seconds 5 * 60

  # Page size and cap for the staff-by-email fallback scan (see `get_user_by_email/3`).
  # Instances can have hundreds of contributors, so the scan is bounded.
  @staff_page_size 100
  @max_staff_scan_pages 20

  @doc """
  Creates a new Req client configured for the Ghost Admin API.

  ## Parameters

    * `base_url` - Your Ghost blog URL (e.g., "https://myblog.ghost.io")
    * `admin_api_key` - Admin API key in format "id:secret"

  ## Examples

      iex> {:ok, client} = Bonfire.Ghost.AdminAPI.client("https://myblog.ghost.io", "abc123:def456...")
      {:ok, %Req.Request{...}}
  """
  def client(base_url, admin_api_key) when is_binary(base_url) and is_binary(admin_api_key) do
    case generate_token(admin_api_key) do
      {:ok, token} ->
        client =
          Req.new(
            base_url: String.trim_trailing(base_url, "/") <> "/ghost/api/admin",
            headers: [
              {"authorization", "Ghost #{token}"},
              {"accept-version", "v5.0"}
            ],
            # see `Bonfire.Ghost.API.client/2`
            receive_timeout: Bonfire.Ghost.request_timeout(),
            retry: :safe_transient,
            max_retries: 1
          )

        {:ok, client}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generates a JWT token for Ghost Admin API authentication.

  The token is short-lived (5 minutes) and should be generated fresh for each request
  or batch of requests.
  """
  def generate_token(admin_api_key) when is_binary(admin_api_key) do
    case String.split(admin_api_key, ":") do
      [id, secret_hex] when byte_size(id) > 0 and byte_size(secret_hex) > 0 ->
        try do
          secret = Base.decode16!(secret_hex, case: :mixed)
          now = System.system_time(:second)

          header = %{"alg" => "HS256", "typ" => "JWT", "kid" => id}
          payload = %{"iat" => now, "exp" => now + @token_expiry_seconds, "aud" => "/admin/"}

          jwk = JOSE.JWK.from_oct(secret)
          {_, token} = JOSE.JWT.sign(jwk, header, payload) |> JOSE.JWS.compact()

          {:ok, token}
        rescue
          e ->
            error(e, "Failed to generate Ghost Admin API token")
            {:error, :invalid_api_key}
        end

      _ ->
        {:error, :invalid_api_key_format}
    end
  end

  @doc """
  Lists members from the Ghost blog.

  ## Options

    * `:limit` - Number of members to return (default: 15, max: varies by Ghost version)
    * `:page` - Page number for pagination
    * `:filter` - Ghost filter string (e.g., "status:paid", "subscribed:true")
    * `:order` - Sort order (e.g., "created_at desc")
    * `:include` - Related data to include (e.g., "labels,newsletters")

  ## Examples

      iex> Bonfire.Ghost.AdminAPI.list_members(client, limit: 50)
      {:ok, %{"members" => [...], "meta" => %{...}}}

      iex> Bonfire.Ghost.AdminAPI.list_members(client, filter: "status:paid")
      {:ok, %{"members" => [...], "meta" => %{...}}}
  """
  def list_members(client, opts \\ []) do
    params =
      [limit: Keyword.get(opts, :limit, 15)]
      |> maybe_add_param(:page, opts)
      |> maybe_add_param(:filter, opts)
      |> maybe_add_param(:order, opts)
      |> maybe_add_param(:include, opts)

    case Req.get(client, url: "/members/", params: params) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 401, body: body}} ->
        error(body, "Ghost Admin API authentication failed")
        {:error, :unauthorized}

      {:ok, %Req.Response{status: 403, body: body}} ->
        error(body, "Ghost Admin API access forbidden")
        {:error, :forbidden}

      {:ok, %Req.Response{status: status, body: body}} ->
        error(body, "Ghost Admin API error (status #{status})")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        error(reason, "Ghost Admin API request failed")
        {:error, reason}
    end
  end

  @doc """
  Gets a single member by ID.

  ## Options

    * `:include` - Related data to include (e.g., "labels,newsletters,subscriptions")

  ## Examples

      iex> Bonfire.Ghost.AdminAPI.get_member(client, "member-id-here")
      {:ok, %{"members" => [%{...}]}}
  """
  def get_member(client, member_id, opts \\ []) when is_binary(member_id) do
    params = maybe_add_param([], :include, opts)

    case Req.get(client, url: "/members/#{member_id}/", params: params) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: 401, body: body}} ->
        error(body, "Ghost Admin API authentication failed")
        {:error, :unauthorized}

      {:ok, %Req.Response{status: status, body: body}} ->
        error(body, "Ghost Admin API error (status #{status})")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        error(reason, "Ghost Admin API request failed")
        {:error, reason}
    end
  end

  @doc """
  Gets a member by email address.

  `email` is escaped before being interpolated into the NQL filter — on the gated-login
  path it is raw, unvalidated user input (the login-email providers run on the submitted
  form field before any changeset validation), so an unescaped quote would let a caller
  break out of the string literal and alter the query.

  ## Examples

      iex> Bonfire.Ghost.AdminAPI.get_member_by_email(client, "user@example.com")
      {:ok, %{"members" => [%{...}]}}
  """
  def get_member_by_email(client, email, opts \\ []) when is_binary(email) do
    list_members(
      client,
      Keyword.merge(opts, filter: "email:'#{escape_nql_string(email)}'", limit: 1)
    )
  end

  @doc """
  Escapes a value for use inside a single-quoted Ghost NQL string literal.

  Backslash must be escaped before the quote, or the backslash rule would double the one the
  quote rule just added. See https://ghost.org/docs/content-api/#filtering

  ## Examples

      iex> Bonfire.Ghost.AdminAPI.escape_nql_string("o'brien@example.com")
      "o\\\\'brien@example.com"

      iex> Bonfire.Ghost.AdminAPI.escape_nql_string("plain@example.com")
      "plain@example.com"
  """
  def escape_nql_string(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("'", "\\'")
  end

  @doc """
  Lists all tiers (membership levels) available on the Ghost site.

  ## Examples

      iex> Bonfire.Ghost.AdminAPI.list_tiers(client)
      {:ok, %{"tiers" => [...]}}
  """
  def list_tiers(client, opts \\ []) do
    params =
      []
      |> maybe_add_param(:limit, opts)
      |> maybe_add_param(:include, opts)

    case Req.get(client, url: "/tiers/", params: params) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        error(body, "Ghost Admin API error (status #{status})")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        error(reason, "Ghost Admin API request failed")
        {:error, reason}
    end
  end

  @doc """
  Lists posts via the Admin API.

  Unlike the Content API, the Admin endpoint returns the full `html` body for **gated** (members/paid) posts too — but only when `formats: "html"` is requested (the Admin API defaults to lexical/mobiledoc). Used by the historical article backfill so imported gated articles aren't truncated.

  ## Options

    * `:limit`   - posts per page (default: 50)
    * `:page`    - page number
    * `:formats` - content formats to include (default: "html")
    * `:include` - related data (default: "tags,authors")
    * `:filter`  - Ghost filter string (e.g. "status:published") — the Admin API
      returns drafts/scheduled posts too unless filtered

  ## Examples

      iex> Bonfire.Ghost.AdminAPI.list_posts(client, page: 1, filter: "status:published")
      {:ok, %{"posts" => [...], "meta" => %{...}}}
  """
  def list_posts(client, opts \\ []) do
    params =
      [
        limit: Keyword.get(opts, :limit, 50),
        formats: Keyword.get(opts, :formats, "html"),
        include: Keyword.get(opts, :include, "tags,authors")
      ]
      |> maybe_add_param(:page, opts)
      |> maybe_add_param(:filter, opts)

    case Req.get(client, url: "/posts/", params: params) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        error(body, "Ghost Admin API error (status #{status})")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        error(reason, "Ghost Admin API request failed")
        {:error, reason}
    end
  end

  @doc """
  Lists newsletters configured on the Ghost site.

  ## Examples

      iex> Bonfire.Ghost.AdminAPI.list_newsletters(client)
      {:ok, %{"newsletters" => [...]}}
  """
  def list_newsletters(client, opts \\ []) do
    params =
      []
      |> maybe_add_param(:limit, opts)
      |> maybe_add_param(:include, opts)

    case Req.get(client, url: "/newsletters/", params: params) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        error(body, "Ghost Admin API error (status #{status})")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        error(reason, "Ghost Admin API request failed")
        {:error, reason}
    end
  end

  @doc """
  Lists staff users (owner/admin/editor/author/contributor) from the Ghost blog.

  Staff are a separate Ghost entity from members — they never appear in `/members/`
  and Ghost emits no webhooks for them.

  ## Options

    * `:limit` - Number of users to return
    * `:page` - Page number for pagination
    * `:filter` - Ghost filter string (e.g., "email:'a@b.c'")
    * `:order` - Sort order (e.g., "created_at asc")
    * `:include` - Related data to include (e.g., "roles")

  ## Examples

      iex> Bonfire.Ghost.AdminAPI.list_users(client, limit: 50)
      {:ok, %{"users" => [...], "meta" => %{...}}}
  """
  def list_users(client, opts \\ []) do
    params =
      [limit: Keyword.get(opts, :limit, 15)]
      |> maybe_add_param(:page, opts)
      |> maybe_add_param(:filter, opts)
      |> maybe_add_param(:order, opts)
      |> maybe_add_param(:include, opts)

    case Req.get(client, url: "/users/", params: params) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 401, body: body}} ->
        error(body, "Ghost Admin API authentication failed")
        {:error, :unauthorized}

      {:ok, %Req.Response{status: 403, body: body}} ->
        error(body, "Ghost Admin API access forbidden")
        {:error, :forbidden}

      {:ok, %Req.Response{status: status, body: body}} ->
        error(body, "Ghost Admin API error (status #{status})")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        error(reason, "Ghost Admin API request failed")
        {:error, reason}
    end
  end

  @doc """
  Gets a staff user by email address, returned in the same shape as `list_users/2`
  (`{:ok, %{"users" => [user]}}`, or an empty list when nobody matches).

  An NQL `email:` filter is attempted first as a fast path, but it is NOT authoritative:
  observed against a real Ghost, `/users/?filter=email:'…'` matches nothing even for a
  plain address on an active staff record (and `+`, NQL's AND operator, cannot be expressed
  in it at all). A staffer wrongly reported as "not found" is told to buy a subscription
  instead of being signed in, so **any** miss or error falls through to walking the staff
  pages and matching locally — which is also case-insensitive.

  The scan is capped at `#{@max_staff_scan_pages}` pages of `#{@staff_page_size}`. On an
  instance with hundreds of contributors an unrecognised address therefore costs a handful
  of requests; the sign-in form is rate-limited, which keeps that bounded.

  Suspended and locked staff are intentionally still returned; `staff_active?/1` is what
  decides whether they may be provisioned, so callers can tell "no such staff" apart from
  "staff, but offboarded".

  ## Examples

      iex> Bonfire.Ghost.AdminAPI.get_user_by_email(client, "editor@example.com")
      {:ok, %{"users" => [%{...}]}}
  """
  def get_user_by_email(client, email, opts \\ []) when is_binary(email) do
    filtered =
      list_users(
        client,
        Keyword.merge(opts, filter: "email:'#{escape_nql_string(email)}'", limit: 1)
      )

    case filtered do
      {:ok, %{"users" => [_ | _]}} ->
        filtered

      # includes API errors: the filter itself may be what Ghost rejected, and the scan
      # propagates its own error if the problem is real (auth, permissions, outage)
      _miss_or_error ->
        scan_staff_by_email(client, String.downcase(email), 1, opts)
    end
  end

  defp scan_staff_by_email(_client, _wanted, page, _opts) when page > @max_staff_scan_pages do
    warn("Gave up scanning Ghost staff pages for a plus-addressed or mixed-case email")
    {:ok, %{"users" => []}}
  end

  defp scan_staff_by_email(client, wanted, page, opts) do
    case list_users(client, Keyword.merge(opts, limit: @staff_page_size, page: page)) do
      {:ok, %{"users" => users} = body} ->
        case Enum.find(users, &email_matches?(&1, wanted)) do
          nil ->
            case next_page(body) do
              nil -> {:ok, %{"users" => []}}
              next -> scan_staff_by_email(client, wanted, next, opts)
            end

          user ->
            {:ok, %{"users" => [user]}}
        end

      other ->
        other
    end
  end

  defp email_matches?(%{"email" => email}, wanted) when is_binary(email),
    do: String.downcase(email) == wanted

  defp email_matches?(_user, _wanted), do: false

  defp next_page(%{"meta" => %{"pagination" => %{"next" => next}}}) when is_integer(next),
    do: next

  defp next_page(%{"meta" => %{"pagination" => %{"next" => next}}}) when is_binary(next) do
    case Integer.parse(next) do
      {page, ""} -> page
      _ -> nil
    end
  end

  defp next_page(_body), do: nil

  # Ghost staff states, per Ghost core `models/user.js`:
  #   active, warn-1..warn-4 — can sign into Ghost (`warn-*` = failed-login warnings)
  #   locked                 — "imported users, they get a random password"; they have simply
  #                            never set a Ghost password, which says nothing about whether
  #                            they still work here. On jacobin.social this is 1522 of 1535
  #                            staff, i.e. essentially every bulk-imported contributor.
  #   inactive               — "owner user before blog setup, suspended users"; suspending in
  #                            the Ghost UI sets this. THE offboarding signal.
  @ghost_active_statuses ~w(active warn-1 warn-2 warn-3 warn-4)
  @signin_statuses @ghost_active_statuses ++ ~w(locked)

  @doc """
  NQL filter fragment matching staff who may be granted a Bonfire account — everything except suspended (`inactive`). Ghost's admin-context `/users/` browse returns suspended staff by default, so a query used to grant access must exclude them explicitly.
  """
  def signin_staff_filter, do: "status:[#{Enum.join(@signin_statuses, ",")}]"

  @doc """
  Whether a Ghost staff payload may be granted a Bonfire account.

  Bonfire signs people in with its own magic link and never touches Ghost credentials, so `"locked"` (imported, no Ghost password set) is NOT a reason to refuse — those are ordinary contributors who have simply never logged into Ghost. Only suspension (`"inactive"`) withholds access. Fails closed: a missing or unknown `"status"` counts as not allowed.

  ## Examples

      iex> Bonfire.Ghost.AdminAPI.staff_may_sign_in?(%{"status" => "active"})
      true

      iex> Bonfire.Ghost.AdminAPI.staff_may_sign_in?(%{"status" => "locked"})
      true

      iex> Bonfire.Ghost.AdminAPI.staff_may_sign_in?(%{"status" => "inactive"})
      false

      iex> Bonfire.Ghost.AdminAPI.staff_may_sign_in?(%{})
      false
  """
  def staff_may_sign_in?(user) when is_map(user), do: user["status"] in @signin_statuses
  def staff_may_sign_in?(_), do: false

  @doc """
  Whether the staffer can authenticate against Ghost itself (i.e. has a usable Ghost password). Not the sign-in gate — see `staff_may_sign_in?/1`.

  ## Examples

      iex> Bonfire.Ghost.AdminAPI.staff_active?(%{"status" => "active"})
      true

      iex> Bonfire.Ghost.AdminAPI.staff_active?(%{"status" => "locked"})
      false
  """
  def staff_active?(user) when is_map(user), do: user["status"] in @ghost_active_statuses
  def staff_active?(_), do: false

  @doc """
  Gets a Ghost staff user by their Ghost user ID.

  Returns the user map including `email` and `name`.
  """
  def get_user(client, ghost_user_id) when is_binary(ghost_user_id) do
    case Req.get(client, url: "/users/#{ghost_user_id}/") do
      {:ok, %Req.Response{status: 200, body: %{"users" => [user | _]}}} ->
        {:ok, user}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: 401, body: body}} ->
        error(body, "Ghost Admin API authentication failed")
        {:error, :unauthorized}

      {:ok, %Req.Response{status: status, body: body}} ->
        error(body, "Ghost Admin API error (status #{status})")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        error(reason, "Ghost Admin API request failed")
        {:error, reason}
    end
  end

  defp maybe_add_param(params, key, opts) do
    case Keyword.get(opts, key) do
      nil -> params
      value -> Keyword.put(params, key, value)
    end
  end
end
