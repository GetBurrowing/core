defmodule Platform.Goals.SpaceUpdatesTest do
  @moduledoc """
  Goals 7/8 stage 4 (task 01a1dfc1-dffb): after the coach closes a check-in
  on a goal opened to spaces, each space gets at most one short update, and
  only when the number or the plan changed.
  """
  use Platform.DataCase, async: false

  import Platform.GoalsFixtures
  import Platform.Goals.OutcomeFixtures

  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, AttentionRouter, Message, Participant}
  alias Platform.Goals
  alias Platform.Goals.{Clock, Entry, Grant, SpaceUpdates, WakeUp}

  defmodule StubAgentChat do
    @moduledoc false
    def chat(_message, _opts), do: {:ok, %{content: "Noted.", model: "stub", usage: %{}}}
  end

  defmodule FailingPoster do
    @moduledoc false
    def post(_attrs), do: {:error, :refused_by_test}
  end

  setup do
    c = setup_outcome()
    {:ok, goal} = Goals.update_goal(c.owner, c.goal.id, %{target_value: Decimal.new(10_000)})
    space = space!(c.org)
    join_space!(space.id, :user, c.owner.id)
    coach_p = join_space!(space.id, :agent, c.coach.id)
    {:ok, _} = Goals.open_goal(c.owner, goal.id, {:space, space.id})

    on_exit(fn -> Application.delete_env(:goals, :space_update_poster) end)

    Map.merge(c, %{goal: goal, space: space, coach_p: coach_p})
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp updates(space_id) do
    Repo.all(
      from(m in Message,
        where: m.space_id == ^space_id and fragment("?->>'source'", m.metadata) == "goals.update",
        order_by: [asc: m.inserted_at, asc: m.id]
      )
    )
  end

  defp message_count, do: Repo.aggregate(Message, :count)

  defp participant_count(space_id),
    do: Repo.aggregate(from(p in Participant, where: p.space_id == ^space_id), :count)

  defp grant(goal, space),
    do: Repo.one!(from(g in Grant, where: g.goal_id == ^goal.id and g.space_id == ^space.id))

  defp close_do!(c, goal \\ nil, attrs \\ %{}) do
    wake = fire(goal || c.goal)
    {:ok, result} = Goals.close_wake_up(c.coach, wake.id, "do", prediction(attrs))
    result
  end

  defp close_wait!(c, goal \\ nil) do
    wake = fire(goal || c.goal)
    {:ok, result} = Goals.close_wake_up(c.coach, wake.id, "wait", %{reason: "Nothing new"})
    result
  end

  defp log!(c, value) do
    {:ok, _} = Goals.log_reading(c.owner, c.goal.id, %{value: value, measured_at: Clock.now()})
  end

  defp agent_participant_ids(space_id) do
    MapSet.new(Chat.list_participants(space_id, participant_type: "agent"), & &1.id)
  end

  defp agent_decisions(message, space_id) do
    {:ok, decisions} = AttentionRouter.route(message)
    agents = agent_participant_ids(space_id)
    Enum.filter(decisions, &MapSet.member?(agents, &1.participant_id))
  end

  defp at_bracket, do: "@" <> "["

  # Core's own router tests start the router and the mutex store the same
  # way: the test app does not run them by default.
  defp start_router! do
    for {key, value} <- [chat_agent_module: StubAgentChat, chat_agent_dispatch_mode: :sync] do
      previous = Application.fetch_env(:platform, key)
      Application.put_env(:platform, key, value)

      on_exit(fn ->
        case previous do
          {:ok, old} -> Application.put_env(:platform, key, old)
          :error -> Application.delete_env(:platform, key)
        end
      end)
    end

    for server <- [AttentionRouter, ActiveAgentStore] do
      pid = Process.whereis(server) || start_supervised!({server, []})
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end

    :ok
  end

  # ── the stream ───────────────────────────────────────────────────────

  test "do, wait, a new number, ask: one update each time something changed", c do
    first = close_do!(c, nil, %{title: "Walk to work"})

    assert [m1] = updates(c.space.id)
    assert m1.participant_id == c.coach_p.id
    assert m1.metadata == %{"source" => "goals.update"}
    assert m1.content_type == "text"
    assert [line1, line2] = String.split(m1.content, "\n")
    assert String.starts_with?(line1, c.goal.title <> ": ")
    assert line1 == "#{c.goal.title}: Target: 10,000 steps"
    assert line2 == "#{c.coach.name} did: Walk to work"
    refute m1.content =~ c.goal.id
    refute m1.content =~ first.wake_up.id

    # wait, no new reading: nothing.
    close_wait!(c)
    assert length(updates(c.space.id)) == 1
    assert grant(c.goal, c.space).last_update_wake_up_id == first.wake_up.id

    # wait after the owner logs a value: one update, the number, no second line.
    log!(c, 4242)
    third = close_wait!(c)
    assert [_, m3] = updates(c.space.id)
    assert m3.content == "#{c.goal.title}: 4,242 of 10,000 steps"
    assert grant(c.goal, c.space).last_update_wake_up_id == third.wake_up.id
    assert grant(c.goal, c.space).last_update_number =~ "|4242"

    # wait again with the same number: nothing.
    close_wait!(c)
    assert length(updates(c.space.id)) == 2

    # ask addressed to the owner: the entry title, never the body or payload.
    wake = fire(c.goal)

    {:ok, %{ask: ask}} =
      Goals.close_wake_up(
        c.coach,
        wake.id,
        "ask",
        ask_attrs(%{
          title: "Should the walk count twice",
          body: "SECRET-BODY",
          payload: %{"draft" => "SECRET-DRAFT"},
          addressed_user_ids: [c.owner.id]
        })
      )

    assert [_, _, m4] = updates(c.space.id)
    assert m4.content =~ "#{c.coach.name} asked: Should the walk count twice"
    refute m4.content =~ "SECRET-BODY"
    refute m4.content =~ "SECRET-DRAFT"

    # Control: the secrets are there to leak.
    {:ok, asks} = Goals.list_asks(c.owner, c.goal.id)
    assert Enum.any?(asks, &(&1.id == ask.id and &1.body == "SECRET-BODY"))
    assert Enum.any?(asks, &(&1.payload["draft"] == "SECRET-DRAFT"))
  end

  test "a goal with no source: a wait posts nothing, a do posts no reading value", c do
    goal =
      goal!(c.owner, c.org, %{
        coach_agent_id: c.coach.id,
        agent_mode: "do",
        outreach: "pushy",
        rhythm: "daily",
        unit: "calls",
        target_value: Decimal.new(50)
      })

    {:ok, _} = Goals.open_goal(c.owner, goal.id, {:space, c.space.id})
    log!(c, 777)

    close_wait!(c, goal)
    assert updates(c.space.id) == []

    close_do!(c, goal, %{title: "Call three people"})
    assert [m] = updates(c.space.id)
    [line1 | _] = String.split(m.content, "\n")
    assert line1 == "#{goal.title}: Target: 50 calls"
    refute line1 =~ "777"
  end

  test "publish/5 twice for the same check-in posts once", c do
    result = close_do!(c)
    assert length(updates(c.space.id)) == 1

    assert SpaceUpdates.publish(c.coach, c.goal.id, result.wake_up, result.entry, []) == []
    assert SpaceUpdates.publish(c.coach, c.goal, result.wake_up, result.entry, []) == []
    assert length(updates(c.space.id)) == 1
  end

  test "two spaces get one update each; a space without the coach gets none", c do
    second = space!(c.org)
    join_space!(second.id, :user, c.owner.id)
    join_space!(second.id, :agent, c.coach.id)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:space, second.id})

    without = space!(c.org)
    join_space!(without.id, :user, c.owner.id)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:space, without.id})
    people = participant_count(without.id)

    close_do!(c)

    assert length(updates(c.space.id)) == 1
    assert length(updates(second.id)) == 1
    assert updates(without.id) == []
    assert participant_count(without.id) == people
    assert Chat.get_agent_participant(without.id, c.coach.id) == nil
  end

  test "a personal goal posts nothing anywhere, even with tasks", c do
    goal =
      goal!(c.owner, c.org, %{
        coach_agent_id: c.coach.id,
        agent_mode: "do",
        outreach: "pushy",
        rhythm: "daily",
        source_key: "self_reported",
        unit: "steps"
      })

    assert goal.kind == "personal"
    project = project(c.org)
    before = message_count()

    result =
      close_do!(c, goal, %{
        task: %{"project_id" => project.id, "title" => "Do it", "description" => "Now"}
      })

    assert [_task] = result.tasks
    assert message_count() == before
  end

  test "tasks handed out are counted and named on the second line", c do
    project = project(c.org)

    result =
      close_do!(c, nil, %{
        title: "Split it",
        task: [
          %{"project_id" => project.id, "title" => "One", "description" => "First"},
          %{"project_id" => project.id, "title" => "Two", "description" => "Second"}
        ]
      })

    assert length(result.tasks) == 2
    assert [m] = updates(c.space.id)

    assert m.content =~
             "#{c.coach.name} did: Split it Tasks handed out: 2 (#{c.coach.name}, #{c.coach.name})."

    refute m.content =~ "One"
    refute m.content =~ "First"
  end

  # ── mentions and routing ─────────────────────────────────────────────

  test "a mention in the title or entry is inert, while the same text unescaped is not", c do
    start_router!()
    named = agent!()
    named_p = join_space!(c.space.id, :agent, named.id)
    {:ok, _} = Chat.add_space_agent(c.space.id, named.id, role: "member")
    token = at_bracket() <> named.name <> "]"

    {:ok, goal} = Goals.update_goal(c.owner, c.goal.id, %{title: "Ship " <> token})
    people = participant_count(c.space.id)

    close_do!(c, nil, %{title: "Ask " <> token})

    assert [m] = updates(c.space.id)
    refute String.contains?(m.content, at_bracket())
    assert m.content =~ named.name
    assert participant_count(c.space.id) == people
    {:ok, decisions} = AttentionRouter.route(m)
    refute Enum.any?(decisions, &(&1.reason in [:mention, :multi_mention]))

    # Positive control: the same text, unescaped, from an admin, does route.
    admin = root_admin!()
    admin_p = join_space!(c.space.id, :user, admin.id)

    {:ok, raw} =
      Chat.post_message(%{
        space_id: c.space.id,
        participant_id: admin_p.id,
        content_type: "text",
        content: "#{goal.title}\nAsk " <> token
      })

    {:ok, raw_decisions} = AttentionRouter.route(raw)

    assert Enum.any?(
             raw_decisions,
             &(&1.participant_id == named_p.id and &1.reason in [:mention, :multi_mention])
           )
  end

  test "the post reaches at most the one other agent holding the mutex", c do
    start_router!()
    other = agent!()
    other_p = join_space!(c.space.id, :agent, other.id)

    close_do!(c)
    assert [m1] = updates(c.space.id)
    ActiveAgentStore.clear_active(c.space.id)
    assert agent_decisions(m1, c.space.id) == []

    ActiveAgentStore.set_active(c.space.id, c.coach_p.id)
    assert agent_decisions(m1, c.space.id) == []

    ActiveAgentStore.set_active(c.space.id, other_p.id)

    assert agent_decisions(m1, c.space.id) == [
             %{participant_id: other_p.id, reason: :active_agent}
           ]

    {:ok, _reply} =
      Chat.post_message(%{
        space_id: c.space.id,
        participant_id: other_p.id,
        content_type: "text",
        content: "Thanks, noted."
      })

    assert length(updates(c.space.id)) == 1
  end

  # ── failure and the switch ───────────────────────────────────────────

  test "a failing post leaves the check-in closed and the entry written", c do
    Application.put_env(:goals, :space_update_poster, {FailingPoster, :post})
    wake = fire(c.goal)

    assert {:ok, %{entry: entry}} =
             Goals.close_wake_up(c.coach, wake.id, "do", prediction(%{title: "Still lands"}))

    assert Repo.one!(from(w in WakeUp, where: w.id == ^wake.id)).status == "closed"
    assert Repo.one!(from(e in Entry, where: e.id == ^entry.id)).title == "Still lands"
    assert updates(c.space.id) == []
  end

  test "with the switch off nothing is posted", c do
    wake = fire(c.goal)
    Application.put_env(:goals, :enabled, false)
    before = message_count()

    assert Goals.close_wake_up(c.coach, wake.id, "do", prediction()) == {:error, :goals_disabled}
    assert SpaceUpdates.publish(c.coach, c.goal.id, %{wake | outcome: "do"}, nil, []) == []
    assert message_count() == before
  end

  test "text/1 keeps to two lines and 500 characters" do
    long = String.duplicate("x", 600)

    text =
      SpaceUpdates.text(%{
        title: long,
        number_sentence: "No number to follow yet",
        outcome: "do",
        coach_name: "Coach",
        entry_title: long,
        task_assignees: []
      })

    assert String.length(text) == 500
    assert length(String.split(text, "\n")) <= 2

    assert SpaceUpdates.text(%{
             title: "T",
             number_sentence: "S",
             outcome: "wait",
             coach_name: "C",
             entry_title: "E",
             task_assignees: []
           }) == "T: S"
  end
end
