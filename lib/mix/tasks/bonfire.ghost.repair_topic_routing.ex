defmodule Mix.Tasks.Bonfire.Ghost.RepairTopicRouting do
  @moduledoc """
  Previews, applies, or rolls back a routing-only repair for imported Ghost articles.

      just mix bonfire.ghost.repair_topic_routing \
        --group GROUP_ID \
        --ghost-url https://blog.example/ \
        --manifest /tmp/ghost-topic-routing.json \
        --dry-run

      just mix bonfire.ghost.repair_topic_routing \
        --manifest /tmp/ghost-topic-routing.json \
        --applied-manifest /tmp/ghost-topic-routing-applied.json \
        --article https://blog.example/one-article/ \
        --apply

      just mix bonfire.ghost.repair_topic_routing \
        --manifest /tmp/ghost-topic-routing-applied.json \
        --rollback

  Preview is the default and is always read-only. Apply requires a preview manifest and writes a separate rollback manifest. Pass `--article` for a one-article pilot. Rollback removes only boosts recorded as created in the applied manifest.
  """

  use Mix.Task

  alias Bonfire.Ghost.TopicRoutingRepair

  @shortdoc "Safely repair imported Ghost article topic routing"
  @requirements ["app.start"]
  @switches [
    group: :string,
    ghost_url: :string,
    manifest: :string,
    applied_manifest: :string,
    article: :string,
    dry_run: :boolean,
    apply: :boolean,
    rollback: :boolean,
    force: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      positional != [] ->
        Mix.raise("Unexpected positional arguments: #{Enum.join(positional, " ")}")

      invalid != [] ->
        Mix.raise("Invalid options: #{inspect(invalid)}")

      Enum.count([opts[:dry_run], opts[:apply], opts[:rollback]], &(&1 == true)) > 1 ->
        Mix.raise("--dry-run, --apply, and --rollback are mutually exclusive")

      opts[:article] && opts[:apply] != true ->
        Mix.raise("--article is only valid with --apply")

      opts[:force] == true and (opts[:apply] == true or opts[:rollback] == true) ->
        Mix.raise("--force is only valid when writing a preview manifest")

      opts[:apply] ->
        run_apply(opts)

      opts[:rollback] ->
        run_rollback(opts)

      true ->
        run_preview(opts)
    end
  end

  defp run_preview(opts) do
    repair_opts = [
      group_id: required_option!(opts, :group),
      ghost_url: required_option!(opts, :ghost_url)
    ]

    path = required_option!(opts, :manifest)

    with {:ok, manifest} <- TopicRoutingRepair.preview(repair_opts) do
      write_manifest!(path, manifest, opts[:force] == true)

      Mix.shell().info(
        "Preview only: #{manifest["summary"]["candidates"]} candidate(s), #{manifest["summary"]["skipped"]} skipped, no rows changed."
      )
    else
      {:error, reason} -> Mix.raise("Could not build routing preview: #{inspect(reason)}")
    end
  end

  defp run_apply(opts) do
    preview_path = required_option!(opts, :manifest)
    applied_path = required_option!(opts, :applied_manifest)

    apply_opts =
      case opts[:article] do
        article when is_binary(article) -> [article_url: article]
        _ -> []
      end

    result =
      with_reserved_manifest(applied_path, fn file ->
        with {:ok, preview_manifest} <- read_manifest(preview_path) do
          before_commit = fn applied_manifest ->
            write_open_manifest(file, applied_manifest)
          end

          TopicRoutingRepair.apply(
            preview_manifest,
            Keyword.put(apply_opts, :before_commit, before_commit)
          )
        end
      end)

    case result do
      {:ok, applied_manifest} ->
        Mix.shell().info(
          "Apply completed: #{applied_manifest["summary"]["created"]} boost(s) created, #{applied_manifest["summary"]["already_present"]} already present. Rollback manifest: #{applied_path}"
        )

      {:error, {:manifest_exists, ^applied_path}} ->
        Mix.raise("Manifest already exists: #{applied_path}. Choose a new path.")

      {:error, reason} ->
        Mix.raise("Could not apply routing repair: #{inspect(reason)}")
    end
  end

  defp run_rollback(opts) do
    path = required_option!(opts, :manifest)

    with {:ok, applied_manifest} <- read_manifest(path),
         {:ok, repaired_count} <- TopicRoutingRepair.rollback(applied_manifest) do
      Mix.shell().info("Rollback completed for #{repaired_count} topic boost(s).")
    else
      {:error, reason} -> Mix.raise("Could not roll back routing repair: #{inspect(reason)}")
    end
  end

  defp read_manifest(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, manifest} <- TopicRoutingRepair.decode_manifest(contents) do
      {:ok, manifest}
    end
  end

  defp write_manifest!(path, manifest, overwrite?) do
    encoded = TopicRoutingRepair.encode_manifest!(manifest) <> "\n"

    if overwrite? do
      File.write!(path, encoded)
    else
      case File.open(path, [:write, :exclusive]) do
        {:ok, file} ->
          try do
            IO.binwrite(file, encoded)
          after
            File.close(file)
          end

        {:error, :eexist} ->
          Mix.raise("Manifest already exists: #{path}. Choose a new path.")

        {:error, reason} ->
          Mix.raise("Could not write manifest #{path}: #{inspect(reason)}")
      end
    end

    Mix.shell().info("Wrote manifest to #{path}")
  end

  defp with_reserved_manifest(path, callback) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, file} ->
        result =
          try do
            callback.(file)
          rescue
            exception -> {:raised, exception, __STACKTRACE__}
          end

        File.close(file)

        case result do
          {:ok, _} = success ->
            success

          {:raised, exception, stacktrace} ->
            File.rm(path)
            reraise(exception, stacktrace)

          error ->
            File.rm(path)
            error
        end

      {:error, :eexist} ->
        {:error, {:manifest_exists, path}}

      {:error, reason} ->
        {:error, {:could_not_reserve_manifest, path, reason}}
    end
  end

  defp write_open_manifest(file, manifest) do
    encoded = TopicRoutingRepair.encode_manifest!(manifest) <> "\n"

    with :ok <- IO.binwrite(file, encoded),
         :ok <- :file.sync(file) do
      :ok
    end
  end

  defp required_option!(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        Mix.raise(
          "Missing required option --#{key |> Atom.to_string() |> String.replace("_", "-")}"
        )
    end
  end
end
