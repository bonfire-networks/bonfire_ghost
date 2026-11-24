defmodule Bonfire.Ghost.Web.GhostSettingsGroupTest do
  @moduledoc """
  On the Ghost settings, an instance admin picks the group imported articles go into from a list of this instance's groups. A value stored before the list existed (eg. a topic's id) stays picked, so saving the page doesn't drop it.
  """
  use Bonfire.Ghost.ConnCase, async: false
  use Repatch.ExUnit
  import PhoenixTest

  @moduletag :ui

  @page "/settings/instance/bonfire_ghost"

  # the settings show the article import only for a configured Ghost blog: pretend there is one, in every process, since the page's LiveView and its fetch tasks run outside the test's
  @global [mode: :global]

  setup do
    Repatch.patch(Bonfire.Ghost, :configured?, @global, fn -> true end)
    Repatch.patch(Bonfire.Ghost, :admin_configured?, @global, fn -> true end)
    Repatch.patch(Bonfire.Ghost, :client, @global, fn -> {:ok, :client} end)
    Repatch.patch(Bonfire.Ghost, :admin_client, @global, fn -> {:ok, :client} end)

    Repatch.patch(Bonfire.Ghost.API, :get_settings, @global, fn :client ->
      {:ok, %{"settings" => %{"title" => "A Ghost blog"}}}
    end)

    Repatch.patch(Bonfire.Ghost.AdminAPI, :list_tiers, @global, fn :client, _opts ->
      {:ok, %{"tiers" => []}}
    end)

    Repatch.patch(Bonfire.Ghost.AdminAPI, :list_members, @global, fn :client, _opts ->
      {:ok, %{"members" => [], "meta" => %{}}}
    end)

    Repatch.patch(Bonfire.Ghost.AdminAPI, :list_users, @global, fn :client, _opts ->
      {:ok, %{"users" => [], "meta" => %{}}}
    end)

    # what the forms save is instance settings, which are global config and outlive the test (and its users, which the sandbox rolls back): put them back for the tests that run after
    for key <- [:auto_import_as, :post_into_group] do
      previous = Application.fetch_env(:bonfire_ghost, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:bonfire_ghost, key, value)
          :error -> Application.delete_env(:bonfire_ghost, key)
        end
      end)
    end

    admin_account = fake_account!()
    admin = fake_admin!(admin_account)
    group = Bonfire.Classify.Simulate.fake_group!(admin)

    {:ok, admin: admin, conn: conn(user: admin, account: admin_account), group: group}
  end

  defp put_setting(key, value) do
    Bonfire.Common.Settings.put([:bonfire_ghost, key], value,
      scope: :instance,
      skip_boundary_check: true
    )
  end

  test "an admin picks one of this instance's groups, and it's stored and shown as picked", %{
    conn: conn,
    group: group
  } do
    conn
    |> visit(@page)
    |> wait_async()
    |> within("[data-role=ghost_group_form]", fn session ->
      select(session, group.profile.name, from: "Post into group")
    end)
    |> assert_has("[data-role=ghost_group_form] option[selected]", text: group.profile.name)

    assert Bonfire.Ghost.post_into_group() == group.id
  end

  # Ghost's setting could name a topic before the list existed, and importing still accepts one
  test "a stored topic shows as picked, and saving another field keeps it", %{
    admin: admin,
    conn: conn,
    group: group
  } do
    topic = Bonfire.Classify.Simulate.fake_category!(admin, group, %{type: :topic})
    put_setting(:post_into_group, topic.id)

    conn
    |> visit(@page)
    |> wait_async()
    |> assert_has("[data-role=ghost_group_form] option[selected]", text: topic.profile.name)
    |> within("[data-role=ghost_author_form]", fn session ->
      session
      |> fill_in("Default author", with: admin.id)
      |> submit()
    end)

    assert Bonfire.Ghost.auto_import_as() == admin.id
    assert Bonfire.Ghost.post_into_group() == topic.id
  end
end
