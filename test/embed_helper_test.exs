defmodule Bonfire.Ghost.EmbedHelperTest do
  # `async: false` — touches instance-wide categories/circles. Ghost instance
  # settings are read via `Config.get`, so tests prime them with `Process.put`
  # (the test-env `Config.get` checks the process tree first — see Bonfire.Common.Config).
  use Bonfire.Ghost.DataCase, async: false

  alias Bonfire.Ghost.EmbedHelper
  alias Bonfire.Me.Fake

  # network-free article (no resolvable Ghost author/tag)
  defp article do
    %{
      "id" => "ghost_post_1",
      "url" => "https://blog.test/hello-world/",
      "title" => "Hello World",
      "html" => "<p>Body</p>",
      "visibility" => "public",
      "published_at" => "2024-01-15T10:00:00.000Z"
    }
  end

  describe "import_article/2 author resolution" do
    test "falls back to the configured default author when none can be resolved" do
      author = Fake.fake_user!(%{}, %{username: "ghostbot"})

      Process.put([:bonfire_ghost, :auto_import_as], author.id)

      assert {:ok, post} = EmbedHelper.import_article(article(), [])
      assert post.id
    end

    test "returns {:error, :no_author} (no crash) when nothing resolves" do
      # no configured default, no current_user, unresolvable Ghost author
      assert {:error, :no_author} = EmbedHelper.import_article(article(), [])
    end

    test "uses an explicit creator when provided (overrides the configured default)" do
      explicit = Fake.fake_user!(%{}, %{username: "explicit_author"})
      assert {:ok, _post} = EmbedHelper.import_article(article(), creator: explicit)
    end
  end

  describe "import_article/2 upsert" do
    setup do
      author = Fake.fake_user!(%{}, %{username: "ghostbot"})

      Process.put([:bonfire_ghost, :auto_import_as], author.id)

      :ok
    end

    test "updates the existing post instead of creating a duplicate" do
      assert {:ok, post} = EmbedHelper.import_article(article())
      assert {:ok, again} = EmbedHelper.import_article(%{article() | "title" => "Changed"})
      assert again.id == post.id
    end
  end

  describe "hide_article/2" do
    test "is a no-op when no post exists for the URL" do
      assert {:ok, :not_found} = EmbedHelper.hide_article("https://blog.test/missing/")
    end
  end

  describe "tier_circles_for_article/1 (A4)" do
    setup do
      Bonfire.Ghost.Sync.Tiers.sync_tiers(
        [
          %{"id" => "t_gold", "slug" => "gold", "name" => "Gold", "type" => "paid"},
          %{"id" => "t_silver", "slug" => "silver", "name" => "Silver", "type" => "paid"},
          %{"id" => "t_free", "slug" => "free", "name" => "Free", "type" => "free"}
        ],
        []
      )

      :ok
    end

    defp gt(slug) do
      {:ok, circle} =
        Bonfire.Boundaries.Circles.get_by_name(
          "ghost_tier:#{slug}",
          Bonfire.Boundaries.Scaffold.Instance.admin_circle()
        )

      circle.id
    end

    test "visibility=tiers → only the named tier circles" do
      art = Map.merge(article(), %{"visibility" => "tiers", "tiers" => [%{"slug" => "gold"}]})

      assert MapSet.new(EmbedHelper.tier_circles_for_article(art)) == MapSet.new([gt("gold")])
    end

    test "visibility=paid → all paid-type tier circles (not free)" do
      art = Map.put(article(), "visibility", "paid")

      assert MapSet.new(EmbedHelper.tier_circles_for_article(art)) ==
               MapSet.new([gt("gold"), gt("silver")])
    end

    test "visibility=members → all ghost_tier circles" do
      art = Map.put(article(), "visibility", "members")

      assert MapSet.new(EmbedHelper.tier_circles_for_article(art)) ==
               MapSet.new([gt("gold"), gt("silver"), gt("free")])
    end

    test "visibility=public → no tier circles" do
      assert EmbedHelper.tier_circles_for_article(article()) == []
    end

    test "an unknown tier slug is skipped (warned, not crashed)" do
      art = Map.merge(article(), %{"visibility" => "tiers", "tiers" => [%{"slug" => "nope"}]})

      assert EmbedHelper.tier_circles_for_article(art) == []
    end
  end

  describe "no-group restricted article boundary (A5)" do
    setup do
      author = Fake.fake_user!(%{}, %{username: "ghostbot"})
      Process.put([:bonfire_ghost, :auto_import_as], author.id)
      # no post_into_group → article resolves to no group context

      Bonfire.Ghost.Sync.Tiers.sync_tiers(
        [%{"id" => "t_gold", "slug" => "gold", "name" => "Gold", "type" => "paid"}],
        []
      )

      :ok
    end

    defp paid_article do
      Map.merge(article(), %{"visibility" => "paid", "tiers" => [%{"slug" => "gold"}]})
    end

    test "an outsider gets :see but NOT :read on a no-group paid article" do
      outsider = Fake.fake_user!()

      assert {:ok, post} = EmbedHelper.import_article(paid_article(), [])

      assert Bonfire.Boundaries.can?(outsider, :see, post)
      refute Bonfire.Boundaries.can?(outsider, :read, post)
    end

    test "a ghost_tier member gets :read on a no-group paid article" do
      member = Fake.fake_user!()

      {:ok, gold} =
        Bonfire.Boundaries.Circles.get_by_name(
          "ghost_tier:gold",
          Bonfire.Boundaries.Scaffold.Instance.admin_circle()
        )

      Bonfire.Boundaries.Circles.add_to_circles(member, gold)

      assert {:ok, post} = EmbedHelper.import_article(paid_article(), [])

      assert Bonfire.Boundaries.can?(member, :read, post)
    end
  end

  describe "restricted article access levels — free is not a paywall (A5)" do
    setup do
      author = Fake.fake_user!(%{}, %{username: "ghostbot"})
      Process.put([:bonfire_ghost, :auto_import_as], author.id)

      Bonfire.Ghost.Sync.Tiers.sync_tiers(
        [
          %{"id" => "t_free", "slug" => "free", "name" => "Free", "type" => "free"},
          %{"id" => "t_gold", "slug" => "gold", "name" => "Gold", "type" => "paid"}
        ],
        []
      )

      :ok
    end

    defp import!(visibility, extra \\ %{}) do
      art = Map.merge(article(), Map.merge(%{"visibility" => visibility}, extra))
      {:ok, post} = EmbedHelper.import_article(art, [])
      post
    end

    test "public → readable by everyone incl. logged-out guests" do
      post = import!("public")
      assert Bonfire.Boundaries.can?(nil, :see, post)
      assert Bonfire.Boundaries.can?(nil, :read, post)
    end

    test "members → readable by any logged-in local user" do
      reader = Fake.fake_user!()
      post = import!("members")
      assert Bonfire.Boundaries.can?(reader, :see, post)
      assert Bonfire.Boundaries.can?(reader, :read, post)
    end

    test "tiers including a free tier → readable by any logged-in local user" do
      reader = Fake.fake_user!()
      post = import!("tiers", %{"tiers" => [%{"slug" => "free"}, %{"slug" => "gold"}]})
      assert Bonfire.Boundaries.can?(reader, :see, post)
      assert Bonfire.Boundaries.can?(reader, :read, post)
    end

    test "tiers with only paid tiers → preview visible to all, read gated to those paid members" do
      outsider = Fake.fake_user!()
      member = Fake.fake_user!()

      {:ok, gold} =
        Bonfire.Boundaries.Circles.get_by_name(
          "ghost_tier:gold",
          Bonfire.Boundaries.Scaffold.Instance.admin_circle()
        )

      Bonfire.Boundaries.Circles.add_to_circles(member, gold)

      post = import!("tiers", %{"tiers" => [%{"slug" => "gold"}]})

      # outsider still SEES the preview (feed card) but cannot READ the body
      assert Bonfire.Boundaries.can?(outsider, :see, post)
      refute Bonfire.Boundaries.can?(outsider, :read, post)

      # tier member sees and reads
      assert Bonfire.Boundaries.can?(member, :see, post)
      assert Bonfire.Boundaries.can?(member, :read, post)
    end
  end

  describe "import as Article type (A2)" do
    setup do
      author = Fake.fake_user!(%{}, %{username: "ghostbot"})
      Process.put([:bonfire_ghost, :auto_import_as], author.id)
      :ok
    end

    test "imported article is created as an Article, not a plain Post" do
      assert {:ok, post} = EmbedHelper.import_article(article(), [])
      assert Bonfire.Common.Types.object_type(post) == Bonfire.Articles.Article
    end
  end

  describe "group/topic posting (A3)" do
    setup do
      author = Fake.fake_user!(%{}, %{username: "ghostbot"})

      Process.put([:bonfire_ghost, :auto_import_as], author.id)

      {:ok, author: author}
    end

    defp group!(creator) do
      Bonfire.Classify.Simulate.fake_group!(creator, %{
        membership: "local:members",
        visibility: "nonfederated",
        participation: "anyone"
      })
    end

    test "imported article reaches the target group's feed (via group_id opt)" do
      creator = Fake.fake_user!()
      group = group!(creator)

      assert {:ok, post} = EmbedHelper.import_article(article(), group_id: group.id)

      assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post,
               by: group,
               current_user: creator
             )
    end

    test "the post_into_group instance setting targets the group when no opt is passed" do
      creator = Fake.fake_user!()
      group = group!(creator)

      Process.put([:bonfire_ghost, :post_into_group], group.id)

      assert {:ok, post} = EmbedHelper.import_article(article(), [])

      assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post,
               by: group,
               current_user: creator
             )
    end

    test "explicit group_id opt overrides the post_into_group setting" do
      creator = Fake.fake_user!()
      setting_group = group!(creator)
      opt_group = group!(creator)

      Process.put([:bonfire_ghost, :post_into_group], setting_group.id)

      assert {:ok, post} = EmbedHelper.import_article(article(), group_id: opt_group.id)

      assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post,
               by: opt_group,
               current_user: creator
             )

      refute Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post,
               by: setting_group,
               current_user: creator
             )
    end

    test "no group configured → post still created, not in any group feed" do
      creator = Fake.fake_user!()
      group = group!(creator)

      assert {:ok, post} = EmbedHelper.import_article(article(), [])
      assert post.id

      refute Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post,
               by: group,
               current_user: creator
             )
    end
  end

  describe "require_topic (A3)" do
    setup do
      author = Fake.fake_user!(%{}, %{username: "ghostbot"})

      Process.put([:bonfire_ghost, :auto_import_as], author.id)

      creator = Fake.fake_user!()
      group = group!(creator)

      Process.put([:bonfire_ghost, :post_into_group], group.id)

      {:ok, creator: creator, group: group}
    end

    # a topic (sub-category) under the group, plus an article whose primary_tag
    # slug matches the topic's username so `resolve_context` resolves to it.
    defp topic_and_tagged_article(creator, group) do
      topic =
        Bonfire.Classify.Simulate.fake_category!(creator, group, %{
          type: :topic,
          name: "Ghost News"
        })

      slug = topic.character.username
      article = Map.put(article(), "primary_tag", %{"slug" => slug})
      {topic, article}
    end

    test "the require_topic instance setting rejects an article with no matching topic" do
      Process.put([:bonfire_ghost, :require_topic], true)

      # article() has no primary_tag → only resolves to the group, not a topic
      assert {:error, :topic_required} = EmbedHelper.import_article(article(), [])
    end

    test "with a matching topic, require_topic passes and the post lands in the topic feed",
         %{creator: creator, group: group} do
      Process.put([:bonfire_ghost, :require_topic], true)
      # import as the group/topic owner (a realistic config — the bot must be able
      # to post into the target topic for the article to reach its feed)
      Process.put([:bonfire_ghost, :auto_import_as], creator.id)

      {topic, tagged} = topic_and_tagged_article(creator, group)

      assert {:ok, post} = EmbedHelper.import_article(tagged, [])

      assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post,
               by: topic,
               current_user: creator
             )
    end

    test "without require_topic, the same article is imported into the group", %{
      creator: creator,
      group: group
    } do
      assert {:ok, post} = EmbedHelper.import_article(article(), [])

      assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post,
               by: group,
               current_user: creator
             )
    end

    test "an explicit require_topic: false opt overrides the setting", %{
      creator: creator,
      group: group
    } do
      Process.put([:bonfire_ghost, :require_topic], true)

      assert {:ok, post} = EmbedHelper.import_article(article(), require_topic: false)

      # not rejected, and still lands in the configured group's feed
      assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post,
               by: group,
               current_user: creator
             )
    end

    # KNOWN GAP (currently RED): in prod the configured import bot (`auto_import_as`)
    # is typically NOT a member of the target group/topic. A non-member's post reaches
    # a GROUP feed but not a TOPIC feed — so imported articles silently miss the topic
    # feed. These assert the DESIRED behaviour; fix pending (auto-add bot as member, or
    # publish with elevated/caretaker permission).
    test "a non-member import bot's article still reaches the target GROUP feed", %{
      creator: creator,
      group: group
    } do
      bot = Fake.fake_user!(%{}, %{username: "import_bot_nonmember"})
      Process.put([:bonfire_ghost, :auto_import_as], bot.id)

      assert {:ok, post} = EmbedHelper.import_article(article(), [])

      assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post,
               by: group,
               current_user: creator
             )
    end

    test "a non-member import bot's article still reaches the target TOPIC feed", %{
      creator: creator,
      group: group
    } do
      bot = Fake.fake_user!(%{}, %{username: "import_bot_nonmember_topic"})
      Process.put([:bonfire_ghost, :auto_import_as], bot.id)

      {topic, tagged} = topic_and_tagged_article(creator, group)

      # the import auto-joins the bot to the group, so it can post into the topic
      assert {:ok, post} = EmbedHelper.import_article(tagged, [])

      assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post,
               by: topic,
               current_user: creator
             )
    end
  end
end
