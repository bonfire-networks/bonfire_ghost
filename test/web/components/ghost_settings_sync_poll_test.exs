defmodule Bonfire.Ghost.Web.GhostSettingsSyncPollTest do
  @moduledoc """
  Tests the article-backfill status poll loop on the settings component: while a
  backfill is queued/running the component re-reads the status the worker writes to the
  cache (see `Bonfire.Ghost.Sync.Articles.status/0`) and keeps polling; once it finishes
  the loop stops and the imported-articles count is refreshed.
  """
  # `async: false` — the status lives in a shared cache.
  use Bonfire.Ghost.DataCase, async: false
  use Repatch.ExUnit

  alias Bonfire.Ghost.Sync.Articles
  alias Bonfire.Ghost.Web.GhostSettingsLive

  setup do
    Articles.clear_status()
    :ok
  end

  defp socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            authorized: true,
            id: "ghost_settings",
            settings: nil,
            sync_polling: false
          },
          assigns
        )
    }
  end

  test "keeps polling while the backfill is running" do
    Articles.put_status(%{
      state: :running,
      page: 2,
      synced: 7,
      filtered: 1,
      errors_count: 0,
      errors: []
    })

    assert {:ok, socket} = GhostSettingsLive.update(%{sync_status_poll: true}, socket())

    assert %{state: :running, synced: 7} = socket.assigns.article_sync_status
    assert socket.assigns.sync_polling == true
  end

  test "stops polling and refreshes the imported-articles count once the backfill is done" do
    Articles.put_status(%{
      state: :done,
      synced: 3,
      filtered: 0,
      errors_count: 0,
      errors: [],
      finished_at: DateTime.utc_now()
    })

    Repatch.patch(Bonfire.Ghost, :imported_articles_count, fn _blog_url -> 42 end)

    assert {:ok, socket} = GhostSettingsLive.update(%{sync_status_poll: true}, socket())

    assert %{state: :done} = socket.assigns.article_sync_status
    assert socket.assigns.sync_polling == false
    assert socket.assigns.articles_count == 42
  end

  test "does nothing for unauthorized viewers" do
    Articles.put_status(%{state: :running, synced: 1})

    assert {:ok, socket} =
             GhostSettingsLive.update(%{sync_status_poll: true}, socket(%{authorized: false}))

    refute Map.has_key?(socket.assigns, :article_sync_status)
  end

  describe "sync_stalled?/1 (heartbeat watchdog for the settings UI)" do
    test "a fresh in-flight status is not stalled" do
      status = Articles.put_status(%{state: :running, synced: 1})

      refute GhostSettingsLive.sync_stalled?(status)
    end

    test "an in-flight status whose heartbeat is old means the job died or hung" do
      status = %{state: :running, synced: 1, updated_at: DateTime.add(DateTime.utc_now(), -10, :minute)}

      assert GhostSettingsLive.sync_stalled?(status)

      # same for a job stuck in the queue
      assert GhostSettingsLive.sync_stalled?(%{status | state: :queued})
    end

    test "an in-flight status without a heartbeat counts as stalled rather than pinning the button disabled" do
      assert GhostSettingsLive.sync_stalled?(%{state: :running, synced: 1})
    end

    test "terminal or missing statuses are never stalled" do
      refute GhostSettingsLive.sync_stalled?(nil)

      refute GhostSettingsLive.sync_stalled?(%{
               state: :done,
               updated_at: DateTime.add(DateTime.utc_now(), -10, :minute)
             })

      refute GhostSettingsLive.sync_stalled?(%{
               state: :failed,
               updated_at: DateTime.add(DateTime.utc_now(), -10, :minute)
             })
    end
  end
end
