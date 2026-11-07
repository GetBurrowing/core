defmodule Platform.Habits.LearnedAttentionTest do
  @moduledoc """
  Task 01a1b6a1 stage 3 (`0061-learned-defaults.md` §§ 4-5): the first
  consumer server side. `Chat.remove_message_attention/4`, the act rung on
  the post path with its undo and stop, and broad capture (mention, DM open,
  agent assignment).
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, AttentionRouter, MessageAttention}
  alias Platform.Habits
  alias Platform.Habits.{LearnedAttention, Pattern, Signal}
  alias Platform.Inbox.Item
  alias Platform.Repo
  alias Platform.Tasks

  @action "chat.message_attention"

  defmodule StubAgentChat do
    def chat(_message, _opts), do: {:ok, %{content: "on it", model: "stub", usage: %{}}}
  end

  setup do
    previous =
      for key <- [:chat_agent_module, :chat_agent_dispatch_mode],
          do: {key, Application.get_env(:platform, key)}

    Application.put_env(:platform, :chat_agent_module, StubAgentChat)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:platform, key, value) end)
    end)

    router = Process.whereis(AttentionRouter) || start_supervised!({AttentionRouter, []})
    Sandbox.allow(Repo, self(), router)
    store = Process.whereis(ActiveAgentStore) || start_supervised!({ActiveAgentStore, []})
    Sandbox.allow(Repo, self(), store)

    n = System.unique_integer([:positive])
    one = user!("Member One", n)
    two = user!("Member Two", n)
    three = user!("Member Three", n)

    {:ok, room_x} =
      Chat.create_space(%{name: "room-x #{n}", slug: "room-x-#{n}", kind: "channel"})

    agent =
      Repo.insert!(%Agent{
        slug: "helper-agent-#{n}",
        name: "Helper Agent #{n}",
        status: "active",
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
      })

    one_p = participant!(room_x, "user", one.id, one.name)
    two_p = participant!(room_x, "user", two.id, two.name)
    three_p = participant!(room_x, "user", three.id, three.name)
    agent_p = participant!(room_x, "agent", agent.id, agent.name)

    %{
      one: one,
      two: two,
      three: three,
      agent: agent,
      room_x: room_x,
      one_p: one_p,
      two_p: two_p,
      three_p: three_p,
      agent_p: agent_p
    }
  end

  defp user!(name, n) do
    slug = name |> String.downcase() |> String.replace(" ", "-")

    Repo.insert!(%User{
      email: "#{slug}-la-#{n}@example.com",
      name: "#{name} #{n}",
      oidc_sub: "oidc-#{slug}-la-#{n}"
    })
  end

  defp participant!(space, type, id, name) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: type,
        participant_id: id,
        display_name: name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp post!(space, participant, content) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: content
      })

    msg
  end

  defp record!(actor, space, type, id, outcome, rung, n) do
    for _ <- 1..n do
      {:ok, %Signal{}} =
        Habits.record(%{
          actor_user_id: actor.id,
          space_id: space.id,
          action: @action,
          target_type: type,
          target_id: id,
          outcome: outcome,
          rung: rung
        })
    end
  end

  # Act unlocked: 5 accepted pre-fills (the control's act_after_accepts).
  defp unlock_act!(actor, space, type, id),
    do: record!(actor, space, type, id, "accepted", "prefill", 5)

  defp attention_rows(msg_id),
    do: Repo.all(from(a in MessageAttention, where: a.message_id == ^msg_id))

  defp mention_rows(user_id, msg_id) do
    Repo.all(
      from(i in Item,
        where:
          i.user_id == ^user_id and i.kind == "chat_mention" and
            i.source_type == "chat_message" and i.source_id == ^msg_id
      )
    )
  end

  defp pattern(user, space, type, id) do
    Repo.one!(
      from(p in Pattern,
        where:
          p.user_id == ^user.id and p.space_id == ^space.id and p.action == @action and
            p.target_type == ^type and p.target_id == ^id
      )
    )
  end

  defp signals(user, action) do
    Repo.all(
      from(s in Signal,
        where: s.actor_user_id == ^user.id and s.action == ^action,
        order_by: [asc: s.inserted_at]
      )
    )
  end

  defp drain, do: :ok = GenServer.call(AttentionRouter, :__drain__)

  # ── remove_message_attention/4 ─────────────────────────────────────────────

  describe "Chat.remove_message_attention/4" do
    test "the adder removes the row and that human's Inbox row, and the change is broadcast",
         %{room_x: room, one: one, two: two, one_p: one_p} do
      msg = post!(room, one_p, "a line")

      {:ok, %{added: [_]}} =
        Chat.add_message_attention({:user, one.id}, room.id, msg.id, [two.id])

      drain()
      assert [_] = mention_rows(two.id, msg.id)

      Chat.PubSub.subscribe(room.id)

      assert {:ok, %MessageAttention{}} =
               Chat.remove_message_attention({:user, one.id}, room.id, msg.id, two.id)

      assert attention_rows(msg.id) == []
      assert mention_rows(two.id, msg.id) == []
      assert_receive {:message_attention_changed, %{id: msg_id, attention: []}}
      assert msg_id == msg.id
    end

    test "keeps the Inbox row the message's own @mention wrote",
         %{room_x: room, one: one, two: two, one_p: one_p, two_p: two_p} do
      msg = post!(room, one_p, "hey @#{two_p.display_name}")
      assert [_mention] = mention_rows(two.id, msg.id)

      {:ok, %{added: [_]}} =
        Chat.add_message_attention({:user, one.id}, room.id, msg.id, [two.id])

      drain()
      assert [_, _] = mention_rows(two.id, msg.id)

      {:ok, _} = Chat.remove_message_attention({:user, one.id}, room.id, msg.id, two.id)
      assert [_] = mention_rows(two.id, msg.id)
    end

    test "refuses someone else's row and an agent's row, changing nothing",
         %{room_x: room, one: one, two: two, three: three, agent: agent, one_p: one_p} do
      msg = post!(room, one_p, "a line")
      {:ok, _} = Chat.add_message_attention({:user, one.id}, room.id, msg.id, [two.id, agent.id])
      drain()

      assert {:error, :forbidden} =
               Chat.remove_message_attention({:user, three.id}, room.id, msg.id, two.id)

      assert {:error, :not_reversible} =
               Chat.remove_message_attention({:user, one.id}, room.id, msg.id, agent.id)

      assert {:error, :not_found} =
               Chat.remove_message_attention({:user, one.id}, room.id, msg.id, three.id)

      assert length(attention_rows(msg.id)) == 2
      assert [_] = mention_rows(two.id, msg.id)
    end
  end

  # ── Act with undo ──────────────────────────────────────────────────────────

  describe "act on the post path" do
    test "with act unlocked for a human target, posting asks them and writes the notice",
         %{room_x: room, one: one, two: two, one_p: one_p, two_p: two_p} do
      unlock_act!(one, room, "user", two.id)
      assert %{act: %{target_id: two_id}} = Habits.suggest(one.id, room.id, @action)
      assert two_id == two.id

      msg = post!(room, one_p, "status update")
      drain()

      assert [%MessageAttention{participant_id: pid, added_by_participant_id: by}] =
               attention_rows(msg.id)

      assert pid == two_p.id and by == one_p.id
      assert [_] = mention_rows(two.id, msg.id)

      assert %{} = notice = Habits.act_notices(one.id, [msg.id])[msg.id]
      assert notice.target_id == two.id and notice.undone? == false
      assert pattern(one, room, "user", two.id).rung == "act"

      [act] = Enum.filter(signals(one, @action), &(&1.rung == "act"))
      assert act.outcome == "accepted" and act.source_message_id == msg.id
    end

    test "undo removes the row AND the Inbox row and demotes the pattern to prefill",
         %{room_x: room, one: one, two: two, one_p: one_p} do
      unlock_act!(one, room, "user", two.id)
      msg = post!(room, one_p, "status update")
      drain()
      assert [_] = attention_rows(msg.id)

      assert :ok = LearnedAttention.undo(one.id, room.id, msg.id)

      assert attention_rows(msg.id) == []
      assert mention_rows(two.id, msg.id) == []

      p = pattern(one, room, "user", two.id)
      assert p.rung == "prefill" and p.accepted_prefills == 0

      suggestion = Habits.suggest(one.id, room.id, @action)
      assert suggestion.act == nil
      assert suggestion.prefill == %{target_type: "user", target_id: two.id}
      assert %{undone?: true} = Habits.act_notices(one.id, [msg.id])[msg.id]

      # The next post no longer acts.
      next = post!(room, one_p, "another")
      assert attention_rows(next.id) == []
    end

    test "stop drops the pattern to rank, and the next post does not act",
         %{room_x: room, one: one, two: two, one_p: one_p} do
      unlock_act!(one, room, "user", two.id)
      msg = post!(room, one_p, "status update")
      drain()
      assert [_] = attention_rows(msg.id)

      assert {:ok, %Pattern{rung: "rank", stopped_at: %DateTime{}}} =
               LearnedAttention.stop(one.id, room.id, msg.id)

      next = post!(room, one_p, "another")
      assert attention_rows(next.id) == []
      assert %{prefill: nil, act: nil, ranked: [_ | _]} = Habits.suggest(one.id, room.id, @action)
    end

    test "an agent target never acts, even with act unlocked",
         %{room_x: room, one: one, agent: agent, one_p: one_p} do
      unlock_act!(one, room, "agent", agent.id)
      assert pattern(one, room, "agent", agent.id).accepted_prefills == 5

      msg = post!(room, one_p, "status update")
      assert attention_rows(msg.id) == []
      assert Habits.act_notices(one.id, [msg.id]) == %{}
    end

    test "never acts in a thread reply, for an opted-out user, or in a DM",
         %{room_x: room, one: one, two: two, one_p: one_p} do
      unlock_act!(one, room, "user", two.id)
      parent = post!(room, one_p, "parent")
      drain()
      {:ok, thread} = Chat.create_thread_for_message(room.id, parent.id)

      {:ok, reply} =
        Chat.post_message(%{
          space_id: room.id,
          thread_id: thread.id,
          participant_id: one_p.id,
          content_type: "text",
          content: "in thread"
        })

      assert attention_rows(reply.id) == []

      {:ok, _} = Habits.set_enabled(one.id, false)
      off = post!(room, one_p, "opted out")
      assert attention_rows(off.id) == []
      {:ok, _} = Habits.set_enabled(one.id, true)

      {:ok, dm} = Chat.find_or_create_dm(one.id, "user", two.id)
      unlock_act!(one, dm, "user", two.id)
      dm_p = dm_participant(dm, one)
      dm_msg = post!(dm, dm_p, "in a dm")
      assert attention_rows(dm_msg.id) == []
    end
  end

  defp dm_participant(space, user) do
    Repo.one!(
      from(p in Chat.Participant,
        where: p.space_id == ^space.id and p.participant_id == ^user.id
      )
    )
  end

  # ── Broad capture ──────────────────────────────────────────────────────────

  describe "broad capture" do
    test "a mention writes one chosen chat.mention signal per mentioned principal",
         %{room_x: room, one: one, two: two, one_p: one_p, two_p: two_p} do
      msg = post!(room, one_p, "hey @#{two_p.display_name} and @#{two_p.display_name}")

      assert [%Signal{} = s] = signals(one, "chat.mention")
      assert {s.target_type, s.target_id, s.outcome, s.rung} == {"user", two.id, "chosen", "none"}
      assert s.space_id == room.id and s.source_message_id == msg.id
    end

    test "opening a DM writes one chosen org-level chat.dm_target signal",
         %{one: one, two: two} do
      {:ok, _dm} = Chat.find_or_create_dm(one.id, "user", two.id)

      assert [%Signal{} = s] = signals(one, "chat.dm_target")
      assert {s.target_type, s.target_id, s.outcome, s.rung} == {"user", two.id, "chosen", "none"}
      assert s.space_id == nil
    end

    test "assigning an agent to a task writes one chosen tasks.assign_agent signal",
         %{one: one, agent: agent} do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Capture #{System.unique_integer([:positive])}",
          repo_url: "https://example.com/capture.git"
        })

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Capture task"})
      entry = %{"assignee_id" => agent.id, "assignee_type" => "agent"}

      {:ok, task} =
        Tasks.set_phase_assignees(
          task,
          %{"planning" => entry, "execution" => entry, "review" => entry},
          actor_user_id: one.id
        )

      assert [%Signal{} = s] = signals(one, "tasks.assign_agent")

      assert {s.target_type, s.target_id, s.outcome, s.rung} ==
               {"agent", agent.id, "chosen", "none"}

      # Re-saving the same agent is not a new assignment.
      {:ok, _} = Tasks.update_task(task, %{title: "Renamed"}, actor_user_id: one.id)
      assert [_] = signals(one, "tasks.assign_agent")
    end
  end
end
