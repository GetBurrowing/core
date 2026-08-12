defmodule Platform.Repo.Migrations.RetypeTaskRouterParticipantsAsSystem do
  @moduledoc """
  Task 019ff1af — retype the synthetic per-space TaskRouter participant from `"agent"` to the
  new `"system"` kind, so agent rosters stop counting a participant that no
  `agents` row can resolve.

  Rows are identified by RECOMPUTING the deterministic id that
  `Platform.Orchestration.ExecutionSpace.ensure_system_participant/1` mints —
  the first 32 hex chars of `sha256("task_router_system:" <> space_id)`,
  formatted as a UUID — and matching it against `participant_id`. Matching on
  `display_name = 'TaskRouter'` was rejected: display name is user-visible
  text, not a key, so a real agent someone happened to name TaskRouter would be
  silently retyped out of its own roster.

  The hash is computed in ELIXIR, iterating the spaces, rather than in SQL via
  `pgcrypto`: the Elixir expression is the same one the application uses, so it
  cannot drift from the writer, and it needs no extension to be installed in
  every environment this runs in.

  Idempotent in both directions — `up` only touches rows still typed `"agent"`,
  `down` only rows typed `"system"`, both under the same recomputation.
  """
  use Ecto.Migration

  import Ecto.Query

  def up, do: retype(repo(), "agent", "system")

  def down, do: retype(repo(), "system", "agent")

  @doc """
  The retype itself, taking the repo explicitly.

  Migrations run to `:up` before ExUnit boots, so `up/0` cannot be exercised
  through `Ecto.Migrator` in a test; this is the same work, wrapped for direct
  invocation. `up/0` and `down/0` are thin arguments to it.
  """
  def retype(repo, from_type, to_type) do
    repo.all(from(s in "chat_spaces", select: s.id))
    |> Enum.each(fn space_id ->
      system_id = system_participant_id(uuid_string(space_id))

      repo.update_all(
        from(p in "chat_participants",
          where:
            p.space_id == ^space_id and
              p.participant_type == ^from_type and
              p.participant_id == type(^system_id, :binary_id)
        ),
        set: [participant_type: to_type]
      )
    end)
  end

  defp uuid_string(id) when is_binary(id) and byte_size(id) == 16 do
    Ecto.UUID.load!(id)
  end

  defp uuid_string(id), do: id

  # Mirror of ExecutionSpace.system_participant_id/1 — inlined so this migration
  # keeps working if that private function is ever moved or renamed.
  defp system_participant_id(space_id) do
    :crypto.hash(:sha256, "task_router_system:#{space_id}")
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
    |> then(fn hex ->
      <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4), rest::binary>> =
        hex

      "#{a}-#{b}-#{c}-#{d}-#{rest}"
    end)
  end
end
