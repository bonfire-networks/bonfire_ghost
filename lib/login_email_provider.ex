defmodule Bonfire.Ghost.LoginEmailProvider do
  @moduledoc """
  Adapter implementing `Bonfire.UI.Me.LoginEmailProvider` for Ghost CMS.

  Auto-discovered at startup via `Bonfire.Common.ExtensionBehaviour`. Called
  from `Bonfire.UI.Me.ForgotPasswordController.create/2` when an unknown email
  is submitted so that a Ghost member with an active tier can seamlessly log in
  — the local account+user+circles are provisioned on the fly and then the
  standard magic-link flow picks them up.
  """
  @behaviour Bonfire.UI.Me.LoginEmailProvider

  alias Bonfire.Ghost
  alias Bonfire.Ghost.Sync.Members

  @impl true
  def ensure_account(email) when is_binary(email) and email != "" do
    case Ghost.get_member_by_email(email) do
      {:ok, %{"members" => [member | _]}} -> Members.provision_from_ghost_member(member)
      {:ok, _} -> :no_match
      {:error, reason} -> {:error, reason}
    end
  end

  def ensure_account(_), do: :no_match
end
