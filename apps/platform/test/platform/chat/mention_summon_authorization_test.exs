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

  # Task 01a0fd62-a7ef-7001-8477-bd17e47bbaca stage 1. Every test above seats
  # its admin by hand, which is why none of them noticed that NO production
  # path produced an admin row in a channel. This one goes through the real
  # creation path: the creator's row must come from `create_channel/1` itself.
  describe "a channel's creator" do
    test "can summon an agent by mention in the channel they created" do
      creator = user!()
      agent = agent!()
      n = System.unique_integer([:positive])

      {:ok, space} =
        Chat.create_channel(%{name: "Created #{n}", slug: "created-#{n}", created_by: creator.id})

      creator_row =
        Repo.one!(
          from(p in Participant,
            where:
              p.space_id == ^space.id and p.participant_type == "user" and
                p.participant_id == ^creator.id
          )
        )

      mention!(space.id, creator_row.id, agent)

      assert [row] = agent_rows(space.id, agent.id)
      assert %DateTime{} = row.history_visible_from
    end

    test "positive control: the same post by a plain member of that channel adds nothing" do
      creator = user!()
      agent = agent!()
      n = System.unique_integer([:positive])

      {:ok, space} =
        Chat.create_channel(%{name: "Created #{n}", slug: "created-#{n}", created_by: creator.id})

      member = user_participant!(space.id, user!(), "member")

      msg = mention!(space.id, member.id, agent)

      assert msg.id
      assert agent_rows(space.id, agent.id) == []
    end
  end

  # Task 01a0fd62-a7ef-7001-8477-bd17e47bbaca stage 2. A refused mention is no
  # longer silent to its author: the post path `send/2`s
  # `{:mention_summon_refused, msg_id, names}` to `from_pid` (the author's own
  # LiveView) and to nothing else. Every `refute_receive` below is paired with
  # a case that DOES receive under the same setup, so a broken send cannot
  # pass them all by sending nothing.
  describe "the refused-summon notice to the author's process" do
    defp post_from_self!(space_id, participant_id, content) do
      {:ok, msg} =
        Chat.post_message(
          %{
            space_id: space_id,
            participant_id: participant_id,
            content_type: "text",
            content: content
          },
          from_pid: self()
        )

      msg
    end

    test "a member author is told, by name, which agent was not added" do
      space = channel!()
      agent = agent!()
      member = user_participant!(space.id, user!(), "member")

      msg = post_from_self!(space.id, member.id, "hi @[" <> agent.slug <> "]")

      assert_receive {:mention_summon_refused, id, names}
      assert id == msg.id
      assert names == [agent.name]
      assert agent_rows(space.id, agent.id) == []
    end

    test "an admin author's mention adds the agent and sends nothing" do
      space = channel!()
      agent = agent!()
      admin = user_participant!(space.id, user!(), "admin")

      post_from_self!(space.id, admin.id, "hi @[" <> agent.slug <> "]")

      refute_receive {:mention_summon_refused, _, _}
      assert [_row] = agent_rows(space.id, agent.id)
    end

    test "a member mentioning an agent ALREADY in the space is not refused" do
      space = channel!()
      agent = agent!()
      {:ok, _} = Chat.add_agent_participant(space.id, agent)
      member = user_participant!(space.id, user!(), "member")

      post_from_self!(space.id, member.id, "hi @[" <> agent.slug <> "]")

      refute_receive {:mention_summon_refused, _, _}
    end

    test "a DM is neither summoned nor noticed" do
      {:ok, dm} = Chat.create_space(%{kind: "dm", name: "dm"})
      agent = agent!()
      member = user_participant!(dm.id, user!(), "member")

      post_from_self!(dm.id, member.id, "hi @[" <> agent.slug <> "]")

      refute_receive {:mention_summon_refused, _, _}
      assert agent_rows(dm.id, agent.id) == []
    end

    test "with no from_pid nothing is sent" do
      space = channel!()
      agent = agent!()
      member = user_participant!(space.id, user!(), "member")

      mention!(space.id, member.id, agent)

      refute_receive {:mention_summon_refused, _, _}
      assert agent_rows(space.id, agent.id) == []
    end

    test "a mixed message names only the refused agent" do
      space = channel!()
      present = agent!()
      absent = agent!()
      {:ok, _} = Chat.add_agent_participant(space.id, present)
      member = user_participant!(space.id, user!(), "member")

      post_from_self!(
        space.id,
        member.id,
        "@[" <> present.slug <> "] and @[" <> absent.slug <> "] please"
      )

      assert_receive {:mention_summon_refused, _id, names}
      assert names == [absent.name]
    end

    test "an execution space's sponsor still adds the agent, with no notice" do
      sponsor = user!()

      {:ok, project} =
        Platform.Tasks.create_project(%{name: "Summon #{System.unique_integer([:positive])}"})

      {:ok, task} =
        Platform.Tasks.create_task(%{
          project_id: project.id,
          title: "Sponsored",
          sponsor_user_id: sponsor.id
        })

      {:ok, exec} =
        Chat.create_space(%{
          kind: "execution",
          name: "exec",
          metadata: %{"task_id" => task.id}
        })

      agent = agent!()
      sponsor_row = user_participant!(exec.id, sponsor, "member")

      post_from_self!(exec.id, sponsor_row.id, "join @[" <> agent.slug <> "]")

      refute_receive {:mention_summon_refused, _, _}
      assert [_row] = agent_rows(exec.id, agent.id)
      assert Chat.can_summon_agents?(exec, sponsor.id)

      # Positive control under the same space: a non-sponsor member IS refused.
      other = user_participant!(exec.id, user!(), "member")
      post_from_self!(exec.id, other.id, "join @[" <> agent!().slug <> "]")
      assert_receive {:mention_summon_refused, _, [_name]}
    end
  end

  describe "Chat.can_summon_agents?/2" do
    test "is true for an admin user participant and false for a member or a nil user" do
      space = channel!()
      admin = user!()
      member = user!()
      user_participant!(space.id, admin, "admin")
      user_participant!(space.id, member, "member")

      assert Chat.can_summon_agents?(space, admin.id)
      refute Chat.can_summon_agents?(space, member.id)
      refute Chat.can_summon_agents?(space, nil)
    end
  end
end
