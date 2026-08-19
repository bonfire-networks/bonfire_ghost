defmodule Bonfire.Ghost.PublicUrlTest do
  @moduledoc """
  `public_url/0` resolves the blog's PUBLIC site URL — what imported articles' `canonical_uri`
  actually use — as distinct from `ghost_url/0` (the API/admin base). Matching `canonical_uri`
  against the API base (e.g. `foo.ghost.io`) finds nothing when articles live at the public
  domain (`foo.de`); that mismatch silently broke `imported_ghost_author?/1` on prod.
  """

  use Bonfire.Ghost.DataCase, async: false
  use Repatch.ExUnit

  alias Bonfire.Ghost
  alias Bonfire.Ghost.API
  alias Bonfire.Common.Cache

  setup do
    Cache.remove_all()
    # clear again afterwards so a cached settings.url can't leak into other test files
    on_exit(fn -> Cache.remove_all() end)
    :ok
  end

  test "derives the public site URL from the Content API settings.url (trailing slash trimmed)" do
    Repatch.patch(Ghost, :client, [force: true], fn -> {:ok, :client} end)

    Repatch.patch(API, :get_settings, [force: true], fn :client ->
      {:ok, %{"settings" => %{"url" => "https://jacobin.de/"}}}
    end)

    assert Ghost.public_url() == "https://jacobin.de"
  end

  test "falls back to the configured ghost_url when Ghost is unreachable" do
    Process.put([:bonfire_ghost, :ghost_url], "https://jacobin-de.ghost.io")
    Repatch.patch(Ghost, :client, [force: true], fn -> {:error, :not_configured} end)

    assert Ghost.public_url() == "https://jacobin-de.ghost.io"
  end
end
