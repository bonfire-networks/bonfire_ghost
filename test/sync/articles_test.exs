defmodule Bonfire.Ghost.Sync.ArticlesTest do
  # `async: false` because it patches instance-level Ghost client/config helpers.
  use Bonfire.Ghost.DataCase, async: false

  alias Bonfire.Ghost
  alias Bonfire.Ghost.API
  alias Bonfire.Ghost.AdminAPI
  alias Bonfire.Ghost.EmbedHelper
  alias Bonfire.Ghost.Sync.Articles

  defp post(id), do: %{"id" => id, "url" => "https://blog.test/#{id}/", "slug" => id}

  defp page(posts, next),
    do: {:ok, %{"posts" => posts, "meta" => %{"pagination" => %{"page" => 1, "next" => next}}}}

  setup do
    # The status is stored in a shared cache, so isolate it between tests.
    Articles.clear_status()
    :ok
  end

  describe "sync_all/1" do
    test "paginates across pages and counts synced articles" do
      Repatch.patch(Ghost, :admin_configured?, fn -> true end)
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)
      Repatch.patch(EmbedHelper, :import_article, [mode: :shared], fn _post, _opts ->
        {:ok, :post}
      end)

      Repatch.patch(AdminAPI, :list_posts, fn :client, opts ->
        case Keyword.fetch!(opts, :page) do
          1 -> page([post("a"), post("b")], 2)
          2 -> page([post("c")], nil)
        end
      end)

      assert {:ok, %{synced: 3, filtered: 0, errors: []}} = Articles.sync_all()
    end

    test "requests tiers in the include, filters to published, and skips (never hides) filtered articles" do
      test_pid = self()
      Repatch.patch(Ghost, :admin_configured?, fn -> true end)
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)

      Repatch.patch(EmbedHelper, :import_article, [mode: :shared], fn _post, opts ->
        send(test_pid, {:import_opts, opts})
        {:ok, :filtered_out}
      end)

      Repatch.patch(AdminAPI, :list_posts, fn :client, opts ->
        send(test_pid, {:list_opts, opts})
        page([post("x")], nil)
      end)

      assert {:ok, %{synced: 0, filtered: 1, errors: []}} = Articles.sync_all()

      assert_receive {:list_opts, list_opts}
      assert Keyword.get(list_opts, :include) =~ "tiers"
      assert Keyword.get(list_opts, :filter) == "status:published"

      assert_receive {:import_opts, import_opts}
      assert Keyword.get(import_opts, :on_filtered) == :skip
    end

    test "advances pagination when Ghost returns a stringified next page" do
      Repatch.patch(Ghost, :admin_configured?, fn -> true end)
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)
      Repatch.patch(EmbedHelper, :import_article, [mode: :shared], fn _post, _opts ->
        {:ok, :post}
      end)

      Repatch.patch(AdminAPI, :list_posts, fn :client, opts ->
        case Keyword.fetch!(opts, :page) do
          1 -> page([post("a")], "2")
          2 -> page([post("b")], nil)
        end
      end)

      assert {:ok, %{synced: 2}} = Articles.sync_all()
    end

    test "stops instead of looping when pagination does not advance" do
      Repatch.patch(Ghost, :admin_configured?, fn -> true end)
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)
      Repatch.patch(EmbedHelper, :import_article, [mode: :shared], fn _post, _opts ->
        {:ok, :post}
      end)

      # `next` repeats the current page — must not recurse forever.
      Repatch.patch(AdminAPI, :list_posts, fn :client, _opts -> page([post("a")], 1) end)

      assert {:ok, %{synced: 1}} = Articles.sync_all()
    end

    test "propagates a page fetch failure so the Oban job fails and retries" do
      Repatch.patch(Ghost, :admin_configured?, fn -> true end)
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)
      Repatch.patch(AdminAPI, :list_posts, fn :client, _opts -> {:error, :nxdomain} end)

      assert {:error, :nxdomain} = Articles.sync_all()
    end

    test "falls back to the Content API when only content credentials are configured" do
      Repatch.patch(Ghost, :admin_configured?, fn -> false end)
      Repatch.patch(Ghost, :configured?, fn -> true end)
      Repatch.patch(Ghost, :client, fn -> {:ok, :content_client} end)
      Repatch.patch(EmbedHelper, :import_article, [mode: :shared], fn _post, _opts ->
        {:ok, :post}
      end)

      Repatch.patch(API, :list_posts, fn :content_client, _opts -> page([post("a")], nil) end)

      assert {:ok, %{synced: 1}} = Articles.sync_all()
    end

    test "returns :not_configured when Ghost has no credentials" do
      Repatch.patch(Ghost, :admin_configured?, fn -> false end)
      Repatch.patch(Ghost, :configured?, fn -> false end)

      assert {:error, :not_configured} = Articles.sync_all()
    end
  end

  describe "status/0 (progress the settings page shows)" do
    test "reports :running progress while importing and :done with counts at the end" do
      test_pid = self()
      Repatch.patch(Ghost, :admin_configured?, fn -> true end)
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)

      # Snapshot the status as seen mid-run, from inside an article import.
      Repatch.patch(EmbedHelper, :import_article, [mode: :shared], fn post, _opts ->
        send(test_pid, {:mid_run_status, post["id"], Articles.status()})
        {:ok, :post}
      end)

      Repatch.patch(AdminAPI, :list_posts, fn :client, opts ->
        case Keyword.fetch!(opts, :page) do
          1 -> page([post("a"), post("b")], 2)
          2 -> page([post("c")], nil)
        end
      end)

      assert {:ok, _} = Articles.sync_all()

      assert_receive {:mid_run_status, "a", %{state: :running, page: 1, synced: 0}}

      assert_receive {:mid_run_status, "b",
                      %{
                        state: :running,
                        page: 1,
                        synced: 1,
                        # which article is being imported right now + a heartbeat, so the
                        # settings page can name the culprit if the import wedges
                        current: "https://blog.test/b/",
                        updated_at: %DateTime{}
                      }}

      assert_receive {:mid_run_status, "c", %{state: :running, page: 2, synced: 2}}

      assert %{state: :done, synced: 3, filtered: 0, errors_count: 0, finished_at: %DateTime{}} =
               Articles.status()
    end

    test "a hung article import times out, is recorded as an error, and the backfill continues" do
      Repatch.patch(Ghost, :admin_configured?, fn -> true end)
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)
      # Shrink the watchdog so the test doesn't wait 2 minutes.
      Repatch.patch(Articles, :import_timeout, fn -> 100 end)

      Repatch.patch(EmbedHelper, :import_article, [mode: :shared], fn post, _opts ->
        if post["id"] == "stuck", do: Process.sleep(:infinity)
        {:ok, :post}
      end)

      Repatch.patch(AdminAPI, :list_posts, fn :client, _opts ->
        page([post("ok1"), post("stuck"), post("ok2")], nil)
      end)

      assert {:ok, %{synced: 2, errors: [{"https://blog.test/stuck/", reason}]}} =
               Articles.sync_all()

      assert reason =~ "timed out"

      assert %{state: :done, synced: 2, errors_count: 1, errors: [err]} = Articles.status()
      assert err.article == "https://blog.test/stuck/"
      assert err.reason =~ "timed out"
    end

    test "an article import that raises is recorded as an error without aborting the backfill" do
      Repatch.patch(Ghost, :admin_configured?, fn -> true end)
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)

      Repatch.patch(EmbedHelper, :import_article, [mode: :shared], fn post, _opts ->
        if post["id"] == "boom", do: raise("kaboom")
        {:ok, :post}
      end)

      Repatch.patch(AdminAPI, :list_posts, fn :client, _opts ->
        page([post("boom"), post("ok")], nil)
      end)

      assert {:ok, %{synced: 1, errors: [_]}} = Articles.sync_all()

      assert %{state: :done, synced: 1, errors_count: 1, errors: [err]} = Articles.status()
      assert err.article == "https://blog.test/boom/"
      assert err.reason =~ "kaboom"
    end

    test "records per-article errors with a readable reason" do
      Repatch.patch(Ghost, :admin_configured?, fn -> true end)
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)

      Repatch.patch(EmbedHelper, :import_article, [mode: :shared], fn post, _opts ->
        case post["id"] do
          "bad" -> {:error, {:http_error, 422}}
          _ -> {:ok, :post}
        end
      end)

      Repatch.patch(AdminAPI, :list_posts, fn :client, _opts ->
        page([post("ok"), post("bad")], nil)
      end)

      assert {:ok, %{synced: 1, errors: [_]}} = Articles.sync_all()

      assert %{state: :done, synced: 1, errors_count: 1, errors: [err]} = Articles.status()
      assert err.article == "https://blog.test/bad/"
      assert err.reason =~ "422"
    end

    test "reports :failed with the reason when a page fetch fails" do
      Repatch.patch(Ghost, :admin_configured?, fn -> true end)
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)
      Repatch.patch(AdminAPI, :list_posts, fn :client, _opts -> {:error, :nxdomain} end)

      assert {:error, :nxdomain} = Articles.sync_all()

      assert %{state: :failed, reason: "nxdomain"} = Articles.status()
    end

    test "reports :failed when Ghost has no credentials" do
      Repatch.patch(Ghost, :admin_configured?, fn -> false end)
      Repatch.patch(Ghost, :configured?, fn -> false end)

      assert {:error, :not_configured} = Articles.sync_all()

      assert %{state: :failed, reason: "Ghost is not configured"} = Articles.status()
    end

    test "caps the stored error list but keeps the full count" do
      Repatch.patch(Ghost, :admin_configured?, fn -> true end)
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)
      Repatch.patch(EmbedHelper, :import_article, [mode: :shared], fn _post, _opts ->
        {:error, :boom}
      end)

      posts = Enum.map(1..25, &post("p#{&1}"))
      Repatch.patch(AdminAPI, :list_posts, fn :client, _opts -> page(posts, nil) end)

      assert {:ok, %{errors: errors}} = Articles.sync_all()
      assert length(errors) == 25

      assert %{state: :done, errors_count: 25, errors: stored} = Articles.status()
      assert length(stored) == 20
    end
  end

  describe "resume (never restart an interrupted sweep from page 1)" do
    test "resumes from the page the previous interrupted run reached, carrying counts forward" do
      test_pid = self()
      Repatch.patch(Ghost, :admin_configured?, fn -> true end)
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)

      Repatch.patch(EmbedHelper, :import_article, [mode: :shared], fn _post, _opts ->
        {:ok, :post}
      end)

      # A prior attempt got interrupted mid-sweep: it had reached page 3 with 120 done.
      Articles.put_status(%{
        state: :failed,
        reason: "nxdomain",
        page: 3,
        synced: 120,
        filtered: 5,
        errors_count: 0,
        errors: []
      })

      Repatch.patch(AdminAPI, :list_posts, fn :client, opts ->
        page = Keyword.fetch!(opts, :page)
        send(test_pid, {:fetched_page, page})

        case page do
          3 -> page([post("c1")], 4)
          4 -> page([post("d1")], nil)
        end
      end)

      assert {:ok, summary} = Articles.sync_all()

      # It picked up at page 3 — pages 1 and 2 were never re-fetched.
      assert_receive {:fetched_page, 3}
      assert_receive {:fetched_page, 4}
      refute_received {:fetched_page, 1}
      refute_received {:fetched_page, 2}

      # Counts continue from the prior run (120 + the 2 newly imported), not from 0.
      assert summary.synced == 122
      assert summary.filtered == 5
      assert %{state: :done, synced: 122, filtered: 5} = Articles.status()
    end

    test "starts fresh (page 1) after a previous run finished cleanly" do
      test_pid = self()
      Repatch.patch(Ghost, :admin_configured?, fn -> true end)
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)
      Repatch.patch(EmbedHelper, :import_article, [mode: :shared], fn _post, _opts ->
        {:ok, :post}
      end)

      Articles.put_status(%{state: :done, page: 9, synced: 400, filtered: 0, errors: []})

      Repatch.patch(AdminAPI, :list_posts, fn :client, opts ->
        send(test_pid, {:fetched_page, Keyword.fetch!(opts, :page)})
        page([post("a")], nil)
      end)

      assert {:ok, %{synced: 1}} = Articles.sync_all()
      assert_receive {:fetched_page, 1}
    end

    test "`restart: true` forces a clean full sweep even after an interrupted run" do
      test_pid = self()
      Repatch.patch(Ghost, :admin_configured?, fn -> true end)
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)
      Repatch.patch(EmbedHelper, :import_article, [mode: :shared], fn _post, _opts ->
        {:ok, :post}
      end)

      Articles.put_status(%{state: :failed, page: 5, synced: 200, filtered: 0, errors: []})

      Repatch.patch(AdminAPI, :list_posts, fn :client, opts ->
        send(test_pid, {:fetched_page, Keyword.fetch!(opts, :page)})
        page([post("a")], nil)
      end)

      assert {:ok, %{synced: 1}} = Articles.sync_all(restart: true)
      assert_receive {:fetched_page, 1}
    end
  end
end
