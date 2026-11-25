defmodule Bonfire.Ghost.Web.GhostSettingsScopeTest do
  @moduledoc """
  The Ghost settings are the instance's: they show in the instance settings, not in a person's own settings, where they'd only be a locked box saying they're for admins.
  """
  use Bonfire.Ghost.ConnCase, async: false
  import PhoenixTest

  @moduletag :ui

  setup do
    account = fake_account!()
    me = fake_user!(account)

    {:ok, conn: conn(user: me, account: account)}
  end

  test "a person's own settings for the Ghost extension show no Ghost settings card", %{
    conn: conn
  } do
    conn
    |> visit("/settings/user/bonfire_ghost")
    # the control: the extension's settings page itself renders
    |> assert_has("[data-role=extension_settings]")
    |> refute_has("[data-role=extension_settings]", text: "Admins only")
  end
end
