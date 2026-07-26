defmodule Bonfire.Ghost.TopicBoostDateRepair do
  @moduledoc """
  Previews and repairs category boosts whose IDs make imported Ghost articles appear newer than their publication dates.

  Repairs are intentionally manifest-driven. A preview records the exact scope and old/new IDs; applying or rolling back revalidates every row against that scope inside a transaction before changing a pointer ID.
  """

  import Ecto.Query

  alias Bonfire.Common.DatesTimes
  alias Bonfire.Common.Repo
  alias Bonfire.Data.ActivityPub.Peered
  alias Bonfire.Data.Edges.Edge
  alias Bonfire.Data.Social.Created
  alias Needle.Pointer

  @manifest_version 1
  @boost_table_id "300STANN0VNCERESHARESH0VTS"
  @article_table_id "7ARTC1ESF0RB0NF1REP0STS000"
  @category_table_id "2AGSCANBECATEG0RY0RHASHTAG"

  @doc """
  Builds a repair manifest for one exact topic, Ghost URL prefix, and import author.

  This function is read-only.
  """
  def preview(opts) when is_list(opts) do
    with {:ok, scope} <- validate_scope(opts) do
      repairs =
        scope
        |> list_scoped_boosts()
        |> Enum.filter(&incorrectly_dated?/1)
        |> Enum.map(&manifest_entry/1)

      {:ok,
       %{
         "version" => @manifest_version,
         "scope" => stringify_scope(scope),
         "repairs" => repairs
       }}
    end
  end

  @doc """
  Applies a previously generated manifest after revalidating every candidate.

  Updating the shared pointer ID cascades to its related edge, activity, ACL, and feed rows without running federation, notifications, or live push.
  """
  def apply(%{} = manifest), do: repair(manifest, :forward)

  @doc """
  Rolls back a previously applied manifest after revalidating every candidate.
  """
  def rollback(%{} = manifest), do: repair(manifest, :backward)

  @doc """
  Encodes a manifest as stable, human-readable JSON.
  """
  def encode_manifest!(manifest), do: Jason.encode!(manifest, pretty: true)

  @doc """
  Decodes a manifest JSON document.
  """
  def decode_manifest(contents) when is_binary(contents), do: Jason.decode(contents)

  defp repair(manifest, direction) do
    with {:ok, scope, repairs} <- validate_manifest(manifest) do
      Repo.transaction(fn ->
        Enum.each(repairs, &repair_entry(&1, scope, direction))
        length(repairs)
      end)
      |> case do
        {:ok, repaired_count} -> {:ok, repaired_count}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp repair_entry(entry, scope, direction) do
    {current_id, replacement_id} =
      case direction do
        :forward -> {entry.old_boost_id, entry.new_boost_id}
        :backward -> {entry.new_boost_id, entry.old_boost_id}
      end

    with {:ok, candidate} <- get_scoped_boost(scope, current_id, lock: true),
         :ok <- validate_candidate(candidate, entry),
         false <- Repo.exists?(from(pointer in Pointer, where: pointer.id == ^replacement_id)),
         %{num_rows: 1} <-
           Repo.query!(
             "UPDATE pointers_pointer SET id = $1 WHERE id = $2",
             [Needle.UID.dump!(replacement_id), Needle.UID.dump!(current_id)]
           ) do
      :ok
    else
      true -> Repo.rollback({:replacement_id_already_exists, replacement_id})
      {:error, reason} -> Repo.rollback(reason)
      %{num_rows: count} -> Repo.rollback({:unexpected_update_count, current_id, count})
      other -> Repo.rollback({:repair_failed, current_id, other})
    end
  end

  defp validate_manifest(%{
         "version" => @manifest_version,
         "scope" => scope,
         "repairs" => repairs
       })
       when is_map(scope) and is_list(repairs) do
    with {:ok, validated_scope} <-
           validate_scope(
             topic_id: scope["topic_id"],
             ghost_url: scope["ghost_url"],
             author_id: scope["author_id"]
           ),
         {:ok, validated_repairs} <- validate_manifest_entries(repairs) do
      {:ok, validated_scope, validated_repairs}
    end
  end

  defp validate_manifest(_), do: {:error, :invalid_manifest}

  defp validate_manifest_entries(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, validated} ->
      case validate_manifest_entry(entry) do
        {:ok, value} -> {:cont, {:ok, [value | validated]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, validated} -> {:ok, Enum.reverse(validated)}
      error -> error
    end
  end

  defp validate_manifest_entry(%{
         "old_boost_id" => old_boost_id,
         "new_boost_id" => new_boost_id,
         "article_id" => article_id,
         "canonical_uri" => canonical_uri
       })
       when is_binary(canonical_uri) do
    with {:ok, old_boost_id} <- validate_id(old_boost_id, :old_boost_id),
         {:ok, new_boost_id} <- validate_id(new_boost_id, :new_boost_id),
         {:ok, article_id} <- validate_id(article_id, :article_id),
         ^new_boost_id <- backdated_boost_id(old_boost_id, article_id) do
      {:ok,
       %{
         old_boost_id: old_boost_id,
         new_boost_id: new_boost_id,
         article_id: article_id,
         canonical_uri: canonical_uri
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:new_boost_id_does_not_match_article, new_boost_id}}
    end
  end

  defp validate_manifest_entry(_), do: {:error, :invalid_manifest_entry}

  defp validate_scope(opts) do
    with {:ok, topic_id} <- validate_id(Keyword.get(opts, :topic_id), :topic_id),
         {:ok, author_id} <- validate_id(Keyword.get(opts, :author_id), :author_id),
         {:ok, ghost_url} <- validate_ghost_url(Keyword.get(opts, :ghost_url)) do
      {:ok, %{topic_id: topic_id, author_id: author_id, ghost_url: ghost_url}}
    end
  end

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

  defp list_scoped_boosts(scope) do
    scoped_boost_query(scope)
    |> Repo.all()
  end

  defp get_scoped_boost(scope, boost_id, opts) do
    query =
      scope
      |> scoped_boost_query()
      |> where([boost_pointer: boost_pointer], boost_pointer.id == ^boost_id)
      |> limit(1)

    query =
      if Keyword.get(opts, :lock, false) do
        lock(query, "FOR UPDATE")
      else
        query
      end

    case Repo.one(query) do
      nil -> {:error, {:candidate_no_longer_matches_scope, boost_id}}
      candidate -> {:ok, candidate}
    end
  end

  defp scoped_boost_query(scope) do
    from(edge in Edge,
      as: :edge,
      join: boost_pointer in Pointer,
      as: :boost_pointer,
      on: boost_pointer.id == edge.id,
      join: article_pointer in Pointer,
      as: :article_pointer,
      on: article_pointer.id == edge.object_id,
      join: topic_pointer in Pointer,
      as: :topic_pointer,
      on: topic_pointer.id == edge.subject_id,
      join: peered in Peered,
      as: :peered,
      on: peered.id == article_pointer.id,
      join: created in Created,
      as: :created,
      on: created.id == article_pointer.id,
      where:
        edge.table_id == ^@boost_table_id and
          boost_pointer.table_id == ^@boost_table_id and
          is_nil(boost_pointer.deleted_at) and
          article_pointer.table_id == ^@article_table_id and
          is_nil(article_pointer.deleted_at) and
          topic_pointer.table_id == ^@category_table_id and
          is_nil(topic_pointer.deleted_at) and
          edge.subject_id == ^scope.topic_id and
          created.creator_id == ^scope.author_id and
          fragment("starts_with(?, ?)", peered.canonical_uri, ^scope.ghost_url),
      select: %{
        boost_id: boost_pointer.id,
        article_id: article_pointer.id,
        canonical_uri: peered.canonical_uri
      }
    )
  end

  defp incorrectly_dated?(candidate) do
    DateTime.compare(
      DatesTimes.date_from_pointer(candidate.boost_id),
      DatesTimes.date_from_pointer(candidate.article_id)
    ) == :gt
  end

  defp manifest_entry(candidate) do
    %{
      "old_boost_id" => candidate.boost_id,
      "new_boost_id" => backdated_boost_id(candidate.boost_id, candidate.article_id),
      "article_id" => candidate.article_id,
      "canonical_uri" => candidate.canonical_uri,
      "old_boost_date" =>
        candidate.boost_id |> DatesTimes.date_from_pointer() |> DateTime.to_iso8601(),
      "new_boost_date" =>
        candidate.article_id |> DatesTimes.date_from_pointer() |> DateTime.to_iso8601()
    }
  end

  defp backdated_boost_id(boost_id, article_id) do
    <<_boost_timestamp::binary-size(6), boost_randomness::binary-size(10)>> =
      Needle.UID.dump!(boost_id)

    <<article_timestamp::binary-size(6), _article_randomness::binary-size(10)>> =
      Needle.UID.dump!(article_id)

    {:ok, new_boost_id} = Needle.UID.load(article_timestamp <> boost_randomness)
    new_boost_id
  end

  defp validate_candidate(candidate, entry) do
    cond do
      candidate.article_id != entry.article_id ->
        {:error, {:article_changed, candidate.boost_id}}

      candidate.canonical_uri != entry.canonical_uri ->
        {:error, {:canonical_uri_changed, candidate.boost_id}}

      backdated_boost_id(entry.old_boost_id, entry.article_id) != entry.new_boost_id ->
        {:error, {:new_boost_id_does_not_match_article, entry.new_boost_id}}

      true ->
        :ok
    end
  end

  defp stringify_scope(scope) do
    %{
      "topic_id" => scope.topic_id,
      "author_id" => scope.author_id,
      "ghost_url" => scope.ghost_url
    }
  end
end
