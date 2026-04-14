defmodule Bonfire.Ghost.Web.GhostSettingsLive do
  @moduledoc """
  Settings component for the Ghost extension.

  Displays:
  - Connected Ghost blog details (title, URL, version, etc.)
  - Membership tiers with a "Sync tiers" action
  - Table of members/subscribers

  Event handling lives in `Bonfire.Ghost.LiveHandler` per Bonfire convention.
  """
  use Bonfire.UI.Common.Web, :stateful_component

  declare_settings_component(l("Ghost"),
    icon: "bi:newspaper",
    description: l("Configure Ghost blog integration and view members")
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

    {:ok, socket}
  end

  def format_date(nil), do: "-"

  def format_date(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, datetime, _offset} ->
        Calendar.strftime(datetime, "%Y-%m-%d")

      _ ->
        iso_string
    end
  end

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
end
