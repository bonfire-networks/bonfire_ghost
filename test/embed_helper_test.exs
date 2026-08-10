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

  describe "import_article/2 access updates" do
    setup do
      author = Fake.fake_user!(%{}, %{username: "ghostbot"})
      Process.put([:bonfire_ghost, :auto_import_as], author.id)

      Bonfire.Ghost.Sync.Tiers.sync_tiers(
        [
          %{"id" => "t_gold", "slug" => "gold", "name" => "Gold", "type" => "paid"},
          %{"id" => "t_silver", "slug" => "silver", "name" => "Silver", "type" => "paid"}
        ],
        []
      )

      :ok
    end

    defp tier_circle!(slug) do
      {:ok, circle} =
        Bonfire.Boundaries.Circles.get_by_name(
          "ghost_tier:#{slug}",
          Bonfire.Boundaries.Scaffold.Instance.admin_circle()
        )

      circle
    end

    test "updates an existing public article when Ghost changes it to a paid tier" do
      outsider = Fake.fake_user!()
      member = Fake.fake_user!()
      Bonfire.Boundaries.Circles.add_to_circles(member, tier_circle!("gold"))

      assert {:ok, post} = EmbedHelper.import_article(article())
      assert Bonfire.Boundaries.can?(outsider, :read, post)

      paid_article =
        Map.merge(article(), %{"visibility" => "tiers", "tiers" => [%{"slug" => "gold"}]})

      assert {:ok, updated} = EmbedHelper.import_article(paid_article)

      assert updated.id == post.id
      refute Bonfire.Boundaries.can?(outsider, :read, updated)
      assert Bonfire.Boundaries.can?(member, :read, updated)
    end

    test "updates an existing paid article when Ghost changes it back to public" do
      outsider = Fake.fake_user!()

      paid_article =
        Map.merge(article(), %{"visibility" => "tiers", "tiers" => [%{"slug" => "gold"}]})

      assert {:ok, post} = EmbedHelper.import_article(paid_article)
      refute Bonfire.Boundaries.can?(outsider, :read, post)

      assert {:ok, updated} = EmbedHelper.import_article(article())

      assert updated.id == post.id
      assert Bonfire.Boundaries.can?(outsider, :read, updated)
    end

    test "updates an existing paid article when Ghost changes it to members-only" do
      reader = Fake.fake_user!()

      paid_article =
        Map.merge(article(), %{"visibility" => "tiers", "tiers" => [%{"slug" => "gold"}]})

      assert {:ok, post} = EmbedHelper.import_article(paid_article)
      refute Bonfire.Boundaries.can?(reader, :read, post)

      members_article = Map.put(article(), "visibility", "members")
      assert {:ok, updated} = EmbedHelper.import_article(members_article)

      assert updated.id == post.id
      assert Bonfire.Boundaries.can?(reader, :read, updated)
    end

    test "removes stale Ghost tier grants when the allowed tier changes" do
      gold_member = Fake.fake_user!()
      silver_member = Fake.fake_user!()
      Bonfire.Boundaries.Circles.add_to_circles(gold_member, tier_circle!("gold"))
      Bonfire.Boundaries.Circles.add_to_circles(silver_member, tier_circle!("silver"))

      gold_article =
        Map.merge(article(), %{"visibility" => "tiers", "tiers" => [%{"slug" => "gold"}]})

      assert {:ok, post} = EmbedHelper.import_article(gold_article)
      assert Bonfire.Boundaries.can?(gold_member, :read, post)
      refute Bonfire.Boundaries.can?(silver_member, :read, post)

      silver_article =
        Map.merge(article(), %{"visibility" => "tiers", "tiers" => [%{"slug" => "silver"}]})

      assert {:ok, updated} = EmbedHelper.import_article(silver_article)

      refute Bonfire.Boundaries.can?(gold_member, :read, updated)
      assert Bonfire.Boundaries.can?(silver_member, :read, updated)
    end
  end

  describe "auto_import_tag filter" do
    setup do
      author = Fake.fake_user!(%{}, %{username: "ghostbot"})

      Process.put([:bonfire_ghost, :auto_import_as], author.id)
      Process.put([:bonfire_ghost, :auto_import_tag], "politik")

      {:ok, author: author}
    end

    test "imports matching Ghost tags into the configured topic id even when names differ", %{
      author: author
    } do
      group = group!(author)
      topic = topic!(author, group, %{name: "Politik Jacobin"})

      Process.put([:bonfire_ghost, :post_into_group], topic.id)

      tagged =
        article()
        |> Map.put("primary_tag", %{"slug" => "politik"})

      assert {:ok, post} = EmbedHelper.import_article(tagged, [])

      assert topic.character.username != "politik"

      assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post,
               by: topic,
               current_user: author
             )
    end

    test "skips non-matching Ghost tags without creating a post" do
      tagged =
        article()
        |> Map.put("primary_tag", %{"slug" => "culture"})

      assert {:ok, :filtered_out} = EmbedHelper.import_article(tagged, [])
      assert {:error, _} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(tagged["url"])
    end

    test "matches secondary Ghost tags" do
      tagged =
        article()
        |> Map.put("primary_tag", %{"slug" => "culture"})
        |> Map.put("tags", [%{"slug" => "culture"}, %{"slug" => "politik"}])

      assert {:ok, post} = EmbedHelper.import_article(tagged, [])
      assert post.id
    end

    test "fails closed when the configured tag filter has an invalid shape" do
      Process.put([:bonfire_ghost, :auto_import_tag], %{slug: "politik"})

      tagged =
        article()
        |> Map.put("primary_tag", %{"slug" => "politik"})

      assert {:error, {:invalid_auto_import_tag_filter, %{slug: "politik"}}} =
               EmbedHelper.import_article(tagged, [])

      assert {:error, _} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(tagged["url"])
    end

    test "hides an existing imported post when an edit no longer matches the tag filter" do
      viewer = Fake.fake_user!()

      matching =
        article()
        |> Map.put("primary_tag", %{"slug" => "politik"})

      non_matching =
        article()
        |> Map.put("primary_tag", %{"slug" => "culture"})

      assert {:ok, post} = EmbedHelper.import_article(matching, [])
      assert Bonfire.Social.FeedLoader.feed_contains?(:local, post, viewer)

      assert {:ok, :filtered_out} = EmbedHelper.import_article(non_matching, [])
      refute Bonfire.Social.FeedLoader.feed_contains?(:local, post, viewer)

      assert {:ok, _} =
               Bonfire.Posts.read(post.id,
                 skip_boundary_check: true,
                 schema: Bonfire.Common.Types.object_type(post)
               )
    end

    test "on_filtered: :skip leaves an existing non-matching post visible (backfill semantics)" do
      viewer = Fake.fake_user!()

      matching =
        article()
        |> Map.put("primary_tag", %{"slug" => "politik"})

      non_matching =
        article()
        |> Map.put("primary_tag", %{"slug" => "culture"})

      assert {:ok, post} = EmbedHelper.import_article(matching, [])
      assert Bonfire.Social.FeedLoader.feed_contains?(:local, post, viewer)

      # A bulk backfill must NOT retroactively hide posts that don't match the filter.
      assert {:ok, :filtered_out} = EmbedHelper.import_article(non_matching, on_filtered: :skip)
      assert Bonfire.Social.FeedLoader.feed_contains?(:local, post, viewer)
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

    defp topic!(creator, group, attrs \\ %{}) do
      Bonfire.Classify.Simulate.fake_category!(
        creator,
        group,
        Map.merge(%{type: :topic, name: "Ghost News"}, attrs)
      )
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

    test "the post_into_group instance setting can target a topic directly" do
      creator = Fake.fake_user!()
      group = group!(creator)
      topic = topic!(creator, group)

      Process.put([:bonfire_ghost, :auto_import_as], creator.id)
      Process.put([:bonfire_ghost, :post_into_group], topic.id)
      Process.put([:bonfire_ghost, :require_topic], true)

      assert {:ok, post} = EmbedHelper.import_article(article(), [])

      assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post,
               by: topic,
               current_user: creator
             )

      assert {:ok, boost} =
               Bonfire.Social.Boosts.get(topic, post, skip_boundary_check: true)

      boost_date = Bonfire.Common.DatesTimes.date_from_pointer(boost)
      post_date = Bonfire.Common.DatesTimes.date_from_pointer(post)

      assert DateTime.compare(boost_date, post_date) == :eq
      assert boost.id != post.id
    end

    test "routing an existing article into a topic preserves its publication date" do
      creator = Fake.fake_user!()
      group = group!(creator)
      topic = topic!(creator, group)

      Process.put([:bonfire_ghost, :auto_import_as], creator.id)

      assert {:ok, post} = EmbedHelper.import_article(article(), [])
      assert {:ok, updated} = EmbedHelper.import_article(article(), group_id: topic.id)

      assert updated.id == post.id

      assert {:ok, boost} =
               Bonfire.Social.Boosts.get(topic, post, skip_boundary_check: true)

      assert DateTime.compare(
               Bonfire.Common.DatesTimes.date_from_pointer(boost),
               Bonfire.Common.DatesTimes.date_from_pointer(post)
             ) == :eq
    end

    test "ordinary category auto-boosts still use the current time" do
      creator = Fake.fake_user!()
      group = group!(creator)
      topic = topic!(creator, group)

      Process.put([:bonfire_ghost, :auto_import_as], creator.id)

      assert {:ok, post} = EmbedHelper.import_article(article(), [])
      before_boost = DateTime.utc_now()

      Bonfire.Social.Tags.maybe_auto_boost(creator, topic, post)

      assert {:ok, boost} =
               Bonfire.Social.Boosts.get(topic, post, skip_boundary_check: true)

      boost_date = Bonfire.Common.DatesTimes.date_from_pointer(boost)

      assert DateTime.compare(boost_date, before_boost) in [:eq, :gt]
      assert DateTime.diff(DateTime.utc_now(), boost_date, :second) <= 1
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

    test "explicit group_id opt can target a topic directly" do
      creator = Fake.fake_user!()
      group = group!(creator)
      topic = topic!(creator, group)

      Process.put([:bonfire_ghost, :auto_import_as], creator.id)
      Process.put([:bonfire_ghost, :require_topic], true)

      assert {:ok, post} = EmbedHelper.import_article(article(), group_id: topic.id)

      assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post,
               by: topic,
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

    test "matches the primary Ghost tag to a topic name when its global username is suffixed",
         %{creator: creator, group: group} do
      Fake.fake_user!(%{}, %{username: "gesellschaft"})

      topic =
        Bonfire.Classify.Simulate.fake_category!(creator, group, %{
          type: :topic,
          name: "Gesellschaft"
        })

      Process.put([:bonfire_ghost, :auto_import_as], creator.id)

      tagged = Map.put(article(), "primary_tag", %{"slug" => "gesellschaft"})

      assert topic.character.username != "gesellschaft"
      assert {:ok, post} = EmbedHelper.import_article(tagged, [])

      assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post,
               by: topic,
               current_user: creator
             )
    end

    test "re-sync routes the existing article into its named topic without losing comments",
         %{creator: creator, group: group} do
      Fake.fake_user!(%{}, %{username: "gesellschaft"})

      topic =
        Bonfire.Classify.Simulate.fake_category!(creator, group, %{
          type: :topic,
          name: "Gesellschaft"
        })

      commenter = Fake.fake_user!()
      Process.put([:bonfire_ghost, :auto_import_as], creator.id)

      assert {:ok, post} = EmbedHelper.import_article(article(), [])

      assert {:ok, comment} =
               Bonfire.Posts.publish(
                 current_user: commenter,
                 post_attrs: %{
                   post_content: %{html_body: "A comment that must survive the re-sync"},
                   reply_to_id: post.id
                 },
                 boundary: "public"
               )

      tagged = Map.put(article(), "primary_tag", %{"slug" => "gesellschaft"})

      assert {:ok, updated} = EmbedHelper.import_article(tagged, [])
      assert updated.id == post.id

      assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, updated,
               by: topic,
               current_user: creator
             )

      %{edges: replies} =
        Bonfire.Social.Threads.list_replies(updated.id,
          current_user: commenter,
          total_replies_count: 1
        )

      assert Enum.any?(replies, &(&1.id == comment.id))
    end

    test "does not guess when multiple topic names match the primary Ghost tag",
         %{creator: creator, group: group} do
      Fake.fake_user!(%{}, %{username: "gesellschaft"})

      for _ <- 1..2 do
        Bonfire.Classify.Simulate.fake_category!(creator, group, %{
          type: :topic,
          name: "Gesellschaft"
        })
      end

      Process.put([:bonfire_ghost, :auto_import_as], creator.id)
      Process.put([:bonfire_ghost, :require_topic], true)

      tagged = Map.put(article(), "primary_tag", %{"slug" => "gesellschaft"})

      assert {:error, :topic_required} = EmbedHelper.import_article(tagged, [])
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

  describe "Bonfire.Ghost.post_into_group/0" do
    test "returns the configured group id, or nil when unset or blank" do
      assert Bonfire.Ghost.post_into_group() == nil

      Process.put([:bonfire_ghost, :post_into_group], "01GROUPIDXXXXXXXXXXXXXXXXX")
      assert Bonfire.Ghost.post_into_group() == "01GROUPIDXXXXXXXXXXXXXXXXX"

      Process.put([:bonfire_ghost, :post_into_group], "")
      assert Bonfire.Ghost.post_into_group() == nil
    end
  end

  describe "Bonfire.Ghost.imported_articles_count/1" do
    test "counts imported articles by their canonical URL prefix" do
      author = Fake.fake_user!(%{}, %{username: "ghostbot"})
      Process.put([:bonfire_ghost, :auto_import_as], author.id)

      assert {:ok, _} =
               EmbedHelper.import_article(%{
                 article()
                 | "url" => "https://blog.test/one/",
                   "id" => "gp1"
               })

      assert {:ok, _} =
               EmbedHelper.import_article(%{
                 article()
                 | "url" => "https://blog.test/two/",
                   "id" => "gp2"
               })

      assert Bonfire.Ghost.imported_articles_count("https://blog.test") == 2
      # trailing slash on the passed URL must not change the result
      assert Bonfire.Ghost.imported_articles_count("https://blog.test/") == 2
      # a different domain matches nothing
      assert Bonfire.Ghost.imported_articles_count("https://other.test") == 0
    end

    test "returns nil when no blog URL is available" do
      # No arg and no configured GHOST_URL → nothing to match on.
      Process.put([:bonfire_ghost, :ghost_url], "")
      assert Bonfire.Ghost.imported_articles_count(nil) == nil
    end
  end
end
