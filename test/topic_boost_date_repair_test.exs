defmodule Bonfire.Ghost.TopicBoostDateRepairTest do
  use Bonfire.Ghost.DataCase, async: false

  alias Bonfire.Common.DatesTimes
  alias Bonfire.Ghost.EmbedHelper
  alias Bonfire.Ghost.TopicBoostDateRepair
  alias Bonfire.Me.Fake
  alias Bonfire.Social.Boosts

  defp article do
    %{
      "id" => "ghost_repair_post",
      "url" => "https://blog.test/archive/old-story/",
      "title" => "Old Story",
      "html" => "<p>Body</p>",
      "visibility" => "public",
      "published_at" => "2021-03-14T10:00:00.000Z"
    }
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
      name: "Ghost Repair"
    })
  end

  setup do
    author = Fake.fake_user!(%{}, %{username: "ghostrepairbot"})
    group = group!(author)
    topic = topic!(author, group)

    Process.put([:bonfire_ghost, :auto_import_as], author.id)

    assert {:ok, post} = EmbedHelper.import_article(article(), [])
    Bonfire.Social.Tags.maybe_auto_boost(author, topic, post, skip_federation: true)
    assert {:ok, boost} = Boosts.get(topic, post, skip_boundary_check: true)

    {:ok, author: author, topic: topic, post: post, boost: boost}
  end

  test "preview selects only the exact Ghost topic, URL, author, and Article", context do
    assert {:ok, manifest} = preview(context)
    assert [repair] = manifest["repairs"]

    assert repair["old_boost_id"] == context.boost.id
    assert repair["article_id"] == context.post.id
    assert repair["canonical_uri"] == article()["url"]
    assert DateTime.compare(date(repair["old_boost_id"]), date(context.post.id)) == :gt
    assert DateTime.compare(date(repair["new_boost_id"]), date(context.post.id)) == :eq

    assert {:ok, %{"repairs" => []}} =
             TopicBoostDateRepair.preview(
               topic_id: context.topic.id,
               ghost_url: "https://another-blog.test/",
               author_id: context.author.id
             )
  end

  test "apply cascades the new boost ID without losing its feed placement", context do
    assert {:ok, manifest} = preview(context)
    [repair] = manifest["repairs"]

    assert {:ok, 1} = TopicBoostDateRepair.apply(manifest)
    assert {:ok, repaired_boost} = Boosts.get(context.topic, context.post, skip_boundary_check: true)

    assert repaired_boost.id == repair["new_boost_id"]
    assert DateTime.compare(date(repaired_boost.id), date(context.post.id)) == :eq

    assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, context.post,
             by: context.topic,
             current_user: context.author
           )
  end

  test "rollback restores the exact original boost ID", context do
    assert {:ok, manifest} = preview(context)
    assert {:ok, 1} = TopicBoostDateRepair.apply(manifest)
    assert {:ok, 1} = TopicBoostDateRepair.rollback(manifest)

    assert {:ok, restored_boost} =
             Boosts.get(context.topic, context.post, skip_boundary_check: true)

    assert restored_boost.id == context.boost.id
  end

  test "apply rejects a tampered manifest without changing the boost", context do
    assert {:ok, manifest} = preview(context)

    tampered =
      put_in(
        manifest,
        ["repairs", Access.at(0), "new_boost_id"],
        Bonfire.Common.Simulation.ulid()
      )

    assert {:error, {:new_boost_id_does_not_match_article, _}} =
             TopicBoostDateRepair.apply(tampered)

    assert {:ok, unchanged_boost} =
             Boosts.get(context.topic, context.post, skip_boundary_check: true)

    assert unchanged_boost.id == context.boost.id
  end

  test "the Mix task writes a preview manifest without overwriting it", context do
    manifest_path =
      Path.join(
        System.tmp_dir!(),
        "ghost-topic-boost-repair-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(manifest_path) end)

    args = [
      "--topic",
      context.topic.id,
      "--ghost-url",
      "https://blog.test/",
      "--author",
      context.author.id,
      "--manifest",
      manifest_path,
      "--dry-run"
    ]

    Mix.Tasks.Bonfire.Ghost.RepairTopicBoostDates.run(args)

    assert {:ok, %{"repairs" => [_repair]}} =
             manifest_path
             |> File.read!()
             |> TopicBoostDateRepair.decode_manifest()

    assert_raise Mix.Error, ~r/Manifest already exists/, fn ->
      Mix.Tasks.Bonfire.Ghost.RepairTopicBoostDates.run(args)
    end
  end

  defp preview(context) do
    TopicBoostDateRepair.preview(
      topic_id: context.topic.id,
      ghost_url: "https://blog.test/",
      author_id: context.author.id
    )
  end

  defp date(id), do: DatesTimes.date_from_pointer(id)
end
