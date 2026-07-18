defmodule Bonfire.Ghost.Sync.Articles do
  @moduledoc """
  One-off backfill of **historical** Ghost articles into Bonfire posts.

  Webhooks (`Bonfire.Ghost.Workers.ArticleWebhookWorker`) keep articles in sync going forward, but posts published *before* webhooks were configured never got imported. This module paginates the Ghost API (preferring the Admin API, which returns full `html` for gated posts too, and falling back to the Content API) and runs each published article through the same import path as webhooks — `Bonfire.Ghost.EmbedHelper.import_article/2` — so the configured author, group/topic routing, tag filter, and topic-matching all apply identically.

  Unlike the passive webhook auto-import, this is an **explicit operator action** and therefore does *not* gate on the `[:bonfire_ghost, :auto_import_articles]` toggle. It still honors every other import setting.

  Re-running is safe: `import_article/2` upserts by canonical URL, so an already-imported article is updated in place rather than duplicated (and unlike webhooks, articles rejected by the tag filter are skipped, never hidden).

  Returns `{:ok, summary}` where `summary` counts successful upserts, articles skipped by the configured tag filter, and per-article errors (a single bad article never aborts the whole backfill), or `{:error, reason}` when a page fetch fails (so the Oban job retries) or Ghost has no credentials at all.

  Progress is also written to `Bonfire.Common.Cache` after every imported article (see `status/0`) so the settings page can show what the background job is doing.
  """

  import Untangle

  alias Bonfire.Common.Cache
  alias Bonfire.Common.Config
  # Config.get/2 is a macro
  require Config
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

  # Oban does not time out `perform`, so a blocked import would otherwise freeze the whole backfill.
  @default_import_timeout :timer.minutes(2)

  @type sync_summary :: %{
          synced: non_neg_integer(),
          filtered: non_neg_integer(),
          errors_count: non_neg_integer(),
          errors: [{String.t(), term()}]
        }

  @empty_summary %{synced: 0, filtered: 0, errors_count: 0, errors: []}
  @sync_option_keys [:checkpoint, :job_id, :on_checkpoint, :restart]

  @doc """
  Fetches every published Ghost article (paginated) and imports each one.

  Prefers the Admin API (full `html` for gated posts too), falling back to the Content API when only Content credentials are configured.

  Import-related `opts` are forwarded to `EmbedHelper.import_article/2`. Worker-only checkpoint options are consumed here and never forwarded to the importer.
  """
  @spec sync_all(keyword()) :: {:ok, sync_summary()} | {:error, term()}
  def sync_all(opts \\ []) do
    {sync_opts, import_opts} = Keyword.split(opts, @sync_option_keys)
    {start_page, start_summary} = resume_point(sync_opts)

    cond do
      Ghost.admin_configured?() ->
        with_status_tracking(start_page, start_summary, sync_opts, fn ->
          paginate_and_import(
            &fetch_admin_page/1,
            start_page,
            start_summary,
            sync_opts,
            import_opts
          )
        end)

      Ghost.configured?() ->
        with_status_tracking(start_page, start_summary, sync_opts, fn ->
          paginate_and_import(
            &fetch_content_page/1,
            start_page,
            start_summary,
            sync_opts,
            import_opts
          )
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

  # Cache-backed UI status is not execution state: it disappears on restart and represents partially completed pages.
  defp resume_point(opts) do
    with false <- Keyword.get(opts, :restart, false),
         checkpoint when is_map(checkpoint) <- Keyword.get(opts, :checkpoint),
         page when is_integer(page) <- checkpoint_value(checkpoint, :page),
         true <- page > 1 do
      info(page, "Resuming Ghost article backfill from durable checkpoint")

      {page,
       %{
         @empty_summary
         | synced: checkpoint_count(checkpoint, :synced),
           filtered: checkpoint_count(checkpoint, :filtered),
           errors_count: checkpoint_count(checkpoint, :errors_count),
           errors: checkpoint_errors(checkpoint)
       }}
    else
      _ -> {1, @empty_summary}
    end
  end

  defp checkpoint_value(checkpoint, key),
    do: Map.get(checkpoint, key) || Map.get(checkpoint, to_string(key))

  defp checkpoint_count(checkpoint, key) do
    case checkpoint_value(checkpoint, key) do
      count when is_integer(count) and count >= 0 -> count
      _ -> 0
    end
  end

  defp checkpoint_errors(checkpoint) do
    checkpoint
    |> checkpoint_value(:errors)
    |> case do
      errors when is_list(errors) -> errors
      _ -> []
    end
    |> Enum.flat_map(fn
      %{} = error ->
        case {checkpoint_value(error, :article), checkpoint_value(error, :reason)} do
          {article, reason} when is_binary(article) and is_binary(reason) -> [{article, reason}]
          _ -> []
        end

      _ ->
        []
    end)
  end

  @doc """
  Current backfill status for the settings UI, or nil when none ran recently.

  A map with `:state` (`:queued` | `:running` | `:retrying` | `:done` | `:failed`) plus
  progress counters (`:page`, `:synced`, `:filtered`, `:errors_count`), a capped
  `:errors` list of `%{article: label, reason: string}`, the `:current` article label,
  timestamps (including the `:updated_at` heartbeat — see `put_status/1`), and — when
  set by the Oban worker after a failed attempt — `:reason`, `:attempt` and
  `:max_attempts`.
  """
  def status, do: Cache.get!(@status_cache_key)

  @doc """
  Overwrites the backfill status shown on the settings page. Returns the map.

  Every write also stamps `:updated_at`, which the settings UI uses as a heartbeat: an
  in-flight status whose heartbeat is minutes old means the job died or hung, so the UI
  can say so (and re-enable the sync button) instead of showing a spinner forever.
  """
  def put_status(map) when is_map(map) do
    map = Map.put(map, :updated_at, DateTime.utc_now())
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

  defp with_status_tracking(start_page, start_summary, sync_opts, fun) do
    %{
      state: :running,
      started_at: DateTime.utc_now(),
      page: start_page,
      synced: start_summary.synced,
      filtered: start_summary.filtered,
      errors_count: start_summary.errors_count,
      errors: stored_errors(start_summary.errors)
    }
    |> maybe_put(:job_id, Keyword.get(sync_opts, :job_id))
    |> put_status()

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
          errors_count: summary.errors_count,
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
  defp paginate_and_import(fetch_page, page, summary, sync_opts, import_opts) do
    import_opts = Keyword.put_new(import_opts, :on_filtered, :skip)
    report_progress_extra(%{page: page})

    case fetch_page.(page) do
      {:ok, %{"posts" => posts, "meta" => meta}} when is_list(posts) ->
        summary = Enum.reduce(posts, summary, &import_one(&1, &2, import_opts))

        case next_page(meta) do
          nil ->
            {:ok, summary}

          next when next > page ->
            with :ok <- persist_checkpoint(sync_opts, next, summary) do
              paginate_and_import(fetch_page, next, summary, sync_opts, import_opts)
            end

          next ->
            warn(
              %{page: page, next: next},
              "Ghost articles pagination did not advance, stopping backfill"
            )

            {:ok, summary}
        end

      {:ok, %{"posts" => posts}} when is_list(posts) ->
        {:ok, Enum.reduce(posts, summary, &import_one(&1, &2, import_opts))}

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
    label = article_label(post)
    report_progress_extra(%{current: label, stage: :starting})

    timeout = import_timeout()
    owner = self()
    result_ref = make_ref()
    stage_ref = make_ref()

    on_stage = fn stage ->
      send(owner, {stage_ref, stage})
      report_progress_extra(%{stage: stage})
    end

    {:ok, pid} =
      Task.start(fn ->
        receive do
          {^result_ref, :run} ->
            result = try_import(post, Keyword.put(opts, :on_stage, on_stage))
            send(owner, {result_ref, result})
        end
      end)

    monitor_ref = Process.monitor(pid)
    send(pid, {result_ref, :run})
    result = await_import(pid, monitor_ref, result_ref, timeout)

    case result do
      {:ok, :synced} ->
        latest_stage(stage_ref, :starting)
        %{summary | synced: summary.synced + 1}

      {:ok, :filtered} ->
        latest_stage(stage_ref, :starting)
        %{summary | filtered: summary.filtered + 1}

      {:ok, {:error, reason}} ->
        latest_stage(stage_ref, :starting)
        add_error(summary, label, reason)

      :timeout ->
        stacktrace = process_stacktrace(pid)
        stop_import(pid, monitor_ref)
        stage = latest_stage(stage_ref, :starting)
        reason = timeout_reason(timeout, stage, stacktrace)

        warn(
          %{article: label, stage: stage, stacktrace: stacktrace, timeout: timeout},
          "Ghost article import timed out — skipping this article and continuing"
        )

        add_error(summary, label, reason)

      {:exit, reason} ->
        stage = latest_stage(stage_ref, :starting)

        warn(
          %{article: label, stage: stage, reason: reason},
          "Ghost article import process crashed — skipping this article and continuing"
        )

        add_error(
          summary,
          label,
          "Import process crashed during #{format_stage(stage)}: #{format_reason(reason)}"
        )
    end
    |> report_progress()
  end

  defp await_import(pid, monitor_ref, result_ref, timeout) do
    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        {:ok, result}

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:exit, reason}
    after
      timeout -> :timeout
    end
  end

  defp latest_stage(stage_ref, latest) do
    receive do
      {^stage_ref, stage} -> latest_stage(stage_ref, stage)
    after
      0 -> latest
    end
  end

  defp stop_import(pid, monitor_ref) do
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      1_000 -> Process.demonitor(monitor_ref, [:flush])
    end
  end

  defp add_error(summary, label, reason) do
    %{
      summary
      | errors: [{label, reason} | summary.errors],
        errors_count: summary.errors_count + 1
    }
  end

  defp process_stacktrace(pid) do
    case Process.info(pid, :current_stacktrace) do
      {:current_stacktrace, stacktrace} ->
        stacktrace
        |> Enum.take(8)
        |> Enum.map(&sanitize_stacktrace_entry/1)
        |> Exception.format_stacktrace()
        |> String.trim()
        |> String.slice(0, 1_500)

      _ ->
        "unavailable"
    end
  end

  defp sanitize_stacktrace_entry({module, function, args, location}) when is_list(args),
    do: {module, function, length(args), location}

  defp sanitize_stacktrace_entry(entry), do: entry

  defp timeout_reason(timeout, stage, stacktrace) do
    "Import timed out after #{div(timeout, 1000)}s during #{format_stage(stage)}. Worker stack: #{stacktrace}"
  end

  defp format_stage(stage) when is_atom(stage),
    do: stage |> Atom.to_string() |> String.replace("_", " ")

  defp format_stage(_), do: "an unknown stage"

  defp persist_checkpoint(sync_opts, next_page, summary) do
    case Keyword.get(sync_opts, :on_checkpoint) do
      nil ->
        :ok

      on_checkpoint when is_function(on_checkpoint, 1) ->
        checkpoint = checkpoint(next_page, summary)

        case on_checkpoint.(checkpoint) do
          :ok -> :ok
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:checkpoint_failed, reason}}
          other -> {:error, {:checkpoint_failed, other}}
        end
    end
  rescue
    e -> {:error, {:checkpoint_failed, e}}
  catch
    kind, reason -> {:error, {:checkpoint_failed, {kind, reason}}}
  end

  defp checkpoint(next_page, summary) do
    %{
      "page" => next_page,
      "synced" => summary.synced,
      "filtered" => summary.filtered,
      "errors_count" => summary.errors_count,
      "errors" =>
        summary.errors
        |> stored_errors()
        |> Enum.map(fn error ->
          %{"article" => error.article, "reason" => error.reason}
        end)
    }
  end

  defp try_import(post, opts) do
    case EmbedHelper.import_article(post, opts) do
      {:ok, :filtered_out} -> :filtered
      {:ok, _post} -> :synced
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  rescue
    e ->
      warn(e, "Failed to import a Ghost article during backfill")
      {:error, e}
  catch
    kind, reason ->
      warn({kind, reason}, "Failed to import a Ghost article during backfill")
      {:error, {kind, reason}}
  end

  defp import_timeout do
    case Config.get([:bonfire_ghost, :article_import_timeout], @default_import_timeout) do
      timeout when is_integer(timeout) and timeout > 0 ->
        timeout

      invalid_timeout ->
        warn(invalid_timeout, "Invalid Ghost article import timeout; using the default")
        @default_import_timeout
    end
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
