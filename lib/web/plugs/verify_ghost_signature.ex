defmodule Bonfire.Ghost.Web.Plugs.VerifyGhostSignature do
  @moduledoc """
  Verifies the `X-Ghost-Signature` header on incoming Ghost webhook requests.

  Ghost signs each webhook with HMAC-SHA256 of `body <> unix_millis_timestamp`
  using the shared secret configured on the Ghost integration. The header
  format is:

      X-Ghost-Signature: sha256=<hex>, t=<unix-ms>

  This plug:

    1. Reads the raw body stashed by `Bonfire.Ghost.BodyReader` at
       `conn.private[:bonfire_raw_body]` (because `Plug.Parsers` has already
       consumed and JSON-decoded the stream by the time routes run).
    2. Rejects the request with 401 if the header is missing/malformed or the
       HMAC doesn't match.
    3. Rejects with 401 if `t` is outside a 5-minute window (replay guard).
    4. Rejects with 503 if no secret is configured — we fail closed rather
       than accept unsigned traffic.

  Constant-time comparison via `Plug.Crypto.secure_compare/2`.
  """

  @behaviour Plug
  import Plug.Conn
  import Untangle

  @header "x-ghost-signature"
  @replay_window_ms 5 * 60 * 1000

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, secret} <- fetch_secret(),
         [header | _] <- get_req_header(conn, @header),
         {:ok, sig_hex, ts_ms} <- parse_header(header),
         :ok <- check_freshness(ts_ms),
         {:ok, body} <- fetch_raw_body(conn),
         :ok <- verify_hmac(secret, body, ts_ms, sig_hex) do
      conn
    else
      {:error, :no_secret} ->
        error("GHOST_WEBHOOK_SECRET not configured — refusing webhook")
        conn |> send_resp(503, "webhook not configured") |> halt()

      {:error, reason} ->
        warn(reason, "Ghost webhook rejected")
        conn |> send_resp(401, "invalid signature") |> halt()

      [] ->
        warn("missing #{@header} header")
        conn |> send_resp(401, "missing signature") |> halt()
    end
  end

  defp fetch_secret do
    case Application.get_env(:bonfire_ghost, :webhook_secret) do
      secret when is_binary(secret) and secret != "" -> {:ok, secret}
      _ -> {:error, :no_secret}
    end
  end

  # Header looks like "sha256=<hex>, t=<ms>" — whitespace varies, order varies.
  defp parse_header(header) do
    parts =
      for part <- String.split(header, ","),
          [k, v] <- [String.split(String.trim(part), "=", parts: 2)],
          into: %{},
          do: {k, v}

    with %{"sha256" => sig, "t" => ts} <- parts,
         {ts_ms, ""} <- Integer.parse(ts) do
      {:ok, sig, ts_ms}
    else
      _ -> {:error, :malformed_header}
    end
  end

  defp check_freshness(ts_ms) do
    if abs(System.system_time(:millisecond) - ts_ms) <= @replay_window_ms do
      :ok
    else
      {:error, :stale_timestamp}
    end
  end

  defp fetch_raw_body(%{private: %{bonfire_raw_body: body}}) when is_binary(body), do: {:ok, body}
  defp fetch_raw_body(_conn), do: {:error, :missing_raw_body}

  defp verify_hmac(secret, body, ts_ms, expected_hex) do
    computed =
      :crypto.mac(:hmac, :sha256, secret, body <> Integer.to_string(ts_ms))
      |> Base.encode16(case: :lower)

    if Plug.Crypto.secure_compare(computed, String.downcase(expected_hex)) do
      :ok
    else
      {:error, :hmac_mismatch}
    end
  end
end
