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

  test "a second sync_members click preserves the in-flight status instead of resetting it" do
    Repatch.patch(Bonfire.Ghost, :admin_configured?, fn -> true end)
    Repatch.patch(LiveHandler, :can_configure_instance?, fn _socket -> true end)
    Sync.Members.clear_status()

    assert {:noreply, _socket} = LiveHandler.handle_event("sync_members", %{}, socket())

    running_status =
      Sync.Members.put_status(%{
        state: :running,
        stage: :staff,
        stages: %{tiers: %{created: 2}}
      })

    assert {:noreply, second_socket} =
             LiveHandler.handle_event("sync_members", %{}, socket())

    assert length(all_enqueued(worker: MemberSyncWorker)) == 1
    assert second_socket.assigns.member_sync_status == running_status
    assert Sync.Members.status() == running_status
  end

  test "sync_members does not overwrite progress when the worker starts before insert returns" do
    Repatch.patch(Bonfire.Ghost, :admin_configured?, fn -> true end)
    Repatch.patch(LiveHandler, :can_configure_instance?, fn _socket -> true end)
    Sync.Members.clear_status()

    running_status = %{
      state: :running,
      stage: :staff,
      stages: %{tiers: %{created: 2}},
      job_id: 987
    }

    Repatch.patch(Oban, :insert, fn _changeset ->
      status = Sync.Members.put_status(running_status)
      assert status.state == :running
      {:ok, %Oban.Job{id: 987, args: %{}}}
    end)

    assert {:noreply, result_socket} =
             LiveHandler.handle_event("sync_members", %{}, socket())

    assert result_socket.assigns.member_sync_status == Sync.Members.status()
    assert result_socket.assigns.member_sync_status.state == :running
    assert result_socket.assigns.member_sync_status.stage == :staff
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

  describe "load_more_staff" do
    alias Bonfire.Ghost.AdminAPI

    test "appends the next page of staff and advances the pagination" do
      Repatch.patch(LiveHandler, :can_configure_instance?, fn _socket -> true end)
      Repatch.patch(Bonfire.Ghost, :admin_client, fn -> {:ok, :client} end)

      Repatch.patch(AdminAPI, :list_users, fn :client, opts ->
        assert Keyword.get(opts, :page) == 2
        # the preview must use the same filter the backfill does
        assert Keyword.get(opts, :filter) == AdminAPI.signin_staff_filter()

        {:ok,
         %{
           "users" => [%{"email" => "page2@test.local", "status" => "locked"}],
           "meta" => %{"pagination" => %{"page" => 2, "pages" => 3, "next" => 3, "total" => 120}}
         }}
      end)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          flash: %{},
          __changed__: %{},
          staff: [%{"email" => "page1@test.local"}],
          staff_page_info: %{page: 1}
        }
      }

      assert {:noreply, socket} = LiveHandler.handle_event("load_more_staff", %{}, socket)

      assert Enum.map(socket.assigns.staff, & &1["email"]) == [
               "page1@test.local",
               "page2@test.local"
             ]

      assert socket.assigns.staff_page_info.page == 2
      assert socket.assigns.staff_page_info.has_next
    end

    test "does nothing without instance permission" do
      Repatch.patch(LiveHandler, :can_configure_instance?, fn _socket -> false end)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{flash: %{}, __changed__: %{}, staff: [], staff_page_info: %{page: 1}}
      }

      assert {:noreply, _socket} = LiveHandler.handle_event("load_more_staff", %{}, socket)
    end
  end
end
