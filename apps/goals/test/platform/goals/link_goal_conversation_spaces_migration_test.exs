defmodule Platform.Goals.LinkGoalConversationSpacesMigrationTest do
  @moduledoc """
  `20261123180100_link_goal_conversation_spaces` (task 01a20939 stage 1).

  Migrations run to `:up` before ExUnit boots, so `up/0` cannot be driven
  through `Ecto.Migrator` inside the sandbox transaction. The migration's
  `up/0` is exactly `link_all(repo())`, so these tests drive `link_all/1`
  with `Platform.Repo` (the pattern of
  `Platform.Goals.MoveProposalsOutOfDmsMigrationTest`).

  A goal confirmed before this release is simulated by confirming on the
  branch and then clearing `conversation_space_id` and the space's
  `goal_id` metadata key, which is the state the earlier code left.
  """
  use Platform.DataCase, async: false

  import Platform.GoalsFixtures

  alias Platform.Chat
  alias Platform.Chat.Space
  alias Platform.Goals
  alias Platform.Goals.{Conversation, Goal, Grant}
  alias Platform.Repo.Migrations.LinkGoalConversationSpaces

  @now ~U[2026-11-16 09:00:00.000000Z]
  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20261123180100_link_goal_conversation_spaces.exs",
                    __DIR__
                  )
  @full %{
    title: "Run a half marathon",
    why: "To feel strong",
    unit: "km",
    target_value: "21.1",
    source_key: "self_reported",
    agent_mode: "coach",
    rhythm: "weekly",
    rhythm_weekday: 3,
    outreach: "gentle",
    kind: "shared"
  }

  setup_all do
    unless Code.ensure_loaded?(LinkGoalConversationSpaces), do: Code.require_file(@migration_path)
    :ok
  end

  setup do
    enable_goals!()

    old = Map.new([:clock_now, :wake_up_dispatcher], &{&1, Application.fetch_env(:goals, &1)})
    Application.put_env(:goals, :clock_now, fn -> @now end)
    Application.put_env(:goals, :wake_up_dispatcher, fn _signal -> :ok end)

    on_exit(fn ->
      for {key, previous} <- old do
        case previous do
          {:ok, value} -> Application.put_env(:goals, key, value)
          :error -> Application.delete_env(:goals, key)
        end
      end
    end)

    org = org_id!()
    person = member!(org)
    lead = coach_agent!(person)
    {:ok, _} = Platform.Roles.assign_role(Chat.Sidebar.agents_leader_role(), lead.id)
    %{org: org, person: person, lead: lead}
  end

  defp confirm!(c) do
    {:ok, proposal} = Goals.start_goal_conversation(c.person, "I want to run a half marathon")
    {:ok, proposal} = Goals.propose_goal(c.lead, proposal.id, Map.put(@full, :ready, true))

    {:ok, %{goal: goal, proposal: proposal}} =
      Goals.confirm_proposal(c.person, proposal.id, proposal.revision)

    {goal, proposal}
  end

  # The state a goal confirmed before this release is in.
  defp unlink!(goal) do
    Repo.update_all(from(g in Goal, where: g.id == ^goal.id), set: [conversation_space_id: nil])

    Repo.query!(
      "UPDATE chat_spaces SET metadata = metadata - 'goal_id' WHERE id = $1::uuid",
      [Ecto.UUID.dump!(goal_space!(goal.conversation_space_id).id)]
    )
  end

  defp goal_space!(id), do: Repo.get!(Space, id)
  defp column(goal), do: Repo.get!(Goal, goal.id).conversation_space_id

  defp snapshot do
    Repo.query!(
      "SELECT g.id::text, g.conversation_space_id::text, g.updated_at::text, " <>
        "s.metadata::text, s.updated_at::text " <>
        "FROM goals g LEFT JOIN chat_spaces s ON s.id = g.conversation_space_id ORDER BY g.id"
    ).rows
  end

  test "links each pre-release confirmed goal to its proposal's space, once", c do
    # A: confirmed before this release.
    {old_goal, old_proposal} = confirm!(c)
    unlink!(old_goal)
    assert column(old_goal) == nil

    # B: confirmed from a proposal, whose space was later replaced
    # (archived, then ensure_space made another). The backfill must not
    # point it back at the proposal's space.
    {moved_goal, moved_proposal} = confirm!(c)

    Repo.update_all(from(s in Space, where: s.id == ^moved_proposal.space_id),
      set: [archived_at: DateTime.utc_now()]
    )

    {:ok, replacement} = Conversation.ensure_space(Repo.get!(Goal, moved_goal.id))
    refute replacement.id == moved_proposal.space_id

    # C: created directly, no proposal and no space; D: created directly,
    # its space made lazily.
    plain = goal!(c.person, c.org)
    lazy = goal!(c.person, c.org, %{coach_agent_id: c.lead.id})
    {:ok, lazy_space} = Conversation.ensure_space(lazy)

    assert LinkGoalConversationSpaces.link_all(Repo) == 1

    assert column(old_goal) == old_proposal.space_id
    linked = goal_space!(old_proposal.space_id)
    assert linked.metadata["goal_id"] == old_goal.id
    assert linked.metadata["surface"] == "goals"
    refute Chat.rail_visible?(linked)

    assert column(moved_goal) == replacement.id
    assert column(plain) == nil
    assert column(lazy) == lazy_space.id

    refute Repo.exists?(
             from(g in Grant,
               where: g.goal_id in ^[old_goal.id, moved_goal.id, plain.id, lazy.id]
             )
           )

    # A second run changes nothing.
    before = snapshot()
    assert LinkGoalConversationSpaces.link_all(Repo) == 0
    assert snapshot() == before
    assert column(moved_goal) == replacement.id
  end

  test "a run with nothing to link changes nothing", c do
    {_goal, _proposal} = confirm!(c)
    before = snapshot()

    assert LinkGoalConversationSpaces.link_all(Repo) == 0
    assert snapshot() == before
  end
end
