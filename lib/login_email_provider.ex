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
  alias Bonfire.Ghost.AdminAPI
  alias Bonfire.Ghost.Sync.Members
  use Bonfire.Common.E
  use Bonfire.Common.Config

  @impl true
  def ensure_account(email) when is_binary(email) and email != "" do
    with {:ok, c} <- Ghost.admin_client() do
      case AdminAPI.get_member_by_email(c, email, include: "tiers") do
        {:ok, %{"members" => [member | _]}} ->
          if tier_allowed?(member) do
            Members.provision_from_ghost_member(member)
          else
            maybe_send_registration_hint(email)
            :no_match
          end

        {:ok, _} ->
          :no_match

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def ensure_account(_), do: :no_match

  defp tier_allowed?(member) do
    required_map =
      Config.get([:bonfire_ghost, :required_tier], %{}, :instance) || %{}

    required_slugs =
      required_map
      |> Enum.filter(fn {_, v} -> v == true end)
      |> Enum.map(fn {k, _} -> to_string(k) end)

    if required_slugs == [] do
      true
    else
      member_slugs =
        e(member, "tiers", [])
        |> Enum.map(&e(&1, "slug", nil))
        |> Enum.reject(&is_nil/1)

      Enum.any?(member_slugs, &(&1 in required_slugs))
    end
  end

  defp maybe_send_registration_hint(email) do
    with url when is_binary(url) and url != "" <-
           Config.get([:bonfire_ui_me, :login, :external_signup_url]),
         mailer when not is_nil(mailer) <- Bonfire.Me.Mails.mailer() do
      Bonfire.Me.Mails.registration_hint(url)
      |> mailer.send_now(email)
    end
  end
end
