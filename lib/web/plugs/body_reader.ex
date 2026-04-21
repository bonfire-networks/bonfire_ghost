defmodule Bonfire.Ghost.BodyReader do
  @moduledoc """
  Custom `Plug.Parsers` body reader for flavours that need to verify signed
  webhooks (Ghost). Delegates to `ActivityPub.Web.Plugs.DigestPlug.read_body/2`
  so ActivityPub HTTP-signature digests keep working, then stashes the raw
  JSON payload in `conn.private[:bonfire_raw_body]` for later HMAC verification.

  The stash is scoped to JSON requests only — we don't want to hold multipart
  uploads or urlencoded form bodies in memory. Downstream plugs (e.g.
  `Bonfire.Ghost.Web.Plugs.VerifyGhostSignature`) read the private field.

  Wired in via `Application.compile_env(:bonfire_ui_common, :body_reader, ...)`
  from the Jacobin flavour config; other flavours fall back to the default
  `DigestPlug` reader.
  """

  alias Plug.Conn
  alias ActivityPub.Web.Plugs.DigestPlug

  @raw_body_key :bonfire_raw_body

  def read_body(conn, opts) do
    with {:ok, body, conn} <- DigestPlug.read_body(conn, opts) do
      {:ok, body, maybe_stash(conn, body)}
    end
  end

  defp maybe_stash(conn, body) do
    if conn |> Conn.get_req_header("content-type") |> Enum.any?(&String.contains?(&1, "json")) do
      Conn.put_private(conn, @raw_body_key, body)
    else
      conn
    end
  end
end
