defmodule Bonfire.Ghost.Workers.ArticleWebhookWorker do
  @moduledoc """
  Oban worker that processes Ghost `post.*` webhooks asynchronously, importing
  articles as Bonfire posts.

  Mirrors `Bonfire.Ghost.Workers.MemberWebhookWorker`: the HTTP controller
  verifies the signature and enqueues a job per webhook so the response stays
  fast and transient errors get Oban's retries.

  Auto-import is **opt-in** — gated on the instance setting
  `[:bonfire_ghost, :auto_import_articles]`. When off, jobs are cancelled.

  Args shape:

      %{
        "event" => "post.published" | "post.published.edited"
                 | "post.unpublished" | "post.deleted",
        "post" => %{...}   # the Ghost article object (post.current / post.previous)
      }

  `post.published`/`post.published.edited` upsert the post; `post.unpublished`/
  `post.deleted` **hide** it instance-wide (never delete) so any attached thread
  is preserved — see `Bonfire.Ghost.EmbedHelper`.
  """

  use Oban.Worker, queue: :ghost_webhooks, max_attempts: 5

  import Untangle

  alias Bonfire.Ghost.EmbedHelper
  alias Bonfire.Common.Settings
  require Bonfire.Common.Settings

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event" => event, "post" => post}}) do
    # Defense in depth: the controller also gates on this before enqueuing, but
    # the setting could have been toggled off between enqueue and run.
    if auto_import_enabled?() do
      dispatch(event, post)
    else
      debug(event, "Ghost article auto-import is disabled — cancelling job")
      {:cancel, :disabled}
    end
  end

  def perform(%Oban.Job{args: args}) do
    error(args, "ArticleWebhookWorker: unrecognized args shape")
    {:cancel, :invalid_args}
  end

  @doc "Whether Ghost article auto-import is enabled for this instance (opt-in)."
  def auto_import_enabled? do
    Settings.get([:bonfire_ghost, :auto_import_articles], false, :instance) in [
      true,
      "true",
      "1",
      "yes"
    ]
  end

  defp dispatch(event, post) when event in ["post.published", "post.published.edited"],
    do: EmbedHelper.import_article(post, [])

  defp dispatch(event, post) when event in ["post.unpublished", "post.deleted"],
    do: EmbedHelper.hide_article(post, [])

  defp dispatch(event, _post) do
    warn(event, "ArticleWebhookWorker: unknown event — cancelling job")
    {:cancel, {:unknown_event, event}}
  end
end
