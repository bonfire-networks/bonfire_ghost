defmodule Bonfire.Ghost do
  @moduledoc """
  Ghost blog integration for Bonfire.

  This extension provides integration with Ghost CMS via both the Content API
  (for public posts) and Admin API (for members, drafts, etc.).

  ## Configuration

  Add to your config:

      config :bonfire_ghost,
        ghost_url: "https://your-blog.ghost.io",
        content_api_key: "your_content_api_key_here",
        admin_api_key: "id:secret_hex"  # Optional, for member access

  ## Usage

      # Check if configured
      Bonfire.Ghost.configured?()

      # List recent posts (Content API)
      Bonfire.Ghost.list_posts(limit: 5)

      # Get a specific post
      Bonfire.Ghost.get_post("my-post-slug")

      # List members (Admin API - requires admin_api_key)
      Bonfire.Ghost.list_members(limit: 50)

      # Get member by email
      Bonfire.Ghost.get_member_by_email("user@example.com")
  """

  use Bonfire.Common.Config
  use Bonfire.Common.Localise
  import Untangle
  import Bonfire.Common.Modularity.DeclareHelpers

  alias Bonfire.Ghost.API
  alias Bonfire.Ghost.AdminAPI

  declare_extension(
    "Bonfire.Ghost",
    icon: "bi:newspaper",
    description: l("Ghost blog integration")
  )

  def repo, do: Config.repo()

  @doc "Returns the configured Ghost blog URL, or nil if not configured."
  def ghost_url do
    Config.get([:bonfire_ghost, :ghost_url])
  end

  @doc "Returns the configured Ghost Content API key, or nil if not configured."
  def api_key do
    Config.get([:bonfire_ghost, :content_api_key])
  end

  @doc "Returns true if both ghost_url and api_key are configured."
  def configured? do
    url = ghost_url()
    key = api_key()
    is_binary(url) and url != "" and is_binary(key) and key != ""
  end

  @doc """
  Creates an API client with the configured credentials.

  Returns `{:ok, client}` if configured, `{:error, :not_configured}` otherwise.
  """
  def client do
    if configured?() do
      {:ok, API.client(ghost_url(), api_key())}
    else
      {:error, :not_configured}
    end
  end

  @doc """
  Lists posts from the configured Ghost blog.

  ## Options

    * `:limit` - Number of posts to return (default: 10)
    * `:page` - Page number for pagination
    * `:filter` - Ghost filter string

  ## Examples

      Bonfire.Ghost.list_posts(limit: 5)
      #=> {:ok, %{"posts" => [...], "meta" => %{...}}}

      Bonfire.Ghost.list_posts()
      #=> {:error, :not_configured}
  """
  def list_posts(opts \\ []) do
    with {:ok, c} <- client() do
      API.list_posts(c, opts)
    end
  end

  @doc """
  Gets a single post by its slug.

  ## Examples

      Bonfire.Ghost.get_post("welcome-to-ghost")
      #=> {:ok, %{"posts" => [%{...}]}}
  """
  def get_post(slug) when is_binary(slug) do
    with {:ok, c} <- client() do
      API.get_post_by_slug(c, slug)
    end
  end

  @doc """
  Gets the Ghost site settings.
  """
  def get_settings do
    with {:ok, c} <- client() do
      API.get_settings(c)
    end
  end

  # --- Admin API functions ---

  @doc "Returns the configured Ghost Admin API key, or nil if not configured."
  def admin_api_key do
    Config.get([:bonfire_ghost, :admin_api_key])
  end

  @doc "Returns true if Admin API is configured (ghost_url and admin_api_key)."
  def admin_configured? do
    url = ghost_url()
    key = admin_api_key()
    is_binary(url) and url != "" and is_binary(key) and key != ""
  end

  @doc """
  Creates an Admin API client with the configured credentials.

  Returns `{:ok, client}` if configured, `{:error, :not_configured}` otherwise.
  """
  def admin_client do
    if admin_configured?() do
      AdminAPI.client(ghost_url(), admin_api_key())
    else
      {:error, :not_configured}
    end
  end

  @doc """
  Lists members from the Ghost blog.

  Requires Admin API configuration.

  ## Options

    * `:limit` - Number of members to return (default: 15)
    * `:page` - Page number for pagination
    * `:filter` - Ghost filter string (e.g., "status:paid", "subscribed:true")
    * `:order` - Sort order (e.g., "created_at desc")
    * `:include` - Related data (e.g., "labels,newsletters,subscriptions")

  ## Examples

      Bonfire.Ghost.list_members(limit: 50)
      #=> {:ok, %{"members" => [...], "meta" => %{...}}}

      Bonfire.Ghost.list_members(filter: "status:paid", include: "subscriptions")
      #=> {:ok, %{"members" => [...], "meta" => %{...}}}
  """
  def list_members(opts \\ []) do
    with {:ok, c} <- admin_client() do
      AdminAPI.list_members(c, opts)
    end
  end

  @doc """
  Gets a single member by ID.

  ## Examples

      Bonfire.Ghost.get_member("member-id-here")
      #=> {:ok, %{"members" => [%{...}]}}
  """
  def get_member(member_id, opts \\ []) when is_binary(member_id) do
    with {:ok, c} <- admin_client() do
      AdminAPI.get_member(c, member_id, opts)
    end
  end

  @doc """
  Gets a member by their email address.

  ## Examples

      Bonfire.Ghost.get_member_by_email("user@example.com")
      #=> {:ok, %{"members" => [%{...}]}}
  """
  def get_member_by_email(email, opts \\ []) when is_binary(email) do
    with {:ok, c} <- admin_client() do
      AdminAPI.get_member_by_email(c, email, opts)
    end
  end

  @doc """
  Lists all tiers (membership levels) available on the Ghost site.

  ## Examples

      Bonfire.Ghost.list_tiers()
      #=> {:ok, %{"tiers" => [...]}}
  """
  def list_tiers(opts \\ []) do
    with {:ok, c} <- admin_client() do
      AdminAPI.list_tiers(c, opts)
    end
  end

  @doc """
  Lists newsletters configured on the Ghost site.

  ## Examples

      Bonfire.Ghost.list_newsletters()
      #=> {:ok, %{"newsletters" => [...]}}
  """
  def list_newsletters(opts \\ []) do
    with {:ok, c} <- admin_client() do
      AdminAPI.list_newsletters(c, opts)
    end
  end
end
