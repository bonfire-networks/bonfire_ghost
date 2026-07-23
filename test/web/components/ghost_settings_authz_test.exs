defmodule Bonfire.Ghost.Web.GhostSettingsAuthzTest do
  @moduledoc """
  Regression tests for authorization on the Ghost settings component's *reads*.

  `GhostSettingsLive` is a `declare_settings_component`, so it is registered on the generic
  settings surface and isn't reachable only via the `:admin_required` route. Its mount
  fetches the Ghost **member list** — emails, names, tiers, subscription status — so the
  read needs the same permission the write/sync events already check, not just route wiring.
  """
  # `async: false` — patches instance-level Ghost helpers.
  use Bonfire.Ghost.DataCase, async: false

  alias Bonfire.Ghost
  alias Bonfire.Ghost.AdminAPI
  alias Bonfire.Ghost.Web.GhostSettingsLive
  alias Bonfire.UI.Common.Testing.Helpers

  # Pretend Ghost is fully configured, and shout if anyone asks it for members.
  #
  # `mode: :shared` matters: `load_ghost_data/1` fans the three Ghost calls out through
  # `Task.async_stream`, so the calls happen in *child* processes. With Repatch's default
  # (process-local) mode the stubs wouldn't apply there — the real HTTP client would run,
  # and a "no PII was fetched" assertion would pass for the wrong reason.
  @global [mode: :shared]

  defp stub_ghost! do
    Repatch.patch(Ghost, :admin_configured?, @global, fn -> true end)
    Repatch.patch(Ghost, :admin_client, @global, fn -> {:ok, :client} end)
    Repatch.patch(Ghost, :client, @global, fn -> {:ok, :client} end)

    Repatch.patch(Bonfire.Ghost.API, :get_settings, @global, fn :client ->
      {:ok, %{"settings" => %{}}}
    end)

    Repatch.patch(AdminAPI, :list_tiers, @global, fn :client, _opts ->
      {:ok, %{"tiers" => []}}
    end)

    test_pid = self()

    Repatch.patch(AdminAPI, :list_members, @global, fn :client, _opts ->
      send(test_pid, :fetched_member_pii)
      {:ok, %{"members" => [], "meta" => %{}}}
    end)

    Repatch.patch(AdminAPI, :list_users, @global, fn :client, _opts ->
      {:ok, %{"users" => [], "meta" => %{}}}
    end)

    :ok
  end

  defp socket_for(user) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        __context__: %{current_user: user}
      }
    }
  end

  defp mount_component(user) do
    GhostSettingsLive.update(%{__context__: %{current_user: user}}, socket_for(user))
  end

  describe "member PII on mount (M3)" do
    test "a non-admin mounting the component does NOT fetch the Ghost member list" do
      stub_ghost!()
      user = Bonfire.Me.Fake.fake_user!()

      assert {:ok, _socket} = mount_component(user)

      refute_received :fetched_member_pii,
                      "a non-admin's mount fetched the Ghost member list (emails, names, tiers)"
    end

    test "an admin mounting the component still loads Ghost data" do
      stub_ghost!()
      admin = Helpers.fake_admin!()

      assert {:ok, _socket} = mount_component(admin)

      assert_received :fetched_member_pii,
                      "an admin must still see the member list — the gate broke the feature"
    end

    test "a guest (no user) does NOT fetch the Ghost member list" do
      stub_ghost!()

      assert {:ok, _socket} = mount_component(nil)

      refute_received :fetched_member_pii
    end
  end
end
