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

  Returns `{:ok, post}` on success, or `{:error, reason}` otherwise.

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

  Returns `{:ok, post}` on success, `{:ok, :filtered_out}` when a configured Ghost tag filter intentionally skips the article, or `{:error, reason}` otherwise.
  """
  def import_article(article, opts \\ []) do
    url = e(article, "url", nil)

    case check_auto_import_tag_filter(article, opts) do
      :ok ->
        case url && Peered.get_by_uri(url) do
          {:ok, %{id: existing_id}} ->
            info(existing_id, "found an existing post for article — updating")
            # un-hide in case it had been unpublished before
            maybe_unhide(existing_id)
            update_post_from_article(existing_id, article, opts)

          _ ->
            create_post_from_article(article, url, opts)
        end

      {:error, :filtered_out} ->
        hide_article(url)
        {:ok, :filtered_out}

      {:error, reason} ->
        {:error, reason}
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

  defp check_auto_import_tag_filter(article, opts) do
    opts
    |> Keyword.get(:auto_import_tag, configured_auto_import_tag())
    |> normalize_tag_filters()
    |> case do
      {:ok, []} ->
        :ok

      {:ok, filters} ->
        tags = article_tag_slugs(article)

        if Enum.any?(tags, &(&1 in filters)) do
          :ok
        else
          info(%{filters: filters, tags: tags}, "Ghost article skipped by tag filter")
          {:error, :filtered_out}
        end

      {:error, reason} ->
        warn(reason, "Invalid Ghost auto-import tag filter")
        {:error, reason}
    end
  end

  defp normalize_tag_filters(nil), do: {:ok, []}
  defp normalize_tag_filters(""), do: {:ok, []}

  defp normalize_tag_filters(filters) when is_binary(filters) do
    parsed =
      filters
      |> String.split([",", " "], trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.downcase/1)

    {:ok, parsed}
  end

  defp normalize_tag_filters(filters) when is_list(filters) do
    filters
    |> Enum.reduce_while({:ok, []}, fn filter, {:ok, acc} ->
      case normalize_tag_filters(filter) do
        {:ok, parsed} -> {:cont, {:ok, acc ++ parsed}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.uniq(parsed)}
      error -> error
    end
  end

  defp normalize_tag_filters(filter), do: {:error, {:invalid_auto_import_tag_filter, filter}}

  defp article_tag_slugs(article) do
    primary = e(article, "primary_tag", "slug", nil)

    tags =
      case e(article, "tags", []) do
        tags when is_list(tags) -> Enum.map(tags, &e(&1, "slug", nil))
        _ -> []
      end

    [primary | tags]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  # Shared create path used by both the on-demand embed flow and webhook import.
  defp create_post_from_article(article, url, opts) do
    group_id = Keyword.get(opts, :group_id) || configured_default_group()
    require_topic? = Keyword.get(opts, :require_topic, configured_require_topic())
    boundary_opt = Keyword.get(opts, :boundary, nil)

    with {:ok, author} <- require_author(article, opts),
         {context_type, context} <- resolve_context(group_id, article),
         :ok <- check_topic_requirement(require_topic?, context_type),
         :ok <- ensure_author_can_post(author, context, group_id),
         # Only PAID tiers gate `:read` — a free tier is open signup, not a paywall
         # (see `article_boundary/2`). So tier circles are granted `:read` only when
         # the article is actually paid-gated.
         read_circles = (requires_paid?(article) && tier_circles_for_article(article)) || [],
         to_circles =
           ((context && Bonfire.Classify.Boundaries.post_circles_for_group(context)) || []) ++
             read_circles,
         boundary =
           boundary_opt ||
             article_boundary(article, context) ||
             (context &&
                Bonfire.Classify.Boundaries.read_default_content_visibility(context)) ||
             "public",
         context_id = (context && Enums.id(context)) || nil,
         published = e(article, "published_at", nil),
         post_id = (published && DatesTimes.generate_ulid_if_past(published)) || nil,
         {:ok, post} <-
           Bonfire.Posts.publish(
             current_user: author,
             # publish as an Article (the epic reuses the same logic, just with the
             # `Article` schema, so the activity UI treats it as an article) when the
             # extension is enabled; a nil schema falls back to a plain Post.
             schema: article_schema(author),
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
         {:ok, post} <- read_imported(post_id, author) do
      # A content edit doesn't (re)apply topic routing, so re-apply the (idempotent) auto-boost
      # in case the article was first imported before `post_into_group`/tag perms were in place.
      maybe_route_into_context(author, article, post, opts)
      {:ok, post}
    end
  end

  # Resolves the target context and (idempotently) boosts the post into its feed, ensuring tag
  # permission first. Best-effort: never fails the update.
  defp maybe_route_into_context(author, article, post, opts) do
    group_id = Keyword.get(opts, :group_id) || configured_default_group()

    with {context_type, context} when context_type in [:topic, :group] and not is_nil(context) <-
           resolve_context(group_id, article) do
      ensure_author_can_post(author, context, group_id)
      Bonfire.Social.Tags.maybe_auto_boost(author, context, post)
    else
      _ -> :ok
    end
  rescue
    e ->
      warn(e, "Could not route re-published Ghost article into its topic feed")
      :ok
  end

  defp read_imported(post_id, author) do
    Bonfire.Posts.read(post_id, skip_boundary_check: true, schema: article_schema(author))
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

  # `Bonfire.Articles.Article` schema when the extension is enabled, else nil (→ Post).
  defp article_schema(author) do
    if Bonfire.Common.Extend.module_enabled?(Bonfire.Articles, author),
      do: Bonfire.Articles.Article
  end

  # An imported article only lands in a group/topic feed if its author can post
  # there, which (for a topic especially) requires group membership. Idempotently
  # add the configured import author to the target group so auto-import "just works"
  # without an admin manually managing the bot's membership. Always returns `:ok`
  # (a failure to join is warned, not fatal, the post is still created).
  defp ensure_author_can_post(_author, nil, _group_id), do: :ok

  # TODO: joining a *group* grants `:tag` (its members circle gets `:contribute`), but joining a
  # *topic* grants nothing (a topic never wires its own members circle into its ACL), so the
  # explicit grant below is needed. Cleaner fix would be at the source in bonfire_classify — have
  # topics grant their own members circle `:contribute` — so "join → can participate" holds uniformly.
  defp ensure_author_can_post(author, context, group_id) do
    target = group_id || Enums.id(context)

    case Bonfire.Classify.Categories.join_group(author, target, skip_boundary_check: true) do
      {:ok, _} ->
        :ok

      other ->
        warn(other, "Could not add import author to group/topic — post may not reach its feed")
    end

    # Membership alone can't tag a *topic* (grant goes to the parent group's members circle, not the
    # topic's own — see `init_boundaries`), so the auto-boost silently no-ops. Grant `:contribute`
    # (includes `:tag`) directly. Idempotent; no-op once the author already has tag permission.
    #
    # On `context`, not `target`: a group `target` can resolve to a child topic, and the boost needs
    # `:tag` on that topic — `can?(:tag, target)` could pass via group membership while it can't.
    maybe_grant_tag_permission(author, Enums.id(context) || target)

    :ok
  end

  defp maybe_grant_tag_permission(author, object) do
    if Bonfire.Boundaries.can?(author, :tag, object) do
      :ok
    else
      Bonfire.Boundaries.Controlleds.grant_role(author, object, :contribute,
        current_user: author,
        skip_boundary_check: true
      )

      :ok
    end
  rescue
    e ->
      warn(e, "Could not grant :contribute to import author — post may not reach the topic feed")
      :ok
  end

  defp resolve_context(group_id, article) when is_binary(group_id) do
    case Bonfire.Classify.Categories.get(group_id, skip_boundary_check: true) do
      {:ok, target} ->
        if topic?(target) do
          {:topic, target}
        else
          resolve_topic_in_group(target, article) || {:group, target}
        end

      _ ->
        {:no_context, nil}
    end
  end

  defp resolve_topic_in_group(group, article) do
    with slug when is_binary(slug) <- e(article, "primary_tag", "slug", nil),
         {:ok, topic} <-
           Bonfire.Classify.Categories.one(
             [username: slug, parent_category: Enums.id(group)],
             skip_boundary_check: true
           ) do
      {:topic, topic}
    else
      _ -> nil
    end
  end

  defp topic?(category) do
    e(category, :type, nil) in [:topic, "topic"]
  end

  defp resolve_context(nil, article) do
    slug = e(article, "primary_tag", "slug", nil)

    case slug && Bonfire.Classify.Categories.get(slug, skip_boundary_check: true) do
      {:ok, topic} ->
        if topic?(topic) do
          {:topic, topic}
        else
          {:no_context, nil}
        end

      _ ->
        {:no_context, nil}
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
    case Config.get([:bonfire_ghost, :auto_import_as], nil) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  # Instance-wide group/topic that webhook auto-import and embeds post into by
  # default (an embed's `data-group-id` param still overrides via `:group_id` opt).
  defp configured_default_group do
    case Config.get([:bonfire_ghost, :post_into_group], nil) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp configured_auto_import_tag do
    Config.get([:bonfire_ghost, :auto_import_tag], nil)
  end

  # When enabled, only import articles whose primary tag maps to a Bonfire topic
  # (articles that only resolve to the group — or to nothing — are skipped).
  defp configured_require_topic do
    Config.get([:bonfire_ghost, :require_topic], false) in [true, "true", "1", "yes"]
  end

  defp fetch_and_provision_staff(ghost_id) do
    with {:ok, c} <- Ghost.admin_client(),
         {:ok, ghost_staff} <- AdminAPI.get_user(c, ghost_id),
         # authors need a full identity to be attributed as a poster, so eagerly
         # create the user (regular members instead go through /create-user)
         {:ok, user} <-
           Bonfire.Ghost.Sync.Members.provision_from_ghost_member(ghost_staff, create_user: true) do
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
  defp article_boundary(article, context) do
    case article_access(article) do
      :public -> "public"
      # grouped `:local` falls through to the group's default content visibility (nil)
      :local -> if context, do: nil, else: "local"
      # see-only preview: public gets `:see` (preview card), `:read` only via the paid
      # `ghost_tier:*` circles granted in `to_circles`
      :paid -> if context, do: "nonfederated:preview", else: "local:preview"
    end
  end

  # `:public | :local | :paid` — the effective read-access requirement. A free tier is
  # open signup (NOT a paywall), so `members` and `tiers` a free tier can satisfy are
  # `:local` (any logged-in user reads; guests get `:see`/preview); only paid-only tiers
  # (and `"paid"`) gate.
  defp article_access(article) do
    case e(article, "visibility", nil) do
      "public" -> :public
      "members" -> :local
      "tiers" -> if tiers_include_free?(article), do: :local, else: :paid
      "paid" -> :paid
      _ -> :public
    end
  end

  defp requires_paid?(article), do: article_access(article) == :paid

  @tier_circle_prefix "ghost_tier:"

  @doc """
  The `ghost_tier:*` circle ids a restricted article should be shared with, based on
  its Ghost `visibility`:

    - `"tiers"`   → the circles named after each slug in `article["tiers"]`
    - `"paid"`    → all tier circles whose stored type is `"paid"`
                    (fallback: all tier circles if none carry type info, e.g. pre-A4 sync)
    - `"members"` → all `ghost_tier:*` circles
    - anything else → `[]`

  Warns (and skips) when a referenced tier slug has no synced circle yet.
  """
  def tier_circles_for_article(article) do
    case e(article, "visibility", nil) do
      "tiers" ->
        article
        |> e("tiers", [])
        |> Enum.map(&e(&1, "slug", nil))
        |> Enum.reject(&is_nil/1)
        |> Enum.flat_map(&tier_circle_id_for_slug/1)

      "paid" ->
        all = all_ghost_tier_circles()
        paid = Enum.filter(all, &(tier_circle_type(&1) == "paid"))

        cond do
          paid != [] -> Enum.map(paid, & &1.id)
          # no type info at all (pre-A4 sync) → fall back to every tier circle
          Enum.all?(all, &(tier_circle_type(&1) in [nil, ""])) -> Enum.map(all, & &1.id)
          true -> []
        end

      "members" ->
        Enum.map(all_ghost_tier_circles(), & &1.id)

      _ ->
        []
    end
  end

  defp tier_circle_id_for_slug(slug) do
    case Bonfire.Boundaries.Circles.get_by_name(
           @tier_circle_prefix <> slug,
           Bonfire.Boundaries.Scaffold.Instance.admin_circle()
         ) do
      {:ok, circle} ->
        [circle.id]

      _ ->
        warn(slug, "No ghost_tier circle for slug yet — article not shared with this tier")
        []
    end
  end

  defp all_ghost_tier_circles do
    Bonfire.Boundaries.Circles.list_my(:instance)
    |> Enum.filter(fn
      %{named: %{name: name}} when is_binary(name) ->
        String.starts_with?(name, @tier_circle_prefix)

      _ ->
        false
    end)
  end

  # info keys may be strings (jsonb roundtrip) or atoms (freshly created) — check both.
  defp tier_circle_type(circle) do
    info = e(circle, :extra_info, :info, %{})
    Map.get(info, "ghost_tier_type") || Map.get(info, :ghost_tier_type)
  end

  # Does the article list any tier that is a free (open-signup) tier? Resolved via the
  # synced `ghost_tier:<slug>` circle's stored type — an unsynced/unknown tier is treated
  # as non-free (i.e. paid-gated) so we never accidentally expose paid content.
  defp tiers_include_free?(article) do
    article
    |> e("tiers", [])
    |> Enum.any?(&free_tier?(e(&1, "slug", nil)))
  end

  defp free_tier?(slug) when is_binary(slug) do
    case Bonfire.Boundaries.Circles.get_by_name(
           @tier_circle_prefix <> slug,
           Bonfire.Boundaries.Scaffold.Instance.admin_circle()
         ) do
      {:ok, circle} ->
        # `get_by_name` preloads `:named`/`:caretaker` but not `:extra_info` (where the type lives)
        tier_circle_type(Bonfire.Common.Repo.maybe_preload(circle, :extra_info)) == "free"

      _ ->
        false
    end
  end

  defp free_tier?(_), do: false
end
