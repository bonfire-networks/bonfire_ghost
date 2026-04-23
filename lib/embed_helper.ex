defmodule Bonfire.Ghost.EmbedHelper do
  @moduledoc "Helpers for creating Bonfire thread anchors from Ghost articles."
  use Bonfire.Common.Config
  use Bonfire.Common.E
  alias Bonfire.Common.Enums
  import Untangle
  alias Bonfire.Ghost
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
        current_user = Keyword.fetch!(opts, :current_user)
        group_id = Keyword.get(opts, :group_id)
        require_topic? = Keyword.get(opts, :require_topic, false)

        boundary_opt = Keyword.get(opts, :boundary, nil)

        with true <- Ghost.configured?() || {:error, :ghost_not_configured},
             {:ok, article} <- fetch_article(slug_or_id),
             {context_type, context} <- resolve_context(group_id, article),
             :ok <- check_topic_requirement(require_topic?, context_type),
             boundary =
               boundary_opt ||
                 ghost_visibility_to_boundary(e(article, "visibility", nil)) ||
                 (context &&
                    Bonfire.Classify.Boundaries.read_default_content_visibility(context)) ||
                 "public",
             {:ok, post} <-
               Bonfire.Posts.publish(
                 current_user: current_user,
                 boundary: boundary,
                 context_id: Enums.id(context),
                 mentions: [Enums.id(context)],
                 post_attrs: %{
                   post_content: %{
                     name: article["title"],
                     html_body: article["html"] || ""
                   }
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
    case Ghost.get_post(slug) do
      {:ok, %{"posts" => [post | _]}} -> {:ok, post}
      {:ok, %{"posts" => []}} -> {:error, :not_found}
      error -> error
    end
  end

  defp fetch_by_id(id) do
    case Ghost.get_post_by_id(id) do
      {:ok, %{"posts" => [post | _]}} -> {:ok, post}
      {:ok, %{"posts" => []}} -> {:error, :not_found}
      error -> error
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

  # Ghost visibility → Bonfire boundary preset name.
  # "public" → federated public; "members"/"paid"/"tiers" → local instance only.
  defp ghost_visibility_to_boundary("public"), do: "public"
  #  only signed in users
  defp ghost_visibility_to_boundary("members"), do: "discoverable"
  # TODO: target a specific circle?
  defp ghost_visibility_to_boundary("paid"), do: "local"
  # defp ghost_visibility_to_boundary("tiers"), do: "local"
  defp ghost_visibility_to_boundary(_), do: nil
end
