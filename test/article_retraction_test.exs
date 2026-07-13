defmodule Bonfire.Ghost.ArticleRetractionTest do
  @moduledoc """
  Regression tests for retracting an imported article (`post.unpublished` / `post.deleted`).

  Two independent defects, both of which left unpublished/deleted (including **paid**)
  articles fully readable in Bonfire:

  1. **The post could not be found.** `hide_article/2` looked the post up by `url` only, but a
     real Ghost `post.deleted` webhook has no top-level `url` in its `previous` object — Ghost's
     webhook serializer builds `previous` from changed *DB attributes*, and `url` is a computed
     field. So the lookup missed and the post stayed live. (The old controller test fabricated a
     `previous` containing `url`, which is why nothing caught this.)

  2. **Even a successful hide did not stop reads.** `Blocks.block(_, :hide, :instance_wide)`
     grants `:cannot_discover`, whose `cannot_verbs` is every verb *except* `[:read, :request]`
     — it removes the post from feeds/search but deliberately leaves `:read` intact, so anyone
     with the direct link could still read a retracted article.
  """
  # `async: false` — touches instance-wide circles/blocks and Ghost config.
  use Bonfire.Ghost.DataCase, async: false

  alias Bonfire.Ghost.EmbedHelper
  alias Bonfire.Me.Fake

  @blog "https://blog.test"
  @slug "hello-world"
  @url "#{@blog}/#{@slug}/"

  setup do
    author = Fake.fake_user!(%{}, %{username: "ghostbot"})
    Process.put([:bonfire_ghost, :auto_import_as], author.id)
    Process.put([:bonfire_ghost, :ghost_url], @blog)

    {:ok, author: author}
  end

  defp article(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "ghost_post_1",
        "url" => @url,
        "slug" => @slug,
        "title" => "Hello World",
        "html" => "<p>Body</p>",
        "visibility" => "public",
        "published_at" => "2024-01-15T10:00:00.000Z"
      },
      overrides
    )
  end

  # What Ghost *actually* sends on post.deleted: `previous` holds changed DB attributes.
  # `url` is computed by the output serializer and is NOT among them. `slug` and `id` are.
  defp realistic_deleted_payload do
    %{
      "id" => "ghost_post_1",
      "slug" => @slug,
      "uuid" => "abc-123",
      "title" => "Hello World",
      "html" => "<p>Body</p>",
      "status" => "published",
      "visibility" => "public",
      "published_at" => "2024-01-15T10:00:00.000Z"
    }
  end

  describe "retracting an article (P1-3)" do
    test "a realistic post.deleted payload (no `url`) still finds and retracts the post" do
      assert {:ok, post} = EmbedHelper.import_article(article(), [])
      reader = Fake.fake_user!()
      assert Bonfire.Boundaries.can?(reader, :read, post)

      assert {:ok, _} = EmbedHelper.hide_article(realistic_deleted_payload(), [])

      refute Bonfire.Boundaries.can?(reader, :read, post.id),
             "a real Ghost delete left the article readable — lookup is by `url`, which the payload doesn't carry"
    end

    test "a retracted article is not readable by direct link, even by a guest" do
      assert {:ok, post} = EmbedHelper.import_article(article(), [])
      assert Bonfire.Boundaries.can?(nil, :read, post)

      assert {:ok, _} = EmbedHelper.hide_article(article(), [])

      refute Bonfire.Boundaries.can?(nil, :read, post.id),
             ":hide only grants :cannot_discover, which leaves :read intact — the article is still readable by direct link"
    end

    test "retracting a PAID article stops reads by a tier member too" do
      Bonfire.Ghost.Sync.Tiers.sync_tiers(
        [%{"id" => "t_gold", "slug" => "gold", "name" => "Gold", "type" => "paid"}],
        []
      )

      {:ok, gold} =
        Bonfire.Boundaries.Circles.get_by_name(
          "ghost_tier:gold",
          Bonfire.Boundaries.Scaffold.Instance.admin_circle()
        )

      member = Fake.fake_user!()
      Bonfire.Boundaries.Circles.add_to_circles(member, gold)

      paid = article(%{"visibility" => "paid"})
      assert {:ok, post} = EmbedHelper.import_article(paid, [])
      assert Bonfire.Boundaries.can?(member, :read, post)

      assert {:ok, _} = EmbedHelper.hide_article(realistic_deleted_payload(), [])

      refute Bonfire.Boundaries.can?(member, :read, post.id)
    end

    test "re-publishing restores readability (retraction is reversible)" do
      assert {:ok, post} = EmbedHelper.import_article(article(), [])
      assert {:ok, _} = EmbedHelper.hide_article(realistic_deleted_payload(), [])

      reader = Fake.fake_user!()
      refute Bonfire.Boundaries.can?(reader, :read, post.id)

      # the article comes back (post.published / post.edited)
      assert {:ok, republished} = EmbedHelper.import_article(article(), [])
      assert republished.id == post.id

      assert Bonfire.Boundaries.can?(reader, :read, post.id),
             "re-publishing must undo the retraction, otherwise a restored article stays dark"
    end

    test "hiding an article that was never imported is a no-op, not an error" do
      assert {:ok, :not_found} = EmbedHelper.hide_article(realistic_deleted_payload(), [])
    end

    test "retraction works when GHOST_URL (API base) differs from the blog's public site URL" do
      # Very common: GHOST_URL is the admin/API endpoint (docker-internal host, odd port, http),
      # while articles are published under the blog's public site URL. Reconstructing the lookup
      # URL from GHOST_URL then finds nothing, and the delete silently no-ops.
      Process.put([:bonfire_ghost, :ghost_url], "https://ghost.internal:2368")

      assert {:ok, post} = EmbedHelper.import_article(article(), [])
      reader = Fake.fake_user!()
      assert Bonfire.Boundaries.can?(reader, :read, post)

      assert {:ok, _} = EmbedHelper.hide_article(realistic_deleted_payload(), [])

      refute Bonfire.Boundaries.can?(reader, :read, post.id),
             "retraction is keyed off GHOST_URL, so a deleted article stays readable whenever the API base differs from the public site URL"
    end
  end
end
