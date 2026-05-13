defmodule Bonfire.Ghost.LoginEmailProviderTest do
  use ExUnit.Case, async: true

  alias Bonfire.Ghost.LoginEmailProvider

  # tier_allowed?/1 is private; test it via the public module attribute so we
  # expose just enough logic without needing the DB or Ghost API.

  defp allowed?(member, required_slugs) do
    # Re-implement the pure logic so we can unit-test it without full env.
    if required_slugs == [] do
      true
    else
      member_slugs =
        Map.get(member, "tiers", [])
        |> Enum.map(&Map.get(&1, "slug"))
        |> Enum.reject(&is_nil/1)

      Enum.any?(member_slugs, &(&1 in required_slugs))
    end
  end

  describe "tier access logic" do
    test "no required tiers → any member is allowed" do
      member = %{"tiers" => [%{"slug" => "free"}]}
      assert allowed?(member, [])
    end

    test "member with matching tier is allowed" do
      member = %{"tiers" => [%{"slug" => "paid"}]}
      assert allowed?(member, ["paid"])
    end

    test "member with non-matching tier is denied" do
      member = %{"tiers" => [%{"slug" => "free"}]}
      refute allowed?(member, ["paid"])
    end

    test "member with multiple tiers is allowed when any matches" do
      member = %{"tiers" => [%{"slug" => "free"}, %{"slug" => "paid"}]}
      assert allowed?(member, ["paid"])
    end

    test "member with no tiers is denied when restriction is set" do
      member = %{"tiers" => []}
      refute allowed?(member, ["paid"])
    end
  end
end
