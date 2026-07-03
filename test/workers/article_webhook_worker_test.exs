defmodule Bonfire.Ghost.Workers.ArticleWebhookWorkerTest do
  # `async: false` because it flips an instance-scoped setting (shared state)
  # and applies instance-wide hides.
  use Bonfire.Ghost.DataCase, async: false

  alias Bonfire.Ghost.Workers.ArticleWebhookWorker
  alias Bonfire.Common.Types
  alias Bonfire.Common.Settings
  alias Bonfire.Posts
  alias Bonfire.Federate.ActivityPub.Peered
  alias Bonfire.Social.FeedLoader
  alias Bonfire.Me.Fake

  # An article payload as Ghost delivers it under `post.current` — kept minimal
  # and network-free: no resolvable `primary_author`/`primary_tag`, so author
  # resolution falls through to the configured default user and no Ghost API is hit.
  defp article(opts \\ []) do
    %{
      "id" => Keyword.get(opts, :id, "ghost_post_1"),
      "slug" => Keyword.get(opts, :slug, "hello-world"),
      "url" => Keyword.get(opts, :url, "https://blog.test/hello-world/"),
      "title" => Keyword.get(opts, :title, "Hello World"),
      "custom_excerpt" => Keyword.get(opts, :excerpt, "An excerpt"),
      "html" => Keyword.get(opts, :html, "<p>Body</p>"),
      "visibility" => Keyword.get(opts, :visibility, "public"),
      "published_at" => Keyword.get(opts, :published_at, "2024-01-15T10:00:00.000Z")
    }
  end

  defp job(event, post), do: %Oban.Job{args: %{"event" => event, "post" => post}}

  defp run(event, post), do: ArticleWebhookWorker.perform(job(event, post))

  defp enable_auto_import!(author) do
    Settings.put([:bonfire_ghost, :auto_import_articles], true,
      scope: :instance,
      skip_boundary_check: true
    )

    Settings.put([:bonfire_ghost, :auto_import_as], author.id,
      scope: :instance,
      skip_boundary_check: true
    )

    :ok
  end

  describe "opt-in gating" do
    test "does nothing and cancels when auto-import is disabled" do
      _author = Fake.fake_user!(%{}, %{username: "ghostbot"})
      # explicit — instance settings are cached and can leak across tests
      Settings.put([:bonfire_ghost, :auto_import_articles], false,
        scope: :instance,
        skip_boundary_check: true
      )

      assert {:cancel, :disabled} = run("post.published", article())
      refute match?({:ok, _}, Peered.get_by_uri("https://blog.test/hello-world/"))
    end
  end

  describe "post.published" do
    setup do
      author = Fake.fake_user!(%{}, %{username: "ghostbot"})
      enable_auto_import!(author)
      {:ok, author: author}
    end

    test "creates a post attributed to the configured author, with canonical URI + backdated id" do
      assert {:ok, post} = run("post.published", article())

      assert {:ok, found} = Peered.get_by_uri("https://blog.test/hello-world/")
      assert found.id == post.id

      # backdated to published_at
      date = Bonfire.Common.DatesTimes.date_from_pointer(post.id)
      assert date.year == 2024 and date.month == 1 and date.day == 15
    end

    test "imports Ghost posts as article objects" do
      assert {:ok, post} = run("post.published", article())

      assert Types.object_type(post) == Bonfire.Articles.Article
    end

    test "is idempotent — re-publishing the same URL does not duplicate" do
      assert {:ok, post_a} = run("post.published", article())
      assert {:ok, post_b} = run("post.published", article())
      assert post_a.id == post_b.id
    end
  end

  describe "post.published.edited" do
    setup do
      author = Fake.fake_user!(%{}, %{username: "ghostbot"})
      enable_auto_import!(author)
      :ok
    end

    test "updates the existing post's content rather than creating a duplicate" do
      assert {:ok, post} = run("post.published", article(title: "Original"))

      assert {:ok, updated} =
               run("post.published.edited", article(title: "Edited title"))

      assert updated.id == post.id
      reloaded = Posts.read(post.id, skip_boundary_check: true) |> elem(1)
      assert reloaded.post_content.name == "Edited title"
    end
  end

  describe "post.unpublished / post.deleted — hide, never delete" do
    setup do
      author = Fake.fake_user!(%{}, %{username: "ghostbot"})
      viewer = Fake.fake_user!()
      enable_auto_import!(author)
      {:ok, viewer: viewer}
    end

    test "unpublish hides the post from local feeds but keeps it", %{viewer: viewer} do
      assert {:ok, post} = run("post.published", article())
      assert FeedLoader.feed_contains?(:local, post, viewer)

      assert {:ok, _} = run("post.unpublished", article())
      refute FeedLoader.feed_contains?(:local, post, viewer)
      # still present, not deleted
      assert {:ok, _} = Posts.read(post.id, skip_boundary_check: true)
    end

    test "delete hides the post from local feeds but keeps it", %{viewer: viewer} do
      assert {:ok, post} = run("post.published", article())
      assert FeedLoader.feed_contains?(:local, post, viewer)

      assert {:ok, _} = run("post.deleted", article())
      refute FeedLoader.feed_contains?(:local, post, viewer)
      assert {:ok, _} = Posts.read(post.id, skip_boundary_check: true)
    end

    test "re-publishing after an unpublish un-hides the post", %{viewer: viewer} do
      assert {:ok, post} = run("post.published", article())
      assert {:ok, _} = run("post.unpublished", article())
      refute FeedLoader.feed_contains?(:local, post, viewer)

      assert {:ok, _} = run("post.published", article())
      assert FeedLoader.feed_contains?(:local, post, viewer)
    end
  end

  describe "unknown events" do
    test "cancels on an unrecognized event" do
      author = Fake.fake_user!(%{}, %{username: "ghostbot"})
      enable_auto_import!(author)

      assert {:cancel, {:unknown_event, "post.whatever"}} =
               run("post.whatever", article())
    end
  end
end
