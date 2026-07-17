defmodule Bonfire.Ghost.GatedLoginSettingsIntegrationTest do
  @moduledoc """
  Integration tests for the seam between the tier toggles in the Ghost settings UI and the
  gated-login provider.

  `login_email_provider_test.exs` drives `ensure_account/1` but writes `required_tier` with a
  hand-built `Settings.put/3` map. The settings UI writes through a different pipeline: each
  `SettingsToggleLive` in `ghost_settings_live.sface` renders a checkbox/hidden-input pair named
  `bonfire_ghost[required_tier][<slug>]` inside a `phx-change="Bonfire.Common.Settings:set"`
  form, so what actually reaches storage is string-keyed, string-valued form params run through
  `Settings.set/2`'s `input_to_atoms(discard_unknown_keys: true, values: true, ...)`
  normalisation and a deep merge into the existing branch. A regression anywhere in that
  pipeline (slug key discarded as unknown, `"true"` left unconverted, branch replaced instead
  of merged) silently opens or closes the login gate for every member — so these tests submit
  the exact wire format the UI produces and assert on the provider's verdict.
  """
  # `async: false` — patches instance-level Ghost helpers and writes instance-scoped settings.
  use Bonfire.Ghost.DataCase, async: false
  use Repatch.ExUnit

  alias Bonfire.Ghost
  alias Bonfire.Ghost.AdminAPI
  alias Bonfire.Ghost.LoginEmailProvider

  @email "tiered-member@example.test"

  setup do
    # The DB write is rolled back by the sandbox; what leaks between tests (and into other
    # files) is the instance-settings cache in app config. Snapshot and restore it — a DB
    # write in `on_exit` would fail anyway (sandbox ownership is already gone by then).
    previous = Application.get_env(:bonfire_ghost, :required_tier)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:bonfire_ghost, :required_tier)
      else
        Application.put_env(:bonfire_ghost, :required_tier, previous)
      end
    end)

    :ok
  end

  defp stub_member_with_tiers(slugs) do
    member = %{
      "id" => "ghost_member_1",
      "email" => @email,
      "name" => "A Member",
      "tiers" => Enum.map(slugs, &%{"slug" => &1, "name" => &1})
    }

    # `force: true` — tests re-stub with different tiers mid-test
    Repatch.patch(Ghost, :admin_configured?, [force: true], fn -> true end)
    Repatch.patch(Ghost, :admin_client, [force: true], fn -> {:ok, :client} end)

    Repatch.patch(AdminAPI, :get_member_by_email, [force: true], fn :client, _email, _opts ->
      {:ok, %{"members" => [member]}}
    end)

    # the tier-gated (disallowed) branch falls back to a staff lookup — not staff here
    Repatch.patch(AdminAPI, :get_user_by_email, [force: true], fn :client, _email ->
      {:ok, %{"users" => []}}
    end)

    :ok
  end

  # Submits exactly what one toggle's form sends to `handle_event("set", ...)` in
  # `Bonfire.Common.Settings.LiveHandler` (minus `"_target"`, which the handler drops
  # before calling `Settings.set/2`): a nested string-keyed map with the string
  # "true"/"false" from the checkbox/hidden pair, plus the hidden scope field.
  defp ui_toggle_tier(slug, enabled?) do
    assert {:ok, _} =
             Bonfire.Common.Settings.set(
               %{
                 "bonfire_ghost" => %{"required_tier" => %{slug => to_string(enabled?)}},
                 "scope" => "instance"
               },
               skip_boundary_check: true
             )
  end

  test "toggling a tier ON through the settings-form wire format gates login on it" do
    ui_toggle_tier("free", false)
    ui_toggle_tier("gold", true)

    stub_member_with_tiers(["free"])
    assert :no_match = LoginEmailProvider.ensure_account(@email)
    refute Bonfire.Me.Accounts.get_by_email(@email)

    stub_member_with_tiers(["gold"])
    assert {:ok, _account} = LoginEmailProvider.ensure_account(@email)
    assert Bonfire.Me.Accounts.get_by_email(@email)
  end

  test "a dashed Ghost slug survives the settings round-trip" do
    # realistic Ghost slugs are dashed; `input_to_atoms(discard_unknown_keys: true)` must not
    # drop the nested key (no `:"gold-vip"` atom pre-exists) or the gate silently stays open
    ui_toggle_tier("free", false)
    ui_toggle_tier("gold-vip", true)

    stub_member_with_tiers(["free"])
    assert :no_match = LoginEmailProvider.ensure_account(@email)

    stub_member_with_tiers(["gold-vip"])
    assert {:ok, _account} = LoginEmailProvider.ensure_account(@email)
  end

  test "toggling the tier back OFF re-opens login to any member" do
    ui_toggle_tier("gold", true)
    ui_toggle_tier("gold", false)

    stub_member_with_tiers(["free"])
    assert {:ok, _account} = LoginEmailProvider.ensure_account(@email)
  end

  test "each toggle write merges into the branch instead of replacing it" do
    # the form wrapping each toggle contains ONLY that tier's input, so consecutive writes
    # must accumulate: if the second write replaced the whole required_tier map, "gold"
    # would be forgotten and the free member would slip through
    ui_toggle_tier("gold", true)
    ui_toggle_tier("free", false)

    stub_member_with_tiers(["free"])
    assert :no_match = LoginEmailProvider.ensure_account(@email)

    stub_member_with_tiers(["free", "gold"])
    assert {:ok, _account} = LoginEmailProvider.ensure_account(@email)
  end
end
