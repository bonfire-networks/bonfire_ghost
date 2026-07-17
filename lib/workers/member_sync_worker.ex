defmodule Bonfire.Ghost.Workers.MemberSyncWorker do
  @moduledoc """
  Oban worker for one-off Ghost member backfills.

  Webhooks and passwordless sign-in keep future member changes in sync, but after syncing or creating `ghost_tier:*` circles we need a background pass over existing Ghost members so their Bonfire accounts/users are inserted into the right circles.
  """

  use Oban.Worker,
    queue: :ghost_webhooks,
    max_attempts: 3,
    unique: [period: 300, states: [:available, :scheduled, :executing, :retryable]]

  import Untangle

  alias Bonfire.Ghost.Sync.Members
  alias Bonfire.Ghost.Sync.Tiers

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when is_map(args) do
    with {:ok, tier_summary, tiers} <- sync_tiers(),
         {:ok, member_summary} <- Members.sync_all(tiers: tiers) do
      # reported before the staff pass so a staff failure can't suppress member diagnostics
      warn_member_errors(member_summary)

      case sync_staff() do
        {:ok, staff_summary} ->
          info(
            %{tiers: tier_summary, members: member_summary, staff: staff_summary},
            "Ghost member backfill complete"
          )

          warn_member_errors(staff_summary)
          :ok

        {:error, _} = e ->
          e

        {:cancel, _} = c ->
          c
      end
    else
      {:error, _} = e ->
        e

      {:cancel, _} = c ->
        c

      other ->
        error(other, "Ghost member backfill returned an unexpected result")
        {:error, {:unexpected_sync_result, other}}
    end
  end

  def perform(%Oban.Job{args: args}) do
    error(args, "MemberSyncWorker: unrecognized args shape")
    {:cancel, :invalid_args}
  end

  # Staff (owner/admin/editor/author/contributor) are backfilled after members: Ghost emits no webhooks for them, so this pass is their only sync path besides gated login. Auth errors on /users/ are deterministic (bad or under-scoped integration key), so cancel instead of burning retries; anything else retries the whole job, which is safe because the member passes are idempotent.
  defp sync_staff do
    case Members.sync_all_staff([]) do
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
