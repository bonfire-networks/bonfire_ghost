defmodule Bonfire.Ghost.Web.GhostSettingsLiveTest do
  use ExUnit.Case, async: true

  alias Bonfire.Ghost.Web.GhostSettingsLive

  describe "format_date/1" do
    # Regression: Ghost returns member `created_at` as a full ISO datetime; the shared
    # DatesTimes.format_date (via Date.from_iso8601) rejects those, so the component must
    # normalize to a DateTime first. Before the fix these all rendered "-".
    test "formats a full ISO datetime string" do
      result = GhostSettingsLive.format_date("2026-01-15T10:00:00.000Z")
      assert is_binary(result)
      refute result == "-"
      assert result =~ "2026"
    end

    test "formats a plain ISO date string" do
      result = GhostSettingsLive.format_date("2026-01-15")
      refute result == "-"
      assert result =~ "2026"
    end

    test "formats a DateTime struct" do
      {:ok, dt, _} = DateTime.from_iso8601("2026-01-15T10:00:00Z")
      result = GhostSettingsLive.format_date(dt)
      refute result == "-"
      assert result =~ "2026"
    end

    test "returns \"-\" for nil and unparseable input" do
      assert GhostSettingsLive.format_date(nil) == "-"
      assert GhostSettingsLive.format_date("not a date") == "-"
    end
  end
end
