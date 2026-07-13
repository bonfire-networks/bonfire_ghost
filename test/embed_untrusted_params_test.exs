defmodule Bonfire.Ghost.EmbedUntrustedParamsTest do
  @moduledoc """
  Regression tests for the unauthenticated embed import path.

  `EmbedHelper.get_or_create_post_for_article/3` is reachable by anyone: the comments
  embed runs on third-party pages and its opts come straight from URL params the visitor
  controls. These tests pin the guarantee that a caller there cannot choose the post's
  author, audience, destination, or dedup key.

  The trusted entrypoint (`import_article/2`, used by the webhook worker and the operator
  backfill) still honours those opts — covered in `embed_helper_test.exs`.
  """
  # `async: false` — patches instance-level Ghost client/config helpers and touches
  # instance-wide circles.
  use Bonfire.Ghost.DataCase, async: false

  alias Bonfire.Ghost
  alias Bonfire.Ghost.API
  alias Bonfire.Ghost.EmbedHelper
  alias Bonfire.Me.Fake

  @slug "hello-world"
  @canonical "https://blog.test/hello-world/"

  defp article(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "ghost_post_1",
        "url" => @canonical,
        "title" => "Hello World",
        "html" => "<p>Body</p>",
        "visibility" => "public",
        "published_at" => "2024-01-15T10:00:00.000Z"
      },
      overrides
    )
  end

  # Serve the article over a stubbed Content API (no Admin key → no Ghost staff author
  # resolves, which is exactly the Content-API-only setup where the forgery bites).
  defp stub_ghost!(article) do
    Repatch.patch(Ghost, :configured?, fn -> true end)
    Repatch.patch(Ghost, :client, fn -> {:ok, :client} end)
    Repatch.patch(API, :get_post_by_slug, fn :client, _slug -> {:ok, %{"posts" => [article]}} end)
    :ok
  end

  defp creator_id(post) do
    Bonfire.Common.Repo.maybe_preload(post, :created)
    |> case do
      %{created: %{creator_id: creator_id}} -> creator_id
      _ -> nil
    end
  end

  describe "author forgery (H1)" do
    test "an embed-supplied `creator` does NOT become the post's author" do
      import_bot = Fake.fake_user!(%{}, %{username: "ghostbot"})
      victim = Fake.fake_user!(%{}, %{username: "victim"})

      Process.put([:bonfire_ghost, :auto_import_as], import_bot.id)
      stub_ghost!(article())

      assert {:ok, post} =
               EmbedHelper.get_or_create_post_for_article(@slug, @canonical,
                 creator: victim.id,
                 current_user: victim
               )

      assert creator_id(post) == import_bot.id,
             "embed param forged the post author — must fall back to the configured import author"

      refute creator_id(post) == victim.id
    end

    test "with no configured import author, an embed cannot create a post at all" do
      victim = Fake.fake_user!(%{}, %{username: "victim"})
      stub_ghost!(article())

      # nothing server-side to attribute to → refuse, rather than trust the caller
      assert {:error, :no_author} =
               EmbedHelper.get_or_create_post_for_article(@slug, @canonical,
                 creator: victim.id,
                 current_user: victim
               )

      assert {:error, _} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(@canonical)
    end
  end

  describe "paywall bypass via `boundary` (H1)" do
    setup do
      import_bot = Fake.fake_user!(%{}, %{username: "ghostbot"})
      Process.put([:bonfire_ghost, :auto_import_as], import_bot.id)

      Bonfire.Ghost.Sync.Tiers.sync_tiers(
        [%{"id" => "t_gold", "slug" => "gold", "name" => "Gold", "type" => "paid"}],
        []
      )

      :ok
    end

    test "an embed-supplied `boundary` cannot make a paid article publicly readable" do
      outsider = Fake.fake_user!()
      paid = article(%{"visibility" => "paid"})
      stub_ghost!(paid)

      assert {:ok, post} =
               EmbedHelper.get_or_create_post_for_article(@slug, @canonical, boundary: "public")

      # the paywall mapping (`:see` preview, `:read` only for ghost_tier circles) must hold
      assert Bonfire.Boundaries.can?(outsider, :see, post)

      refute Bonfire.Boundaries.can?(outsider, :read, post),
             "embed param overrode the paywall — paid article became publicly readable"

      refute Bonfire.Boundaries.can?(nil, :read, post)
    end
  end

  describe "dedup / amplification (H1)" do
    setup do
      import_bot = Fake.fake_user!(%{}, %{username: "ghostbot"})
      Process.put([:bonfire_ghost, :auto_import_as], import_bot.id)
      :ok
    end

    test "a varying caller URL does not mint duplicate posts for one article" do
      stub_ghost!(article())

      # the embedding page reports its own URL — query strings (utm params, or an
      # attacker simply varying them) must not defeat dedup
      assert {:ok, first} =
               EmbedHelper.get_or_create_post_for_article(@slug, @canonical <> "?utm_source=a")

      assert {:ok, second} =
               EmbedHelper.get_or_create_post_for_article(@slug, @canonical <> "?utm_source=b")

      assert first.id == second.id,
             "each distinct caller URL created a new post for the same article"
    end

    test "the canonical URI stored is the one Ghost reports, not the caller's" do
      stub_ghost!(article())

      assert {:ok, post} =
               EmbedHelper.get_or_create_post_for_article(@slug, "https://evil.test/not-my-url/")

      assert {:ok, %{id: id}} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(@canonical)
      assert id == post.id

      assert {:error, _} =
               Bonfire.Federate.ActivityPub.Peered.get_by_uri("https://evil.test/not-my-url/")
    end
  end
end
