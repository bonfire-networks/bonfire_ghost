defmodule Bonfire.Ghost.LiveHandlerTest do
  use Bonfire.Ghost.DataCase, async: false
  use Oban.Testing, repo: Bonfire.Common.Repo
  use Repatch.ExUnit

  alias Bonfire.Ghost.LiveHandler
  alias Bonfire.Ghost.Workers.MemberSyncWorker

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
end
