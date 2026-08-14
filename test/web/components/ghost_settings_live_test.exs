defmodule Bonfire.Ghost.Web.GhostSettingsLiveTest do
  use ExUnit.Case, async: true

  # bucket this into the backend CI leg: bare `ExUnit.Case` skips the tag the extension case templates apply, so without it this also runs in the federation job catch-all
  @moduletag :backend

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

  describe "staff_role/1" do
    test "returns the first role name" do
      assert GhostSettingsLive.staff_role(%{"roles" => [%{"name" => "Contributor"}]}) ==
               "Contributor"

      assert GhostSettingsLive.staff_role(%{
               "roles" => [%{"name" => "Editor"}, %{"name" => "Author"}]
             }) == "Editor"
    end

    test "returns \"-\" when roles are missing or empty" do
      assert GhostSettingsLive.staff_role(%{}) == "-"
      assert GhostSettingsLive.staff_role(%{"roles" => []}) == "-"
      assert GhostSettingsLive.staff_role(%{"roles" => [%{}]}) == "-"
    end
  end

  describe "status_badge_class/1" do
    test "distinguishes active, locked and suspended staff" do
      # locked (imported, no Ghost password) must not look like an error state — it's
      # the normal state of ~99% of bulk-imported contributors
      assert GhostSettingsLive.status_badge_class("active") == "badge-success"
      assert GhostSettingsLive.status_badge_class("locked") == "badge-ghost"
      assert GhostSettingsLive.status_badge_class("inactive") == "badge-warning"
    end
  end
end
