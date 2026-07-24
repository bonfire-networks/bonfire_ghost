defmodule Bonfire.Ghost.Workers.MemberSyncWorker do
  @moduledoc """
  Oban worker for one-off Ghost member backfills.

  Webhooks and passwordless sign-in keep future member changes in sync, but after syncing or creating `ghost_tier:*` circles we need a background pass over existing Ghost members so their Bonfire accounts/users are inserted into the right circles.
  """

  use Oban.Worker,
    queue: :ghost_webhooks,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  import Untangle

  alias Bonfire.Ghost.Sync.Members
  alias Bonfire.Ghost.Sync.Tiers

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) when is_map(args) do
    # The accumulated status is threaded through this function rather than rebuilt by re-reading the cache in each stage: a read-merge-write across a long pass can lose earlier stages.
    status = %{
      state: :running,
      stage: :tiers,
      started_at: DateTime.utc_now(),
      job_id: job.id,
      attempt: job.attempt,
      stages: %{}
    }

    Members.put_status(status)

    # Staff identities are protected before the potentially large member population, closing the window in which a Ghost email change can fork an existing author.
    with {:ok, tier_summary, tiers} <- sync_tiers(),
         status = stage_done(status, :tiers, tier_summary, :staff),
         {:ok, staff_summary} <-
           sync_staff(on_progress: stage_progress_callback(status, :staff)),
         status = stage_done(status, :staff, staff_summary, :members),
         {:ok, member_summary} <-
           Members.sync_all(
             tiers: tiers,
             on_progress: stage_progress_callback(status, :members)
           ) do
      info(
        %{tiers: tier_summary, members: member_summary, staff: staff_summary},
        "Ghost member backfill complete"
      )

      warn_member_errors(staff_summary)
      warn_member_errors(member_summary)

      status
      |> record_stage(:members, member_summary)
      |> Map.merge(%{state: :done, finished_at: DateTime.utc_now()})
      |> Members.put_status()

      :ok
    else
      {:error, reason} = e ->
        fail_status(reason, job)
        e

      {:cancel, reason} = c ->
        fail_status(reason, job)
        c

      other ->
        error(other, "Ghost member backfill returned an unexpected result")
        fail_status(other, job)
        {:error, {:unexpected_sync_result, other}}
    end
  end

  def perform(%Oban.Job{args: args}) do
    error(args, "MemberSyncWorker: unrecognized args shape")
    {:cancel, :invalid_args}
  end

  # Records what a finished stage did and names the stage now starting, so the UI distinguishes completed, current, and pending stages.
  defp stage_done(status, stage, summary, next_stage) do
    status
    |> record_stage(stage, summary)
    |> Map.put(:stage, next_stage)
    |> Map.delete(:page)
    |> Members.put_status()
  end

  # Adds one stage's counters to the accumulated status map (pure — no cache read).
  defp record_stage(status, stage, summary) do
    Map.update(status, :stages, %{stage => Members.stage_counts(summary)}, fn stages ->
      Map.put(stages, stage, Members.stage_counts(summary))
    end)
  end

  # Each page writes a complete snapshot from the immutable status accumulated before the stage, giving the UI a heartbeat without cache merge races.
  defp stage_progress_callback(status, stage) do
    fn page, summary ->
      status
      |> record_stage(stage, summary)
      |> Map.put(:stage, stage)
      |> Map.put(:page, page)
      |> Members.put_status()
    end
  end

  # Read the last persisted status because a `with/else` clause cannot see accumulator rebindings from the chain; this one-shot failure-path read has no long-loop merge race.
  defp fail_status(reason, job) do
    (Members.status() || %{stages: %{}})
    |> Map.merge(%{
      state: :failed,
      reason: inspect(reason) |> String.slice(0, 500),
      attempt: job.attempt,
      max_attempts: job.max_attempts,
      finished_at: DateTime.utc_now()
    })
    |> Members.put_status()
  end

  # Staff (owner/admin/editor/author/contributor) are backfilled before members: Ghost emits no webhooks for them, so this pass is their only sync path besides gated login, and delaying it behind a large member population leaves legacy authors exposed to email-change forks. Auth errors on /users/ are deterministic (bad or under-scoped integration key), so cancel instead of burning retries; anything else retries the whole job, which is safe because every pass is idempotent.
  defp sync_staff(opts) do
    case Members.sync_all_staff(opts) do
      {:error, reason} when reason in [:unauthorized, :forbidden] ->
        error(reason, "Ghost staff backfill failed with an auth error, cancelling")
        {:cancel, {:staff_sync_failed, reason}}

      {:ok, _} = ok ->
        ok

      {:error, _} = e ->
        e

      other ->
        error(other, "Ghost staff backfill returned an unexpected result")
        {:error, {:unexpected_sync_result, other}}
    end
  end

  defp sync_tiers do
    case Tiers.sync_all([]) do
      {:ok, %{errors: errors}, _tiers} when errors != [] ->
        error(errors, "Ghost member backfill aborted because tier sync had errors")
        # Tier errors are deterministic (bad slug/config), so retrying wouldn't help.
        {:cancel, {:tier_sync_failed, errors}}

      other ->
        other
    end
  end

  defp warn_member_errors(%{errors: errors}) when errors != [] do
    warn(errors, "Ghost member backfill finished with member provisioning errors")
  end

  defp warn_member_errors(_summary), do: :ok
end
