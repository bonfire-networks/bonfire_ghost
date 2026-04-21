defmodule Bonfire.Ghost.Web.WebhookController do
  @moduledoc """
  Receives Ghost membership webhooks.

  The route pipeline runs `Bonfire.Ghost.Web.Plugs.VerifyGhostSignature`
  first, so by the time we get here the payload is trusted. This controller
  does as little as possible: pick out the relevant Ghost member object,
  enqueue an Oban job on `:ghost_webhooks`, return 200.

  Events are disambiguated by URL path. Ghost binds each webhook integration
  to one event, so the admin configures three separate webhook URLs in
  Ghost admin:

      POST /ghost/webhook/member-added
      POST /ghost/webhook/member-edited
      POST /ghost/webhook/member-deleted

  Ghost's `member.*` payload shape is:

      {"member": {"current": {...}, "previous": {...}}}

  We pass `current` to the worker for `added`/`edited` and `previous` for
  `deleted`; both are included in the job args for future auditing.
  """

  use Bonfire.UI.Common.Web, :controller

  import Untangle

  alias Bonfire.Ghost.Workers.MemberWebhookWorker

  plug(Bonfire.Ghost.Web.Plugs.VerifyGhostSignature)

  def member(conn, %{"event" => "member-added"} = params),
    do: enqueue(conn, "member.added", params)

  def member(conn, %{"event" => "member-edited"} = params),
    do: enqueue(conn, "member.edited", params)

  def member(conn, %{"event" => "member-deleted"} = params),
    do: enqueue(conn, "member.deleted", params)

  def member(conn, %{"event" => path_event}) do
    warn(path_event, "unknown Ghost webhook path")
    send_resp(conn, 404, "unknown event")
  end

  defp enqueue(conn, event, params) do
    with {:ok, member} <- extract_member(event, params) do
      %{
        "event" => event,
        "member" => member,
        "previous" => get_in(params, ["member", "previous"])
      }
      |> MemberWebhookWorker.new()
      |> Oban.insert()
      |> case do
        {:ok, _job} ->
          send_resp(conn, 200, "ok")

        {:error, reason} ->
          error(reason, "failed to enqueue Ghost webhook job")
          send_resp(conn, 500, "enqueue failed")
      end
    else
      {:error, :no_member} ->
        warn(params, "Ghost webhook missing member.current/previous")
        send_resp(conn, 400, "malformed payload")
    end
  end

  # `added` / `edited` carry the new state in `member.current`; `deleted` in `member.previous`.
  defp extract_member("member.deleted", params), do: fetch_member(params, "previous")
  defp extract_member(_event, params), do: fetch_member(params, "current")

  defp fetch_member(params, key) do
    case get_in(params, ["member", key]) do
      m when is_map(m) -> {:ok, m}
      _ -> {:error, :no_member}
    end
  end
end
