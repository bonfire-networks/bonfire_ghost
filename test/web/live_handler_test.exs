defmodule Bonfire.Ghost.LiveHandlerTest do
  use Bonfire.Ghost.DataCase, async: false
  use Oban.Testing, repo: Bonfire.Common.Repo
  use Repatch.ExUnit

  alias Bonfire.Ghost.LiveHandler
  alias Bonfire.Ghost.Sync
  alias Bonfire.Ghost.Workers.ArticleSyncWorker
  alias Bonfire.Ghost.Workers.MemberSyncWorker

  defp socket, do: %Phoenix.LiveView.Socket{assigns: %{flash: %{}, __changed__: %{}}}

  test "sync_members enqueues the member backfill worker" do
    Repatch.patch(Bonfire.Ghost, :admin_configured?, fn -> true end)
    Repatch.patch(LiveHandler, :can_configure_instance?, fn _socket -> true end)

    socket = %Phoenix.LiveView.Socket{assigns: %{flash: %{}, __changed__: %{}}}

    assert {:noreply, _socket} = LiveHandler.handle_event("sync_members", %{}, socket)
    assert_enqueued(worker: MemberSyncWorker, args: %{})
  end

  test "sync_members does not enqueue when the user lacks instance permission" do
    Repatch.patch(Bonfire.Ghost, :admin_configured?, fn -> true end)
    Repatch.patch(LiveHandler, :can_configure_instance?, fn _socket -> false end)

    socket = %Phoenix.LiveView.Socket{assigns: %{flash: %{}, __changed__: %{}}}

    assert {:noreply, _socket} = LiveHandler.handle_event("sync_members", %{}, socket)
    refute_enqueued(worker: MemberSyncWorker)
  end

  describe "sync_articles" do
    setup do
      Sync.Articles.clear_status()
      :ok
    end

    test "enqueues the article backfill worker and marks the status as queued" do
      Repatch.patch(Bonfire.Ghost, :configured?, fn -> true end)
      Repatch.patch(LiveHandler, :can_configure_instance?, fn _socket -> true end)

      assert {:noreply, socket} = LiveHandler.handle_event("sync_articles", %{}, socket())

      assert_enqueued(worker: ArticleSyncWorker, args: %{})
      assert %{state: :queued} = socket.assigns.article_sync_status
      assert %{state: :queued} = Sync.Articles.status()
    end

    test "a second click while a backfill is queued reports the existing one instead of pretending to start a new import" do
      Repatch.patch(Bonfire.Ghost, :configured?, fn -> true end)
      Repatch.patch(LiveHandler, :can_configure_instance?, fn _socket -> true end)

      assert {:noreply, _} = LiveHandler.handle_event("sync_articles", %{}, socket())
      assert {:noreply, socket} = LiveHandler.handle_event("sync_articles", %{}, socket())

      # Only one job — the unique worker deduplicated — and the status panel still
      # reflects the in-flight backfill.
      assert length(all_enqueued(worker: ArticleSyncWorker)) == 1
      assert %{state: :queued} = socket.assigns.article_sync_status
    end

    test "does not enqueue when the user lacks instance permission" do
      Repatch.patch(Bonfire.Ghost, :configured?, fn -> true end)
      Repatch.patch(LiveHandler, :can_configure_instance?, fn _socket -> false end)

      assert {:noreply, _socket} = LiveHandler.handle_event("sync_articles", %{}, socket())
      refute_enqueued(worker: ArticleSyncWorker)
    end
  end
end
