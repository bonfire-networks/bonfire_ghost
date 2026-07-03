defmodule Bonfire.Ghost.Sync.Tiers do
  @moduledoc """
  Syncs Ghost membership tiers into Bonfire circles.

  For each Ghost tier we ensure a **circle** named `ghost_tier:<slug>` exists
  at instance scope. Members are added to it later by
  `Bonfire.Ghost.Sync.Members`. Its `extra_info.summary` is
  `"Ghost tier: <display_name>"`; `extra_info.info` keeps the slug, Ghost tier
  id, and display name for diffing on re-sync.

  This module deliberately does **not** create roles, ACLs, or grants. Admins
  compose those themselves using these circles as subjects — same as any other
  circle in Bonfire's boundaries system.

  Re-running the sync is idempotent: it only creates missing circles, refreshes
  the circle's display-name metadata when it drifts from Ghost, and marks any
  orphaned `ghost_tier:*` circles (tier removed upstream) by appending
  "(archived)" to their summary — nothing is ever deleted.

  See `Bonfire.Ghost.AdminAPI.list_tiers/2` for the upstream Ghost API.
  """

  import Untangle

  alias Bonfire.Boundaries.Circles
  alias Bonfire.Boundaries.Scaffold.Instance, as: InstanceScaffold
  alias Bonfire.Common.Repo
  alias Bonfire.Data.Identity.ExtraInfo
  alias Bonfire.Ghost
  alias Bonfire.Ghost.AdminAPI
  alias Ecto.Changeset

  @circle_prefix "ghost_tier:"

  # Ghost slugs are lowercase alphanumeric with dashes/underscores; enforce
  # this as basic input sanitation before composing the circle name.
  @slug_regex ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/

  @archived_marker " (archived)"

  @type sync_summary :: %{
          created: non_neg_integer(),
          updated: non_neg_integer(),
          unchanged: non_neg_integer(),
          archived: non_neg_integer(),
          errors: [{String.t(), term()}]
        }

  @empty_summary %{created: 0, updated: 0, unchanged: 0, archived: 0, errors: []}

  @doc """
  Fetches tiers from Ghost and reconciles them with local circles.

  Returns `{:ok, summary, tiers}` on success (the raw Ghost tier payloads are
  returned so the caller can refresh its UI state without re-fetching) or
  `{:error, reason}` if the upstream Ghost call fails.

  The Ghost fetch uses `include: "benefits,monthly_price,yearly_price"` — the
  richer payload needed to render the tier cards in the settings UI — so the
  returned list is safe to drop straight into the page.
  """
  @spec sync_all(keyword()) :: {:ok, sync_summary(), [map()]} | {:error, term()}
  def sync_all(opts \\ []) do
    with {:ok, c} <- Ghost.admin_client(),
         {:ok, %{"tiers" => tiers}} when is_list(tiers) <-
           AdminAPI.list_tiers(c, include: "benefits,monthly_price,yearly_price") do
      {:ok, sync_tiers(tiers, opts), tiers}
    end
  end

  @doc """
  Reconciles a pre-fetched list of Ghost tier payloads with local circles.

  Exposed primarily for tests — production code goes through `sync_all/1`.
  """
  @spec sync_tiers([map()], keyword()) :: sync_summary()
  def sync_tiers(tiers, opts) when is_list(tiers) do
    summary =
      Enum.reduce(tiers, @empty_summary, fn tier, acc ->
        case sync_tier(tier, opts) do
          {:ok, state} when state in [:created, :updated, :unchanged] ->
            Map.update!(acc, state, &(&1 + 1))

          {:error, reason} ->
            Map.update!(acc, :errors, &[{tier["slug"], reason} | &1])
        end
      end)

    active_slugs =
      tiers
      |> Enum.map(& &1["slug"])
      |> Enum.reject(&is_nil/1)

    archive_orphans(active_slugs, summary, opts)
  end

  @doc false
  def sync_tier(tier, opts \\ [])

  def sync_tier(
        %{"slug" => slug, "name" => name, "id" => ghost_tier_id} = tier,
        _opts
      )
      when is_binary(slug) and is_binary(name) do
    if Regex.match?(@slug_regex, slug) do
      circle_name = @circle_prefix <> slug

      case ensure_circle(circle_name, name, slug, ghost_tier_id, tier["type"]) do
        {:ok, _circle, state} -> {:ok, state}
        {:error, reason} -> {:error, reason}
      end
    else
      error(slug, "Ghost tier slug failed validation — refusing to use as circle name")
      {:error, :invalid_slug}
    end
  end

  def sync_tier(tier, _opts) do
    error(tier, "Ghost tier payload missing slug/name/id")
    {:error, :invalid_tier}
  end

  # --- Circle --------------------------------------------------------------

  defp ensure_circle(circle_name, display_name, slug, ghost_tier_id, type) do
    case Circles.get_by_name(circle_name, InstanceScaffold.admin_circle()) do
      {:ok, circle} ->
        maybe_refresh_circle(circle, display_name, slug, ghost_tier_id, type)

      {:error, :not_found} ->
        attrs = %{
          named: %{name: circle_name},
          extra_info: %{
            summary: circle_summary(display_name),
            info: circle_info(slug, ghost_tier_id, display_name, type)
          }
        }

        with {:ok, circle} <- Circles.create(:instance, attrs) do
          {:ok, circle, :created}
        end
    end
  end

  defp maybe_refresh_circle(circle, display_name, slug, ghost_tier_id, type) do
    # `Circles.get_by_name` preloads `:named` + `:caretaker` but not `:extra_info`
    circle = Repo.maybe_preload(circle, :extra_info)
    expected_summary = circle_summary(display_name)
    expected_info = circle_info(slug, ghost_tier_id, display_name, type)

    current = extra_info(circle)

    if current.summary == expected_summary and maps_equivalent?(current.info, expected_info) do
      {:ok, circle, :unchanged}
    else
      update_extra_info(circle, expected_summary, expected_info)
    end
  end

  # Side-steps `Circles.edit/3` — that path re-casts every Circle has-one
  # association and requires a `%User{}`, neither of which we want for a
  # metadata-only sync invoked from a webhook worker with no current user.
  defp update_extra_info(circle, summary, info) do
    extra = circle.extra_info || %ExtraInfo{id: circle.id}

    changeset =
      extra
      |> Changeset.cast(%{summary: summary, info: info}, [:summary, :info])
      |> Changeset.force_change(:id, circle.id)

    with {:ok, updated_extra} <- Repo.insert_or_update(changeset) do
      {:ok, %{circle | extra_info: updated_extra}, :updated}
    end
  end

  defp extra_info(%{extra_info: %{summary: summary, info: info}}) when is_map(info),
    do: %{summary: summary, info: info}

  defp extra_info(%{extra_info: %{summary: summary}}), do: %{summary: summary, info: %{}}
  defp extra_info(_), do: %{summary: nil, info: %{}}

  defp circle_summary(display_name), do: "Ghost tier: #{display_name}"

  # Atom keys (not strings): `Circles.create` runs the attrs through
  # `Enums.input_to_atoms`, which drops string keys whose atom isn't already
  # registered in the BEAM atom table. Literal atom keys here guarantee they
  # are registered at module load, so the full info map survives the write.
  defp circle_info(slug, ghost_tier_id, display_name, type) do
    %{
      ghost_tier_slug: slug,
      ghost_tier_id: ghost_tier_id,
      display_name: display_name,
      ghost_tier_type: type
    }
  end

  # jsonb roundtrips give us string keys even if we wrote atoms — normalize
  # before comparing so idempotency holds on re-sync.
  defp maps_equivalent?(a, b) when is_map(a) and is_map(b),
    do: stringify_keys(a) == stringify_keys(b)

  defp maps_equivalent?(a, b), do: a == b

  defp stringify_keys(%{} = map),
    do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  # --- Archived tiers ------------------------------------------------------

  defp archive_orphans(active_slugs, summary, _opts) do
    Circles.list_my(:instance)
    |> Enum.filter(&ghost_tier_circle?/1)
    |> Enum.reject(&(circle_slug(&1) in active_slugs))
    |> Enum.reduce(summary, fn circle, acc ->
      case mark_archived(circle) do
        {:ok, :archived} -> Map.update!(acc, :archived, &(&1 + 1))
        {:ok, :unchanged} -> acc
        {:error, reason} -> Map.update!(acc, :errors, &[{circle_slug(circle), reason} | &1])
      end
    end)
  end

  defp ghost_tier_circle?(%{named: %{name: name}}) when is_binary(name),
    do: String.starts_with?(name, @circle_prefix)

  defp ghost_tier_circle?(_), do: false

  defp circle_slug(%{named: %{name: name}}) when is_binary(name),
    do: String.replace_prefix(name, @circle_prefix, "")

  defp circle_slug(_), do: nil

  defp mark_archived(circle) do
    # already preloaded by `Circles.list_my/1` → `query/1`
    %{summary: summary, info: info} = extra_info(circle)
    summary = summary || ""

    if String.ends_with?(summary, @archived_marker) do
      {:ok, :unchanged}
    else
      case update_extra_info(circle, summary <> @archived_marker, info) do
        {:ok, _circle, :updated} -> {:ok, :archived}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
