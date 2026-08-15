defmodule Platform.Repo.Migrations.AddAvatarToAgents do
  @moduledoc """
  Task `01a00122` stage 1: agents get a face. Until now an agent rendered as
  a `color` swatch and its initials, so every surface that lists agents
  side by side — chat, meetings, the control center, the activity feed —
  distinguished them only by hue.

  Two columns, and the second is NOT provenance:

    * `avatar_url` — the servable URL for the agent's avatar, so read paths
      render an agent without knowing anything about the storage layout.
    * `avatar_storage_key` — the key the bytes actually live under in
      `Platform.Agents.AvatarStorage`. It exists so REPLACING an avatar can
      delete the previous blob instead of leaking it. Deriving the old key
      from the URL would couple deletion to the URL format forever.

  Deliberately NO `avatar_source` enum, unlike `users`. `users.avatar_source`
  arbitrates between two competing writers — its only load-bearing clause is
  `accounts.ex:312-316`, which preserves a `:local` avatar so an OIDC refresh
  cannot clobber a user upload. Agents have no OIDC and no login, so
  `agents.avatar_url` has exactly one writer and there is nothing to
  arbitrate. Copying the column would copy an aspiration rather than a
  working precedent: `:local` is dead code today — nothing in `lib/`,
  `test/` or `priv/` ever writes it.

  Both nullable: every existing agent has no avatar, and an agent without
  one stays valid forever. The fallback (color + initials) is not a
  degraded state, it is the default state, so a NOT NULL with a backfilled
  sentinel would encode a lie.

  No index on either column. Neither is ever a filter or a join key — both
  are read only for a row some other query already selected by `id` or
  `slug`. An index here would cost writes and buy nothing.
  """
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add(:avatar_url, :string)
      add(:avatar_storage_key, :string)
    end
  end
end
