defmodule Bonfire.Ghost.EmbedLookupTest do
  @moduledoc """
  The public comments embed may resolve articles imported by webhooks or backfill, but page navigation must never create an article itself.
  """
  use Bonfire.Ghost.DataCase, async: false

  alias Bonfire.Federate.ActivityPub.Peered
  alias Bonfire.Ghost
  alias Bonfire.Ghost.API
  alias Bonfire.Ghost.EmbedHelper
  alias Bonfire.Me.Fake

  @slug "hello-world"
  @canonical "https://blog.test/hello-world/"

  defp article do
    %{
      "id" => "ghost_post_1",
      "slug" => @slug,
      "url" => @canonical,
      "title" => "Hello World",
      "html" => "<p>Body</p>",
      "visibility" => "public",
      "published_at" => "2024-01-15T10:00:00.000Z"
    }
  end

  defp stub_ghost! do
    Repatch.patch(Ghost, :configured?, fn -> true end)
    Repatch.patch(Ghost, :client, fn -> {:ok, :client} end)

    Repatch.patch(API, :get_post_by_slug, fn :client, @slug ->
      {:ok, %{"posts" => [article()]}}
    end)
  end

  test "returns an existing webhook/backfill import without requiring Ghost configuration" do
    author = Fake.fake_user!(%{}, %{username: "ghost_lookup_bot"})
    Process.put([:bonfire_ghost, :auto_import_as], author.id)

    assert {:ok, imported} = EmbedHelper.import_article(article())
    assert {:ok, found} = EmbedHelper.get_post_for_article(@slug, @canonical)
    assert found.id == imported.id
  end

  test "uses Ghost only to resolve the canonical URL of an existing import" do
    author = Fake.fake_user!(%{}, %{username: "ghost_canonical_lookup_bot"})
    Process.put([:bonfire_ghost, :auto_import_as], author.id)

    assert {:ok, imported} = EmbedHelper.import_article(article())
    stub_ghost!()

    assert {:ok, found} =
             EmbedHelper.get_post_for_article(@slug, "https://blog.test/hello-world/?ref=home")

    assert found.id == imported.id
  end

  test "does not create an article when Ghost resolves one that was never imported" do
    author = Fake.fake_user!(%{}, %{username: "ghost_read_only_lookup_bot"})
    Process.put([:bonfire_ghost, :auto_import_as], author.id)
    stub_ghost!()

    assert {:error, :not_found} =
             EmbedHelper.get_post_for_article(@slug, "https://blog.test/alternate-url/")

    assert {:error, :not_found} = Peered.get_by_uri(@canonical)
  end
end
