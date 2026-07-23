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
  alias Bonfire.Ghost.Workers.ArticleSyncWorker

  # Ghost API include lists — keep in sync with what the settings page renders.
  @members_include "labels,newsletters"
  @tiers_include "benefits,monthly_price,yearly_price"

  def handle_event("refresh", _params, socket) do
    if not can_configure_instance?(socket) do
      {:noreply, assign_flash(socket, :error, unauthorized_message())}
    else
      {:noreply,
       socket
       |> assign(:loading, true)
       |> load_ghost_data()}
    end
  end

  def handle_event("load_more", _params, socket) do
    if not can_configure_instance?(socket) do
      {:noreply, assign_flash(socket, :error, unauthorized_message())}
    else
      current_page = get_in(socket.assigns, [:page_info, :page]) || 1
      next_page = current_page + 1

      with {:ok, c} <- Ghost.admin_client(),
           {:ok, %{"members" => new_members, "meta" => meta}} <-
             AdminAPI.list_members(c, limit: 50, page: next_page, include: @members_include) do
        page_info = extract_page_info(meta)
        members = socket.assigns.members ++ new_members

        {:noreply,
         socket
         |> assign(members: members, page_info: page_info)
         |> assign_member_usernames()}
      else
        _ -> {:noreply, socket}
      end
    end
  end

  def handle_event("load_more_staff", _params, socket) do
    if not can_configure_instance?(socket) do
      {:noreply, assign_flash(socket, :error, unauthorized_message())}
    else
      current_page = get_in(socket.assigns, [:staff_page_info, :page]) || 1
      next_page = current_page + 1

      with {:ok, c} <- Ghost.admin_client(),
           {:ok, %{"users" => new_staff, "meta" => meta}} <-
             AdminAPI.list_users(c,
               limit: 50,
               page: next_page,
               include: "roles",
               filter: AdminAPI.signin_staff_filter()
             ) do
        {:noreply,
         assign(socket,
           staff: socket.assigns.staff ++ new_staff,
           staff_page_info: extract_page_info(meta)
         )}
      else
        _ -> {:noreply, socket}
      end
    end
  end

  def handle_event("sync_tiers", _params, socket) do
    if not can_configure_instance?(socket) do
      {:noreply, assign_flash(socket, :error, unauthorized_message())}
    else
      do_sync_tiers(socket)
    end
  end

  defp do_sync_tiers(socket) do
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
      not can_configure_instance?(socket) ->
        {:noreply, assign_flash(socket, :error, unauthorized_message())}

      not Ghost.admin_configured?() ->
        {:noreply, assign_flash(socket, :error, l("Ghost Admin API is not configured"))}

      true ->
        case MemberSyncWorker.new(%{}) |> Oban.insert() do
          {:ok, _job} ->
            status =
              Bonfire.Ghost.Sync.Members.put_status(%{
                state: :queued,
                stage: :tiers,
                stages: %{},
                started_at: DateTime.utc_now()
              })

            {:noreply,
             socket
             |> assign(:member_sync_status, status)
             |> start_sync_status_polling()
             |> assign_flash(
               :info,
               l(
                 "Ghost member & staff backfill started. Progress is shown below; tiers sync first, then members, then staff."
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

  def handle_event("sync_articles", _params, socket) do
    cond do
      not can_configure_instance?(socket) ->
        {:noreply, assign_flash(socket, :error, unauthorized_message())}

      not Ghost.configured?() ->
        {:noreply, assign_flash(socket, :error, l("Ghost is not configured"))}

      true ->
        case ArticleSyncWorker.new(%{}) |> Oban.insert() do
          {:ok, %Oban.Job{conflict?: true}} ->
            {:noreply,
             socket
             |> assign(:article_sync_status, Sync.Articles.status())
             |> start_sync_status_polling()
             |> assign_flash(
               :info,
               l("An article import is already queued or running — its progress is shown below.")
             )}

          {:ok, %Oban.Job{} = job} ->
            status =
              Sync.Articles.put_status(%{
                state: :queued,
                job_id: job.id,
                queued_at: DateTime.utc_now()
              })

            {:noreply,
             socket
             |> assign(:article_sync_status, status)
             |> start_sync_status_polling()
             |> assign_flash(
               :info,
               l(
                 "Article backfill started. Existing published Ghost articles will be imported in the background, honoring your author, group, and tag settings."
               )
             )}

          {:error, reason} ->
            {:noreply,
             assign_flash(
               socket,
               :error,
               l("Article backfill could not be started: %{reason}", reason: inspect(reason))
             )}
        end
    end
  end

  # Kicks off the settings component's poll loop (see `GhostSettingsLive.update/2` with
  # `sync_status_poll: true`) so the panel refreshes while the background job runs.
  defp start_sync_status_polling(socket) do
    Bonfire.Ghost.Web.GhostSettingsLive.schedule_sync_status_poll(socket)
    assign(socket, :sync_polling, true)
  end

  # These sync actions enqueue instance-wide work (imports, boundary rewrites, member
  # provisioning), so gate them on the same permission the settings write path enforces
  # (`can?(current_account, :configure, :instance)` in Bonfire.Common.Settings) — the
  # `Bonfire.Ghost:*` events are otherwise routable from any connected LiveView.
  defp can_configure_instance?(socket) do
    Bonfire.Boundaries.can?(current_user(socket), :configure, :instance)
  end

  defp unauthorized_message,
    do: l("You do not have permission to manage this instance's Ghost integration.")

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
       end},
      {:staff,
       fn ->
         with {:ok, c} <- admin_client,
              # same filter the staff backfill uses, so the preview matches what would sync
              do:
                AdminAPI.list_users(c,
                  limit: 50,
                  include: "roles",
                  filter: AdminAPI.signin_staff_filter()
                )
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

    socket =
      socket
      |> apply_settings(results.settings)
      |> apply_tiers(results.tiers)
      |> apply_members(results.members)
      |> assign_member_usernames()
      |> apply_staff(results.staff)

    # Count imported articles by their canonical URL prefix — use the blog's public
    # site URL (what article URLs actually use), falling back to the configured GHOST_URL.
    blog_url = (is_map(socket.assigns[:settings]) && socket.assigns.settings["url"]) || nil

    socket
    |> assign(:articles_count, Ghost.imported_articles_count(blog_url))
    |> assign(:article_sync_status, Sync.Articles.status())
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

  # Annotate the current members with the @username of any linked Bonfire profile, so the
  # table can show who has connected/created their identity vs who only has an account.
  defp assign_member_usernames(socket) do
    ghost_ids = Enum.map(socket.assigns[:members] || [], & &1["id"])

    assign(
      socket,
      :member_usernames,
      Bonfire.Ghost.Identities.usernames_by_ghost_id(ghost_ids, :member)
    )
  end

  defp apply_staff(socket, nil), do: assign(socket, staff: [])

  defp apply_staff(socket, {:ok, %{"users" => staff, "meta" => meta}}),
    do: assign(socket, staff: staff, staff_page_info: extract_page_info(meta))

  defp apply_staff(socket, {:ok, %{"users" => staff}}), do: assign(socket, staff: staff)
  # a staff-fetch error is non-fatal to the rest of the page (don't clobber :error)
  defp apply_staff(socket, {:error, _reason}), do: assign(socket, staff: [])

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
