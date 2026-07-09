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

  def update(assigns, socket) do
    socket = assign(socket, assigns)

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
       gated_login: gated_login?(),
       # Normalized boolean (the stored value can be the string "true"), so the toggle's
       # `checked` comparison and the webhook block agree. Reuses the canonical predicate.
       auto_import: Bonfire.Ghost.Workers.ArticleWebhookWorker.auto_import_enabled?()
     )
     |> assign_show_topic_matching()}
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
