defmodule Bonfire.Ghost.EmbedHelperTest do
  # `async: false` — flips instance-scoped settings.
  use Bonfire.Ghost.DataCase, async: false

  alias Bonfire.Ghost.EmbedHelper
  alias Bonfire.Common.Settings
  alias Bonfire.Me.Fake

  # network-free article (no resolvable Ghost author/tag)
  defp article do
    %{
      "id" => "ghost_post_1",
      "url" => "https://blog.test/hello-world/",
      "title" => "Hello World",
      "html" => "<p>Body</p>",
      "visibility" => "public",
      "published_at" => "2024-01-15T10:00:00.000Z"
    }
  end

  describe "import_article/2 author resolution" do
    test "falls back to the configured default author when none can be resolved" do
      _author = Fake.fake_user!(%{}, %{username: "ghostbot"})

      Settings.put([:bonfire_ghost, :auto_import_as], "ghostbot",
        scope: :instance,
        skip_boundary_check: true
      )

      assert {:ok, post} = EmbedHelper.import_article(article(), [])
      assert post.id
    end

    test "returns {:error, :no_author} (no crash) when nothing resolves" do
      # no configured default, no current_user, unresolvable Ghost author
      assert {:error, :no_author} = EmbedHelper.import_article(article(), [])
    end

    test "uses an explicit current_user when provided" do
      explicit = Fake.fake_user!(%{}, %{username: "explicit_author"})
      assert {:ok, _post} = EmbedHelper.import_article(article(), current_user: explicit)
    end
  end

  describe "import_article/2 upsert" do
    setup do
      _author = Fake.fake_user!(%{}, %{username: "ghostbot"})

      Settings.put([:bonfire_ghost, :auto_import_as], "ghostbot",
        scope: :instance,
        skip_boundary_check: true
      )

      :ok
    end

    test "updates the existing post instead of creating a duplicate" do
      assert {:ok, post} = EmbedHelper.import_article(article())
      assert {:ok, again} = EmbedHelper.import_article(%{article() | "title" => "Changed"})
      assert again.id == post.id
    end
  end

  describe "hide_article/2" do
    test "is a no-op when no post exists for the URL" do
      assert {:ok, :not_found} = EmbedHelper.hide_article("https://blog.test/missing/")
    end
  end
end
