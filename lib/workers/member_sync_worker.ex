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
      info(%{tiers: tier_summary, members: member_summary}, "Ghost member backfill complete")
      warn_member_errors(member_summary)
      :ok
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
