defmodule Bonfire.Ghost.Sync.TiersTest do
  # `async: false` because `Sync.Tiers` writes to instance-scoped circles,
  # which are shared state across concurrent tests.
  use Bonfire.Ghost.DataCase, async: false

  alias Bonfire.Boundaries.Circles
  alias Bonfire.Boundaries.Scaffold.Instance, as: InstanceScaffold
  alias Bonfire.Ghost.Sync.Tiers
  alias Bonfire.Me.Fake

  @free %{"id" => "tier_free_1", "slug" => "free", "name" => "Free"}
  @paid %{"id" => "tier_paid_1", "slug" => "paid", "name" => "Paid"}

  defp lookup(slug),
    do: Circles.get_by_name("ghost_tier:#{slug}", InstanceScaffold.admin_circle())

  describe "sync_tier/2 input validation" do
    test "rejects payloads missing slug/name/id" do
      assert {:error, :invalid_tier} = Tiers.sync_tier(%{"slug" => "foo"}, [])
      assert {:error, :invalid_tier} = Tiers.sync_tier(%{"slug" => "foo", "name" => "Foo"}, [])
      assert {:error, :invalid_tier} = Tiers.sync_tier(%{}, [])
    end

    test "rejects slugs that fail the regex (path-unsafe / whitespace / uppercase)" do
      for bad <- ["Bad", "with space", "a/b", "-leading-dash", ""] do
        tier = %{"id" => "x", "slug" => bad, "name" => "X"}

        assert {:error, :invalid_slug} = Tiers.sync_tier(tier, []),
               "expected #{inspect(bad)} to be rejected"
      end
    end
  end

  describe "sync_tier/2 circle lifecycle" do
    test "creates a circle on first run" do
      assert {:ok, :created} = Tiers.sync_tier(@free, [])
      assert {:ok, circle} = lookup("free")
      assert circle.named.name == "ghost_tier:free"
    end

    test "is idempotent — a second run reports :unchanged" do
      assert {:ok, :created} = Tiers.sync_tier(@free, [])
      assert {:ok, :unchanged} = Tiers.sync_tier(@free, [])
    end

    test "refreshes extra_info when the display name changes upstream" do
      user = Fake.fake_user!()
      assert {:ok, :created} = Tiers.sync_tier(@free, current_user: user)

      renamed = Map.put(@free, "name", "Free (updated)")
      assert {:ok, :updated} = Tiers.sync_tier(renamed, current_user: user)

      {:ok, circle} = lookup("free")
      circle = Bonfire.Common.Repo.maybe_preload(circle, :extra_info)
      assert circle.extra_info.summary == "Ghost tier: Free (updated)"
      assert circle.extra_info.info["display_name"] == "Free (updated)"
    end

    test "stores tier type for paid-circle auto-detection" do
      assert {:ok, :created} = Tiers.sync_tier(Map.put(@paid, "type", "paid"), [])

      {:ok, circle} = lookup("paid")
      circle = Bonfire.Common.Repo.maybe_preload(circle, :extra_info)

      assert circle.extra_info.info["type"] == "paid"
    end
  end

  describe "sync_tiers/2 archiving" do
    test "marks orphaned ghost_tier:* circles archived without deleting them" do
      user = Fake.fake_user!()
      opts = [current_user: user]

      # First sync has both tiers.
      summary1 = Tiers.sync_tiers([@free, @paid], opts)
      assert summary1.created == 2
      assert summary1.archived == 0

      # Second sync drops @paid → it should be archived, @free stays unchanged.
      summary2 = Tiers.sync_tiers([@free], opts)
      assert summary2.unchanged == 1
      assert summary2.archived == 1

      {:ok, paid} = lookup("paid")
      paid = Bonfire.Common.Repo.maybe_preload(paid, :extra_info)
      assert String.ends_with?(paid.extra_info.summary, "(archived)")

      # Running again doesn't double-archive.
      summary3 = Tiers.sync_tiers([@free], opts)
      assert summary3.archived == 0
    end

    test "aggregates errors by slug without halting the batch" do
      # Missing id/name → :invalid_tier (falls through the matched head).
      bad_payload = %{"slug" => "missing-fields"}
      # Valid shape but slug fails regex → :invalid_slug.
      bad_slug = %{"id" => "x", "slug" => "Bad Slug", "name" => "X"}

      summary = Tiers.sync_tiers([@free, bad_payload, bad_slug], [])

      assert summary.created == 1
      assert {"missing-fields", :invalid_tier} in summary.errors
      assert {"Bad Slug", :invalid_slug} in summary.errors
    end
  end
end
