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
  alias Bonfire.Common.Settings
  require Bonfire.Common.Settings
  use Bonfire.Common.E
  use Bonfire.Common.Config

  # Shape check only, to keep junk input (this runs on the raw, unvalidated forgot-password field)
  # from costing a Ghost round-trip. Deliberately permissive: injection is handled by
  # `AdminAPI.escape_nql_string/1`, and quotes are legal in a local part (o'brien@…).
  @email_regex ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  @impl true
  def ensure_account(email) when is_binary(email) and email != "" do
    with true <- Regex.match?(@email_regex, email) or :no_match,
         {:ok, c} <- Ghost.admin_client() do
      case AdminAPI.get_member_by_email(c, email, include: "tiers") do
        {:ok, %{"members" => [member | _]}} ->
          if tier_allowed?(member) do
            Members.provision_from_ghost_member(member)
          else
            # no hint email here — the dispatcher already sends one when all providers `:no_match`
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
    # MUST be `Settings.get(..., :instance)`: `Config.get/3`'s 3rd arg is an **otp_app**, not a
    # scope, so it would read a non-existent `:instance` app, always return the default, and let
    # every member through the gate. The settings UI writes these at instance scope.
    required_map =
      Settings.get([:bonfire_ghost, :required_tier], %{}, :instance) || %{}

    # not `v == true`: the settings toggle can store the string "true" (cf. auto_import_enabled?/0),
    # which would leave required_slugs empty and again let every member through
    required_slugs =
      required_map
      |> Enum.filter(fn {_, v} -> v in [true, "true", "1", "yes"] end)
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
end
