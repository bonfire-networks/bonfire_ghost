defmodule Bonfire.Ghost.Sync.Members do
  @moduledoc """
  Syncs Ghost members into Bonfire users/accounts.

  **Stub.** Step 2 of the Ghost integration plan only wires the webhook
  pipeline up to an Oban worker; real provisioning/reconciliation lands in
  Steps 3-4. Each function here logs the call and returns `:ok` so the
  end-to-end flow (webhook → signature verified → worker enqueued → worker
  runs) can be exercised without creating accounts yet.

  The surface is kept small and stable so the worker and any future callers
  don't have to change when the bodies are filled in.
  """

  import Untangle

  @doc """
  Creates (or updates) a local account/user from a Ghost member payload.

  Called on `member.added` webhooks and as a fallback during passwordless
  login when the local record is missing but Ghost knows the email.
  """
  @spec provision_from_ghost_member(map()) :: {:ok, :stubbed}
  def provision_from_ghost_member(ghost_member) when is_map(ghost_member) do
    info(ghost_member["email"], "Sync.Members.provision_from_ghost_member — stubbed")
    {:ok, :stubbed}
  end

  @doc """
  Handles `member.deleted` — reconciles local state so the user loses
  ghost-tier circle membership. We do **not** delete the Bonfire account.
  """
  @spec remove_member(map()) :: {:ok, :stubbed}
  def remove_member(ghost_member) when is_map(ghost_member) do
    info(ghost_member["email"], "Sync.Members.remove_member — stubbed")
    {:ok, :stubbed}
  end

  @doc """
  Given a Bonfire user and the current Ghost tier slugs they should belong
  to, add/remove `ghost_tier:*` circle memberships to match.
  """
  @spec reconcile_circles(term(), [String.t()]) :: {:ok, :stubbed}
  def reconcile_circles(user, tier_slugs) when is_list(tier_slugs) do
    info(%{user: user, tier_slugs: tier_slugs}, "Sync.Members.reconcile_circles — stubbed")
    {:ok, :stubbed}
  end
end
