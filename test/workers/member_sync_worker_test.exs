defmodule Bonfire.Ghost.Workers.MemberSyncWorkerTest do
  use Bonfire.Ghost.DataCase, async: false
  use Repatch.ExUnit

  alias Bonfire.Ghost.Sync.Members
  alias Bonfire.Ghost.Sync.Tiers
  alias Bonfire.Ghost.Workers.MemberSyncWorker

  test "runs tier sync, then member backfill, then staff backfill" do
    parent = self()

    Repatch.patch(Tiers, :sync_all, fn _opts ->
      send(parent, :tiers_synced)
      {:ok, %{created: 0, updated: 0, unchanged: 0, archived: 0, errors: []}, []}
    end)

    Repatch.patch(Members, :sync_all, fn _opts ->
      assert_received :tiers_synced
      send(parent, :members_synced)
      {:ok, %{provisioned: 0, errors: []}}
    end)

    Repatch.patch(Members, :sync_all_staff, fn _opts ->
      assert_received :members_synced
      send(parent, :staff_synced)
      {:ok, %{provisioned: 0, errors: []}}
    end)

    assert :ok = MemberSyncWorker.perform(%Oban.Job{args: %{}})
    assert_receive :staff_synced
  end

  test "retries when the staff backfill fails transiently" do
    Repatch.patch(Tiers, :sync_all, fn _opts ->
      {:ok, %{created: 0, updated: 0, unchanged: 0, archived: 0, errors: []}, []}
    end)

    Repatch.patch(Members, :sync_all, fn _opts ->
      {:ok, %{provisioned: 0, errors: []}}
    end)

    Repatch.patch(Members, :sync_all_staff, fn _opts -> {:error, :timeout} end)

    # member sync is idempotent, so retrying the whole job to recover staff is fine
    assert {:error, :timeout} = MemberSyncWorker.perform(%Oban.Job{args: %{}})
  end

  test "cancels (no retries) when the staff backfill hits a deterministic auth error" do
    Repatch.patch(Tiers, :sync_all, fn _opts ->
      {:ok, %{created: 0, updated: 0, unchanged: 0, archived: 0, errors: []}, []}
    end)

    Repatch.patch(Members, :sync_all, fn _opts ->
      {:ok, %{provisioned: 0, errors: []}}
    end)

    Repatch.patch(Members, :sync_all_staff, fn _opts -> {:error, :forbidden} end)

    # an integration key that can't read /users/ won't start working on retry, and the
    # member pass already completed — burning retries would just repeat it
    assert {:cancel, {:staff_sync_failed, :forbidden}} =
             MemberSyncWorker.perform(%Oban.Job{args: %{}})
  end

  test "retries when upstream tier sync fails" do
    Repatch.patch(Tiers, :sync_all, fn _opts -> {:error, :not_configured} end)

    assert {:error, :not_configured} = MemberSyncWorker.perform(%Oban.Job{args: %{}})
  end

  test "cancels (no retries) and does not backfill members when tier sync has partial errors" do
    Repatch.patch(Tiers, :sync_all, fn _opts ->
      {:ok,
       %{
         created: 0,
         updated: 0,
         unchanged: 0,
         archived: 0,
         errors: [{"paid", :invalid_slug}]
       }, []}
    end)

    Repatch.patch(Members, :sync_all, fn _opts ->
      flunk("members should not sync when tier sync had errors")
    end)

    assert {:cancel, {:tier_sync_failed, [{"paid", :invalid_slug}]}} =
             MemberSyncWorker.perform(%Oban.Job{args: %{}})
  end

  test "errors instead of silently succeeding on an unexpected tier sync result" do
    Repatch.patch(Tiers, :sync_all, fn _opts -> {:ok, %{"not" => "tiers"}} end)

    Repatch.patch(Members, :sync_all, fn _opts ->
      flunk("members should not sync when tier sync returned an unexpected shape")
    end)

    assert {:error, {:unexpected_sync_result, {:ok, %{"not" => "tiers"}}}} =
             MemberSyncWorker.perform(%Oban.Job{args: %{}})
  end

  test "finishes with warning when only member payloads fail" do
    Repatch.patch(Tiers, :sync_all, fn _opts ->
      {:ok, %{created: 0, updated: 0, unchanged: 0, archived: 0, errors: []}, []}
    end)

    Repatch.patch(Members, :sync_all, fn _opts ->
      {:ok, %{provisioned: 1, errors: [{"bad-member", :missing_email}]}}
    end)

    Repatch.patch(Members, :sync_all_staff, fn _opts ->
      {:ok, %{provisioned: 0, errors: []}}
    end)

    assert :ok = MemberSyncWorker.perform(%Oban.Job{args: %{}})
  end
end
