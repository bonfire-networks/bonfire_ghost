defmodule Bonfire.Ghost.Web.Plugs.VerifyGhostSignatureTest do
  # `async: false` because we mutate the `:bonfire_ghost` :webhook_secret
  # app env. Runs without DB so no sandbox collisions.
  use ExUnit.Case, async: false

  # bucket this into the backend CI leg: bare `ExUnit.Case` skips the tag the extension case templates apply, so without it this also runs in the federation job catch-all
  @moduletag :backend

  import Plug.Conn
  import Plug.Test

  alias Bonfire.Ghost.Web.Plugs.VerifyGhostSignature

  @secret "webhook-secret-for-tests"
  @body ~s({"member":{"current":{"email":"a@b.test"}}})

  setup do
    prior = Application.get_env(:bonfire_ghost, :webhook_secret)
    Application.put_env(:bonfire_ghost, :webhook_secret, @secret)

    on_exit(fn ->
      if is_nil(prior),
        do: Application.delete_env(:bonfire_ghost, :webhook_secret),
        else: Application.put_env(:bonfire_ghost, :webhook_secret, prior)
    end)

    :ok
  end

  # Build a conn with the raw body stashed (as `Bonfire.Ghost.BodyReader` would)
  # and optionally a signature header. Pass `stash: false` to simulate BodyReader
  # not running.
  defp conn_with(sig_header, opts \\ []) do
    conn = conn(:post, "/ghost/webhook/member-added", @body)

    conn =
      if Keyword.get(opts, :stash, true),
        do: put_private(conn, :bonfire_raw_body, @body),
        else: conn

    conn = if sig_header, do: put_req_header(conn, "x-ghost-signature", sig_header), else: conn
    put_req_header(conn, "content-type", "application/json")
  end

  defp sign(body, ts_ms, secret \\ @secret) do
    :crypto.mac(:hmac, :sha256, secret, body <> Integer.to_string(ts_ms))
    |> Base.encode16(case: :lower)
  end

  describe "rejects malformed / missing signatures" do
    test "halts 401 when header missing" do
      conn = VerifyGhostSignature.call(conn_with(nil), [])
      assert conn.halted
      assert conn.status == 401
    end

    test "halts 401 when header is malformed" do
      conn = VerifyGhostSignature.call(conn_with("not-a-real-sig"), [])
      assert conn.halted
      assert conn.status == 401
    end

    test "halts 401 when HMAC doesn't match" do
      ts = System.system_time(:millisecond)
      conn = VerifyGhostSignature.call(conn_with("sha256=deadbeef, t=#{ts}"), [])
      assert conn.halted
      assert conn.status == 401
    end

    test "halts 401 when timestamp is outside the 5-minute window" do
      ts = System.system_time(:millisecond) - 6 * 60 * 1000
      sig = sign(@body, ts)

      conn = VerifyGhostSignature.call(conn_with("sha256=#{sig}, t=#{ts}"), [])
      assert conn.halted
      assert conn.status == 401
    end

    test "halts 401 when raw body is missing (BodyReader didn't run)" do
      ts = System.system_time(:millisecond)
      sig = sign(@body, ts)

      conn = VerifyGhostSignature.call(conn_with("sha256=#{sig}, t=#{ts}", stash: false), [])
      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "accepts valid signatures" do
    test "passes through when HMAC matches within window" do
      ts = System.system_time(:millisecond)
      sig = sign(@body, ts)

      conn = VerifyGhostSignature.call(conn_with("sha256=#{sig}, t=#{ts}"), [])
      refute conn.halted
      assert is_nil(conn.status)
    end

    test "accepts uppercase hex from the signer" do
      ts = System.system_time(:millisecond)
      sig = @body |> sign(ts) |> String.upcase()

      conn = VerifyGhostSignature.call(conn_with("sha256=#{sig}, t=#{ts}"), [])
      refute conn.halted
    end
  end

  describe "fails closed when misconfigured" do
    test "halts 503 when secret is not set" do
      Application.delete_env(:bonfire_ghost, :webhook_secret)

      ts = System.system_time(:millisecond)
      conn = VerifyGhostSignature.call(conn_with("sha256=abc, t=#{ts}"), [])

      assert conn.halted
      assert conn.status == 503
    end
  end
end
