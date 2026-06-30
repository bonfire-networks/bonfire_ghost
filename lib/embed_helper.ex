defmodule Bonfire.Ghost.EmbedHelper do
  @moduledoc "Helpers for creating Bonfire thread anchors from Ghost articles."
  use Bonfire.Common.Config
  use Bonfire.Common.E
  alias Bonfire.Common.Enums
  alias Bonfire.Common.DatesTimes
  alias Bonfire.Common.Settings
  require Bonfire.Common.Settings
  import Bonfire.Common.Utils
  import Untangle
  alias Bonfire.Ghost
  alias Bonfire.Ghost.API
  alias Bonfire.Ghost.AdminAPI
  alias Bonfire.Federate.ActivityPub.Peered

  @doc """
  Finds or creates a Bonfire Post for a Ghost article.

  `url` is the article's page URL (already known from embed params — used as dedup key via Peered).
  `slug_or_id` is the Ghost canonical slug or `"id:<ghost_id>"`.

  Returns `{:ok, post}` on success, `{:error, reason}` otherwise.

  Opts:
    - `current_user` — user to attribute the post to (required)
    - `boundary` — visibility boundary (default: "public")
    - `group_id` — context_id for group posting (optional)
    - `require_topic` — boolean; only create if article's primary tag matches a Bonfire topic (optional)
  """
  def get_or_create_post_for_article(slug_or_id, url, opts \\ []) do
    case url && Peered.get_by_uri(url) do
      {:ok, %{id: existing_id} = post} ->
        info(existing_id, "found an existing post")
        {:ok, post}

      other ->
        info(other, "did not find an existing post, fetch from source")

        with true <- Ghost.configured?() || {:error, :ghost_not_configured},
             {:ok, article} <- fetch_article(slug_or_id) do
          create_post_from_article(article, url, opts)
        end
    end
  end

  @doc """
  Creates or updates a Bonfire Post from an already-fetched Ghost article map
  (e.g. the `post.current` object delivered by a Ghost webhook).

  Upserts by canonical URI: if a post already exists for `article["url"]` it is
  updated (and un-hidden, in case it was previously unpublished); otherwise a
  new post is created. Author is resolved via the shared fallback chain (see
  `get_or_create_post_for_article/3`).
  """
  def import_article(article, opts \\ []) do
    url = e(article, "url", nil)

    case url && Peered.get_by_uri(url) do
      {:ok, %{id: existing_id}} ->
        info(existing_id, "found an existing post for article — updating")
        # un-hide in case it had been unpublished before
        maybe_unhide(existing_id)
        update_post_from_article(existing_id, article, opts)

      _ ->
        create_post_from_article(article, url, opts)
    end
  end

  @doc """
  Hides (instance-wide) the Bonfire post for a Ghost article, without deleting
  it — so any attached comment thread is preserved. Accepts an article map or a
  canonical URL. Reversed by re-publishing (see `import_article/2`).
  """
  def hide_article(article_or_url, _opts \\ []) do
    url = article_url(article_or_url)

    case url && Peered.get_by_uri(url) do
      {:ok, %{id: existing_id}} ->
        Bonfire.Boundaries.Blocks.block(existing_id, :hide, :instance_wide)

      _ ->
        info(url, "no post found for article — nothing to hide")
        {:ok, :not_found}
    end
  end

  defp article_url(url) when is_binary(url), do: url
  defp article_url(article) when is_map(article), do: e(article, "url", nil)
  defp article_url(_), do: nil

  # `:hide` blocks aren't detectable via `Blocks.is_blocked?` (that checks the
  # silence/ghost circles, not object-discovery grants), so just attempt to
  # reverse it — `unblock(:hide)` is a no-op when nothing was hidden.
  defp maybe_unhide(post_id) do
    Bonfire.Boundaries.Blocks.unblock(post_id, :hide, :instance_wide)
  rescue
    e -> warn(e, "Could not un-hide previously hidden Ghost post")
  end

  # Shared create path used by both the on-demand embed flow and webhook import.
  defp create_post_from_article(article, url, opts) do
    group_id = Keyword.get(opts, :group_id)
    require_topic? = Keyword.get(opts, :require_topic, false)
    boundary_opt = Keyword.get(opts, :boundary, nil)

    with {:ok, author} <- require_author(article, opts),
         {context_type, context} <- resolve_context(group_id, article),
         :ok <- check_topic_requirement(require_topic?, context_type),
         to_circles =
           (context && Bonfire.Classify.Boundaries.post_circles_for_group(context)) || [],
         boundary =
           boundary_opt ||
             ghost_visibility_to_boundary(e(article, "visibility", nil), context) ||
             (context &&
                Bonfire.Classify.Boundaries.read_default_content_visibility(context)) ||
             "public",
         context_id = (context && Enums.id(context)) || nil,
         published = e(article, "published_at", nil),
         post_id = (published && DatesTimes.generate_ulid_if_past(published)) || nil,
         {:ok, post} <-
           Bonfire.Posts.publish(
             current_user: author,
             boundary: boundary,
             to_circles: to_circles,
             context_id: context_id,
             mentions: [context_id],
             post_id: post_id,
             post_attrs: %{
               id: post_id,
               post_content: %{
                 name: article["title"],
                 summary: article["custom_excerpt"],
                 html_body: article["html"] || ""
               },
               uploaded_media: primary_image_attachment(article)
             }
           ) do
      maybe_save_canonical_uri(post, url)
      {:ok, post}
    end
  end

  defp update_post_from_article(post_id, article, opts) do
    with {:ok, author} <- require_author(article, opts),
         {:ok, _updated} <-
           Bonfire.Social.PostContents.edit(author, post_id, %{
             post_content: %{
               name: article["title"],
               summary: article["custom_excerpt"],
               html_body: article["html"] || ""
             }
           }),
         {:ok, post} <- Bonfire.Posts.read(post_id, skip_boundary_check: true) do
      {:ok, post}
    end
  end

  defp require_author(article, opts) do
    case resolve_author(article, opts) do
      nil ->
        error(article, "No author could be resolved for Ghost article")
        {:error, :no_author}

      author when is_binary(author) ->
        # only an id was resolved (e.g. the configured default author) — load the
        # user with `character: [:peered]` (so federation's `is_local?` works) and
        # `:settings` (so user-scoped settings lookups don't re-query)
        case Bonfire.Me.Users.by_id(author) do
          {:ok, user} ->
            {:ok, Bonfire.Common.Repo.maybe_preload(user, [:settings, character: [:peered]])}

          _ ->
            {:error, :no_author}
        end

      author ->
        {:ok, author}
    end
  end

  defp maybe_save_canonical_uri(_post, nil), do: :ok

  defp maybe_save_canonical_uri(post, url) do
    case Peered.save_canonical_uri(post, url) do
      {:ok, _} ->
        :ok

      err ->
        error(err, "Could not save canonical URI for Ghost article — duplicates may occur")
    end
  end

  defp fetch_article("id:" <> id), do: fetch_by_id(id)
  defp fetch_article(slug), do: fetch_by_slug(slug)

  defp fetch_by_slug(slug) do
    with {:ok, c} <- Ghost.client() do
      case API.get_post_by_slug(c, slug) do
        {:ok, %{"posts" => [post | _]}} -> {:ok, post}
        {:ok, %{"posts" => []}} -> {:error, :not_found}
        error -> error
      end
    end
  end

  defp fetch_by_id(id) do
    with {:ok, c} <- Ghost.client() do
      case API.get_post_by_id(c, id) do
        {:ok, %{"posts" => [post | _]}} -> {:ok, post}
        {:ok, %{"posts" => []}} -> {:error, :not_found}
        error -> error
      end
    end
  end

  defp check_topic_requirement(false, _context_type), do: :ok
  defp check_topic_requirement(true, :topic), do: :ok
  defp check_topic_requirement(true, _context_type), do: {:error, :topic_required}

  defp resolve_context(group_id, article) when is_binary(group_id) do
    # otherwise try with just group
    with slug when is_binary(slug) <- e(article, "primary_tag", "slug", nil),
         {:ok, topic} <-
           Bonfire.Classify.Categories.one(
             [username: slug, parent_category: group_id],
             skip_boundary_check: true
           ) do
      {:topic, topic}
    else
      _ -> nil
    end ||
      case Bonfire.Classify.Categories.get(group_id, skip_boundary_check: true) do
        {:ok, group} -> {:group, group}
        _ -> {:no_context, nil}
      end
  end

  defp resolve_context(nil, article) do
    slug = e(article, "primary_tag", "slug", nil)

    case slug && Bonfire.Classify.Categories.get(slug, skip_boundary_check: true) do
      {:ok, topic} -> {:topic, topic}
      _ -> {:no_context, nil}
    end
  end

  defp resolve_context(_, _article), do: {:no_context, nil}

  defp primary_image_attachment(article) do
    case article["feature_image"] do
      url when is_binary(url) and url != "" ->
        [
          %{
            "href" => url,
            "label" => article["feature_image_caption"],
            "alt" => article["feature_image_alt"],
            "primary_image" => true
          }
        ]

      _ ->
        []
    end
  end

  # Shared author resolution
  # Returns a user struct or ID or nil.
  defp resolve_author(article, opts) do
    resolve_ghost_author(article) || opts[:creator] || configured_default_author() ||
      current_user_or_id(opts)
  end

  defp resolve_ghost_author(article) do
    primary_author =
      e(article, "primary_author", nil)
      |> debug("attempt to resolve author from article data")

    ghost_id = e(primary_author, "id", nil)
    slug = e(primary_author, "slug", nil)

    (ghost_id && fetch_and_provision_staff(ghost_id)) ||
      (slug && Config.get([:bonfire_ghost, :match_author_by_username], false) &&
         find_by_username(slug))
  end

  # Returns the configured user ID as-is (no lookup) — it's passed straight to
  # `Bonfire.Posts.publish`/`PostContents.edit` as the author.
  defp configured_default_author do
    case Settings.get([:bonfire_ghost, :auto_import_as], nil, :instance) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp fetch_and_provision_staff(ghost_id) do
    with {:ok, c} <- Ghost.admin_client(),
         {:ok, ghost_staff} <- AdminAPI.get_user(c, ghost_id),
         {:ok, user} <- Bonfire.Ghost.Sync.Members.provision_from_ghost_member(ghost_staff) do
      user
    else
      other ->
        warn(other, "Failed to fetch/provision Ghost staff user")
        nil
    end
  end

  defp find_by_username(slug) do
    case Bonfire.Me.Characters.by_username(slug) do
      {:ok, user} -> user
      _ -> nil
    end
  end

  # In a group context: "public" falls through to the group DCV; restricted visibilitym maps to group-aware presets
  # TODO: only share with a particular circle?
  defp ghost_visibility_to_boundary("paid", context) when not is_nil(context),
    do: "nonfederated:preview"

  # defp ghost_visibility_to_boundary("tiers", context) when not is_nil(context), do: "members:private"
  defp ghost_visibility_to_boundary("members", context) when not is_nil(context),
    do: "nonfederated:preview"

  defp ghost_visibility_to_boundary("public", context) when not is_nil(context),
    do: "nonfederated"

  # Without a group: map to standard non-group presets.
  defp ghost_visibility_to_boundary("members", _), do: "discoverable"
  defp ghost_visibility_to_boundary("paid", _), do: "local"
  # defp ghost_visibility_to_boundary("tiers", _), do: "local"
  defp ghost_visibility_to_boundary("public", _), do: "public"
  defp ghost_visibility_to_boundary(_, _), do: nil
end
