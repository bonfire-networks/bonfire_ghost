defmodule Bonfire.Ghost.LoginEmailProvider do
  @moduledoc """
  Adapter implementing `Bonfire.UI.Me.LoginEmailProvider` for Ghost CMS.

  Auto-discovered at startup via `Bonfire.Common.ExtensionBehaviour`. Called
  from `Bonfire.UI.Me.ForgotPasswordController.create/2` when an unknown email
  is submitted so that a Ghost member with an active tier can seamlessly log in
  — the local account+user+circles are provisioned on the fly and then the
  standard magic-link flow picks them up.

  Ghost *staff* (owner/admin/editor/author/contributor) are a separate Ghost entity:
  they don't appear in the Members API and Ghost emits no webhooks for them, so when
  the member lookup misses we fall back to a staff lookup. Staff bypass the
  `required_tier` gate — they're the site's own team and have no tiers to gate on.

  Note this path only runs for emails with **no local account** — an existing account
  always gets its magic link without Ghost being consulted. That is only safe because
  the tier gate (`Bonfire.Ghost.TierGate`) is now enforced on every path that can
  *create* an account, i.e. in `Bonfire.Ghost.Sync.Members.provision_from_ghost_member/2`.
  """
  @behaviour Bonfire.UI.Me.LoginEmailProvider

  import Untangle

  alias Bonfire.Ghost
  alias Bonfire.Ghost.AdminAPI
  alias Bonfire.Ghost.Sync.Members
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
            # A member failing the tier gate can still be staff (e.g. subscribed to their
            # own newsletter on a free tier) — staff bypass the gate. If they're not staff
            # either, this returns :no_match with no hint email — the dispatcher already
            # sends one when all providers `:no_match`.
            ensure_staff_account(c, email)
          end

        {:ok, _} ->
          # Not a member at all — but Ghost staff (owner/admin/editor/author/contributor)
          # are a separate entity that never appears in the Members API, so check them too.
          ensure_staff_account(c, email)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def ensure_account(_), do: :no_match

  # Staff have no tiers, so the `required_tier` gate deliberately does not apply to them —
  # they're the site's own team. Ghost-side suspension is honored instead: it is the ONLY
  # offboarding control for staff, and Ghost's /users/ lookup returns suspended/locked rows.
  defp ensure_staff_account(client, email) do
    case AdminAPI.get_user_by_email(client, email) do
      {:ok, %{"users" => [staff | _]}} ->
        if AdminAPI.staff_may_sign_in?(staff) do
          # identities that split before the identity link existed get reconnected
          # to their stranded account instead of forking yet another one (the
          # client lets it verify an unlabelled account isn't a member's)
          Members.claim_split_author(staff, client: client) ||
            Members.provision_from_ghost_staff(staff)
        else
          info(email, "Ghost staff exists but is suspended in Ghost — not provisioning")
          :no_match
        end

      {:ok, _} ->
        # the sign-in response is deliberately neutral, so this log is the only place a
        # "why was my contributor told to subscribe?" report can be answered from
        info(email, "Ghost has no staff user with this email — sending the signup hint")
        :no_match

      {:error, reason} ->
        error(
          reason,
          "Ghost staff lookup FAILED — treating as unknown, but it may be a real staffer being turned away"
        )

        {:error, reason}
    end
  end

  # The gate itself lives in `Bonfire.Ghost.TierGate` — it is enforced on every
  # provisioning path (webhooks, backfill), not just this one. Checking it here too
  # keeps the staff fallback below reachable: a member who fails the gate may still
  # be staff.
  defp tier_allowed?(member), do: Bonfire.Ghost.TierGate.allowed?(member)
end
