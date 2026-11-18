defmodule Platform.Repo.Migrations.BackfillStaleAgentParticipantDisplayNamesTest do
  @moduledoc """
  Task 01a1f0d1 stage 2: behavioural coverage of
  `20261118230000_backfill_stale_agent_participant_display_names`.

  The suite migrates an empty database, where the UPDATE matches nothing, so
  this file seeds the stale shapes directly with `Repo.insert!` (bypassing the
  rename sync in `Agent.changeset/2`) and runs the shipped `up/0` through
  `Ecto.Migration.Runner` on the sandboxed connection, the same way as
  `BackfillChannelCreatorAdminTest`.
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Chat.Participant
  alias Platform.Chat.Space
  alias Platform.Repo

  @migration Platform.Repo.Migrations.BackfillStaleAgentParticipantDisplayNames

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/" <>
                      "20261118230000_backfill_stale_agent_participant_display_names.exs",
                    __DIR__
                  )

  setup_all do
    unless Code.ensure_loaded?(@migration), do: Code.require_file(@migration_path)
    :ok
  end

  defp run_migration!(operation) when operation in [:up, :down] do
    {:ok, runner} =
      Ecto.Migration.Runner.start_link(
        {self(), Repo, Repo.config(), @migration, :forward, operation,
         %{level: false, sql: false}}
      )

    Ecto.Migration.Runner.metadata(runner, [])
    apply(@migration, operation, [])
    Ecto.Migration.Runner.flush()
    Ecto.Migration.Runner.stop()
    :ok
  end

  defp space! do
    n = System.unique_integer([:positive])
    Repo.insert!(%Space{name: "Backfill #{n}", slug: "backfill-stale-#{n}", kind: "channel"})
  end

  defp row!(space, type, participant_id, display_name) do
    Repo.insert!(%Participant{
      space_id: space.id,
      participant_type: type,
      participant_id: participant_id,
      role: "member",
      attention_mode: "mention",
      display_name: display_name,
      joined_at: DateTime.utc_now()
    })
  end

  defp name_of(%Participant{id: id}), do: Repo.get!(Participant, id).display_name

  setup do
    n = System.unique_integer([:positive])

    agent =
      Repo.insert!(%Agent{
        slug: "ux-agent-#{n}",
        name: "Loki",
        status: "active",
        max_concurrent: 1,
        sandbox_mode: "off"
      })

    %{agent: agent}
  end

  test "stale, NULL and current agent rows all read the agent's name", %{agent: agent} do
    stale = row!(space!(), "agent", agent.id, "UX")
    null = row!(space!(), "agent", agent.id, nil)
    current = row!(space!(), "agent", agent.id, "Loki")

    run_migration!(:up)

    assert name_of(stale) == "Loki"
    assert name_of(null) == "Loki"
    assert name_of(current) == "Loki"
  end

  test "a federated-style row whose participant_id is no agent id is untouched" do
    federated = row!(space!(), "agent", Ecto.UUID.generate(), "Bob (via peer)")

    run_migration!(:up)

    assert name_of(federated) == "Bob (via peer)"
  end

  test "a user row is untouched even when its id collides with an agent id", %{agent: agent} do
    user_row = row!(space!(), "user", agent.id, "Avery")

    run_migration!(:up)

    assert name_of(user_row) == "Avery"
  end

  test "a second run and a down/up cycle are no-ops", %{agent: agent} do
    stale = row!(space!(), "agent", agent.id, "UX")

    run_migration!(:up)
    run_migration!(:up)
    run_migration!(:down)
    run_migration!(:up)

    assert name_of(stale) == "Loki"
  end
end
