defmodule Bonfire.Ghost.Web.GhostSettingsLive do
  @moduledoc """
  Settings component for the Ghost extension.

  Displays:
  - Connected Ghost blog details (title, URL, version, etc.)
  - Table of members/subscribers
  """
  use Bonfire.UI.Common.Web, :stateful_component

  declare_settings_component(l("Ghost"),
    icon: "bi:newspaper",
    description: l("Configure Ghost blog integration and view members")
  )

  alias Bonfire.Ghost

  prop scope, :any, default: nil
  data settings, :any, default: nil
  data members, :list, default: []
  data tiers, :list, default: []
  data page_info, :any, default: nil
  data loading, :boolean, default: true
  data error, :any, default: nil

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if not Map.get(socket.assigns, :loaded, false) do
        socket
        |> load_ghost_data()
        |> assign(:loaded, true)
      else
        socket
      end

    {:ok, socket}
  end

  defp load_ghost_data(socket) do
    socket
    |> load_settings()
    |> load_tiers()
    |> load_members()
    |> assign(:loading, false)
  end

  defp load_settings(socket) do
    case Ghost.get_settings() do
      {:ok, %{"settings" => settings}} ->
        assign(socket, :settings, settings)

      {:error, :not_configured} ->
        assign(socket, :settings, nil)

      {:error, reason} ->
        assign(socket, error: reason)
    end
  end

  defp load_tiers(socket) do
    if Ghost.admin_configured?() do
      case Ghost.list_tiers(include: "benefits,monthly_price,yearly_price") do
        {:ok, %{"tiers" => tiers}} ->
          assign(socket, :tiers, tiers)

        {:error, reason} ->
          assign(socket, tiers: [], error: reason)
      end
    else
      socket
    end
  end

  defp load_members(socket) do
    if Ghost.admin_configured?() do
      case Ghost.list_members(limit: 50, include: "labels,newsletters") do
        {:ok, %{"members" => members, "meta" => meta}} ->
          page_info = extract_page_info(meta)
          assign(socket, members: members, page_info: page_info)

        {:error, reason} ->
          assign(socket, members: [], error: reason)
      end
    else
      assign(socket, members: [])
    end
  end

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

  def handle_event("load_more", _params, socket) do
    current_page = get_in(socket.assigns, [:page_info, :page]) || 1
    next_page = current_page + 1

    case Ghost.list_members(limit: 50, page: next_page, include: "labels,newsletters") do
      {:ok, %{"members" => new_members, "meta" => meta}} ->
        page_info = extract_page_info(meta)
        members = socket.assigns.members ++ new_members
        {:noreply, assign(socket, members: members, page_info: page_info)}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("refresh", _params, socket) do
    socket =
      socket
      |> assign(:loading, true)
      |> load_ghost_data()

    {:noreply, socket}
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
