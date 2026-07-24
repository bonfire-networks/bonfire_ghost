defmodule Bonfire.Ghost.Identities.GhostIdentity do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "bonfire_ghost_identity" do
    belongs_to(:account, Bonfire.Data.Identity.Account, type: Needle.ULID, primary_key: true)
    belongs_to(:user, Bonfire.Data.Identity.User, type: Needle.ULID)
    field(:ghost_member_id, :string)
    field(:ghost_staff_id, :string)
    field(:ghost_email, :string)
    timestamps()
  end
end
