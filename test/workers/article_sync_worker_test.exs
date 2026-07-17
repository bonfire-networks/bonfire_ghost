defmodule Bonfire.Ghost.Workers.ArticleSyncWorkerTest do
  use Bonfire.Ghost.DataCase, async: false
  use Repatch.ExUnit

  alias Bonfire.Ghost.Sync.Articles
  alias Bonfire.Ghost.Workers.ArticleSyncWorker

  setup do
    Articles.clear_status()
    :ok
  end

  test "returns :ok and leaves the :done status alone when the backfill succeeds" do
    Repatch.patch(Articles, :sync_all, fn _opts ->
      Articles.put_status(%{state: :done, synced: 2, filtered: 0, errors_count: 0, errors: []})
      {:ok, %{synced: 2, filtered: 0, errors: []}}
    end)

    assert :ok = ArticleSyncWorker.perform(%Oban.Job{args: %{}, attempt: 1, max_attempts: 3})
    assert %{state: :done, synced: 2} = Articles.status()
  end

  test "marks the status as :retrying with attempt info when a retry is coming" do
    Repatch.patch(Articles, :sync_all, fn _opts ->
      Articles.put_status(%{state: :failed, reason: "nxdomain", synced: 5})
      {:error, :nxdomain}
    end)

    assert {:error, :nxdomain} =
             ArticleSyncWorker.perform(%Oban.Job{args: %{}, attempt: 1, max_attempts: 3})

    # Progress so far is kept, and the panel can say "retrying (attempt 1 of 3)".
    assert %{state: :retrying, reason: "nxdomain", attempt: 1, max_attempts: 3, synced: 5} =
             Articles.status()
  end

  test "leaves the status as :failed on the final attempt" do
    Repatch.patch(Articles, :sync_all, fn _opts ->
      Articles.put_status(%{state: :failed, reason: "nxdomain"})
      {:error, :nxdomain}
    end)

    assert {:error, :nxdomain} =
             ArticleSyncWorker.perform(%Oban.Job{args: %{}, attempt: 3, max_attempts: 3})

    assert %{state: :failed, reason: "nxdomain", attempt: 3} = Articles.status()
  end

  test "cancels without retrying when Ghost is not configured" do
    Repatch.patch(Articles, :sync_all, fn _opts -> {:error, :not_configured} end)

    assert {:cancel, :not_configured} =
             ArticleSyncWorker.perform(%Oban.Job{args: %{}, attempt: 1, max_attempts: 3})
  end
end
