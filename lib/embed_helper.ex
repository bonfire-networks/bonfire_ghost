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
  alias Bonfire.Boundaries.Acls
  alias Bonfire.Boundaries.Controlleds
  alias Bonfire.Boundaries.Grants

  @doc """
  Finds an already-imported Bonfire post for a Ghost article without creating or updating anything.

  The embedding page's URL is checked first. When that does not match and Ghost is configured, the article is fetched only to resolve its canonical URL before looking up the existing import. Article creation belongs to the webhook importer or the explicit historical backfill, never to page navigation.
  """
  def get_post_for_article(slug_or_id, url) do
    case find_imported_post(url) do
      {:ok, %{id: existing_id} = post} ->
        info(existing_id, "found an existing post")
        {:ok, post}

      _ ->
        with true <- Ghost.configured?() || {:error, :ghost_not_configured},
             {:ok, article} <- fetch_article(slug_or_id) do
          find_imported_post(article)
        end
    end
  end

  @doc """
  Creates or updates a Bonfire Post from an already-fetched Ghost article map
  (e.g. the `post.current` object delivered by a Ghost webhook).

  Upserts by canonical URI: if a post already exists for `article["url"]` it is
  updated (and un-hidden, in case it was previously unpublished); otherwise a
  new post is created. Author is resolved via the shared fallback chain (see
  `resolve_author/2`).

  Returns `{:ok, post}` on success, `{:ok, :filtered_out}` when a configured Ghost tag filter intentionally skips the article, or `{:error, reason}` otherwise.

  Opts:
    - `on_filtered` — what to do when the tag filter rejects the article: `:hide` (default) hides any existing post instance-wide, which is the webhook "the article no longer qualifies, retract it" semantics; `:skip` leaves existing posts untouched (used by the historical backfill, which sweeps every article and must not retroactively hide posts created via other paths).
  """
  def import_article(article, opts \\ []) do
    url = e(article, "url", nil)
    report_import_stage(opts, :filtering)

    case check_auto_import_tag_filter(article, opts) do
      :ok ->
        report_import_stage(opts, :looking_up_existing_post)

        case url && Peered.get_by_uri(url) do
          {:ok, %{id: existing_id}} ->
            info(existing_id, "found an existing post for article — updating")
            # un-hide in case it had been unpublished before
            report_import_stage(opts, :unhiding_existing_post)
            maybe_unhide(existing_id)
            update_post_from_article(existing_id, article, opts)

          _ ->
            create_post_from_article(article, url, opts)
        end

      {:error, :filtered_out} ->
        if Keyword.get(opts, :on_filtered, :hide) == :hide, do: hide_article(url)
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
    case find_imported_post(article_or_url) do
      {:ok, %{id: existing_id}} ->
        retract(existing_id)

      _ ->
        info(article_or_url, "no post found for article — nothing to hide")
        {:ok, :not_found}
    end
  end

  # `:hide` grants `:cannot_discover`, which excludes `[:read, :request]` — it unlists but leaves
  # the article readable by direct link. Retraction must also deny `:read`.
  defp retract(post_id) do
    with {:ok, _} <- Bonfire.Boundaries.Blocks.block(post_id, :hide, :instance_wide),
         :ok <- set_read_denial(post_id, :deny) do
      {:ok, :hidden}
    end
  end

  defp set_read_denial(post_id, :deny) do
    with {:ok, acl} <- Acls.get_or_create_object_custom_acl(post_id, :instance_wide) do
      apply_read_denial(acl, :deny)
    end
  end

  # get-only, never get_or_create: `maybe_unhide/1` runs on every update webhook, so creating
  # here would mint a custom ACL for every article on its first edit (and `single()` errors
  # permanently if two concurrent webhooks each create one). No custom ACL → nothing to lift.
  defp set_read_denial(post_id, :allow) do
    case Acls.get_object_custom_acl(post_id) do
      {:ok, acl} -> apply_read_denial(acl, :allow)
      _ -> :ok
    end
  end

  defp apply_read_denial(acl, deny_or_allow) do
    circles = Bonfire.Boundaries.Blocks.instance_wide_circles([:guest, :local, :activity_pub])

    result =
      case deny_or_allow do
        :deny -> Grants.grant_role(circles, acl, :cannot_read, scope: :instance_wide)
        :allow -> Grants.remove_role(circles, acl, :cannot_read, scope: :instance_wide)
      end

    if Enums.all_ok?(result) do
      :ok
    else
      error(result, "Could not #{deny_or_allow} :read on retracted Ghost article")
    end
  end

  # A real `post.deleted` payload carries no `url` (Ghost builds `previous` from changed DB
  # attributes; `url` is computed), so fall back to `canonical_url`, then to the slug.
  defp find_imported_post(article_or_url) do
    article_or_url
    |> candidate_urls()
    |> Enum.find_value(fn url ->
      case Peered.get_by_uri(url) do
        {:ok, post} -> {:ok, post}
        _ -> nil
      end
    end)
    |> case do
      {:ok, post} -> {:ok, post}
      _ -> find_by_slug_suffix(article_slug(article_or_url))
    end
  end

  defp article_slug(article) when is_map(article), do: e(article, "slug", nil)
  defp article_slug(_), do: nil

  # Needs no base URL, so unlike `slug_url/1` it still works when `GHOST_URL` (the API base) isn't
  # the blog's public site URL — which is common, and would otherwise make deletes silently no-op.
  defp find_by_slug_suffix(slug) when is_binary(slug) and slug != "" do
    import Ecto.Query

    pattern = "%/" <> slug <> "/"

    Bonfire.Common.Repo.one(
      from(p in Bonfire.Data.ActivityPub.Peered,
        where: like(p.canonical_uri, ^pattern),
        select: %{id: p.id},
        limit: 1
      )
    )
    |> case do
      %{id: id} -> {:ok, %{id: id}}
      _ -> {:error, :not_found}
    end
  rescue
    e ->
      warn(e, "Could not look up Ghost article by slug suffix")
      {:error, :not_found}
  end

  defp find_by_slug_suffix(_), do: {:error, :not_found}

  defp candidate_urls(url) when is_binary(url), do: [url]

  defp candidate_urls(article) when is_map(article) do
    [
      e(article, "url", nil),
      e(article, "canonical_url", nil),
      slug_url(e(article, "slug", nil))
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp candidate_urls(_), do: []

  defp slug_url(slug) when is_binary(slug) and slug != "" do
    case Ghost.ghost_url() do
      base when is_binary(base) and base != "" ->
        String.trim_trailing(base, "/") <> "/" <> slug <> "/"

      _ ->
        nil
    end
  end

  defp slug_url(_), do: nil

  # `:hide` blocks aren't detectable via `Blocks.is_blocked?` (that checks the
  # silence/ghost circles, not object-discovery grants), so just attempt to
  # reverse it — `unblock(:hide)` is a no-op when nothing was hidden.
  defp maybe_unhide(post_id) do
    Bonfire.Boundaries.Blocks.unblock(post_id, :hide, :instance_wide)
    # mirrors `retract/1`, else a re-published article returns to feeds but stays unreadable
    set_read_denial(post_id, :allow)
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

    with :ok <- report_import_stage(opts, :resolving_author),
         {:ok, author} <- require_author(article, opts),
         :ok <- report_import_stage(opts, :resolving_destination),
         {context_type, context} <- resolve_context(group_id, article),
         :ok <- check_topic_requirement(require_topic?, context_type),
         :ok <- report_import_stage(opts, :authorizing_destination),
         :ok <- ensure_author_can_post(author, context, group_id),
         %{boundary: boundary, to_circles: to_circles} <-
           article_boundary_attrs(article, context, boundary_opt),
         context_id = (context && Enums.id(context)) || nil,
         # the article's own publication date, else an explicit `:published_at` override opt,
         # so an old article is backdated instead of surfacing as fresh
         published = e(article, "published_at", nil) || Keyword.get(opts, :published_at),
         post_id = (published && DatesTimes.generate_ulid_if_past(published)) || nil,
         :ok <- report_import_stage(opts, :publishing_post),
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
             auto_boost_at: published,
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
      report_import_stage(opts, :saving_canonical_uri)
      maybe_save_canonical_uri(post, url)
      {:ok, post}
    end
  end

  defp update_post_from_article(post_id, article, opts) do
    with :ok <- report_import_stage(opts, :resolving_author),
         {:ok, author} <- require_author(article, opts),
         :ok <- report_import_stage(opts, :editing_post),
         {:ok, _updated} <-
           Bonfire.Social.PostContents.edit(author, post_id, %{
             post_content: %{
               name: article["title"],
               summary: article["custom_excerpt"],
               html_body: article["html"] || ""
             }
           }),
         :ok <- report_import_stage(opts, :loading_updated_post),
         {:ok, post} <- read_imported(post_id, author),
         :ok <- report_import_stage(opts, :updating_boundaries),
         :ok <- update_article_boundaries(author, article, post, opts) do
      # Content edits do not reapply topic routing, so retry the idempotent route operation.
      report_import_stage(opts, :routing_to_destination)
      maybe_route_into_context(author, article, post, opts)
      {:ok, post}
    end
  end

  # Stage reporting is best-effort because diagnostics must not break an import.
  defp report_import_stage(opts, stage) do
    case Keyword.get(opts, :on_stage) do
      on_stage when is_function(on_stage, 1) -> on_stage.(stage)
      _ -> :ok
    end

    :ok
  rescue
    e ->
      warn(e, "Could not report Ghost article import stage")
      :ok
  catch
    kind, reason ->
      warn({kind, reason}, "Could not report Ghost article import stage")
      :ok
  end

  defp update_article_boundaries(author, article, post, opts) do
    group_id = Keyword.get(opts, :group_id) || configured_default_group()
    boundary_opt = Keyword.get(opts, :boundary, nil)

    with {_, context} <- resolve_context(group_id, article),
         :ok <- ensure_author_can_post(author, context, group_id),
         %{boundary: boundary, to_circles: to_circles} <-
           article_boundary_attrs(article, context, boundary_opt),
         set_opts =
           [
             boundary: boundary,
             to_circles: to_circles,
             context_id: (context && Enums.id(context)) || nil
           ] do
      # Strip-then-replace the post's read ACLs atomically: if applying the new
      # boundaries fails or raises, the removals roll back — the post is never left
      # with no read ACLs (which would make it invisible to everyone, including its
      # own audience) until a later retry happens to succeed.
      Bonfire.Common.Repo.transact_with(fn ->
        with :ok <- remove_old_article_preset_acls(post),
             :ok <- remove_old_ghost_tier_grants(post),
             {:ok, :granted} <- Bonfire.Boundaries.set_boundaries(author, post, set_opts) do
          {:ok, :granted}
        end
      end)
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp article_boundary_attrs(article, context, boundary_opt) do
    # Only PAID tiers gate `:read`; a free tier is open signup, not a paywall.
    read_circles = (requires_paid?(article) && tier_circles_for_article(article)) || []

    %{
      boundary:
        boundary_opt ||
          article_boundary(article, context) ||
          (context && Bonfire.Classify.Boundaries.read_default_content_visibility(context)) ||
          "public",
      to_circles:
        ((context && Bonfire.Classify.Boundaries.post_circles_for_group(context)) || []) ++
          read_circles
    }
  end

  defp remove_old_ghost_tier_grants(post) do
    ghost_tier_subject_ids = Enum.map(all_ghost_tier_circles(), & &1.id)

    custom_acl_ids =
      post
      |> Controlleds.list_on_object(skip_boundary_check: true)
      |> Enum.filter(&object_custom_acl?/1)
      |> Enum.map(&(e(&1, :acl_id, nil) || e(&1, :acl, :id, nil)))
      |> Enum.reject(&is_nil/1)

    if ghost_tier_subject_ids != [] and custom_acl_ids != [] do
      Enum.each(ghost_tier_subject_ids, &Grants.remove_subject_from_acl(&1, custom_acl_ids))
    end

    :ok
  end

  defp remove_old_article_preset_acls(post) do
    article_preset_acl_ids = article_preset_acl_ids()

    preset_acl_ids =
      post
      |> Controlleds.list_acls_on_object(skip_boundary_check: true)
      |> Enum.map(&(e(&1, :acl_id, nil) || e(&1, :acl, :id, nil)))
      |> Enum.filter(&(&1 in article_preset_acl_ids))

    if preset_acl_ids != [] do
      Controlleds.remove_acls(post, preset_acl_ids)
    end

    :ok
  end

  defp article_preset_acl_ids do
    Config.get!(:preset_acls_match)
    |> Map.values()
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.map(&Acls.get_id!/1)
  end

  defp object_custom_acl?(controlled) do
    e(controlled, :acl, :stereotyped, :stereotype_id, nil) ==
      Bonfire.Boundaries.Scaffold.Instance.custom_acl()
  end

  # Resolves the target context and (idempotently) boosts the post into its feed, ensuring tag
  # permission first. Best-effort: never fails the update.
  defp maybe_route_into_context(author, article, post, opts) do
    group_id = Keyword.get(opts, :group_id) || configured_default_group()

    with {context_type, context} when context_type in [:topic, :group] and not is_nil(context) <-
           resolve_context(group_id, article) do
      ensure_author_can_post(author, context, group_id)

      Bonfire.Social.Tags.maybe_auto_boost(author, context, post,
        auto_boost_at: e(article, "published_at", nil)
      )
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

  # Returns a user struct, an ID, or nil. `opts[:creator]`/`opts[:current_user]` are honoured for
  # TRUSTED callers only (`import_article/2` — webhook worker, operator backfill); the public
  # embed never creates posts at all (`get_post_for_article/2` is read-only).
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
  defp configured_default_author, do: Ghost.auto_import_as()

  # Instance-wide group/topic that webhook auto-import and the backfill post into. Trusted
  # callers (`import_article/2`) may override it with a `:group_id` opt.
  defp configured_default_group, do: Ghost.post_into_group()

  defp configured_auto_import_tag do
    Config.get([:bonfire_ghost, :auto_import_tag], nil)
  end

  # When enabled, only import articles whose primary tag maps to a Bonfire topic
  # (articles that only resolve to the group — or to nothing — are skipped).
  defp configured_require_topic do
    Config.get([:bonfire_ghost, :require_topic], false) in [true, "true", "1", "yes"]
  end

  defp fetch_and_provision_staff(ghost_id) do
    # the persisted identity link wins: stable attribution across email changes
    # and on accounts with several profiles, with no Ghost API round-trip
    Bonfire.Ghost.Identities.staff_user(ghost_id) ||
      fetch_and_provision_staff_via_api(ghost_id)
  end

  defp fetch_and_provision_staff_via_api(ghost_id) do
    with {:ok, c} <- Ghost.admin_client(),
         {:ok, ghost_staff} <- AdminAPI.get_user(c, ghost_id),
         # authors need a full identity to be attributed as a poster, so eagerly
         # create the user (regular members instead go through /create-user)
         {:ok, user} <-
           Bonfire.Ghost.Sync.Members.provision_from_ghost_staff(ghost_staff, create_user: true) do
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
