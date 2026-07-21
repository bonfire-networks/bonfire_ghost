defmodule Bonfire.Ghost.Repo.Migrations.GhostIdentities do
  @moduledoc false
  use Ecto.Migration
  import Needle.Migration

  @table "bonfire_ghost_identity"

  def up do
    # dev/test DBs may carry the table in a superseded shape from a dropped
    # migration (20260720000001); recreate from scratch (no-op elsewhere)
    drop_if_exists(table(@table))

    create table(@table, primary_key: false) do
      # one row per person: the account is the identity anchor
      add_pointer(:account_id, :strong, Needle.Pointer, primary_key: true)
      # the author/attribution profile, once known
      add_pointer(:user_id, :weak)
      # Ghost staff users and members are separate entities with separate ID
      # spaces — the same human can be both, hence one row with both columns
      add(:ghost_member_id, :text)
      add(:ghost_staff_id, :text)
      # last email seen from Ghost: lets sync distinguish "Ghost changed the
      # email" (follow it) from "the person changed their Bonfire email" (keep it)
      add(:ghost_email, :text)
      timestamps()
    end

    create_if_not_exists(
      unique_index(@table, [:ghost_member_id], where: "ghost_member_id IS NOT NULL")
    )

    create_if_not_exists(
      unique_index(@table, [:ghost_staff_id], where: "ghost_staff_id IS NOT NULL")
    )

    create_if_not_exists(index(@table, [:user_id]))
  end

  def down do
    drop_if_exists(table(@table))
  end
end
