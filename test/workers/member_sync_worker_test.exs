defmodule Bonfire.Ghost.Workers.MemberSyncWorkerTest do
  use Bonfire.Ghost.DataCase, async: false
  use Repatch.ExUnit

  alias Bonfire.Ghost.Sync.Members
  alias Bonfire.Ghost.Sync.Tiers
  alias Bonfire.Ghost.Workers.MemberSyncWorker

  test "runs tier sync, then protects staff identities before the long member backfill" do
    parent = self()

    Repatch.patch(Tiers, :sync_all, fn _opts ->
      send(parent, :tiers_synced)
      {:ok, %{created: 0, updated: 0, unchanged: 0, archived: 0, errors: []}, []}
    end)

    Repatch.patch(Members, :sync_all_staff, fn _opts ->
      assert_received :tiers_synced
      send(parent, :staff_synced)
      {:ok, %{provisioned: 0, errors: []}}
    end)

    Repatch.patch(Members, :sync_all, fn _opts ->
      assert_received :staff_synced
      send(parent, :members_synced)
      {:ok, %{provisioned: 0, errors: []}}
    end)

    assert :ok = MemberSyncWorker.perform(%Oban.Job{args: %{}})
    assert_receive :members_synced
  end

  test "retries when the staff backfill fails transiently" do
    Repatch.patch(Tiers, :sync_all, fn _opts ->
      {:ok, %{created: 0, updated: 0, unchanged: 0, archived: 0, errors: []}, []}
    end)

    Repatch.patch(Members, :sync_all, fn _opts -> flunk("members must wait for staff") end)

    Repatch.patch(Members, :sync_all_staff, fn _opts -> {:error, :timeout} end)

    # member sync is idempotent, so retrying the whole job to recover staff is fine
    assert {:error, :timeout} = MemberSyncWorker.perform(%Oban.Job{args: %{}})
  end

  test "cancels (no retries) when the staff backfill hits a deterministic auth error" do
    Repatch.patch(Tiers, :sync_all, fn _opts ->
      {:ok, %{created: 0, updated: 0, unchanged: 0, archived: 0, errors: []}, []}
    end)

    Repatch.patch(Members, :sync_all, fn _opts -> flunk("members must wait for staff") end)

    Repatch.patch(Members, :sync_all_staff, fn _opts -> {:error, :forbidden} end)

    # an integration key that can't read /users/ won't start working on retry
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

  describe "status reporting (so a backfill is not a black box)" do
    setup do
      Members.clear_status()
      on_exit(&Members.clear_status/0)
      :ok
    end

    defp stub_tiers(
           result \\ {:ok, %{created: 0, updated: 0, unchanged: 0, archived: 0, errors: []}, []}
         ) do
      Repatch.patch(Tiers, :sync_all, fn _opts -> result end)
    end

    test "a completed run records ALL THREE stages, even if the cache goes stale mid-run" do
      stub_tiers({:ok, %{created: 2, updated: 1, unchanged: 0, archived: 0, errors: []}, []})

      Repatch.patch(Members, :sync_all_staff, fn _opts ->
        {:ok, %{provisioned: 1522, skipped: 0, errors: []}}
      end)

      Repatch.patch(Members, :sync_all, fn _opts ->
        # Simulate the real hazard: the shared status cache is clobbered while the long
        # member pass runs. The final status must still carry tiers + staff because the
        # worker accumulates in-process rather than re-reading the cache to append.
        Members.put_status(%{state: :running, stages: %{}})
        {:ok, %{provisioned: 7, skipped: 2, errors: []}}
      end)

      assert :ok = MemberSyncWorker.perform(%Oban.Job{args: %{}, id: 42, attempt: 1})

      status = Members.status()
      assert status.state == :done
      assert status.stages[:tiers].created == 2
      assert status.stages[:tiers].updated == 1
      assert status.stages[:members].provisioned == 7
      # the number an operator needs to see: did the staff pass actually run?
      assert status.stages[:staff].provisioned == 1522
    end

    test "a run that dies during members keeps the completed staff diagnostics" do
      stub_tiers()

      Repatch.patch(Members, :sync_all_staff, fn _opts ->
        {:ok, %{provisioned: 2, skipped: 0, errors: []}}
      end)

      Repatch.patch(Members, :sync_all, fn _opts -> {:error, :unauthorized} end)

      assert {:error, :unauthorized} =
               MemberSyncWorker.perform(%Oban.Job{args: %{}, id: 43, attempt: 1, max_attempts: 3})

      status = Members.status()
      assert status.state == :failed
      assert status.stage == :members
      assert status.reason =~ "unauthorized"
      assert status.stages[:staff].provisioned == 2
    end

    test "page callbacks expose live staff and member progress" do
      parent = self()
      stub_tiers()

      Repatch.patch(Members, :sync_all_staff, fn opts ->
        opts[:on_progress].(2, %{provisioned: 125, skipped: 0, errors: []})
        send(parent, {:staff_progress, Members.status()})
        {:ok, %{provisioned: 150, skipped: 0, errors: []}}
      end)

      Repatch.patch(Members, :sync_all, fn opts ->
        opts[:on_progress].(3, %{provisioned: 210, skipped: 40, errors: []})
        send(parent, {:member_progress, Members.status()})
        {:ok, %{provisioned: 220, skipped: 45, errors: []}}
      end)

      assert :ok = MemberSyncWorker.perform(%Oban.Job{args: %{}, id: 45, attempt: 1})

      assert_receive {:staff_progress,
                      %{stage: :staff, page: 2, stages: %{staff: %{provisioned: 125}}}}

      assert_receive {:member_progress,
                      %{stage: :members, page: 3, stages: %{members: %{provisioned: 210}}}}
    end

    test "staff errors are surfaced with the affected identities" do
      stub_tiers()

      Repatch.patch(Members, :sync_all, fn _opts ->
        {:ok, %{provisioned: 0, skipped: 0, errors: []}}
      end)

      Repatch.patch(Members, :sync_all_staff, fn _opts ->
        {:ok, %{provisioned: 3, skipped: 0, errors: [{"who@test.local", :missing_email}]}}
      end)

      assert :ok = MemberSyncWorker.perform(%Oban.Job{args: %{}, id: 44, attempt: 1})

      assert %{errors_count: 1, errors: [%{who: "who@test.local"}]} =
               Members.status().stages[:staff]
    end

    test "normalizes missing and non-list errors for display" do
      assert %{created: 2, errors_count: 0, errors: []} =
               Members.stage_counts(%{created: 2, errors: nil})

      assert %{errors_count: 1, errors: [%{who: "?", reason: ":invalid"}]} =
               Members.stage_counts(%{errors: :invalid})
    end
  end
end
