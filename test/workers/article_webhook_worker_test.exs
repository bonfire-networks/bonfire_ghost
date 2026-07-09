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
    article = %{
      "id" => Keyword.get(opts, :id, "ghost_post_1"),
      "slug" => Keyword.get(opts, :slug, "hello-world"),
      "url" => Keyword.get(opts, :url, "https://blog.test/hello-world/"),
      "title" => Keyword.get(opts, :title, "Hello World"),
      "custom_excerpt" => Keyword.get(opts, :excerpt, "An excerpt"),
      "html" => Keyword.get(opts, :html, "<p>Body</p>"),
      "visibility" => Keyword.get(opts, :visibility, "public"),
      "published_at" => Keyword.get(opts, :published_at, "2024-01-15T10:00:00.000Z")
    }

    case Keyword.get(opts, :tag) do
      tag when is_binary(tag) -> Map.put(article, "primary_tag", %{"slug" => tag})
      _ -> article
    end
  end

  defp job(event, post), do: %Oban.Job{args: %{"event" => event, "post" => post}}

  defp run(event, post), do: ArticleWebhookWorker.perform(job(event, post))

  defp read_imported!(post) do
    {:ok, reloaded} =
      Posts.read(post.id,
        skip_boundary_check: true,
        schema: Types.object_type(post)
      )

    reloaded
  end

  defp group!(creator) do
    Bonfire.Classify.Simulate.fake_group!(creator, %{
      membership: "local:members",
      visibility: "nonfederated",
      participation: "anyone"
    })
  end

  defp topic!(creator, group) do
    Bonfire.Classify.Simulate.fake_category!(creator, group, %{
      type: :topic,
      name: "Ghost News"
    })
  end

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

    test "auto-import can publish directly into the configured topic", %{author: author} do
      group = group!(author)
      topic = topic!(author, group)

      Process.put([:bonfire_ghost, :post_into_group], topic.id)
      Process.put([:bonfire_ghost, :require_topic], true)

      assert {:ok, post} = run("post.published", article())

      assert FeedLoader.feed_contains?(:user_activities, post,
               by: topic,
               current_user: author
             )
    end

    test "auto-import tag filters Ghost eligibility while topic id controls placement", %{
      author: author
    } do
      group = group!(author)
      topic = topic!(author, group)

      Process.put([:bonfire_ghost, :auto_import_tag], "politik")
      Process.put([:bonfire_ghost, :post_into_group], topic.id)

      assert {:ok, post} = run("post.published", article(tag: "politik"))
      assert topic.character.username != "politik"

      assert FeedLoader.feed_contains?(:user_activities, post,
               by: topic,
               current_user: author
             )
    end

    test "auto-import skips posts that do not match the configured Ghost tag" do
      Process.put([:bonfire_ghost, :auto_import_tag], "politik")

      assert {:ok, :filtered_out} =
               run(
                 "post.published",
                 article(tag: "culture", url: "https://blog.test/culture/")
               )

      assert {:error, _} =
               Peered.get_by_uri("https://blog.test/culture/")
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
      reloaded = read_imported!(post)
      assert reloaded.post_content.name == "Edited title"
    end
  end

  describe "post.edited" do
    setup do
      author = Fake.fake_user!(%{}, %{username: "ghostbot"})
      enable_auto_import!(author)
      :ok
    end

    test "treats a published edit event as an upsert" do
      assert {:ok, post} = run("post.published", article(title: "Original"))

      edited =
        article(title: "Edited through post.edited")
        |> Map.put("status", "published")

      assert {:ok, updated} = run("post.edited", edited)

      assert updated.id == post.id
      reloaded = read_imported!(post)
      assert reloaded.post_content.name == "Edited through post.edited"
    end

    test "does not import an explicit draft edit" do
      draft =
        article(title: "Draft")
        |> Map.put("status", "draft")
        |> Map.put("url", "https://blog.test/draft/")

      assert {:cancel, :not_published} = run("post.edited", draft)
      refute match?({:ok, _}, Peered.get_by_uri("https://blog.test/draft/"))
    end

    test "fails closed: an edit with no status is not imported" do
      # A slimmed/unexpected payload without a status must not publish a draft.
      no_status =
        article(title: "No status")
        |> Map.delete("status")
        |> Map.put("url", "https://blog.test/no-status/")

      assert {:cancel, :not_published} = run("post.edited", no_status)
      refute match?({:ok, _}, Peered.get_by_uri("https://blog.test/no-status/"))
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
      assert read_imported!(post)
    end

    test "delete hides the post from local feeds but keeps it", %{viewer: viewer} do
      assert {:ok, post} = run("post.published", article())
      assert FeedLoader.feed_contains?(:local, post, viewer)

      assert {:ok, _} = run("post.deleted", article())
      refute FeedLoader.feed_contains?(:local, post, viewer)
      assert read_imported!(post)
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
