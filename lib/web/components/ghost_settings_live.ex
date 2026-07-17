defmodule Bonfire.Ghost.Web.GhostSettingsLive do
  @moduledoc """
  Settings component for the Ghost extension.

  Organised as a persistent status band plus grouped sections (heavy/rare ones collapsed by default, via Alpine `x-collapse`):
  - Status band: connection, blog title/version/URL, member & tier vitals, Refresh
  - Article import (open): author, group/topic, tag filters, auto-import + webhooks
  - Access & login (open): gated login + external signup URL
  - Membership tiers (open when present): flat rows + "Sync tiers" action
  - Members (collapsed): subscriber table + "Sync members" action
  - Blog details (collapsed): language, timezone, cover, members/paid flags

  Event handling lives in `Bonfire.Ghost.LiveHandler` per Bonfire convention.
  """
  use Bonfire.UI.Common.Web, :stateful_component

  declare_settings_component(l("Ghost"),
    icon: "bi:newspaper",
    description: l("Configure Ghost blog integration and view members"),
    # suppress the WidgetsLive wrapper title/description — the parent extension card already shows them
    data: %{}
  )

  prop scope, :any, default: nil
  data settings, :any, default: nil
  data members, :list, default: []
  data tiers, :list, default: []
  data page_info, :any, default: nil
  data loading, :boolean, default: true
  data syncing, :boolean, default: false
  data last_sync, :any, default: nil
  data error, :any, default: nil
  data gated_login, :boolean, default: false
  data show_topic_matching, :boolean, default: false
  data auto_import, :boolean, default: false
  data articles_count, :any, default: nil
  data topic_matching_group, :any, default: :__unset__
  # Live status of the background article backfill — see Bonfire.Ghost.Sync.Articles.status/0.
  data article_sync_status, :any, default: nil
  data sync_polling, :boolean, default: false
  # Fail-closed: only flipped true once the viewer is confirmed to be an instance admin.
  data authorized, :boolean, default: false

  # 2s poll while an article backfill is queued/running: re-reads the status the worker
  # writes to the cache after every imported article, and stops itself once it finishes
  # (refreshing the imported-articles count on the way out).
  def update(%{sync_status_poll: true}, socket) do
    if socket.assigns[:authorized] != true do
      {:ok, socket}
    else
      status = Bonfire.Ghost.Sync.Articles.status()
      socket = assign(socket, :article_sync_status, status)

      if sync_in_flight?(status) do
        schedule_sync_status_poll(socket)
        {:ok, assign(socket, :sync_polling, true)}
      else
        blog_url = (is_map(socket.assigns[:settings]) && socket.assigns.settings["url"]) || nil

        {:ok,
         assign(socket,
           sync_polling: false,
           articles_count: Bonfire.Ghost.imported_articles_count(blog_url)
         )}
      end
    end
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # The Ghost integration exposes member PII, tiers, and instance-wide sync actions.
    # The dedicated /ghost/settings route is admin-gated, but this is also a
    # `declare_settings_component` rendered in the general settings UI, so gate it here
    # too — otherwise any logged-in user opening settings triggers the member fetch.
    if not authorized?(socket) do
      {:ok, assign(socket, authorized: false, loading: false)}
    else
      socket =
        if not Map.get(socket.assigns, :loaded, false) do
          socket
          |> Bonfire.Ghost.LiveHandler.load_ghost_data()
          |> assign(:loaded, true)
        else
          socket
        end

      # These cheap in-memory reads are recomputed on every update so the UI reflects a
      # just-changed setting live. (`show_topic_matching` needs a DB query, so it's handled
      # separately below to avoid running that query on every re-render.)
      {:ok,
       socket
       |> assign(
         authorized: true,
         gated_login: gated_login?(),
         # Normalized boolean (the stored value can be the string "true"), so the toggle's
         # `checked` comparison and the webhook block agree. Reuses the canonical predicate.
         auto_import: Bonfire.Ghost.Workers.ArticleWebhookWorker.auto_import_enabled?()
       )
       |> assign_show_topic_matching()
       |> maybe_resume_sync_polling()}
    end
  end

  # If a backfill was already queued/running when the page (re)loaded, resume the status
  # poll loop — `sync_polling` dedupes so unrelated update/2 calls don't stack timers.
  defp maybe_resume_sync_polling(socket) do
    if sync_in_flight?(socket.assigns[:article_sync_status]) and
         socket.assigns[:sync_polling] != true do
      schedule_sync_status_poll(socket)
      assign(socket, :sync_polling, true)
    else
      socket
    end
  end

  @doc false
  def schedule_sync_status_poll(socket) do
    if id = socket.assigns[:id] do
      Phoenix.LiveView.send_update_after(__MODULE__, [id: id, sync_status_poll: true], 2_000)
    end

    socket
  end

  # The backfill's watchdog guarantees a status write at least every ~2 min while the job
  # is alive (see Bonfire.Ghost.Sync.Articles), so a heartbeat this old means the job
  # died or hung without ever reaching a terminal state.
  @sync_stall_after_ms :timer.minutes(5)

  @doc "State atom of the article backfill status map (nil when none)."
  def sync_state(%{state: state}), do: state
  def sync_state(_), do: nil

  @doc "Whether an article backfill is queued, running, or about to be retried."
  def sync_in_flight?(status), do: sync_state(status) in [:queued, :running, :retrying]

  @doc """
  Whether an in-flight backfill has stopped writing its heartbeat (job died or hung).

  When true the UI warns and re-enables the sync button: re-clicking either restarts the
  import (the `ghost_webhooks` queue runs 2 jobs, so a wedged one can't block a fresh
  one) or — if the old job is genuinely still executing and recent — Oban's uniqueness
  reports "already running" instead.
  """
  def sync_stalled?(status) do
    sync_in_flight?(status) and
      case Map.get(status, :updated_at) do
        %DateTime{} = dt ->
          DateTime.diff(DateTime.utc_now(), dt, :millisecond) > @sync_stall_after_ms

        # Statuses written before the heartbeat existed (or malformed) count as stalled
        # rather than pinning the button disabled forever.
        _ ->
          true
      end
  end

  @doc "A counter from the status map, defaulting to 0."
  def sync_count(status, key) when is_map(status), do: Map.get(status, key) || 0
  def sync_count(_, _), do: 0

  @doc "Capped list of per-article import errors (`%{article: label, reason: string}`)."
  def sync_errors(%{errors: errors}) when is_list(errors), do: errors
  def sync_errors(_), do: []

  # Gate on the same permission the settings write path enforces (`can?(:configure, :instance)`).
  defp authorized?(socket) do
    Bonfire.Boundaries.can?(current_user(socket), :configure, :instance) == true
  end

  # `show_topic_matching_toggle?/0` runs a DB query (destination_group?/1), so only re-run
  # it when the underlying `post_into_group` setting actually changes — a cheap Config read
  # gates the query, keeping it both live and off the per-render hot path.
  defp assign_show_topic_matching(socket) do
    group = Bonfire.Ghost.post_into_group()

    if group == Map.get(socket.assigns, :topic_matching_group, :__unset__) do
      socket
    else
      socket
      |> assign(:topic_matching_group, group)
      |> assign(:show_topic_matching, show_topic_matching_toggle?())
    end
  end

  @doc "Whether gated login (Ghost-members-only, passwordless) is enabled instance-wide."
  def gated_login? do
    Bonfire.Common.Settings.get([:bonfire_ui_me, :login, :passwordless_only], false, :instance) in [
      true,
      "true",
      "1",
      "yes"
    ]
  end

  # Presentational adapter over the locale-aware shared formatter. Normalizes to a
  # DateTime first (via to_date_time/1) so full ISO datetime strings work too — Ghost
  # returns member `created_at` as e.g. "2026-01-15T10:00:00.000Z", which the shared
  # format_date/to_date path (Date.from_iso8601) rejects. Falls back to "-".
  def format_date(nil), do: "-"

  def format_date(date) do
    case Bonfire.Common.DatesTimes.to_date_time(date) do
      %DateTime{} = dt -> Bonfire.Common.DatesTimes.format_date(dt) || "-"
      _ -> "-"
    end
  end

  @doc "Relative timestamp (\"5 minutes ago\") with a date fallback, for sync status lines."
  def format_time_ago(nil), do: "-"

  def format_time_ago(dt),
    do: Bonfire.Common.DatesTimes.date_from_now(dt) || format_date(dt)

  # Locale-aware thousands grouping (6309 → "6,309"), with a plain-integer fallback.
  def format_count(n) when is_integer(n) do
    case Bonfire.Common.Utils.maybe_apply(Bonfire.Common.Localise.Cldr.Number, :to_string, [n],
           fallback_return: nil
         ) do
      {:ok, formatted} -> formatted
      _ -> Integer.to_string(n)
    end
  end

  def format_count(other), do: to_string(other)

  def format_price(nil, _currency), do: "-"

  def format_price(cents, currency) when is_integer(cents) do
    major = div(cents, 100)
    minor = rem(cents, 100)

    symbol =
      case String.upcase(currency || "usd") do
        "EUR" -> "€"
        "GBP" -> "£"
        _ -> "$"
      end

    "#{symbol}#{major}.#{String.pad_leading(Integer.to_string(minor), 2, "0")}"
  end

  def format_price(_, _), do: "-"

  def status_badge_class(status) do
    case status do
      "paid" -> "badge-success"
      "comped" -> "badge-info"
      _ -> "badge-ghost"
    end
  end

  @doc "Returns true when the legacy primary-tag-to-topic matcher applies to the configured destination."
  def show_topic_matching_toggle? do
    case Bonfire.Ghost.post_into_group() do
      id when is_binary(id) -> destination_group?(id)
      _ -> false
    end
  end

  defp destination_group?(id) do
    case Bonfire.Classify.Categories.get(id, skip_boundary_check: true) do
      {:ok, %{type: type}} when type in [nil, :group, "group"] -> true
      _ -> false
    end
  end
end
