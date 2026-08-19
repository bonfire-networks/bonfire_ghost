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
  alias Bonfire.Common.Cache

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

  @doc """
  The blog's PUBLIC site URL (which imported articles' `canonical_uri` actually uses) for matching imported content.

  Distinct from `ghost_url/0`, which is the API/admin base: a Ghost-hosted site's API host (e.g. `https://foo.ghost.io`) differs from its public domain (e.g. `https://foo.de`, which the ghost.io host merely redirects to), and article URLs are stamped with the public domain, so matching `canonical_uri` against the API base finds nothing.

  Resolved from the Ghost Content API `settings.url` (the same value the settings page shows), cached because callers like `imported_ghost_author?/1` run in the login-critical path. Falls back to `ghost_url/0` when Ghost is unconfigured or unreachable.
  """
  def public_url do
    cached_public_url() || ghost_url()
  end

  defp cached_public_url do
    Cache.maybe_apply_cached({__MODULE__, :fetch_public_url}, [], expire: :timer.hours(24))
  rescue
    _ -> nil
  end

  @doc false
  def fetch_public_url do
    with {:ok, client} <- client(),
         {:ok, %{"settings" => %{"url" => url}}} when is_binary(url) and url != "" <-
           API.get_settings(client) do
      String.trim_trailing(url, "/")
    else
      _ -> nil
    end
  end

  @doc """
  The group/topic id (or @username) that imported articles are posted into, or nil.

  Read via `Config.get` (the app-env), not `Settings.get(:instance)`: the `:bonfire_ghost`
  instance branch can contain non-atom keys, which breaks `Settings.get`'s keyword-path
  lookup — see `Bonfire.Ghost.Workers.ArticleWebhookWorker.auto_import_enabled?/0`.
  """
  def post_into_group do
    case Config.get([:bonfire_ghost, :post_into_group], nil) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  @doc """
  The user id that imported articles (and guest-created generic embed thread anchors)
  are attributed to, or nil.

  This is the instance's "post on our behalf" identity. It is the *only* trusted source
  for an import's author — an embedding page may not supply one (the comments embed
  ignores author/audience params, and never creates Ghost articles at all — see
  `Bonfire.Ghost.EmbedHelper.get_post_for_article/2`). Same `Config.get` caveat as
  `post_into_group/0`.
  """
  def auto_import_as do
    case Config.get([:bonfire_ghost, :auto_import_as], nil) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  @doc """
  Counts articles imported from the Ghost blog at `blog_url`.

  Imported articles store their Ghost page URL as the `canonical_uri` on a `Peered` row, so we count the rows whose `canonical_uri` starts with the blog URL. Pass the blog's public site URL (the Ghost Content API `settings.url`, which is what article URLs actually use) — falling back to the configured `GHOST_URL` when unknown. Returns an integer, or `nil` when no usable URL is available.

  Note: `canonical_uri` is unindexed, so this is a table scan; fine for this admin-only settings page, but add an index (or revive a peer-based count) if it ever runs hot.
  """
  def imported_articles_count(blog_url \\ nil) do
    case blog_url || public_url() do
      url when is_binary(url) and url != "" ->
        count_peered_by_uri_prefix(String.trim_trailing(url, "/") <> "/")

      _ ->
        nil
    end
  end

  defp count_peered_by_uri_prefix(prefix) do
    import Ecto.Query

    Bonfire.Common.Repo.one(
      from(p in Bonfire.Data.ActivityPub.Peered,
        where: like(p.canonical_uri, ^(prefix <> "%")),
        select: count(p.id)
      )
    ) || 0
  rescue
    _ -> nil
  end

  @doc "Returns the configured Ghost Content API key, or nil if not configured."
  def api_key do
    Config.get([:bonfire_ghost, :content_api_key])
  end

  @doc """
  How long (ms) to wait on a Ghost API response before giving up. Default 8s.

  Kept short on purpose: Ghost is called synchronously from request-critical paths (the gated-login
  provider, inside the login request; the comments embed, during LiveView mount), so a hung Ghost
  must fail fast rather than pin those processes.
  """
  def request_timeout do
    case Config.get([:bonfire_ghost, :request_timeout], 8_000) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> 8_000
    end
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
