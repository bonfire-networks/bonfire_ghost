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
            ]
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

  ## Examples

      iex> Bonfire.Ghost.AdminAPI.get_member_by_email(client, "user@example.com")
      {:ok, %{"members" => [%{...}]}}
  """
  def get_member_by_email(client, email, opts \\ []) when is_binary(email) do
    list_members(client, Keyword.merge(opts, filter: "email:'#{email}'", limit: 1))
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
