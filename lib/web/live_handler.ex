defmodule Bonfire.Ghost.LiveHandler do
  @moduledoc """
  Routes `phx-click="Bonfire.Ghost:..."` events for the Ghost settings page.

  Also hosts the data-loading helpers shared between `update/2` (initial mount)
  and `refresh`/`sync_tiers` (reload after an action) on
  `Bonfire.Ghost.Web.GhostSettingsLive`.
  """

  use Bonfire.UI.Common.Web, :live_handler

  alias Bonfire.Ghost
  alias Bonfire.Ghost.API
  alias Bonfire.Ghost.AdminAPI
  alias Bonfire.Ghost.Sync
  alias Bonfire.Ghost.Workers.MemberSyncWorker

  # Ghost API include lists — keep in sync with what the settings page renders.
  @members_include "labels,newsletters"
  @tiers_include "benefits,monthly_price,yearly_price"

  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:loading, true)
     |> load_ghost_data()}
  end

  def handle_event("load_more", _params, socket) do
    current_page = get_in(socket.assigns, [:page_info, :page]) || 1
    next_page = current_page + 1

    with {:ok, c} <- Ghost.admin_client(),
         {:ok, %{"members" => new_members, "meta" => meta}} <-
           AdminAPI.list_members(c, limit: 50, page: next_page, include: @members_include) do
      page_info = extract_page_info(meta)
      members = socket.assigns.members ++ new_members
      {:noreply, assign(socket, members: members, page_info: page_info)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("sync_tiers", _params, socket) do
    opts = [
      current_user: current_user(socket),
      current_account: current_account(socket)
    ]

    case Sync.Tiers.sync_all(opts) do
      {:ok, summary, tiers} ->
        {flash_type, message} = sync_flash(summary)

        {:noreply,
         socket
         |> assign(
           syncing: false,
           tiers: tiers,
           last_sync: %{at: DateTime.utc_now(), summary: summary}
         )
         |> assign_flash(flash_type, message)}

      {:error, :not_configured} ->
        {:noreply,
         socket
         |> assign(:syncing, false)
         |> assign_flash(:error, l("Ghost Admin API is not configured"))}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:syncing, false)
         |> assign_flash(:error, l("Ghost tier sync failed: %{reason}", reason: inspect(reason)))}
    end
  end

  def handle_event("sync_members", _params, socket) do
    cond do
      not Ghost.admin_configured?() ->
        {:noreply, assign_flash(socket, :error, l("Ghost Admin API is not configured"))}

      true ->
        case MemberSyncWorker.new(%{}) |> Oban.insert() do
          {:ok, _job} ->
            {:noreply,
             assign_flash(
               socket,
               :info,
               l(
                 "Ghost member backfill started. Tiers will sync first, then existing members will be added to their circles."
               )
             )}

          {:error, reason} ->
            {:noreply,
             assign_flash(
               socket,
               :error,
               l("Ghost member backfill could not be started: %{reason}", reason: inspect(reason))
             )}
        end
    end
  end

  @doc """
  Loads Ghost settings, tiers, and members into the socket in one pass.
  Called from `GhostSettingsLive.update/2` and from the refresh/sync handlers above.

  The three Ghost API calls are independent and each takes ~200ms, so we run
  them concurrently and apply the results sequentially.
  """
  def load_ghost_data(socket) do
    content_client = Ghost.client()
    admin_client = Ghost.admin_client()

    fetchers = [
      {:settings,
       fn ->
         with {:ok, c} <- content_client, do: API.get_settings(c)
       end},
      {:tiers,
       fn ->
         with {:ok, c} <- admin_client, do: AdminAPI.list_tiers(c, include: @tiers_include)
       end},
      {:members,
       fn ->
         with {:ok, c} <- admin_client,
              do: AdminAPI.list_members(c, limit: 50, include: @members_include)
       end}
    ]

    results =
      fetchers
      |> Task.async_stream(fn {key, fun} -> {key, fun.()} end,
        timeout: :infinity,
        max_concurrency: length(fetchers),
        ordered: false
      )
      |> Map.new(fn {:ok, {key, result}} -> {key, result} end)

    socket
    |> apply_settings(results.settings)
    |> apply_tiers(results.tiers)
    |> apply_members(results.members)
    |> assign(:loading, false)
  end

  defp apply_settings(socket, {:ok, %{"settings" => settings}}),
    do: assign(socket, :settings, settings)

  defp apply_settings(socket, {:error, :not_configured}), do: assign(socket, :settings, nil)
  defp apply_settings(socket, {:error, reason}), do: assign(socket, error: reason)

  defp apply_tiers(socket, nil), do: socket

  defp apply_tiers(socket, {:ok, %{"tiers" => tiers}}), do: assign(socket, :tiers, tiers)

  defp apply_tiers(socket, {:error, reason}), do: assign(socket, tiers: [], error: reason)

  defp apply_members(socket, nil), do: assign(socket, members: [])

  defp apply_members(socket, {:ok, %{"members" => members, "meta" => meta}}),
    do: assign(socket, members: members, page_info: extract_page_info(meta))

  defp apply_members(socket, {:error, reason}), do: assign(socket, members: [], error: reason)

  defp extract_page_info(%{"pagination" => pagination}) do
    %{
      page: pagination["page"],
      pages: pagination["pages"],
      limit: pagination["limit"],
      total: pagination["total"],
      has_next: pagination["next"] != nil,
      has_prev: pagination["prev"] != nil
    }
  end

  defp extract_page_info(_), do: nil

  defp sync_flash(%{
         created: created,
         updated: updated,
         unchanged: unchanged,
         archived: archived,
         errors: errors
       }) do
    err_count = length(errors)
    total = created + updated + unchanged + err_count
    anything_changed? = created > 0 or updated > 0 or archived > 0

    cond do
      err_count > 0 ->
        {:warning,
         l(
           "Synced %{total} Ghost tier(s) with %{errors} error(s): %{created} new, %{updated} refreshed, %{unchanged} unchanged, %{archived} archived",
           total: total,
           errors: err_count,
           created: created,
           updated: updated,
           unchanged: unchanged,
           archived: archived
         )}

      anything_changed? ->
        {:info,
         l(
           "Synced %{total} Ghost tier(s): %{created} new, %{updated} refreshed, %{unchanged} unchanged, %{archived} archived",
           total: total,
           created: created,
           updated: updated,
           unchanged: unchanged,
           archived: archived
         )}

      true ->
        {:info, l("All %{total} Ghost tier(s) already in sync — nothing to update", total: total)}
    end
  end
end
