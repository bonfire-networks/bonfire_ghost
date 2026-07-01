defmodule Bonfire.Ghost do
  @moduledoc """
  Ghost blog integration for Bonfire.

  Provides configuration helpers and API clients for Ghost CMS via both the
  Content API (for public posts) and Admin API (for members, drafts, etc.).

  For API calls use the underlying modules directly:

      {:ok, c} = Bonfire.Ghost.client()
      Bonfire.Ghost.API.list_posts(c, limit: 5)

      {:ok, c} = Bonfire.Ghost.admin_client()
      Bonfire.Ghost.AdminAPI.list_members(c, limit: 50)

  ## Configuration

  Add to your config:

      config :bonfire_ghost,
        ghost_url: "https://your-blog.ghost.io",
        content_api_key: "your_content_api_key_here",
        admin_api_key: "id:secret_hex"  # Optional, for member access
  """

  use Bonfire.Common.Config
  use Bonfire.Common.Localise
  import Bonfire.Common.Modularity.DeclareHelpers

  alias Bonfire.Ghost.API
  alias Bonfire.Ghost.AdminAPI

  declare_extension(
    l("Ghost blog"),
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
  Creates a Content API client with the configured credentials.

  Returns `{:ok, client}` if configured, `{:error, :not_configured}` otherwise.
  """
  def client do
    if configured?() do
      {:ok, API.client(ghost_url(), api_key())}
    else
      {:error, :not_configured}
    end
  end

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
end
