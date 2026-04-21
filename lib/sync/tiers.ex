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

  See `Bonfire.Ghost.list_tiers/1` for the upstream Ghost API.
  """

  import Untangle

  alias Bonfire.Boundaries.Circles
  alias Bonfire.Boundaries.Scaffold.Instance, as: InstanceScaffold
  alias Bonfire.Common.Repo
  alias Bonfire.Ghost

  @circle_prefix "ghost_tier:"

  # Ghost slugs are lowercase alphanumeric with dashes/underscores; enforce
  # this as basic input sanitation before composing the circle name.
  @slug_regex ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/

  @archived_marker " (archived)"

  # `Circles.edit/3` runs params through `Enums.input_to_atoms`, which silently
  # drops string keys whose atom doesn't already exist in the BEAM atom table
  # (turning them into `nil` keys). Declaring them here as a module attribute
  # ensures they're present before `info` is ever cast, so the keys survive.
  @info_atoms [:ghost_tier_slug, :ghost_tier_id, :display_name]

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
    with {:ok, %{"tiers" => tiers}} when is_list(tiers) <-
           Ghost.list_tiers(include: "benefits,monthly_price,yearly_price") do
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
        %{"slug" => slug, "name" => name, "id" => ghost_tier_id},
        opts
      )
      when is_binary(slug) and is_binary(name) do
    if Regex.match?(@slug_regex, slug) do
      circle_name = @circle_prefix <> slug
      scoped_opts = Keyword.put(opts, :scope, :instance)

      with {:ok, _circle, state} <-
             ensure_circle(circle_name, name, slug, ghost_tier_id, scoped_opts) do
        {:ok, state}
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

  defp ensure_circle(circle_name, display_name, slug, ghost_tier_id, opts) do
    case Circles.get_by_name(circle_name, InstanceScaffold.admin_circle()) do
      {:ok, circle} ->
        maybe_refresh_circle(circle, display_name, slug, ghost_tier_id, opts)

      {:error, :not_found} ->
        attrs = %{
          named: %{name: circle_name},
          extra_info: %{
            summary: circle_summary(display_name),
            info: circle_info(slug, ghost_tier_id, display_name)
          }
        }

        with {:ok, circle} <- Circles.create(:instance, attrs) do
          {:ok, circle, :created}
        end
    end
  end

  defp maybe_refresh_circle(circle, display_name, slug, ghost_tier_id, opts) do
    # `Circles.get_by_name` preloads `:named` + `:caretaker` but not `:extra_info`
    circle = Repo.maybe_preload(circle, :extra_info)
    expected_summary = circle_summary(display_name)
    expected_info = circle_info(slug, ghost_tier_id, display_name)

    current = extra_info(circle)

    if current.summary == expected_summary and current.info == expected_info do
      {:ok, circle, :unchanged}
    else
      update_circle_extra_info(circle, expected_summary, expected_info, opts)
    end
  end

  # `Circles.edit/3` re-casts every Circle has-one association, so we must echo
  # the existing `:named` back even though we're only changing `:extra_info` —
  # otherwise Ecto's `cast_assoc(:named)` tries to replace the loaded mixin
  # with an empty record and crashes on the NOT NULL id constraint.
  defp update_circle_extra_info(circle, summary, info, opts) do
    user = Keyword.get(opts, :current_user)
    attrs = %{named: %{name: circle.named.name}, extra_info: %{summary: summary, info: info}}

    with {:ok, updated} <- Circles.edit(circle, user, attrs) do
      {:ok, updated, :updated}
    end
  end

  defp extra_info(%{extra_info: %{summary: summary, info: info}}) when is_map(info),
    do: %{summary: summary, info: info}

  defp extra_info(%{extra_info: %{summary: summary}}), do: %{summary: summary, info: %{}}
  defp extra_info(_), do: %{summary: nil, info: %{}}

  defp circle_summary(display_name), do: "Ghost tier: #{display_name}"

  defp circle_info(slug, ghost_tier_id, display_name) do
    %{
      "ghost_tier_slug" => slug,
      "ghost_tier_id" => ghost_tier_id,
      "display_name" => display_name
    }
  end

  # --- Archived tiers ------------------------------------------------------

  defp archive_orphans(active_slugs, summary, opts) do
    Circles.list_my(:instance)
    |> Enum.filter(&ghost_tier_circle?/1)
    |> Enum.reject(&(circle_slug(&1) in active_slugs))
    |> Enum.reduce(summary, fn circle, acc ->
      case mark_archived(circle, opts) do
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

  defp mark_archived(circle, opts) do
    # already preloaded by `Circles.list_my/1` → `query/1`
    %{summary: summary, info: info} = extra_info(circle)
    summary = summary || ""

    if String.ends_with?(summary, @archived_marker) do
      {:ok, :unchanged}
    else
      case update_circle_extra_info(circle, summary <> @archived_marker, info, opts) do
        {:ok, _circle, :updated} -> {:ok, :archived}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
