defmodule Bonfire.Ghost.API do
  @moduledoc """
  Ghost Content API client.

  The Ghost Content API is a read-only API that provides access to published
  content on a Ghost site. Authentication is done via a Content API key passed
  as a query parameter.

  See: https://docs.ghost.org/content-api/
  """

  import Untangle

  @doc """
  Creates a new Req client configured for the Ghost Content API.

  ## Examples

      iex> client = Bonfire.Ghost.API.client("https://myblog.ghost.io", "abc123")
      %Req.Request{...}
  """
  def client(base_url, api_key) when is_binary(base_url) and is_binary(api_key) do
    Req.new(
      base_url: String.trim_trailing(base_url, "/") <> "/ghost/api/content",
      params: [key: api_key],
      headers: [{"accept-version", "v5.0"}]
    )
  end

  @doc """
  Lists posts from the Ghost blog.

  ## Options

    * `:limit` - Number of posts to return (default: 10)
    * `:page` - Page number for pagination
    * `:filter` - Ghost filter string (e.g., "tag:news")
    * `:include` - Related data to include (default: "tags,authors")

  ## Examples

      iex> Bonfire.Ghost.API.list_posts(client)
      {:ok, %{posts: [...], meta: %{...}}}
  """
  def list_posts(client, opts \\ []) do
    params =
      [
        limit: Keyword.get(opts, :limit, 10),
        include: Keyword.get(opts, :include, "tags,authors")
      ]
      |> maybe_add_param(:page, opts)
      |> maybe_add_param(:filter, opts)

    case Req.get(client, url: "/posts/", params: params) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        error(body, "Ghost API error (status #{status})")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        error(reason, "Ghost API request failed")
        {:error, reason}
    end
  end

  @doc """
  Gets a single post by its slug.

  ## Examples

      iex> Bonfire.Ghost.API.get_post_by_slug(client, "welcome-to-ghost")
      {:ok, %{posts: [%{...}]}}
  """
  def get_post_by_slug(client, slug) when is_binary(slug) do
    params = [include: "tags,authors"]

    case Req.get(client, url: "/posts/slug/#{slug}/", params: params) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 404, body: body}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status, body: body}} ->
        error(body, "Ghost API error (status #{status})")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        error(reason, "Ghost API request failed")
        {:error, reason}
    end
  end

  @doc """
  Gets a single post by its ID.

  ## Examples

      iex> Bonfire.Ghost.API.get_post_by_id(client, "abc123")
      {:ok, %{posts: [%{...}]}}
  """
  def get_post_by_id(client, id, opts \\ []) when is_binary(id) do
    fields = Keyword.get(opts, :fields, nil)

    params =
      [include: "tags,authors"]
      |> then(fn p -> if fields, do: [{:fields, fields} | p], else: p end)

    case Req.get(client, url: "/posts/#{id}/", params: params) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status, body: body}} ->
        error(body, "Ghost API error (status #{status})")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        error(reason, "Ghost API request failed")
        {:error, reason}
    end
  end

  @doc """
  Gets the Ghost site settings.

  ## Examples

      iex> Bonfire.Ghost.API.get_settings(client)
      {:ok, %{settings: %{...}}}
  """
  def get_settings(client) do
    case Req.get(client, url: "/settings/") do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        error(body, "Ghost API error (status #{status})")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        error(reason, "Ghost API request failed")
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
