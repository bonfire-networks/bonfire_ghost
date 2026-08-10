defmodule Bonfire.Ghost.TopicRoutingRepairTest do
  use Bonfire.Ghost.DataCase, async: false

  alias Bonfire.Ghost.EmbedHelper
  alias Bonfire.Ghost.TopicRoutingRepair
  alias Bonfire.Me.Fake
  alias Bonfire.Social.Boosts

  @repair_task Mix.Tasks.Bonfire.Ghost.RepairTopicRouting

  defp article(slug, primary_tag \\ nil) do
    %{
      "id" => "ghost_#{slug}",
      "slug" => slug,
      "url" => "https://blog.test/#{slug}/",
      "title" => "Story #{slug}",
      "html" => "<p>Original body for #{slug}</p>",
      "visibility" => "public",
      "published_at" => "2024-01-15T10:00:00.000Z"
    }
    |> then(fn article ->
      if primary_tag,
        do: Map.put(article, "primary_tag", %{"slug" => primary_tag}),
        else: article
    end)
  end

  setup do
    creator = Fake.fake_user!(%{}, %{username: "routingrepairbot"})

    group =
      Bonfire.Classify.Simulate.fake_group!(creator, %{
        membership: "local:members",
        visibility: "nonfederated",
        participation: "anyone"
      })

    Fake.fake_user!(%{}, %{username: "gesellschaft"})

    topic =
      Bonfire.Classify.Simulate.fake_category!(creator, group, %{
        type: :topic,
        name: "Gesellschaft"
      })

    Process.put([:bonfire_ghost, :auto_import_as], creator.id)
    Process.put([:bonfire_ghost, :post_into_group], group.id)

    {:ok, creator: creator, group: group, topic: topic}
  end

  test "preview is read-only and records the exact existing article, topic, and comment count",
       %{creator: creator, group: group, topic: topic} do
    assert {:ok, post} = EmbedHelper.import_article(article("with-comments"), [])

    assert {:ok, _comment} =
             Bonfire.Posts.publish(
               current_user: creator,
               post_attrs: %{
                 post_content: %{html_body: "A comment that must remain untouched"},
                 reply_to_id: post.id
               },
               boundary: "public"
             )

    tagged = article("with-comments", "gesellschaft")

    assert {:ok, manifest} =
             TopicRoutingRepair.preview(
               group_id: group.id,
               ghost_url: "https://blog.test/",
               articles: [tagged]
             )

    assert [repair] = manifest["repairs"]
    assert repair["article_id"] == post.id
    assert repair["canonical_uri"] == tagged["url"]
    assert repair["primary_tag_slug"] == "gesellschaft"
    assert repair["topic_id"] == topic.id
    assert repair["topic_name"] == "Gesellschaft"
    assert repair["comment_count"] == 1

    assert {:error, _} = Boosts.get(topic, post, skip_boundary_check: true)
  end

  test "apply only adds the topic placement, preserves comments and content, and does not federate",
       %{creator: creator, group: group, topic: topic} do
    untagged = article("safe-apply")
    tagged = article("safe-apply", "gesellschaft")

    assert {:ok, post} = EmbedHelper.import_article(untagged, [])

    assert {:ok, comment} =
             Bonfire.Posts.publish(
               current_user: creator,
               post_attrs: %{
                 post_content: %{html_body: "Keep this comment"},
                 reply_to_id: post.id
               },
               boundary: "public"
             )

    assert {:ok, manifest} = preview(group, [tagged])

    test_pid = self()

    Repatch.patch(Bonfire.Social, :maybe_federate_and_gift_wrap_activity, [mode: :shared], fn
      subject, object ->
        send(test_pid, {:unexpected_federation, subject, object})
        {:ok, object}
    end)

    Repatch.patch(Bonfire.Social.LivePush, :push_activity_object, [mode: :shared], fn
      feed_ids, boost, object, opts ->
        send(test_pid, {:unexpected_live_push, feed_ids, boost, object, opts})
        :ok
    end)

    assert {:ok, applied_manifest} = TopicRoutingRepair.apply(manifest, articles: [tagged])
    assert applied_manifest["summary"] == %{"already_present" => 0, "created" => 1}
    assert [%{"boost_id" => boost_id}] = applied_manifest["applied_repairs"]

    assert {:ok, repaired_boost} = Boosts.get(topic, post, skip_boundary_check: true)
    assert repaired_boost.id == boost_id
    refute_receive {:unexpected_federation, _, _}
    refute_receive {:unexpected_live_push, _, _, _, _}

    assert {:ok, reloaded} =
             Bonfire.Posts.read(post.id,
               skip_boundary_check: true,
               schema: Bonfire.Common.Types.object_type(post)
             )

    assert reloaded.id == post.id
    assert reloaded.post_content.html_body == untagged["html"]

    %{edges: replies} =
      Bonfire.Social.Threads.list_replies(post.id,
        current_user: creator,
        total_replies_count: 1
      )

    assert Enum.any?(replies, &(&1.id == comment.id))

    assert {:ok, 1} = TopicRoutingRepair.rollback(applied_manifest)
    assert {:error, _} = Boosts.get(topic, post, skip_boundary_check: true)

    %{edges: replies_after_rollback} =
      Bonfire.Social.Threads.list_replies(post.id,
        current_user: creator,
        total_replies_count: 1
      )

    assert Enum.any?(replies_after_rollback, &(&1.id == comment.id))
  end

  test "a pilot apply touches only one selected article and a later full apply is idempotent",
       %{group: group, topic: topic} do
    first = article("pilot-first")
    second = article("pilot-second")

    assert {:ok, first_post} = EmbedHelper.import_article(first, [])
    assert {:ok, second_post} = EmbedHelper.import_article(second, [])

    tagged_first = article("pilot-first", "gesellschaft")
    tagged_second = article("pilot-second", "gesellschaft")

    assert {:ok, manifest} = preview(group, [tagged_first, tagged_second])

    assert {:ok, pilot_manifest} =
             TopicRoutingRepair.apply(manifest,
               article_url: tagged_first["url"],
               articles: [tagged_first, tagged_second]
             )

    assert pilot_manifest["summary"] == %{"already_present" => 0, "created" => 1}
    assert {:ok, _} = Boosts.get(topic, first_post, skip_boundary_check: true)
    assert {:error, _} = Boosts.get(topic, second_post, skip_boundary_check: true)

    assert {:ok, remainder_manifest} =
             TopicRoutingRepair.apply(manifest, articles: [tagged_first, tagged_second])

    assert remainder_manifest["summary"] == %{"already_present" => 1, "created" => 1}
    assert {:ok, _} = Boosts.get(topic, second_post, skip_boundary_check: true)

    assert {:ok, 1} = TopicRoutingRepair.rollback(pilot_manifest)
    assert {:error, _} = Boosts.get(topic, first_post, skip_boundary_check: true)
    assert {:ok, _} = Boosts.get(topic, second_post, skip_boundary_check: true)

    assert {:ok, 1} = TopicRoutingRepair.rollback(remainder_manifest)
    assert {:error, _} = Boosts.get(topic, second_post, skip_boundary_check: true)
  end

  test "preview skips articles that are not imported or have no unique matching topic",
       %{group: group} do
    no_topic = article("no-topic", "unmapped")
    not_imported = article("not-imported", "gesellschaft")

    assert {:ok, _post} = EmbedHelper.import_article(article("no-topic"), [])

    assert {:ok, manifest} = preview(group, [no_topic, not_imported])
    assert manifest["repairs"] == []

    assert Enum.any?(manifest["skipped"], fn skipped ->
             skipped["canonical_uri"] == no_topic["url"] and
               skipped["reason"] == "no_unique_topic_match"
           end)

    assert Enum.any?(manifest["skipped"], fn skipped ->
             skipped["canonical_uri"] == not_imported["url"] and
               skipped["reason"] == "not_imported"
           end)
  end

  test "apply rejects a manifest whose topic was changed after preview",
       %{creator: creator, group: group} do
    tagged = article("tampered-topic", "gesellschaft")
    assert {:ok, post} = EmbedHelper.import_article(article("tampered-topic"), [])
    assert {:ok, manifest} = preview(group, [tagged])

    other_topic =
      Bonfire.Classify.Simulate.fake_category!(creator, group, %{
        type: :topic,
        name: "Politik"
      })

    tampered_manifest =
      update_in(manifest, ["repairs", Access.at(0)], fn repair ->
        repair
        |> Map.put("topic_id", other_topic.id)
        |> Map.put("topic_name", "Politik")
      end)

    other_topic_id = other_topic.id

    assert {:error, {:topic_does_not_match_primary_tag, ^other_topic_id}} =
             TopicRoutingRepair.apply(tampered_manifest, articles: [tagged])

    assert {:error, _} = Boosts.get(other_topic, post, skip_boundary_check: true)
  end

  test "apply rejects an article whose primary Ghost tag changed after preview",
       %{group: group, topic: topic} do
    tagged = article("changed-primary-tag", "gesellschaft")
    changed = article("changed-primary-tag", "politik")
    assert {:ok, post} = EmbedHelper.import_article(article("changed-primary-tag"), [])
    assert {:ok, manifest} = preview(group, [tagged])

    assert {:error,
            {:primary_tag_changed, "https://blog.test/changed-primary-tag/", "gesellschaft",
             "politik"}} =
             TopicRoutingRepair.apply(manifest, articles: [changed])

    assert {:error, _} = Boosts.get(topic, post, skip_boundary_check: true)
  end

  test "preview fetches every page of published Ghost articles", %{group: group} do
    tagged = article("paginated", "gesellschaft")
    assert {:ok, post} = EmbedHelper.import_article(article("paginated"), [])

    patch_admin_articles(%{
      1 =>
        {:ok,
         %{
           "posts" => [tagged],
           "meta" => %{"pagination" => %{"next" => 2}}
         }},
      2 =>
        {:ok,
         %{
           "posts" => [],
           "meta" => %{"pagination" => %{"next" => nil}}
         }}
    })

    assert {:ok, manifest} =
             TopicRoutingRepair.preview(
               group_id: group.id,
               ghost_url: "https://blog.test/"
             )

    assert [%{"article_id" => article_id}] = manifest["repairs"]
    assert article_id == post.id
    assert_received {:ghost_page_requested, 1}
    assert_received {:ghost_page_requested, 2}
  end

  test "the preview command writes once and refuses to overwrite its manifest",
       %{group: group} do
    tagged = article("command-preview", "gesellschaft")
    assert {:ok, _post} = EmbedHelper.import_article(article("command-preview"), [])

    patch_admin_articles(%{
      1 =>
        {:ok,
         %{
           "posts" => [tagged],
           "meta" => %{"pagination" => %{"next" => nil}}
         }}
    })

    directory =
      Path.join(
        System.tmp_dir!(),
        "ghost-topic-routing-task-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    manifest_path = Path.join(directory, "preview.json")

    args = [
      "--group",
      group.id,
      "--ghost-url",
      "https://blog.test/",
      "--manifest",
      manifest_path,
      "--dry-run"
    ]

    assert :ok = @repair_task.run(args)
    original_contents = File.read!(manifest_path)
    assert {:ok, %{"kind" => "ghost_topic_routing_preview"}} = Jason.decode(original_contents)

    assert_raise Mix.Error, ~r/Manifest already exists/, fn ->
      @repair_task.run(args)
    end

    assert File.read!(manifest_path) == original_contents
  end

  test "the apply command refuses an occupied rollback path before changing the database",
       %{group: group, topic: topic} do
    tagged = article("occupied-rollback-path", "gesellschaft")
    assert {:ok, post} = EmbedHelper.import_article(article("occupied-rollback-path"), [])
    assert {:ok, preview_manifest} = preview(group, [tagged])

    directory =
      Path.join(
        System.tmp_dir!(),
        "ghost-topic-routing-apply-task-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    preview_path = Path.join(directory, "preview.json")
    applied_path = Path.join(directory, "already-used.json")
    File.write!(preview_path, TopicRoutingRepair.encode_manifest!(preview_manifest))
    File.write!(applied_path, "do not overwrite")

    assert_raise Mix.Error, ~r/Manifest already exists/, fn ->
      @repair_task.run([
        "--manifest",
        preview_path,
        "--applied-manifest",
        applied_path,
        "--apply"
      ])
    end

    assert File.read!(applied_path) == "do not overwrite"
    assert {:error, _} = Boosts.get(topic, post, skip_boundary_check: true)
  end

  test "the apply and rollback commands use the persisted rollback manifest",
       %{group: group, topic: topic} do
    tagged = article("command-apply", "gesellschaft")
    assert {:ok, post} = EmbedHelper.import_article(article("command-apply"), [])
    assert {:ok, preview_manifest} = preview(group, [tagged])

    directory =
      Path.join(
        System.tmp_dir!(),
        "ghost-topic-routing-command-roundtrip-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    preview_path = Path.join(directory, "preview.json")
    applied_path = Path.join(directory, "applied.json")
    File.write!(preview_path, TopicRoutingRepair.encode_manifest!(preview_manifest))

    patch_admin_articles(%{
      1 =>
        {:ok,
         %{
           "posts" => [tagged],
           "meta" => %{"pagination" => %{"next" => nil}}
         }}
    })

    assert :ok =
             @repair_task.run([
               "--manifest",
               preview_path,
               "--applied-manifest",
               applied_path,
               "--apply"
             ])

    assert {:ok, %{"summary" => %{"created" => 1}}} =
             applied_path
             |> File.read!()
             |> Jason.decode()

    assert {:ok, _boost} = Boosts.get(topic, post, skip_boundary_check: true)

    assert :ok = @repair_task.run(["--manifest", applied_path, "--rollback"])
    assert {:error, _} = Boosts.get(topic, post, skip_boundary_check: true)
  end

  test "apply rolls back every placement when its manifest cannot be persisted",
       %{group: group, topic: topic} do
    tagged = article("manifest-write-failure", "gesellschaft")
    assert {:ok, post} = EmbedHelper.import_article(article("manifest-write-failure"), [])
    assert {:ok, preview_manifest} = preview(group, [tagged])

    assert {:error, {:before_commit_failed, :disk_full}} =
             TopicRoutingRepair.apply(preview_manifest,
               articles: [tagged],
               before_commit: fn _applied_manifest -> {:error, :disk_full} end
             )

    assert {:error, _} = Boosts.get(topic, post, skip_boundary_check: true)
  end

  defp preview(group, articles) do
    TopicRoutingRepair.preview(
      group_id: group.id,
      ghost_url: "https://blog.test/",
      articles: articles
    )
  end

  defp patch_admin_articles(pages) do
    test_pid = self()

    Repatch.patch(Bonfire.Ghost, :admin_configured?, [mode: :shared], fn -> true end)
    Repatch.patch(Bonfire.Ghost, :admin_client, [mode: :shared], fn -> {:ok, :client} end)

    Repatch.patch(Bonfire.Ghost.AdminAPI, :list_posts, [mode: :shared], fn :client, opts ->
      page = Keyword.fetch!(opts, :page)
      send(test_pid, {:ghost_page_requested, page})
      Map.fetch!(pages, page)
    end)
  end
end
