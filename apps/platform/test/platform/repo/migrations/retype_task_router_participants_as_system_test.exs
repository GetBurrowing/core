defmodule Platform.Repo.Migrations.RetypeTaskRouterParticipantsAsSystemTest do
  @moduledoc """
  Regression coverage for
  `20260811120000_retype_task_router_participants_as_system`.

  The DECOY is the point of this file: a real agent participant whose
  `display_name` is literally "TaskRouter", in the same space as a synthetic
  router. A name-matching implementation retypes the decoy out of its own
  roster and still passes every other assertion here. Only the decoy
  distinguishes hash-matching from name-matching.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Repo
  alias Platform.Repo.Migrations.RetypeTaskRouterParticipantsAsSystem, as: Migration

  # Migration source lives under `priv/repo/migrations/` and is not on the
  # compile path — walk up to `apps/platform/` and back down.
  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260811120000_retype_task_router_participants_as_system.exs"
                  ])

  setup_all do
    unless Code.ensure_loaded?(Migration), do: Code.require_file(@migration_path)
    :ok
  end

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

  defp type_of(id), do: Repo.get!(Participant, id).participant_type

  test "retypes the hash-identified row and leaves a same-named real agent alone" do
    {:ok, space} =
      Chat.create_space(%{
        name: "Exec",
        slug: "exec-#{System.unique_integer([:positive])}",
        kind: "execution"
      })

    # Pre-change state: the router row as it existed before this migration.
    {:ok, legacy} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: system_participant_id(space.id),
        display_name: "TaskRouter",
        attention_mode: "mention",
        joined_at: DateTime.utc_now()
      })

    decoy_agent =
      Repo.insert!(%Agent{
        slug: "taskrouter-#{System.unique_integer([:positive])}",
        name: "TaskRouter",
        status: "active"
      })

    {:ok, decoy} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: decoy_agent.id,
        display_name: "TaskRouter",
        joined_at: DateTime.utc_now()
      })

    Migration.retype(Repo, "agent", "system")

    assert type_of(legacy.id) == "system"
    assert type_of(decoy.id) == "agent", "a real agent named TaskRouter was retyped by name"

    # Idempotent: a second run changes nothing further.
    Migration.retype(Repo, "agent", "system")
    assert type_of(legacy.id) == "system"
    assert type_of(decoy.id) == "agent"

    assert Repo.aggregate(
             from(p in Participant,
               where: p.space_id == ^space.id and p.participant_type == "system"
             ),
             :count
           ) == 1

    # `down` reverses only the same recomputed row.
    Migration.retype(Repo, "system", "agent")
    assert type_of(legacy.id) == "agent"
    assert type_of(decoy.id) == "agent"
  end
end
