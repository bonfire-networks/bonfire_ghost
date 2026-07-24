defmodule Bonfire.Ghost.Repo.Migrations.PreserveGhostIdentityShape do
  @moduledoc false
  use Ecto.Migration
  import Needle.Migration

  @table "bonfire_ghost_identity"
  @pointer_table Needle.Pointer.__schema__(:source)

  def up do
    create_if_not_exists table(@table, primary_key: false) do
      add_pointer(:account_id, :strong, Needle.Pointer, primary_key: true)
      add_pointer(:user_id, :weak)
      add(:ghost_member_id, :text)
      add(:ghost_staff_id, :text)
      add(:ghost_email, :text)
      timestamps()
    end

    ensure_columns()

    create_if_not_exists(unique_index(@table, [:account_id]))

    create_if_not_exists(
      unique_index(@table, [:ghost_member_id], where: "ghost_member_id IS NOT NULL")
    )

    create_if_not_exists(
      unique_index(@table, [:ghost_staff_id], where: "ghost_staff_id IS NOT NULL")
    )

    create_if_not_exists(index(@table, [:user_id]))
  end

  def down, do: :ok

  defp ensure_columns do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = '#{@table}'
          AND column_name = 'account_id'
      ) THEN
        ALTER TABLE "#{@table}"
          ADD COLUMN account_id uuid
          REFERENCES "#{@pointer_table}"(id)
          ON UPDATE CASCADE
          ON DELETE CASCADE;
      END IF;

      IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = '#{@table}'
          AND column_name = 'user_id'
      ) THEN
        ALTER TABLE "#{@table}"
          ADD COLUMN user_id uuid
          REFERENCES "#{@pointer_table}"(id)
          ON UPDATE CASCADE
          ON DELETE SET NULL;
      END IF;
    END
    $$;
    """)

    execute("""
    ALTER TABLE "#{@table}"
      ADD COLUMN IF NOT EXISTS ghost_member_id text,
      ADD COLUMN IF NOT EXISTS ghost_staff_id text,
      ADD COLUMN IF NOT EXISTS ghost_email text,
      ADD COLUMN IF NOT EXISTS inserted_at timestamp(0) without time zone,
      ADD COLUMN IF NOT EXISTS updated_at timestamp(0) without time zone
    """)
  end
end
