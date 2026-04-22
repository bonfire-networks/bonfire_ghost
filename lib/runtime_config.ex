defmodule Bonfire.Ghost.RuntimeConfig do
  @moduledoc """
  Runtime configuration for the Ghost extension.

  ## Environment Variables

    * `GHOST_URL` - Your Ghost blog URL (e.g., https://your-blog.ghost.io)
    * `GHOST_CONTENT_API_KEY` - Your Ghost Content API key (for public posts)
    * `GHOST_ADMIN_API_KEY` - Your Ghost Admin API key (for members, drafts, etc.)
    * `GHOST_WEBHOOK_SECRET` - Shared secret Ghost signs webhook payloads with
      (set the same value in the Ghost admin → Integrations → webhook "Secret" field)
    * `GHOST_GATED_MODE` - When `true`/`1`/`yes`, the Bonfire login page hides
      password+signup and shows a passwordless email-only form. Members who
      exist in Ghost (with any active tier) are provisioned on demand when
      they request a login link.

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
    webhook_secret = System.get_env("GHOST_WEBHOOK_SECRET")
    gated_mode = System.get_env("GHOST_GATED_MODE")

    config_opts =
      []
      |> maybe_add(:ghost_url, ghost_url)
      |> maybe_add(:content_api_key, content_api_key)
      |> maybe_add(:admin_api_key, admin_api_key)
      |> maybe_add(:webhook_secret, webhook_secret)

    if config_opts != [] do
      config :bonfire_ghost, config_opts
    end

    if truthy?(gated_mode) do
      # Drive the login page toggle through bonfire_ui_me's own setting so
      # the UI extension never needs to know about Ghost.
      config :bonfire_ui_me, :login, passwordless_only: true
    end

    existing_providers = Application.get_env(:bonfire_ui_me, :login_email_providers, [])

    config :bonfire_ui_me,
      login_email_providers: Enum.uniq(existing_providers ++ [Bonfire.Ghost.LoginEmailProvider])
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, _key, ""), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp truthy?(v) when v in [true, "true", "1", "yes"], do: true
  defp truthy?(_), do: false
end
