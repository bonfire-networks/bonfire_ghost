defmodule Bonfire.Ghost.Workers.ArticleSyncWorker do
  @moduledoc """
  Oban worker for the one-off Ghost **article** backfill.

  Mirrors `Bonfire.Ghost.Workers.MemberSyncWorker`: the settings page enqueues a single job so the request stays fast and the (potentially long, paginated) import runs in the background with Oban's retries.

  Delegates to `Bonfire.Ghost.Sync.Articles.sync_all/1`, which imports every published Ghost article through the same path as webhooks. Unlike the webhook worker this is an explicit operator action, so it does **not** gate on the `[:bonfire_ghost, :auto_import_articles]` toggle.
  """

  use Oban.Worker,
    queue: :ghost_webhooks,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  import Untangle

  alias Bonfire.Ghost.Sync.Articles

  @checkpoint_key "article_sync_checkpoint"

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max_attempts} = job)
      when is_map(args) do
    checkpoint = Map.get(job.meta || %{}, @checkpoint_key)

    sync_opts = [
      checkpoint: checkpoint,
      job_id: job.id,
      on_checkpoint: &persist_checkpoint(job.id, &1)
    ]

    case Articles.sync_all(sync_opts) do
      {:ok, summary} ->
        info(summary, "Ghost article backfill complete")
        warn_errors(summary)
        :ok

      {:error, :not_configured} ->
        # Deterministic — retrying won't help.
        {:cancel, :not_configured}

      {:error, reason} = e ->
        error(reason, "Ghost article backfill failed")

        # Preserve the failure details while exposing whether Oban will retry it.
        Articles.put_status(
          Map.merge(Articles.status() || %{}, %{
            state: if(attempt < max_attempts, do: :retrying, else: :failed),
            reason: Articles.format_reason(reason),
            attempt: attempt,
            max_attempts: max_attempts
          })
        )

        e
    end
  end

  def perform(%Oban.Job{args: args}) do
    error(args, "ArticleSyncWorker: unrecognized args shape")
    {:cancel, :invalid_args}
  end

  defp warn_errors(%{errors: errors}) when errors != [],
    do: warn(errors, "Ghost article backfill finished with per-article errors")

  defp warn_errors(_summary), do: :ok

  # Persist only completed pages so a retry cannot inflate counts from a partial page.
  defp persist_checkpoint(nil, _checkpoint), do: {:error, :missing_job_id}

  defp persist_checkpoint(job_id, checkpoint) do
    case Oban.update_job(job_id, fn job ->
           %{meta: Map.put(job.meta || %{}, @checkpoint_key, checkpoint)}
         end) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
