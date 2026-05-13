defmodule Bonfire.Ghost.EmbedHelper do
  @moduledoc "Helpers for creating Bonfire thread anchors from Ghost articles."
  use Bonfire.Common.Config
  use Bonfire.Common.E
  alias Bonfire.Common.Enums
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
        group_id = Keyword.get(opts, :group_id)
        require_topic? = Keyword.get(opts, :require_topic, false)

        boundary_opt = Keyword.get(opts, :boundary, nil)

        with true <- Ghost.configured?() || {:error, :ghost_not_configured},
             {:ok, article} <- fetch_article(slug_or_id),
             author = resolve_author(article) || Keyword.fetch!(opts, :current_user),
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
             {:ok, post} <-
               Bonfire.Posts.publish(
                 current_user: author,
                 boundary: boundary,
                 to_circles: to_circles,
                 context_id: Enums.id(context),
                 mentions: [Enums.id(context)],
                 post_attrs: %{
                   post_content: %{
                     name: article["title"],
                     summary: article["custom_excerpt"],
                     html_body: article["html"] || ""
                   },
                   uploaded_media: primary_image_attachment(article)
                 }
               ) do
          if url do
            case Peered.save_canonical_uri(post, url) do
              {:ok, _} ->
                :ok

              err ->
                error(
                  err,
                  "Could not save canonical URI for Ghost article — duplicates may occur"
                )
            end
          end

          {:ok, post}
        end
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

  defp resolve_author(article) do
    primary_author =
      e(article, "primary_author", nil)
      |> flood("attempt to resolve author from article data")

    ghost_id = e(primary_author, "id", nil)
    slug = e(primary_author, "slug", nil)

    (ghost_id && fetch_and_provision_staff(ghost_id)) ||
      (slug && Config.get([:bonfire_ghost, :match_author_by_username], false) &&
         find_by_username(slug))
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
