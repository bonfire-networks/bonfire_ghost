defmodule Bonfire.Ghost.Sync.Articles do
  @moduledoc """
  One-off backfill of **historical** Ghost articles into Bonfire posts.

  Webhooks (`Bonfire.Ghost.Workers.ArticleWebhookWorker`) keep articles in sync going forward, but posts published *before* webhooks were configured never got imported. This module paginates the Ghost API (preferring the Admin API, which returns full `html` for gated posts too, and falling back to the Content API) and runs each published article through the same import path as webhooks — `Bonfire.Ghost.EmbedHelper.import_article/2` — so the configured author, group/topic routing, tag filter, and topic-matching all apply identically.

  Unlike the passive webhook auto-import, this is an **explicit operator action** and therefore does *not* gate on the `[:bonfire_ghost, :auto_import_articles]` toggle. It still honors every other import setting.

  Re-running is safe: `import_article/2` upserts by canonical URL, so an already-imported article is updated in place rather than duplicated (and unlike webhooks, articles rejected by the tag filter are skipped, never hidden).

  Returns `{:ok, summary}` where `summary` counts successful upserts, articles skipped by the configured tag filter, and per-article errors (a single bad article never aborts the whole backfill), or `{:error, reason}` when a page fetch fails (so the Oban job retries) or Ghost has no credentials at all.

  Progress is also written to `Bonfire.Common.Cache` after every imported article (see
  `status/0`), so the settings page can show what the background job is doing instead of
  the backfill being a black box that only reports to server logs.
  """

  import Untangle

  alias Bonfire.Common.Cache
  alias Bonfire.Ghost
  alias Bonfire.Ghost.API
  alias Bonfire.Ghost.AdminAPI
  alias Bonfire.Ghost.EmbedHelper

  # Ghost caps `limit` at 100; 50 keeps each page's payload modest.
  @page_limit 50

  @status_cache_key "ghost_article_sync_status"
  # Keep the last outcome around long enough that an admin coming back the next day
  # still sees what happened (the cache default would drop it after 6h).
  @status_ttl 1_000 * 60 * 60 * 24 * 7
  # The status is rewritten after every article, so cap the error detail we carry along.
  @max_stored_errors 20

  @type sync_summary :: %{
          synced: non_neg_integer(),
          filtered: non_neg_integer(),
          errors: [{String.t(), term()}]
        }

  @empty_summary %{synced: 0, filtered: 0, errors: []}

  @doc """
  Fetches every published Ghost article (paginated) and imports each one.

  Prefers the Admin API (full `html` for gated posts too), falling back to the
  Content API when only Content credentials are configured.

  `opts` are forwarded to `EmbedHelper.import_article/2` — normally empty so the
  instance-configured author/group/tag/topic settings are used.
  """
  @spec sync_all(keyword()) :: {:ok, sync_summary()} | {:error, term()}
  def sync_all(opts \\ []) do
    cond do
      Ghost.admin_configured?() ->
        with_status_tracking(fn ->
          paginate_and_import(&fetch_admin_page/1, 1, @empty_summary, opts)
        end)

      Ghost.configured?() ->
        with_status_tracking(fn ->
          paginate_and_import(&fetch_content_page/1, 1, @empty_summary, opts)
        end)

      true ->
        put_status(%{
          state: :failed,
          reason: "Ghost is not configured",
          finished_at: DateTime.utc_now()
        })

        {:error, :not_configured}
    end
  end

  @doc """
  Current backfill status for the settings UI, or nil when none ran recently.

  A map with `:state` (`:queued` | `:running` | `:retrying` | `:done` | `:failed`) plus
  progress counters (`:page`, `:synced`, `:filtered`, `:errors_count`), a capped
  `:errors` list of `%{article: label, reason: string}`, timestamps, and — when set by
  the Oban worker after a failed attempt — `:reason`, `:attempt` and `:max_attempts`.
  """
  def status, do: Cache.get!(@status_cache_key)

  @doc "Overwrites the backfill status shown on the settings page. Returns the map."
  def put_status(map) when is_map(map) do
    # `async: false`: status updates are read-modify-write and must land in order —
    # the default fire-and-forget put could apply a stale :running over the final :done.
    Cache.put(@status_cache_key, map, expire: @status_ttl, async: false)
    map
  end

  @doc "Forgets the stored backfill status (mainly for tests)."
  def clear_status, do: Cache.remove(@status_cache_key)

  @doc "Human-readable rendering of an error reason for the settings UI."
  def format_reason(reason) when is_binary(reason), do: reason
  def format_reason(%{__exception__: true} = e), do: Exception.message(e)
  def format_reason(reason) when is_atom(reason), do: to_string(reason)
  def format_reason(reason), do: reason |> inspect() |> String.slice(0, 500)

  defp with_status_tracking(fun) do
    put_status(%{
      state: :running,
      started_at: DateTime.utc_now(),
      page: 1,
      synced: 0,
      filtered: 0,
      errors_count: 0,
      errors: []
    })

    case fun.() do
      {:ok, summary} ->
        report_progress(summary, %{state: :done, finished_at: DateTime.utc_now()})
        {:ok, summary}

      {:error, reason} = e ->
        # The Oban worker may overwrite this right after with retry info (attempt count).
        report_progress_extra(%{
          state: :failed,
          reason: format_reason(reason),
          finished_at: DateTime.utc_now()
        })

        e
    end
  end

  # Merges the running summary's counters into the cached status (keeping started_at,
  # page, etc.) and returns the summary so it can be used in a pipeline.
  defp report_progress(summary, extra \\ %{}) do
    report_progress_extra(
      Map.merge(
        %{
          synced: summary.synced,
          filtered: summary.filtered,
          errors_count: length(summary.errors),
          errors: stored_errors(summary.errors)
        },
        extra
      )
    )

    summary
  end

  defp report_progress_extra(extra) do
    put_status(Map.merge(status() || %{}, extra))
  end

  # Errors are prepended as they happen, so taking from the front keeps the most recent.
  defp stored_errors(errors) do
    errors
    |> Enum.take(@max_stored_errors)
    |> Enum.map(fn {label, reason} -> %{article: label, reason: format_reason(reason)} end)
  end

  # A fresh client per page keeps the short-lived Admin JWT (5 min) valid across a
  # long backfill; the Content API key doesn't expire but is recreated for symmetry.
  defp fetch_admin_page(page) do
    with {:ok, c} <- Ghost.admin_client() do
      # `tiers` is needed so tier-gated ("tiers" visibility) articles carry the tier
      # list EmbedHelper reads to grant the matching ghost_tier circles :read.
      # The Admin API returns drafts/scheduled too — restrict to published, matching
      # the Content API's behavior (and what a "historical articles" backfill means).
      AdminAPI.list_posts(c,
        limit: @page_limit,
        page: page,
        include: "tags,authors,tiers",
        filter: "status:published"
      )
    end
  end

  # Content-API fallback: gated posts already come back with truncated html here, so
  # `tiers` isn't requested (it isn't a Content API post include and would 422).
  defp fetch_content_page(page) do
    with {:ok, c} <- Ghost.client() do
      API.list_posts(c, limit: @page_limit, page: page)
    end
  end

  # `on_filtered: :skip` — a bulk backfill must never retroactively hide posts (created
  # via embeds or before the tag filter existed) just because they don't match the filter.
  defp paginate_and_import(fetch_page, page, summary, opts) do
    opts = Keyword.put_new(opts, :on_filtered, :skip)
    report_progress_extra(%{page: page})

    case fetch_page.(page) do
      {:ok, %{"posts" => posts, "meta" => meta}} when is_list(posts) ->
        summary = Enum.reduce(posts, summary, &import_one(&1, &2, opts))

        case next_page(meta) do
          nil ->
            {:ok, summary}

          next when next > page ->
            paginate_and_import(fetch_page, next, summary, opts)

          next ->
            warn(
              %{page: page, next: next},
              "Ghost articles pagination did not advance, stopping backfill"
            )

            {:ok, summary}
        end

      {:ok, %{"posts" => posts}} when is_list(posts) ->
        {:ok, Enum.reduce(posts, summary, &import_one(&1, &2, opts))}

      {:ok, other} ->
        error(other, "Ghost articles backfill returned an unexpected payload")
        {:error, :invalid_posts_payload}

      # Propagate fetch failures (Ghost unreachable, bad/expired key) so the Oban job
      # fails and retries — rather than reporting a zero-import run as success.
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp import_one(post, summary, opts) do
    case EmbedHelper.import_article(post, opts) do
      {:ok, :filtered_out} ->
        %{summary | filtered: summary.filtered + 1}

      {:ok, _post} ->
        %{summary | synced: summary.synced + 1}

      {:error, reason} ->
        %{summary | errors: [{article_label(post), reason} | summary.errors]}
    end
    |> report_progress()
  rescue
    e ->
      warn(e, "Failed to import a Ghost article during backfill")
      report_progress(%{summary | errors: [{article_label(post), e} | summary.errors]})
  end

  defp article_label(post), do: post["url"] || post["slug"] || post["id"] || "?"

  # Ghost's `meta.pagination.next` is the next page number (or a stringified one from
  # some responses), or null on the last page.
  defp next_page(%{"pagination" => %{"next" => next}}) when is_integer(next), do: next

  defp next_page(%{"pagination" => %{"next" => next}}) when is_binary(next) do
    case Integer.parse(next) do
      {page, ""} -> page
      _ -> nil
    end
  end

  defp next_page(_), do: nil
end
