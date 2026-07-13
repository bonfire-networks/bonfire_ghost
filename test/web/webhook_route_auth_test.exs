defmodule Bonfire.Ghost.Web.WebhookRouteAuthTest do
  @moduledoc """
  Regression tests for webhook auth **through the router**.

  `webhook_controller_test.exs` calls `WebhookController.webhook/2` directly, and
  `verify_ghost_signature_test.exs` unit-tests the plug in isolation — so nothing asserts
  that the plug is actually *wired* to `/ghost/webhook/*`. Dropping `plug VerifyGhostSignature`
  from the controller (or moving the route out of its scope) would keep every existing test
  green while leaving the endpoint open to anyone.

  These tests drive the real endpoint, so they also cover the raw-body plumbing
  (`Bonfire.Ghost.BodyReader`) that HMAC verification depends on — if that wiring is missing,
  even a correctly-signed request fails closed with 401.
  """
  # `async: false` — mutates the app-env webhook secret.
  use Bonfire.Ghost.ConnCase, async: false
  use Oban.Testing, repo: Bonfire.Common.Repo

  alias Bonfire.Ghost.Workers.MemberWebhookWorker

  @secret "test_ghost_webhook_secret"
  @path "/ghost/webhook/member.added"

  setup do
    previous = Application.get_env(:bonfire_ghost, :webhook_secret)
    Application.put_env(:bonfire_ghost, :webhook_secret, @secret)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:bonfire_ghost, :webhook_secret, previous),
        else: Application.delete_env(:bonfire_ghost, :webhook_secret)
    end)

    :ok
  end

  defp body do
    Jason.encode!(%{"member" => %{"current" => %{"email" => "member@example.test"}}})
  end

  # Ghost signs `body <> unix_millis`, hex, as `X-Ghost-Signature: sha256=<hex>, t=<ms>`
  defp sign(body, ts_ms) do
    hex =
      :crypto.mac(:hmac, :sha256, @secret, body <> Integer.to_string(ts_ms))
      |> Base.encode16(case: :lower)

    "sha256=#{hex}, t=#{ts_ms}"
  end

  defp post_webhook(body, signature) do
    conn = put_req_header(build_conn(), "content-type", "application/json")

    conn =
      if signature,
        do: put_req_header(conn, "x-ghost-signature", signature),
        else: conn

    post(conn, @path, body)
  end

  describe "POST /ghost/webhook/:event auth (L2)" do
    test "an unsigned request is rejected" do
      conn = post_webhook(body(), nil)

      assert conn.status == 401,
             "the signature plug is not wired to the webhook route — anyone can post webhooks"

      refute_enqueued(worker: MemberWebhookWorker)
    end

    test "a request with a bogus signature is rejected" do
      conn = post_webhook(body(), "sha256=deadbeef, t=#{System.system_time(:millisecond)}")

      assert conn.status == 401
      refute_enqueued(worker: MemberWebhookWorker)
    end

    test "a signature over a DIFFERENT body is rejected (no tampering)" do
      ts = System.system_time(:millisecond)
      signature_for_other_body = sign(Jason.encode!(%{"member" => %{}}), ts)

      conn = post_webhook(body(), signature_for_other_body)

      assert conn.status == 401
      refute_enqueued(worker: MemberWebhookWorker)
    end

    test "a correctly-signed-but-stale request is rejected (replay window)" do
      stale = System.system_time(:millisecond) - 6 * 60 * 1000
      conn = post_webhook(body(), sign(body(), stale))

      assert conn.status == 401
      refute_enqueued(worker: MemberWebhookWorker)
    end

    test "a correctly-signed request is accepted and enqueues the member worker" do
      ts = System.system_time(:millisecond)
      conn = post_webhook(body(), sign(body(), ts))

      assert conn.status == 200,
             "a valid signature was rejected — check the `body_reader` wiring (Bonfire.Ghost.BodyReader), " <>
               "without it fetch_raw_body/1 fails and every webhook 401s"

      # the member path had no enqueue assertion anywhere before this
      assert_enqueued(
        worker: MemberWebhookWorker,
        args: %{"event" => "member.added", "member" => %{"email" => "member@example.test"}}
      )
    end

    test "with no secret configured, webhooks fail closed (503, never processed)" do
      Application.delete_env(:bonfire_ghost, :webhook_secret)

      ts = System.system_time(:millisecond)
      conn = post_webhook(body(), sign(body(), ts))

      assert conn.status == 503
      refute_enqueued(worker: MemberWebhookWorker)
    end
  end
end
