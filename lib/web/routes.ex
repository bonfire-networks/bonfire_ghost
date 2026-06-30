defmodule Bonfire.Ghost.Web.Routes do
  @moduledoc """
  Route definitions for the Ghost extension.
  """
  @behaviour Bonfire.UI.Common.RoutesModule

  defmacro __using__(_) do
    quote do
      # Ghost blog pages - anyone can view
      scope "/ghost" do
        pipe_through(:browser)

        live("/", Bonfire.Ghost.Web.GhostPostsLive)
      end

      # Ghost settings - admin only
      scope "/ghost", Bonfire.Ghost.Web do
        pipe_through(:browser)
        pipe_through(:admin_required)

        live("/settings", GhostSettingsLive)
      end

      # Ghost webhook receiver — deliberately outside the :browser pipeline
      # (no session, no CSRF, no flash). HMAC signature verification runs
      # as a controller plug; see Bonfire.Ghost.Web.WebhookController.
      # Handles both member.* and post.* events, disambiguated by `:event` path
      # (e.g. member-added, post-published, post-edited, post-unpublished,
      # post-deleted).
      scope "/ghost", Bonfire.Ghost.Web do
        pipe_through(:basic_json)

        post("/webhook/:event", WebhookController, :webhook)
      end
    end
  end
end
