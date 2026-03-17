defmodule Bonfire.Ghost.RuntimeConfig do
  @moduledoc """
  Runtime configuration for the Ghost extension.

  ## Environment Variables

    * `GHOST_URL` - Your Ghost blog URL (e.g., https://your-blog.ghost.io)
    * `GHOST_CONTENT_API_KEY` - Your Ghost Content API key (for public posts)
    * `GHOST_ADMIN_API_KEY` - Your Ghost Admin API key (for members, drafts, etc.)

  ## How to get API keys

  1. Go to your Ghost Admin panel
  2. Navigate to Settings -> Integrations
  3. Click "Add custom integration"
  4. Copy the **Content API Key** for reading public posts
  5. Copy the **Admin API Key** for accessing members (format: `id:secret`)
  """
  use Bonfire.Common.Localise

  @behaviour Bonfire.Common.ConfigModule
  def config_module, do: true

  @doc """
  Sets runtime configuration for the extension (typically by reading ENV variables).
  """
  def config do
    import Config

    ghost_url = System.get_env("GHOST_URL")
    content_api_key = System.get_env("GHOST_CONTENT_API_KEY")
    admin_api_key = System.get_env("GHOST_ADMIN_API_KEY")

    config_opts =
      []
      |> maybe_add(:ghost_url, ghost_url)
      |> maybe_add(:content_api_key, content_api_key)
      |> maybe_add(:admin_api_key, admin_api_key)

    if config_opts != [] do
      config :bonfire_ghost, config_opts
    end
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, _key, ""), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)
end
