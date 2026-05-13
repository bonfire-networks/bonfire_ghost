defmodule Bonfire.Ghost.Web.GhostPostsLive do
  @moduledoc """
  LiveView page displaying posts from a connected Ghost blog.
  """
  use Bonfire.UI.Common.Web, :surface_live_view

  on_mount {LivePlugs, [Bonfire.UI.Me.LivePlugs.LoadCurrentUser]}

  alias Bonfire.Ghost
  alias Bonfire.Ghost.API

  def format_date(nil), do: ""

  def format_date(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, datetime, _offset} ->
        Calendar.strftime(datetime, "%B %d, %Y")

      _ ->
        iso_string
    end
  end

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page: "Ghost Blog",
        page_title: "Ghost Blog",
        back: true,
        nav_items: Bonfire.Common.ExtensionModule.default_nav(),
        without_secondary_widgets: true,
        loading: true,
        posts: [],
        error: nil,
        ghost_configured: Bonfire.Ghost.configured?()
      )

    if connected?(socket) and socket.assigns.ghost_configured do
      send(self(), :load_posts)
    end

    {:ok, socket}
  end

  def handle_info(:load_posts, socket) do
    socket =
      case Ghost.client() do
        {:ok, c} ->
          case API.list_posts(c, limit: 10) do
            {:ok, %{"posts" => posts}} ->
              assign(socket, loading: false, posts: posts, error: nil)

            {:ok, body} when is_map(body) ->
              assign(socket, loading: false, posts: Map.get(body, "posts", []), error: nil)

            {:error, reason} ->
              assign(socket, loading: false, error: reason)
          end

        {:error, reason} ->
          assign(socket, loading: false, error: reason)
      end

    {:noreply, socket}
  end
end
