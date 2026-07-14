defmodule Bonfire.Ghost.Sync.StaffTierWipeTest do
  @moduledoc """
  Regression tests for tier reconciliation against payloads that are **not** member payloads.

  `EmbedHelper.fetch_and_provision_staff/1` feeds a Ghost **staff user** payload (from the
  Admin API `GET /users/:id`) to `Members.provision_from_ghost_member/2`, which reconciles
  `ghost_tier:*` circles. Ghost staff resources have no `tiers` field — it is a members/
  products concept — and `reconcile_circles/3`'s catch-all coerces a payload without `"tiers"`
  to `%{"tiers" => []}`, i.e. "this person is on no tiers, remove them from every tier circle".

  So importing or updating an article by a staff author who is *also* a paying member silently
  stripped their paid access. The same trap applies to any webhook payload that omits `tiers`.
  """
  # `async: false` — touches instance-wide circles and patches Ghost helpers.
  use Bonfire.Ghost.DataCase, async: false

  alias Bonfire.Boundaries.Circles
  alias Bonfire.Boundaries.Scaffold.Instance, as: InstanceScaffold
  alias Bonfire.Ghost
  alias Bonfire.Ghost.AdminAPI
  alias Bonfire.Ghost.Sync.Members
  alias Bonfire.Me.Fake

  @email "author@example.test"

  setup do
    Bonfire.Ghost.Sync.Tiers.sync_tiers(
      [%{"id" => "t_gold", "slug" => "gold", "name" => "Gold", "type" => "paid"}],
      []
    )

    :ok
  end

  defp gold_circle! do
    {:ok, circle} = Circles.get_by_name("ghost_tier:gold", InstanceScaffold.admin_circle())
    circle
  end

  defp paying_member_user! do
    user = Fake.fake_user!()
    Circles.add_to_circles(user, gold_circle!())
    assert Circles.is_encircled_by?(user, gold_circle!().id)
    user
  end

  # What Ghost's Admin API actually returns for a staff user: no `tiers` key at all.
  defp staff_payload do
    %{
      "id" => "ghost_staff_1",
      "email" => @email,
      "name" => "Staff Author",
      "slug" => "staff-author"
    }
  end

  describe "reconcile_circles/3 with a payload that has no tiers (P1-5)" do
    test "a staff-author payload does NOT strip the user's paid tier circles" do
      user = paying_member_user!()

      # Ghost not reachable → we cannot learn their real tiers → must leave circles alone,
      # never assume "no tiers".
      Repatch.patch(Ghost, :admin_configured?, fn -> false end)
      Repatch.patch(Ghost, :admin_client, fn -> {:error, :not_configured} end)

      assert {:ok, _diff} = Members.reconcile_circles(user, staff_payload(), [])

      assert Circles.is_encircled_by?(user, gold_circle!().id),
             "importing an article by a staff author stripped their paid tier circle"
    end

    test "a staff author who is also a paying member keeps their tiers (resolved from Ghost)" do
      user = paying_member_user!()

      # the same human, looked up as a *member*, is on the gold tier
      Repatch.patch(Ghost, :admin_configured?, fn -> true end)
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)

      Repatch.patch(AdminAPI, :get_member_by_email, fn :client, @email, _opts ->
        {:ok,
         %{
           "members" => [
             %{"email" => @email, "tiers" => [%{"slug" => "gold", "name" => "Gold"}]}
           ]
         }}
      end)

      assert {:ok, _diff} = Members.reconcile_circles(user, staff_payload(), [])

      assert Circles.is_encircled_by?(user, gold_circle!().id)
    end

    test "a staff author who is NOT a member keeps any circles they already had" do
      user = paying_member_user!()

      Repatch.patch(Ghost, :admin_configured?, fn -> true end)
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)

      Repatch.patch(AdminAPI, :get_member_by_email, fn :client, _e, _o ->
        {:ok, %{"members" => []}}
      end)

      assert {:ok, _diff} = Members.reconcile_circles(user, staff_payload(), [])

      # not a member → nothing authoritative to reconcile against → don't touch their circles
      assert Circles.is_encircled_by?(user, gold_circle!().id)
    end
  end

  describe "a transient Ghost failure must be retryable, not silently succeed" do
    test "an API error returns {:error, _} so Oban retries (and does not touch circles)" do
      user = paying_member_user!()

      Repatch.patch(Ghost, :admin_configured?, fn -> true end)
      Repatch.patch(Ghost, :admin_client, fn -> {:ok, :client} end)

      # Ghost is up but erroring/timing out — we genuinely don't know their tiers
      Repatch.patch(AdminAPI, :get_member_by_email, fn :client, _e, _o ->
        {:error, :timeout}
      end)

      assert {:error, _} = Members.reconcile_circles(user, staff_payload(), []),
             "a transient Ghost outage reported SUCCESS — the Oban webhook job completes and the tier change is dropped forever"

      # and it must certainly not have stripped anything on the way out
      assert Circles.is_encircled_by?(user, gold_circle!().id)
    end

    test "Ghost not being configured is NOT retried (retrying can't help)" do
      user = paying_member_user!()

      Repatch.patch(Ghost, :admin_configured?, fn -> false end)
      Repatch.patch(Ghost, :admin_client, fn -> {:error, :not_configured} end)

      assert {:ok, _diff} = Members.reconcile_circles(user, staff_payload(), [])
      assert Circles.is_encircled_by?(user, gold_circle!().id)
    end
  end

  describe "reconcile_circles/3 still reconciles real member payloads" do
    test "an explicit empty tiers list DOES remove tier circles (downgrade still works)" do
      user = paying_member_user!()

      # a real member payload says, authoritatively, "on no tiers"
      assert {:ok, _diff} =
               Members.reconcile_circles(user, %{"email" => @email, "tiers" => []}, [])

      refute Circles.is_encircled_by?(user, gold_circle!().id),
             "a genuine downgrade must still remove the tier circle"
    end

    test "a member payload with tiers adds the matching circle" do
      user = Fake.fake_user!()
      refute Circles.is_encircled_by?(user, gold_circle!().id)

      assert {:ok, _diff} =
               Members.reconcile_circles(
                 user,
                 %{"email" => @email, "tiers" => [%{"slug" => "gold"}]},
                 []
               )

      assert Circles.is_encircled_by?(user, gold_circle!().id)
    end
  end
end
