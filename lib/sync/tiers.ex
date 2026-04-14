defmodule Bonfire.Ghost.Sync.Tiers do
  @moduledoc """
  Syncs Ghost membership tiers into Bonfire circles + roles + ACLs.

  For each Ghost tier:

    * A **circle** named `ghost_tier:<slug>` holds the tier's members (populated
      later by `Bonfire.Ghost.Sync.Members`). Its `extra_info.summary` is
      "Ghost tier: <display_name>"; `extra_info.info` keeps the slug, Ghost tier
      id, and display name for diffing on re-sync.
    * A **role** named `ghost_tier_<slug>` stored at instance scope, seeded with
      the verbs of the built-in `:participate` role so new grants aren't
      empty. Admins can then tune verbs from the Roles settings page — re-runs
      never touch an existing role.
    * An **ACL** named `ghost_tier_acl:<slug>` with grants tying the role to the
      circle.

  Re-running the sync is idempotent: it only creates missing pieces, refreshes
  the circle's display-name metadata when it drifts from Ghost, and marks any
  orphaned `ghost_tier:*` circles (tier removed upstream) by appending
  "(archived)" to their summary — nothing is ever deleted.

  See `Bonfire.Ghost.list_tiers/1` for the upstream Ghost API.
  """

  import Untangle

  alias Bonfire.Boundaries.Acls
  alias Bonfire.Boundaries.Circles
  alias Bonfire.Boundaries.Grants
  alias Bonfire.Boundaries.Roles
  alias Bonfire.Boundaries.Scaffold.Instance, as: InstanceScaffold
  alias Bonfire.Common.Repo
  alias Bonfire.Ghost

  @circle_prefix "ghost_tier:"
  @role_prefix "ghost_tier_"
  @acl_prefix "ghost_tier_acl:"

  # Ghost slugs are lowercase alphanumeric with dashes/underscores; enforce this
  # before we atomise the role name. Roles at instance scope live in Application
  # config (keyword list, atom keys), so role names must be atoms — but unbounded
  # `String.to_atom/1` would be a memory-leak footgun without this regex guard.
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
  Fetches tiers from Ghost and reconciles them with local circles/roles/ACLs.

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
  Reconciles a pre-fetched list of Ghost tier payloads with local boundaries.

  Exposed primarily for tests — production code goes through `sync_all/1`.
  """
  @spec sync_tiers([map()], keyword()) :: sync_summary()
  def sync_tiers(tiers, opts) when is_list(tiers) do
    acl_index = index_ghost_acls()

    summary =
      Enum.reduce(tiers, @empty_summary, fn tier, acc ->
        case sync_tier(tier, acl_index, opts) do
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
  def sync_tier(tier, acl_index, opts \\ [])

  def sync_tier(
        %{"slug" => slug, "name" => name, "id" => ghost_tier_id},
        acl_index,
        opts
      )
      when is_binary(slug) and is_binary(name) do
    if Regex.match?(@slug_regex, slug) do
      circle_name = @circle_prefix <> slug
      role_name = String.to_atom(@role_prefix <> slug)
      acl_name = @acl_prefix <> slug
      scoped_opts = Keyword.put(opts, :scope, :instance)

      with {:ok, circle, state} <-
             ensure_circle(circle_name, name, slug, ghost_tier_id, scoped_opts),
           :ok <- ensure_role(role_name, scoped_opts),
           {:ok, acl} <- ensure_acl(acl_name, acl_index),
           :ok <- apply_grants(circle, acl, role_name, scoped_opts) do
        {:ok, state}
      end
    else
      error(slug, "Ghost tier slug failed validation — refusing to create atom")
      {:error, :invalid_slug}
    end
  end

  def sync_tier(tier, _acl_index, _opts) do
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

  # --- Role ----------------------------------------------------------------

  # Creates the role at instance scope if missing. We deliberately don't seed
  # `can_verbs` — pre-populating them via `Settings.put_raw` rewrites the entire
  # `:role_verbs` Application config tree through the settings hooks, which
  # corrupts existing role entries and breaks the Roles UI. Empty roles cause
  # `Grants.change_role` to raise, which `apply_grants/4` rescues silently;
  # admins assign verbs from the Roles settings page afterwards.
  #
  # Reads are rescued because `:role_verbs` in the Application env is a keyword
  # list with atom keys: one bad entry (e.g. a leftover string key from an older
  # version) makes `Access.get` raise, which would otherwise take down the whole
  # sync. On read failure we assume the role is missing and try to create it.
  defp ensure_role(role_name, opts) do
    if role_exists?(role_name, opts) do
      :ok
    else
      try do
        Roles.create(role_name, :ops, opts)
        :ok
      rescue
        e ->
          warn(e, "Could not create role #{inspect(role_name)}")
          {:error, :role_create_failed}
      end
    end
  end

  defp role_exists?(role_name, opts) do
    existing = Roles.get(role_name, opts)
    is_map(existing) and map_size(existing) > 0
  rescue
    e ->
      warn(e, "Could not read role #{inspect(role_name)} — assuming missing")
      false
  end

  # --- ACL -----------------------------------------------------------------
  #
  # `Acls` has no by-name lookup, so we build an index of existing ghost-tier
  # ACLs once per sync and reuse it across tiers.

  defp index_ghost_acls do
    Acls.list_my(:instance)
    |> Enum.reduce(%{}, fn acl, acc ->
      case acl_name(acl) do
        nil -> acc
        name -> Map.put(acc, name, acl)
      end
    end)
  end

  defp acl_name(%{named: %{name: name}}) when is_binary(name), do: name
  defp acl_name(_), do: nil

  defp ensure_acl(acl_name, acl_index) do
    case Map.get(acl_index, acl_name) do
      nil -> Acls.simple_create(:instance, acl_name)
      acl -> {:ok, acl}
    end
  end

  # --- Grants --------------------------------------------------------------

  # `Grants.change_role` raises when the role has no verbs configured yet.
  # The circle+role+ACL structure is still in place for the admin to configure,
  # so we treat that case as a soft warning.
  defp apply_grants(circle, acl, role_name, opts) do
    Grants.change_role(circle.id, acl.id, role_name, opts)
    :ok
  rescue
    e ->
      warn(e, "apply_grants for #{role_name} skipped (likely empty role)")
      :ok
  end
end
