defmodule Bonfire.Ghost.Web.WebhookController do
  @moduledoc """
  Receives Ghost membership webhooks.

  The route pipeline runs `Bonfire.Ghost.Web.Plugs.VerifyGhostSignature`
  first, so by the time we get here the payload is trusted. This controller
  does as little as possible: pick out the relevant Ghost member object,
  enqueue an Oban job on `:ghost_webhooks`, return 200.

  Events are disambiguated by URL path. Ghost binds each webhook integration to
  one event; the URL path is admin-chosen, so we use Ghost's *exact* event names
  (see https://docs.ghost.org/webhooks) as the path segment:

      POST /ghost/webhook/member.added
      POST /ghost/webhook/member.edited
      POST /ghost/webhook/member.deleted
      POST /ghost/webhook/post.published
      POST /ghost/webhook/post.published.edited
      POST /ghost/webhook/post.unpublished
      POST /ghost/webhook/post.deleted

  The earlier hyphenated member aliases (`member-added`, etc.) are still
  accepted for backwards compatibility with already-configured webhooks.

  Ghost's `member.*` / `post.*` payload shape is:

      {"member": {"current": {...}, "previous": {...}}}
      {"post":   {"current": {...}, "previous": {...}}}

  We pass `current` to the worker for added/edited/published and `previous` for
  deleted (the object no longer exists by then). Post auto-import is opt-in —
  see `Bonfire.Ghost.Workers.ArticleWebhookWorker`.
  """

  use Bonfire.UI.Common.Web, :controller

  import Untangle

  alias Bonfire.Ghost.Workers.MemberWebhookWorker
  alias Bonfire.Ghost.Workers.ArticleWebhookWorker

  plug(Bonfire.Ghost.Web.Plugs.VerifyGhostSignature)

  # member events — Ghost's exact event names, plus hyphenated aliases for back-compat
  def webhook(conn, %{"event" => e} = params) when e in ["member.added", "member-added"],
    do: enqueue_member(conn, "member.added", params, "current")

  def webhook(conn, %{"event" => e} = params) when e in ["member.edited", "member-edited"],
    do: enqueue_member(conn, "member.edited", params, "current")

  def webhook(conn, %{"event" => e} = params) when e in ["member.deleted", "member-deleted"],
    do: enqueue_member(conn, "member.deleted", params, "previous")

  # post (article) events — Ghost's exact event names
  def webhook(conn, %{"event" => "post.published"} = params),
    do: enqueue_post(conn, "post.published", params, "current")

  def webhook(conn, %{"event" => "post.published.edited"} = params),
    do: enqueue_post(conn, "post.published.edited", params, "current")

  def webhook(conn, %{"event" => "post.unpublished"} = params),
    do: enqueue_post(conn, "post.unpublished", params, "current")

  def webhook(conn, %{"event" => "post.deleted"} = params),
    do: enqueue_post(conn, "post.deleted", params, "previous")

  def webhook(conn, %{"event" => path_event}) do
    warn(path_event, "unknown Ghost webhook path")
    send_resp(conn, 404, "unknown event")
  end

  defp enqueue_member(conn, event, params, key) do
    case fetch_object(params, "member", key) do
      {:ok, member} ->
        enqueue(
          conn,
          MemberWebhookWorker.new(%{
            "event" => event,
            "member" => member,
            "previous" => get_in(params, ["member", "previous"])
          })
        )

      {:error, :no_object} ->
        malformed(conn, params, "member.#{key}")
    end
  end

  defp enqueue_post(conn, event, params, key) do
    cond do
      not ArticleWebhookWorker.auto_import_enabled?() ->
        # Opt-in is off — ack so Ghost doesn't retry, but don't enqueue.
        debug(event, "Ghost article auto-import disabled — ignoring webhook")
        send_resp(conn, 200, "ok (auto-import disabled)")

      true ->
        case fetch_object(params, "post", key) do
          {:ok, post} ->
            enqueue(conn, ArticleWebhookWorker.new(%{"event" => event, "post" => post}))

          {:error, :no_object} ->
            malformed(conn, params, "post.#{key}")
        end
    end
  end

  defp enqueue(conn, changeset) do
    changeset
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        send_resp(conn, 200, "ok")

      {:error, reason} ->
        error(reason, "failed to enqueue Ghost webhook job")
        send_resp(conn, 500, "enqueue failed")
    end
  end

  defp fetch_object(params, root, key) do
    case get_in(params, [root, key]) do
      m when is_map(m) and map_size(m) > 0 -> {:ok, m}
      _ -> {:error, :no_object}
    end
  end

  defp malformed(conn, params, what) do
    warn(params, "Ghost webhook missing #{what}")
    send_resp(conn, 400, "malformed payload")
  end
end
