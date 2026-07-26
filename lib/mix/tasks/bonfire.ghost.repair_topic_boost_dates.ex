defmodule Mix.Tasks.Bonfire.Ghost.RepairTopicBoostDates do
  @moduledoc """
  Previews, applies, or rolls back a filtered Ghost topic-boost date repair.

      just mix bonfire.ghost.repair_topic_boost_dates \\
        --topic TOPIC_ID \\
        --ghost-url https://blog.example/ \\
        --author IMPORT_AUTHOR_ID \\
        --manifest /tmp/ghost-topic-boost-repair.json \\
        --dry-run

      just mix bonfire.ghost.repair_topic_boost_dates \\
        --manifest /tmp/ghost-topic-boost-repair.json \\
        --apply

      just mix bonfire.ghost.repair_topic_boost_dates \\
        --manifest /tmp/ghost-topic-boost-repair.json \\
        --rollback

  Preview is the default and is always read-only. Applying and rolling back require an existing manifest. Preview refuses to overwrite a manifest unless `--force` is passed.
  """

  use Mix.Task

  alias Bonfire.Ghost.TopicBoostDateRepair

  @shortdoc "Repair historical Ghost article ordering in one topic"
  @requirements ["app.start"]
  @switches [
    topic: :string,
    ghost_url: :string,
    author: :string,
    manifest: :string,
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

      opts[:force] == true and (opts[:apply] == true or opts[:rollback] == true) ->
        Mix.raise("--force is only valid when writing a preview manifest")

      opts[:apply] ->
        run_manifest(opts, :apply)

      opts[:rollback] ->
        run_manifest(opts, :rollback)

      true ->
        run_preview(opts)
    end
  end

  defp run_preview(opts) do
    repair_opts = [
      topic_id: required_option!(opts, :topic),
      ghost_url: required_option!(opts, :ghost_url),
      author_id: required_option!(opts, :author)
    ]

    with {:ok, manifest} <- TopicBoostDateRepair.preview(repair_opts) do
      encoded = TopicBoostDateRepair.encode_manifest!(manifest)
      maybe_write_manifest(opts[:manifest], encoded, opts[:force] == true)
      Mix.shell().info(encoded)
      Mix.shell().info("Preview only: #{length(manifest["repairs"])} candidate(s), no rows changed.")
    else
      {:error, reason} -> Mix.raise("Could not build repair preview: #{inspect(reason)}")
    end
  end

  defp run_manifest(opts, operation) do
    path = required_option!(opts, :manifest)

    with {:ok, contents} <- File.read(path),
         {:ok, manifest} <- TopicBoostDateRepair.decode_manifest(contents),
         {:ok, repaired_count} <- apply_operation(operation, manifest) do
      Mix.shell().info("#{operation} completed for #{repaired_count} boost(s).")
    else
      {:error, reason} ->
        Mix.raise("Could not #{operation} repair manifest #{path}: #{inspect(reason)}")
    end
  end

  defp apply_operation(:apply, manifest), do: TopicBoostDateRepair.apply(manifest)
  defp apply_operation(:rollback, manifest), do: TopicBoostDateRepair.rollback(manifest)

  defp maybe_write_manifest(nil, _encoded, _force?), do: :ok

  defp maybe_write_manifest(path, encoded, true) do
    File.write!(path, encoded <> "\n")
    Mix.shell().info("Wrote repair manifest to #{path}")
  end

  defp maybe_write_manifest(path, encoded, false) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, file} ->
        try do
          IO.binwrite(file, encoded <> "\n")
        after
          File.close(file)
        end

        Mix.shell().info("Wrote repair manifest to #{path}")

      {:error, :eexist} ->
        Mix.raise("Manifest already exists: #{path}. Pass --force to overwrite it.")

      {:error, reason} ->
        Mix.raise("Could not write repair manifest #{path}: #{inspect(reason)}")
    end
  end

  defp required_option!(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> value
      _ -> Mix.raise("Missing required option --#{key |> Atom.to_string() |> String.replace("_", "-")}")
    end
  end
end
