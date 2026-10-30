defmodule Platform.Repo.Migrations.AddShortCodeToMeetingInvites do
  @moduledoc """
  Task 01a18d0a-ec37-7000-8a47-108834f2efe2, stage 1: short guest links.

  Adds `meeting_invites.short_code`, the opaque code behind
  `https://<guest host>/g/<code>`. Only the code is stored. The signed guest
  token is a live bearer credential and is re-minted from the row on every
  short-link hit, so no token column exists or is added here.

  Nullable because account-holder rows (`user_id` set) have no guest link and
  never get a code. The unique index is partial (`WHERE short_code IS NOT
  NULL`) so those rows do not compete for it.

  Existing guest rows (`user_id IS NULL AND expires_at IS NOT NULL`) are
  backfilled with a fresh code generated here in Elixir, one parameterised
  `UPDATE` per row, in batches. Nothing is reconstructed: a pre-existing invite
  simply gets a new random value written against its id. The generator is
  inlined rather than calling `Platform.Meetings.GuestShortCode`, so this
  migration keeps its meaning if that module ever changes.
  """
  use Ecto.Migration

  @batch_size 500

  def up do
    alter table(:meeting_invites) do
      add(:short_code, :text)
    end

    create(
      unique_index(:meeting_invites, [:short_code],
        name: :meeting_invites_short_code_index,
        where: "short_code IS NOT NULL"
      )
    )

    flush()

    backfill(repo())
  end

  def down do
    drop(index(:meeting_invites, [:short_code], name: :meeting_invites_short_code_index))

    alter table(:meeting_invites) do
      remove(:short_code)
    end
  end

  @doc """
  Writes a fresh code onto every guest row that has none. Returns the number
  of rows updated. Public so a test can drive it inside the Ecto sandbox,
  since migrations have already run before ExUnit starts.

  `AND short_code IS NULL` on the UPDATE makes it safe to re-run and safe
  against a row that gained a code between the SELECT and the UPDATE.
  """
  @spec backfill(module()) :: non_neg_integer()
  def backfill(repo), do: backfill(repo, 0)

  defp backfill(repo, acc) do
    %Postgrex.Result{rows: rows} =
      repo.query!(
        """
        SELECT id FROM meeting_invites
         WHERE user_id IS NULL
           AND expires_at IS NOT NULL
           AND short_code IS NULL
         LIMIT $1
        """,
        [@batch_size]
      )

    updated =
      Enum.reduce(rows, 0, fn [id], count ->
        %Postgrex.Result{num_rows: n} =
          repo.query!(
            "UPDATE meeting_invites SET short_code = $2 WHERE id = $1 AND short_code IS NULL",
            [id, generate_code()]
          )

        count + n
      end)

    if length(rows) < @batch_size or updated == 0 do
      acc + updated
    else
      backfill(repo, acc + updated)
    end
  end

  defp generate_code do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
