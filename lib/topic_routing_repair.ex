defmodule Bonfire.Ghost.TopicRoutingRepair do
  @moduledoc """
  Previews, applies, and rolls back a routing-only repair for imported Ghost articles.

  Preview fetches published Ghost articles and records only existing Bonfire posts that have one unique matching child topic and no current boost into it. Apply revalidates every manifest entry and adds only the missing topic boost with federation, creator notifications, and live pushes disabled. It never edits article content, authors, boundaries, canonical URLs, or comments, and it never creates an article. Rollback removes only boosts recorded as created by that apply run.
  """

  alias Bonfire.Common.DatesTimes
  alias Bonfire.Common.Needles
  alias Bonfire.Common.Repo
  alias Bonfire.Federate.ActivityPub.Peered
  alias Bonfire.Ghost
  alias Bonfire.Ghost.API
  alias Bonfire.Ghost.AdminAPI
  alias Bonfire.Ghost.EmbedHelper
  alias Bonfire.Social.Boosts
  alias Bonfire.Social.Threads

  @manifest_version 1
  @preview_kind "ghost_topic_routing_preview"
  @applied_kind "ghost_topic_routing_applied"
  @page_limit 50

  @doc """
  Builds a read-only repair manifest for one exact group and Ghost URL prefix.

  Pass `:articles` with a pre-fetched list to preview an explicit snapshot without calling Ghost. When omitted, all currently published articles are fetched from the configured Admin API, falling back to the Content API.
  """
  def preview(opts) when is_list(opts) do
    with {:ok, scope} <- validate_scope(opts),
         {:ok, articles} <- articles_snapshot(opts) do
      {repairs, skipped} =
        articles
        |> Enum.reduce({[], []}, fn article, {repairs, skipped} ->
          case preview_article(scope, article) do
            {:repair, repair} -> {[repair | repairs], skipped}
            {:skip, skip} -> {repairs, [skip | skipped]}
          end
        end)

      repairs = Enum.sort_by(repairs, & &1["canonical_uri"])
      skipped = Enum.sort_by(skipped, & &1["canonical_uri"])

      {:ok,
       %{
         "version" => @manifest_version,
         "kind" => @preview_kind,
         "scope" => stringify_scope(scope),
         "repairs" => repairs,
         "skipped" => skipped,
         "summary" => %{
           "candidates" => length(repairs),
           "skipped" => length(skipped)
         }
       }}
    end
  end

  @doc """
  Applies a preview manifest after revalidating every selected article and topic.

  Pass `:article_url` to perform a one-article pilot. Current published articles are fetched again from Ghost before any database transaction; pass `:articles` only when supplying an explicit current snapshot. The returned applied manifest contains only boosts created by this invocation and is the rollback record. A `:before_commit` function can persist that record inside the transaction; returning `{:error, reason}` rolls back every placement.
  """
  def apply(manifest, opts \\ []) when is_map(manifest) and is_list(opts) do
    with {:ok, scope, repairs} <- validate_preview_manifest(manifest),
         {:ok, selected_repairs} <- select_repairs(repairs, Keyword.get(opts, :article_url)),
         {:ok, current_articles} <- articles_snapshot(opts),
         {:ok, current_articles_by_uri} <- index_current_articles(current_articles) do
      Repo.transaction(fn ->
        result =
          selected_repairs
          |> Enum.reduce(%{applied: [], already_present: 0}, fn repair, result ->
            case apply_repair(scope, repair, current_articles_by_uri) do
              {:created, boost_id} ->
                %{result | applied: [Map.put(repair, "boost_id", boost_id) | result.applied]}

              :already_present ->
                %{result | already_present: result.already_present + 1}

              {:error, reason} ->
                Repo.rollback(reason)
            end
          end)

        applied_manifest = applied_manifest(scope, result)

        case run_before_commit(applied_manifest, Keyword.get(opts, :before_commit)) do
          :ok -> applied_manifest
          {:error, reason} -> Repo.rollback({:before_commit_failed, reason})
        end
      end)
      |> case do
        {:ok, applied_manifest} ->
          {:ok, applied_manifest}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp applied_manifest(scope, result) do
    applied_repairs = Enum.reverse(result.applied)

    %{
      "version" => @manifest_version,
      "kind" => @applied_kind,
      "scope" => stringify_scope(scope),
      "applied_repairs" => applied_repairs,
      "summary" => %{
        "created" => length(applied_repairs),
        "already_present" => result.already_present
      }
    }
  end

  defp run_before_commit(_manifest, nil), do: :ok

  defp run_before_commit(manifest, callback) when is_function(callback, 1) do
    case callback.(manifest) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_before_commit_result, other}}
    end
  rescue
    exception -> {:error, exception}
  end

  defp run_before_commit(_manifest, callback),
    do: {:error, {:invalid_before_commit, callback}}

  @doc """
  Removes exactly the topic boosts recorded in an applied manifest.

  Every boost, article URL, post ID, topic, and group relationship is revalidated inside one transaction before deletion.
  """
  def rollback(manifest) when is_map(manifest) do
    with {:ok, scope, repairs} <- validate_applied_manifest(manifest) do
      Repo.transaction(fn ->
        Enum.each(repairs, fn repair ->
          case rollback_repair(scope, repair) do
            :ok -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

        length(repairs)
      end)
      |> case do
        {:ok, count} -> {:ok, count}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Encodes a manifest as stable, human-readable JSON."
  def encode_manifest!(manifest), do: Jason.encode!(manifest, pretty: true)

  @doc "Decodes a repair manifest JSON document."
  def decode_manifest(contents) when is_binary(contents), do: Jason.decode(contents)

  defp validate_scope(opts) do
    with {:ok, group_id} <- validate_id(Keyword.get(opts, :group_id), :group_id),
         {:ok, ghost_url} <- validate_ghost_url(Keyword.get(opts, :ghost_url)),
         {:ok, group} <- load_group(group_id) do
      {:ok, %{group: group, group_id: group_id, ghost_url: ghost_url}}
    end
  end

  defp validate_manifest_scope(%{"group_id" => group_id, "ghost_url" => ghost_url}) do
    validate_scope(group_id: group_id, ghost_url: ghost_url)
  end

  defp validate_manifest_scope(_), do: {:error, :invalid_manifest_scope}

  defp validate_preview_manifest(%{
         "version" => @manifest_version,
         "kind" => @preview_kind,
         "scope" => scope,
         "repairs" => repairs
       })
       when is_map(scope) and is_list(repairs) do
    with {:ok, validated_scope} <- validate_manifest_scope(scope),
         {:ok, validated_repairs} <- validate_repairs(repairs, false) do
      {:ok, validated_scope, validated_repairs}
    end
  end

  defp validate_preview_manifest(_), do: {:error, :invalid_preview_manifest}

  defp validate_applied_manifest(%{
         "version" => @manifest_version,
         "kind" => @applied_kind,
         "scope" => scope,
         "applied_repairs" => repairs
       })
       when is_map(scope) and is_list(repairs) do
    with {:ok, validated_scope} <- validate_manifest_scope(scope),
         {:ok, validated_repairs} <- validate_repairs(repairs, true) do
      {:ok, validated_scope, validated_repairs}
    end
  end

  defp validate_applied_manifest(_), do: {:error, :invalid_applied_manifest}

  defp validate_repairs(repairs, boost_id_required?) do
    repairs
    |> Enum.reduce_while({:ok, []}, fn repair, {:ok, validated} ->
      case validate_repair(repair, boost_id_required?) do
        {:ok, value} -> {:cont, {:ok, [value | validated]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, validated} -> {:ok, Enum.reverse(validated)}
      error -> error
    end
  end

  defp validate_repair(
         %{
           "article_id" => article_id,
           "canonical_uri" => canonical_uri,
           "primary_tag_slug" => primary_tag_slug,
           "topic_id" => topic_id,
           "topic_name" => topic_name,
           "published_at" => published_at
         } = repair,
         boost_id_required?
       )
       when is_binary(canonical_uri) and is_binary(primary_tag_slug) and
              is_binary(topic_name) and (is_binary(published_at) or is_nil(published_at)) do
    with {:ok, article_id} <- validate_id(article_id, :article_id),
         {:ok, topic_id} <- validate_id(topic_id, :topic_id),
         {:ok, boost_id} <- validate_optional_boost_id(repair, boost_id_required?) do
      {:ok,
       repair
       |> Map.put("article_id", article_id)
       |> Map.put("topic_id", topic_id)
       |> maybe_put("boost_id", boost_id)}
    end
  end

  defp validate_repair(_, _), do: {:error, :invalid_manifest_entry}

  defp validate_optional_boost_id(repair, true) do
    repair
    |> Map.get("boost_id")
    |> validate_id(:boost_id)
  end

  defp validate_optional_boost_id(_repair, false), do: {:ok, nil}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp select_repairs(repairs, nil), do: {:ok, repairs}

  defp select_repairs(repairs, article_url) when is_binary(article_url) do
    selected = Enum.filter(repairs, &(&1["canonical_uri"] == article_url))

    case selected do
      [] -> {:error, {:article_not_in_manifest, article_url}}
      _ -> {:ok, selected}
    end
  end

  defp select_repairs(_repairs, article_url),
    do: {:error, {:invalid_article_url, article_url}}

  defp preview_article(scope, article) do
    canonical_uri = article["url"] || ""
    primary_tag_slug = get_in(article, ["primary_tag", "slug"])

    cond do
      not is_binary(article["url"]) or not String.starts_with?(canonical_uri, scope.ghost_url) ->
        {:skip, skipped_entry(article, canonical_uri, "outside_scope")}

      not is_binary(primary_tag_slug) or primary_tag_slug == "" ->
        {:skip, skipped_entry(article, canonical_uri, "missing_primary_tag")}

      true ->
        preview_imported_article(scope, article, canonical_uri, primary_tag_slug)
    end
  end

  defp preview_imported_article(scope, article, canonical_uri, primary_tag_slug) do
    with {:ok, post} <- load_imported_post(canonical_uri),
         {:ok, topic} <- EmbedHelper.find_topic_for_article(scope.group, article) do
      case Boosts.get(topic, post, skip_boundary_check: true) do
        {:ok, _boost} ->
          {:skip, skipped_entry(article, canonical_uri, "already_routed")}

        _ ->
          {:repair,
           %{
             "article_id" => post.id,
             "canonical_uri" => canonical_uri,
             "title" => article["title"],
             "published_at" => article["published_at"],
             "primary_tag_slug" => primary_tag_slug,
             "topic_id" => topic.id,
             "topic_name" => topic.name,
             "comment_count" => comment_count(post.id)
           }}
      end
    else
      {:error, :not_imported} ->
        {:skip, skipped_entry(article, canonical_uri, "not_imported")}

      {:error, :not_found} ->
        {:skip, skipped_entry(article, canonical_uri, "no_unique_topic_match")}

      {:error, reason} ->
        {:skip, skipped_entry(article, canonical_uri, inspect(reason))}
    end
  end

  defp skipped_entry(article, canonical_uri, reason) do
    %{
      "canonical_uri" => canonical_uri,
      "title" => article["title"],
      "reason" => reason
    }
  end

  defp comment_count(post_id) do
    Threads.count_replies(post_id)
  end

  defp apply_repair(scope, repair, current_articles_by_uri) do
    with {:ok, topic} <- load_scoped_topic(scope.group_id, repair["topic_id"]),
         {:ok, current_article} <- load_current_article(current_articles_by_uri, repair),
         :ok <- validate_topic_match(scope, repair, topic, current_article),
         {:ok, post} <- load_imported_post(repair["canonical_uri"], repair["article_id"]) do
      case Boosts.get(topic, post, skip_boundary_check: true) do
        {:ok, _boost} ->
          :already_present

        _ ->
          boost_opts =
            [skip_federation: true, skip_live_push: true, notify_creator: false]
            |> maybe_put_pointer_id(current_article["published_at"])

          case Boosts.maybe_boost(topic, post, boost_opts) do
            {:ok, boost} ->
              {:created, boost.id}

            {:error, reason} ->
              {:error, {:could_not_create_topic_boost, repair["article_id"], reason}}

            other ->
              {:error, {:could_not_create_topic_boost, repair["article_id"], other}}
          end
      end
    end
  end

  defp validate_topic_match(scope, repair, topic, current_article) do
    current_primary_tag_slug = get_in(current_article, ["primary_tag", "slug"])

    with true <-
           current_primary_tag_slug == repair["primary_tag_slug"] ||
             {:error,
              {:primary_tag_changed, repair["canonical_uri"], repair["primary_tag_slug"],
               current_primary_tag_slug}} do
      validate_current_topic_match(scope, repair, topic, current_article)
    end
  end

  defp validate_current_topic_match(scope, repair, topic, current_article) do
    case EmbedHelper.find_topic_for_article(scope.group, current_article) do
      {:ok, %{id: resolved_topic_id} = resolved_topic} ->
        cond do
          resolved_topic_id != topic.id ->
            {:error, {:topic_does_not_match_primary_tag, topic.id}}

          resolved_topic.name != repair["topic_name"] ->
            {:error, {:topic_name_changed, topic.id}}

          true ->
            :ok
        end

      _ ->
        {:error, {:primary_tag_no_longer_has_unique_topic, repair["primary_tag_slug"]}}
    end
  end

  defp rollback_repair(scope, repair) do
    with {:ok, topic} <- load_scoped_topic(scope.group_id, repair["topic_id"]),
         {:ok, post} <- load_imported_post(repair["canonical_uri"], repair["article_id"]),
         {:ok, _} <- Boosts.unboost_by_id(repair["boost_id"], topic, post) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:could_not_rollback_topic_boost, repair["article_id"], other}}
    end
  end

  defp maybe_put_pointer_id(opts, published_at) do
    case DatesTimes.generate_ulid_if_past(published_at) do
      pointer_id when is_binary(pointer_id) -> Keyword.put(opts, :pointer_id, pointer_id)
      _ -> opts
    end
  end

  defp load_imported_post(canonical_uri, expected_id \\ nil) do
    with {:ok, %{id: article_id}} <- Peered.get_by_uri(canonical_uri),
         true <- is_nil(expected_id) or article_id == expected_id,
         {:ok, post} <- Needles.get(article_id, skip_boundary_check: true) do
      {:ok, post}
    else
      false -> {:error, {:article_id_changed, canonical_uri}}
      _ -> {:error, :not_imported}
    end
  end

  defp load_group(group_id) do
    case Bonfire.Classify.Categories.get(group_id, skip_boundary_check: true) do
      {:ok, %{type: type} = group} when type in [:group, "group"] -> {:ok, group}
      {:ok, _} -> {:error, {:not_a_group, group_id}}
      _ -> {:error, {:group_not_found, group_id}}
    end
  end

  defp load_scoped_topic(group_id, topic_id) do
    case Bonfire.Classify.Categories.one(
           [id: topic_id, parent_category: group_id, type: :topic, preload: :character],
           skip_boundary_check: true
         ) do
      {:ok, topic} -> {:ok, topic}
      _ -> {:error, {:topic_no_longer_in_group, topic_id, group_id}}
    end
  end

  defp articles_snapshot(opts) do
    case Keyword.get(opts, :articles) do
      articles when is_list(articles) -> {:ok, articles}
      nil -> fetch_published_articles()
      invalid -> {:error, {:invalid_articles, invalid}}
    end
  end

  defp index_current_articles(articles) do
    articles
    |> Enum.reduce_while({:ok, %{}}, fn article, {:ok, indexed} ->
      case article["url"] do
        canonical_uri when is_binary(canonical_uri) and canonical_uri != "" ->
          if Map.has_key?(indexed, canonical_uri) do
            {:halt, {:error, {:duplicate_current_ghost_article, canonical_uri}}}
          else
            {:cont, {:ok, Map.put(indexed, canonical_uri, article)}}
          end

        _ ->
          {:halt, {:error, :invalid_current_ghost_article}}
      end
    end)
  end

  defp load_current_article(current_articles_by_uri, repair) do
    case Map.fetch(current_articles_by_uri, repair["canonical_uri"]) do
      {:ok, article} -> {:ok, article}
      :error -> {:error, {:current_ghost_article_not_found, repair["canonical_uri"]}}
    end
  end

  defp fetch_published_articles do
    cond do
      Ghost.admin_configured?() ->
        with {:ok, client} <- Ghost.admin_client() do
          paginate_articles(fn page ->
            AdminAPI.list_posts(client,
              limit: @page_limit,
              page: page,
              include: "tags,authors",
              filter: "status:published"
            )
          end)
        end

      Ghost.configured?() ->
        with {:ok, client} <- Ghost.client() do
          paginate_articles(fn page ->
            API.list_posts(client, limit: @page_limit, page: page, include: "tags,authors")
          end)
        end

      true ->
        {:error, :not_configured}
    end
  end

  defp paginate_articles(fetch_page, page \\ 1, articles \\ []) do
    case fetch_page.(page) do
      {:ok, %{"posts" => posts, "meta" => meta}} when is_list(posts) ->
        accumulated = articles ++ posts

        case next_page(meta) do
          nil -> {:ok, accumulated}
          next when next > page -> paginate_articles(fetch_page, next, accumulated)
          next -> {:error, {:pagination_did_not_advance, page, next}}
        end

      {:ok, %{"posts" => posts}} when is_list(posts) ->
        {:ok, articles ++ posts}

      {:ok, _} ->
        {:error, :invalid_posts_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp next_page(%{"pagination" => %{"next" => next}}) when is_integer(next), do: next

  defp next_page(%{"pagination" => %{"next" => next}}) when is_binary(next) do
    case Integer.parse(next) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp next_page(_), do: nil

  defp validate_id(value, field) when is_binary(value) do
    case Needle.UID.cast(value) do
      {:ok, id} when not is_nil(id) -> {:ok, id}
      _ -> {:error, {:invalid_id, field, value}}
    end
  end

  defp validate_id(value, field), do: {:error, {:invalid_id, field, value}}

  defp validate_ghost_url(value) when is_binary(value) do
    trimmed = String.trim(value)
    uri = URI.parse(trimmed)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      {:ok, String.trim_trailing(trimmed, "/") <> "/"}
    else
      {:error, {:invalid_ghost_url, value}}
    end
  end

  defp validate_ghost_url(value), do: {:error, {:invalid_ghost_url, value}}

  defp stringify_scope(scope) do
    %{"group_id" => scope.group_id, "ghost_url" => scope.ghost_url}
  end
end
