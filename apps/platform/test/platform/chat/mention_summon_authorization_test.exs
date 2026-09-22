defmodule Platform.Chat.MentionSummonAuthorizationTest do
  @moduledoc """
  Task 01a0ac64-a959-7001-9ca2-e429535a1bb2 stage 1.

  Before this stage `Chat.reinvite_and_pin_mentioned/1` added ANY workspace
  agent to ANY non-DM space for ANY message author, with no permission check.
  These tests pin the two halves of the repair:

    * the **gate** — the add fires only for an admin user participant of the
      space or the sponsor of an execution space's task. The unauthorized case
      asserts a row COUNT of zero AND that the message posted fine, because a
      gate that raised would also produce no row while breaking chat;
    * the **grant stamp** — an authorized add writes `history_visible_from`,
      the dispatch path (`DispatchMembership.ensure_writable/3`) leaves it NULL,
      and a repeat mention of an already-present agent does not overwrite an
      existing NULL. Asserting only "a row exists" would pass against a
      version that stamped every row, which would bound history for agents
      dispatched into the space legitimately.

  The bracketed tokens below are test fixtures exercising the parser; they are
  the defect under repair and must never appear in a posted message.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Chat
  alias Platform.Chat.DispatchMembership
  alias Platform.Chat.Participant
  alias Platform.Repo

  defp agent! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Agents.Agent{
      name: "Summon Target #{n}",
      slug: "summon-target-#{n}",
      status: "active"
    })
  end

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: "User #{n}",
      email: "summon-#{n}@example.com",
      oidc_sub: "sub-summon-#{n}"
    })
  end

  defp channel! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{name: "Summon #{n}", slug: "summon-#{n}", kind: "channel"})

    space
  end

  defp user_participant!(space_id, user, role) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        role: role,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp agent_rows(space_id, agent_id) do
    Repo.all(
      from(p in Participant,
        where:
          p.space_id == ^space_id and p.participant_type == "agent" and
            p.participant_id == ^agent_id
      )
    )
  end

  defp mention!(space_id, participant_id, agent) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space_id,
        participant_id: participant_id,
        content_type: "text",
        content: "hey @[" <> agent.slug <> "] please look"
      })

    msg
  end

  test "a mention by an unauthorized author creates NO participant row" do
    space = channel!()
    agent = agent!()
    author = user_participant!(space.id, user!(), "member")

    msg = mention!(space.id, author.id, agent)

    assert msg.id
    assert agent_rows(space.id, agent.id) == []
  end

  test "a mention by an admin user participant adds the agent with history_visible_from set" do
    space = channel!()
    agent = agent!()
    author = user_participant!(space.id, user!(), "admin")

    mention!(space.id, author.id, agent)

    assert [row] = agent_rows(space.id, agent.id)
    assert %DateTime{} = row.history_visible_from
  end

  test "an admin mention naming an already-present agent is a no-op and preserves NULL history_visible_from" do
    space = channel!()
    agent = agent!()

    {:ok, existing} = Chat.add_agent_participant(space.id, agent)
    assert is_nil(existing.history_visible_from)

    author = user_participant!(space.id, user!(), "admin")
    mention!(space.id, author.id, agent)

    assert [row] = agent_rows(space.id, agent.id)
    assert row.id == existing.id
    assert is_nil(row.history_visible_from)
  end

  test "DispatchMembership.ensure_writable/3 still creates a row with NULL history_visible_from" do
    space = channel!()
    agent = agent!()

    assert {:ok, _} = DispatchMembership.ensure_writable(space.id, agent.id, source: "test")

    assert [row] = agent_rows(space.id, agent.id)
    assert is_nil(row.history_visible_from)
  end
end
