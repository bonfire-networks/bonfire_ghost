defmodule Bonfire.Ghost.Workers.MemberWebhookWorker do
  @moduledoc """
  Oban worker that processes Ghost `member.*` webhooks asynchronously.

  The HTTP controller enqueues a job per webhook so the response stays fast
  (Ghost retries slow endpoints) and so transient DB errors get Oban's retry
  machinery for free. Signature verification happens *before* enqueue — by
  the time a job runs, the payload is trusted.

  Args shape:

      %{
        "event" => "member.added" | "member.edited" | "member.deleted",
        "member" => %{...},   # Ghost member payload (previous, current)
        "previous" => %{...}  # optional, present on member.edited
      }
  """

  use Oban.Worker, queue: :ghost_webhooks, max_attempts: 5

  import Untangle

  alias Bonfire.Ghost.Sync.Members

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event" => event, "member" => member}}) do
    dispatch(event, member)
  end

  def perform(%Oban.Job{args: args}) do
    error(args, "MemberWebhookWorker: unrecognized args shape")
    {:cancel, :invalid_args}
  end

  defp dispatch("member.added", member), do: Members.provision_from_ghost_member(member)
  defp dispatch("member.edited", member), do: Members.provision_from_ghost_member(member)
  defp dispatch("member.deleted", member), do: Members.remove_member(member)

  defp dispatch(event, _member) do
    warn(event, "MemberWebhookWorker: unknown event — cancelling job")
    {:cancel, {:unknown_event, event}}
  end
end
