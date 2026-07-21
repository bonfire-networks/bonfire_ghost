defmodule Bonfire.Ghost.TierGate do
  @moduledoc """
  The single decision point for "may this Ghost member get a login-capable Bonfire account?"

  The instance admin picks the required tiers on `/ghost/settings` ("Membership
  tiers" → one toggle per tier), which writes `[:bonfire_ghost, :required_tier,
  <slug>]` at instance scope. **No tier toggled on means the gate is off** and any
  Ghost member is allowed — that is the documented default, not a bug.

  This module exists because the gate used to live only in
  `Bonfire.Ghost.LoginEmailProvider`, which is consulted *only for emails with no
  local account* (`ForgotPasswordController.maybe_run_login_email_providers/1`).
  Every other provisioning path — the `member.added`/`member.edited` webhooks and
  the "Sync members" backfill — created accounts without asking, so a free member
  who signed up on Ghost got an account, and their next login found that account
  and never reached the gate. The gate is therefore enforced in
  `Bonfire.Ghost.Sync.Members.provision_from_ghost_member/2` itself, so a new call
  site cannot forget it.

  Ghost *staff* are exempt: they are a separate Ghost entity with no tiers at all
  (see `Bonfire.Ghost.Sync.Members.provision_from_ghost_staff/2`, which owns that
  exemption).
  """

  import Untangle
  use Bonfire.Common.E

  alias Bonfire.Common.Settings
  require Bonfire.Common.Settings

  alias Bonfire.Ghost
  alias Bonfire.Ghost.AdminAPI

  @doc """
  The tier slugs an admin has marked as required. `[]` means the gate is off.
  """
  @spec required_slugs() :: [String.t()]
  def required_slugs do
    # MUST be `Settings.get(..., :instance)`: `Config.get/3`'s 3rd arg is an **otp_app**, not a
    # scope, so it would read a non-existent `:instance` app, always return the default, and let
    # every member through the gate. The settings UI writes these at instance scope.
    required_map = Settings.get([:bonfire_ghost, :required_tier], %{}, :instance) || %{}

    # not `v == true`: the settings toggle can store the string "true" (cf. auto_import_enabled?/0),
    # which would leave required_slugs empty and again let every member through
    required_map
    |> Enum.filter(fn {_k, v} -> v in [true, "true", "1", "yes"] end)
    |> Enum.map(fn {k, _v} -> to_string(k) end)
  end

  @doc "Is the gate switched on at all (i.e. is at least one tier required)?"
  @spec enabled?() :: boolean()
  def enabled?, do: required_slugs() != []

  @doc """
  Does this Ghost member payload satisfy the required tiers?

  Pass `client:` to reuse an already-built Admin API client (the backfill does).

  Fails **closed**: a payload we cannot resolve tiers for is refused rather than
  waved through, since being wrong in the other direction hands out accounts.
  """
  @spec allowed?(map(), keyword()) :: boolean()
  def allowed?(member, opts \\ [])

  def allowed?(member, opts) when is_map(member) do
    case required_slugs() do
      [] ->
        true

      required ->
        member
        |> member_slugs(opts)
        |> Enum.any?(&(&1 in required))
    end
  end

  def allowed?(member, _opts) do
    error(member, "Not a Ghost member payload — refusing the tier gate")
    false
  end

  # Ghost's `member.*` webhook payload is not contractually guaranteed to carry
  # `tiers`, and reading a missing key as "no tiers" would deny a paying member.
  # So: use the list when it's there, otherwise ask Ghost. Note the lookup only
  # ever runs when the gate is ON — an instance with no required tiers costs no
  # extra API call.
  defp member_slugs(member, opts) do
    case Map.get(member, "tiers") do
      tiers when is_list(tiers) -> slugs(tiers)
      _ -> slugs(fetch_tiers(member, opts))
    end
  end

  defp slugs(tiers) when is_list(tiers) do
    tiers
    |> Enum.map(&e(&1, "slug", nil))
    |> Enum.reject(&is_nil/1)
  end

  defp slugs(_), do: []

  defp fetch_tiers(member, opts) do
    with email when is_binary(email) and email != "" <- member["email"],
         {:ok, client} <- client(opts),
         {:ok, %{"members" => [%{"tiers" => tiers} | _]}} when is_list(tiers) <-
           AdminAPI.get_member_by_email(client, email, include: "tiers") do
      tiers
    else
      other ->
        warn(
          other,
          "Ghost payload carried no tiers and they could not be fetched — failing the tier gate closed"
        )

        []
    end
  end

  defp client(opts) do
    case opts[:client] do
      nil -> Ghost.admin_client()
      client -> {:ok, client}
    end
  end
end
