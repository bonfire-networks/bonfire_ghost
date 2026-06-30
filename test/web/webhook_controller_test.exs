defmodule Bonfire.Ghost.Web.WebhookControllerTest do
  # Exercises the controller's path→event mapping + enqueue. The HMAC signature
  # plug is unit-tested separately (verify_ghost_signature_test.exs); here we call
  # the action directly, which (per the controller's design) runs after the payload
  # is already trusted.
  use Bonfire.Ghost.DataCase, async: false
  use Oban.Testing, repo: Bonfire.Common.Repo

  import Plug.Test
  import Plug.Conn

  alias Bonfire.Ghost.Web.WebhookController
  alias Bonfire.Ghost.Workers.ArticleWebhookWorker
  alias Bonfire.Common.Settings

  setup do
    # post events are gated on the opt-in before enqueue
    Settings.put([:bonfire_ghost, :auto_import_articles], true,
      scope: :instance,
      skip_boundary_check: true
    )

    :ok
  end

  defp article_payload do
    %{
      "current" => %{
        "id" => "ghost_post_1",
        "url" => "https://blog.test/hello-world/",
        "title" => "Hello World",
        "html" => "<p>Body</p>",
        "visibility" => "public",
        "published_at" => "2024-01-15T10:00:00.000Z"
      }
    }
  end

  defp call(event, params) do
    conn(:post, "/ghost/webhook/#{event}")
    |> put_req_header("content-type", "application/json")
    |> WebhookController.webhook(Map.put(params, "event", event))
  end

  test "post.published enqueues an ArticleWebhookWorker job and returns 200" do
    conn = call("post.published", %{"post" => article_payload()})

    assert conn.status == 200

    assert_enqueued(
      worker: ArticleWebhookWorker,
      args: %{"event" => "post.published", "post" => %{"id" => "ghost_post_1"}}
    )
  end

  test "does not enqueue (but still acks 200) when auto-import is disabled" do
    Settings.put([:bonfire_ghost, :auto_import_articles], false,
      scope: :instance,
      skip_boundary_check: true
    )

    conn = call("post.published", %{"post" => article_payload()})

    assert conn.status == 200
    refute_enqueued(worker: ArticleWebhookWorker)
  end

  test "post.deleted uses the `previous` object" do
    payload = %{
      "post" => %{"previous" => %{"id" => "ghost_post_1", "url" => "https://blog.test/x/"}}
    }

    conn = call("post.deleted", payload)

    assert conn.status == 200
    assert_enqueued(worker: ArticleWebhookWorker, args: %{"event" => "post.deleted"})
  end

  test "still accepts the legacy hyphenated member alias" do
    conn = call("member-added", %{"member" => %{"current" => %{"email" => "a@b.test"}}})
    assert conn.status == 200
  end

  test "returns 400 when the post object is missing" do
    conn = call("post.published", %{"post" => %{}})
    assert conn.status == 400
    refute_enqueued(worker: ArticleWebhookWorker)
  end

  test "returns 404 for an unknown event path" do
    conn = call("post.nonsense", %{"post" => article_payload()})
    assert conn.status == 404
  end
end
