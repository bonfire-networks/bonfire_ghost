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

  describe "sync_all/1" do
    test "paginates across pages and counts synced articles" do
      Repatch.patch(Ghost, :admin_configured?, fn -> true end)
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)
      Repatch.patch(EmbedHelper, :import_article, fn _post, _opts -> {:ok, :post} end)

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

      Repatch.patch(EmbedHelper, :import_article, fn _post, opts ->
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
      Repatch.patch(EmbedHelper, :import_article, fn _post, _opts -> {:ok, :post} end)

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
      Repatch.patch(EmbedHelper, :import_article, fn _post, _opts -> {:ok, :post} end)

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
      Repatch.patch(EmbedHelper, :import_article, fn _post, _opts -> {:ok, :post} end)

      Repatch.patch(API, :list_posts, fn :content_client, _opts -> page([post("a")], nil) end)

      assert {:ok, %{synced: 1}} = Articles.sync_all()
    end

    test "returns :not_configured when Ghost has no credentials" do
      Repatch.patch(Ghost, :admin_configured?, fn -> false end)
      Repatch.patch(Ghost, :configured?, fn -> false end)

      assert {:error, :not_configured} = Articles.sync_all()
    end
  end
end
