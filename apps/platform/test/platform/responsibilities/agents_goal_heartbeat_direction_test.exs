defmodule Platform.Responsibilities.AgentsGoalHeartbeatDirectionTest do
  @moduledoc """
  The goal direction and the direction-aware drive paragraph (task
  `01a0caa5` stage 1): `goal_direction/1` and `drive_instruction/2`.

  ## Literals, never re-derived

  Every expected drive paragraph below is typed out in full inside the
  test that asserts it. None is built from a module attribute or by
  calling the function under test: a test that asks the function what it
  should have said passes against any wording.

  Pure functions, no Repo, no named processes -> `async: true`.
  """

  use ExUnit.Case, async: true

  alias Platform.Responsibilities.Handlers.AgentsGoalHeartbeat, as: Handler

  @one [%{agent_id: "id-a", name: "A"}]

  describe "goal_direction/1" do
    test "beta's live growth goal is :grow" do
      assert Handler.goal_direction(
               "Grow the job-board backlog: keep it populated with new opportunities that " <>
                 "match the expected criteria defined in the project org memory."
             ) == :grow
    end

    test "Acme's live goal is :close" do
      assert Handler.goal_direction("Close backlog items in Suite") == :close
    end

    test "a reduce goal is :close" do
      assert Handler.goal_direction("Reduce open bugs") == :close
    end

    test "each listed grow form is :grow" do
      for word <-
            ~w(grow grows growing grown increase increases increasing populate populated populating) do
        assert Handler.goal_direction("#{word} the list") == :grow, word
      end
    end

    test "each listed close form is :close" do
      for word <-
            ~w(close closes closing closed reduce reduces reducing shrink shrinks shrinking) do
        assert Handler.goal_direction("#{word} the list") == :close, word
      end
    end

    test "the match is case-insensitive" do
      assert Handler.goal_direction("GROW signups") == :grow
      assert Handler.goal_direction("SHRINK the queue") == :close
    end

    test "a goal with no direction word is :neutral" do
      assert Handler.goal_direction("Ship 3 backlog items this week") == :neutral
    end

    test "a goal carrying both families is :neutral, not guessed" do
      assert Handler.goal_direction("Close the gap by increasing signups") == :neutral
    end

    test "a direction word inside a longer word does not match" do
      assert Handler.goal_direction("enclosed growth-hacking") == :neutral
      assert Handler.goal_direction("Disclosed regrowth") == :neutral
      assert Handler.goal_direction("Reductions in overgrown closets") == :neutral
    end

    test "a non-binary goal is :neutral" do
      assert Handler.goal_direction(nil) == :neutral
      assert Handler.goal_direction(%{missing?: true}) == :neutral

      assert Handler.goal_direction(%{missing?: true, reason: "no chat space carries a goal"}) ==
               :neutral
    end
  end

  describe "drive_instruction/2 :close" do
    test "[] is today's solo sentence, exactly" do
      assert Handler.drive_instruction([], :close) ==
               "You are the only agent working this goal. There is no one to delegate to; this is yours. Pick the single open item that most moves the measurement and work it this turn. Report what you picked and what changed."
    end

    test "a one-agent roster is today's delegate drive, exactly" do
      assert Handler.drive_instruction(@one, :close) ==
               "Pick the single open item that most moves the measurement. Assign it to one of these agents by creating or assigning a task, or work it yourself this turn. Report what you picked, who has it, and what changed.\nAgents you can delegate to: A (id-a)"
    end

    test ":unavailable is today's unavailable sentence, exactly" do
      assert Handler.drive_instruction(:unavailable, :close) ==
               "The delegate roster could not be read this hour, so it is not known whether anyone else can take work. Pick the single open item that most moves the measurement and work it this turn. Report what you picked and what changed."
    end

    test "drive_instruction/1 is the :close direction" do
      assert Handler.drive_instruction([]) ==
               "You are the only agent working this goal. There is no one to delegate to; this is yours. Pick the single open item that most moves the measurement and work it this turn. Report what you picked and what changed."

      assert Handler.drive_instruction(@one) ==
               "Pick the single open item that most moves the measurement. Assign it to one of these agents by creating or assigning a task, or work it yourself this turn. Report what you picked, who has it, and what changed.\nAgents you can delegate to: A (id-a)"

      assert Handler.drive_instruction(:unavailable) ==
               "The delegate roster could not be read this hour, so it is not known whether anyone else can take work. Pick the single open item that most moves the measurement and work it this turn. Report what you picked and what changed."
    end
  end

  describe "drive_instruction/2 :grow" do
    test "[] is the grow solo sentence, exactly" do
      text = Handler.drive_instruction([], :grow)

      assert text ==
               "You are the only agent working this goal. There is no one to delegate to; this is yours. Pick the single item to add that most moves the measurement toward the goal and add it this turn. Report what you added and what changed."

      refute text =~ "open item"
    end

    test "a one-agent roster is the grow delegate drive, exactly" do
      text = Handler.drive_instruction(@one, :grow)

      assert text ==
               "Pick the single item to add that most moves the measurement toward the goal. Assign it to one of these agents by creating or assigning a task, or add it yourself this turn. Report what you picked, who has it, and what changed.\nAgents you can delegate to: A (id-a)"

      refute text =~ "open item"
    end

    test ":unavailable is the grow unavailable sentence, exactly" do
      text = Handler.drive_instruction(:unavailable, :grow)

      assert text ==
               "The delegate roster could not be read this hour, so it is not known whether anyone else can take work. Pick the single item to add that most moves the measurement toward the goal and add it this turn. Report what you added and what changed."

      refute text =~ "open item"
    end
  end

  describe "drive_instruction/2 :neutral" do
    test "[] is the neutral solo sentence, exactly" do
      text = Handler.drive_instruction([], :neutral)

      assert text ==
               "You are the only agent working this goal. There is no one to delegate to; this is yours. Pick the single action that most moves the measurement toward the goal and take it this turn. Report what you did and what changed."

      refute text =~ "open item"
    end

    test "a one-agent roster is the neutral delegate drive, exactly" do
      text = Handler.drive_instruction(@one, :neutral)

      assert text ==
               "Pick the single action that most moves the measurement toward the goal. Assign it to one of these agents by creating or assigning a task, or take it yourself this turn. Report what you picked, who has it, and what changed.\nAgents you can delegate to: A (id-a)"

      refute text =~ "open item"
    end

    test ":unavailable is the neutral unavailable sentence, exactly" do
      text = Handler.drive_instruction(:unavailable, :neutral)

      assert text ==
               "The delegate roster could not be read this hour, so it is not known whether anyone else can take work. Pick the single action that most moves the measurement toward the goal and take it this turn. Report what you did and what changed."

      refute text =~ "open item"
    end
  end
end

defmodule Platform.Responsibilities.AgentsGoalHeartbeatDirectionFireTest do
  @moduledoc """
  The goal direction reaching the dispatched prompt (task `01a0caa5`
  stage 2), driven through the production entry point, `Router.fire/2`,
  with the native dispatcher stubbed by a capture module (the harness of
  `agents_goal_heartbeat_uncounted_test.exs`; the connected-delegate
  fixtures of `agents_goal_heartbeat_drive_test.exs`).

  A separate module in the same file because `async:` is per MODULE:
  the pure tests above stay `async: true`, these need `async: false`
  (`RuntimePresence` is a single named process, and the native
  dispatcher is a global Application env).

  ## Literals, never re-derived

  Every expected drive paragraph and the closing goal's whole prompt are
  typed out here. The closing-goal prompt is a hand copy of
  `@measured_literal` in `agents_goal_heartbeat_uncounted_test.exs`,
  not a reference to it: a control imported from, or rebuilt by, the
  code it guards moves with it.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Chat.Space
  alias Platform.Federation.RuntimePresence
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.AgentsGoalHeartbeat, as: Handler
  alias Platform.Responsibilities.Router
  alias Platform.Roles
  alias Platform.Roles.Role
  alias Platform.Roles.RoleResponsibility
  alias Platform.Tasks

  @key "agents.goal_heartbeat"
  @role_key "agents_leader"

  @growth_goal "Grow the job-board backlog: keep it populated with new opportunities that " <>
                 "match the expected criteria defined in the project org memory."

  @closing_goal "Close backlog items in Suite"

  @solo_sentence "You are the only agent working this goal. There is no one to delegate to; " <>
                   "this is yours."

  @grow_solo "You are the only agent working this goal. There is no one to delegate to; this is yours. Pick the single item to add that most moves the measurement toward the goal and add it this turn. Report what you added and what changed."

  @grow_delegate "Pick the single item to add that most moves the measurement toward the goal. Assign it to one of these agents by creating or assigning a task, or add it yourself this turn. Report what you picked, who has it, and what changed.\nAgents you can delegate to: "

  @neutral_solo "You are the only agent working this goal. There is no one to delegate to; this is yours. Pick the single action that most moves the measurement toward the goal and take it this turn. Report what you did and what changed."

  @close_solo "You are the only agent working this goal. There is no one to delegate to; this is yours. Pick the single open item that most moves the measurement and work it this turn. Report what you picked and what changed."

  # Hand copy of `@measured_literal` (agents_goal_heartbeat_uncounted_test.exs):
  # goal "Close backlog items in Suite", 3 open tasks, first beat, solo.
  @closing_literal """
  You are the agents leader. This hourly heartbeat is a prod to drive the goal, not a status report. Never invent a number: use only the figures given. If the delta is absent, say this is the first measurement rather than reporting no change.

  You are the agents leader. This is the hourly goal heartbeat for the agents space: a prod to move the goal, not a status report.

  Goal: Close backlog items in Suite
  Measurement: 3 open tasks (first measurement — no prior run to compare against)

  This is the first beat; there is no prior claim to check.

  You are the only agent working this goal. There is no one to delegate to; this is yours. Pick the single open item that most moves the measurement and work it this turn. Report what you picked and what changed.

  Lead with the measurement and its movement exactly as given above. Do not recompute it, do not round it, and do not invent a number that is not there. If the measurement says this is the first run, say so rather than reporting no change.

  Post your reply in this space. End it with one line that starts "Next:" naming the single action you will have done before the next beat.
  """

  defmodule CaptureDispatcher do
    @moduledoc false
    def maybe_dispatch(signal) do
      pid = Application.get_env(:platform, :goal_heartbeat_direction_capture_pid)
      if is_pid(pid), do: send(pid, {:captured_signal, signal})
      :ok
    end
  end

  setup do
    Application.put_env(:platform, :goal_heartbeat_direction_capture_pid, self())
    on_exit(fn -> Application.delete_env(:platform, :goal_heartbeat_direction_capture_pid) end)

    Application.put_env(
      :platform,
      :responsibility_router_native_dispatcher,
      {CaptureDispatcher, :maybe_dispatch}
    )

    on_exit(fn ->
      Application.delete_env(:platform, :responsibility_router_native_dispatcher)
    end)

    [spec] = Handler.register()
    {:ok, _row} = Responsibilities.upsert_by_key(spec)

    {:ok, project} =
      Tasks.create_project(%{
        name: "Goal Heartbeat Direction #{System.unique_integer([:positive])}"
      })

    %{project: project, agent: wire_leader!()}
  end

  # ── fixtures ─────────────────────────────────────────────────────────

  defp wire_leader! do
    Repo.insert!(
      %Role{
        key: @role_key,
        name: "Agents Leader",
        description: "test fixture",
        icon: "hero-bolt"
      },
      on_conflict: :nothing,
      conflict_target: :key
    )

    %RoleResponsibility{}
    |> RoleResponsibility.changeset(%{role_key: @role_key, responsibility_key: @key})
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:role_key, :responsibility_key])

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "goal-heartbeat-direction-#{System.unique_integer([:positive])}",
        name: "Agents Leader Direction Test",
        status: "active",
        kind: "native",
        runtime_type: "external",
        workspace_id: nil
      })
      |> Repo.insert!()

    {:ok, _} = Roles.assign_role(@role_key, agent.id)

    agent
  end

  defp goal_space!(agent, goal) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Agents direction #{System.unique_integer([:positive])}",
        slug: "agents-direction-#{System.unique_integer([:positive])}",
        kind: "channel",
        goal: goal,
        leader_agent_id: agent.id
      })

    space
  end

  defp add_open_tasks!(project, n) do
    for i <- 1..n do
      {:ok, _} =
        Tasks.create_task(%{project_id: project.id, title: "open #{i}", status: "in_progress"})
    end
  end

  # Mirrors `agents_goal_heartbeat_drive_test.exs`.
  defp agent!(name) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      slug: "direction-#{String.downcase(String.replace(name, " ", "-"))}-#{n}",
      name: "#{name} #{n}",
      status: "active"
    })
  end

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      email: "direction-#{n}@example.com",
      name: "Direction Owner #{n}",
      oidc_sub: "oidc-direction-#{n}"
    })
  end

  defp runtime!(agent, features) do
    n = System.unique_integer([:positive])
    runtime_id = "direction-runtime-#{n}"

    Repo.insert!(%AgentRuntime{
      runtime_id: runtime_id,
      agent_id: agent.id,
      owner_user_id: user!().id,
      display_name: "Direction Runtime #{n}",
      status: "active",
      auth_token_hash: "hash-#{n}",
      metadata: %{"client_info" => %{"features" => features}}
    })

    RuntimePresence.track(runtime_id)
    on_exit(fn -> RuntimePresence.untrack(runtime_id) end)

    runtime_id
  end

  # Fires once and returns the captured prompt. `{:ok, :dispatched}`,
  # `assert_receive` and the agent_id / goal asserts are the positive
  # controls: without them every `refute` below passes on a fire that
  # never happened.
  defp fire_prompt!(agent, goal) do
    {result, _log} =
      with_log([level: :info], fn ->
        Router.fire(@key, %{kind: :cron, fired_at: DateTime.utc_now()})
      end)

    assert {:ok, :dispatched} = result
    assert_receive {:captured_signal, signal}
    assert signal.metadata.agent_id == agent.id
    assert signal.metadata.prompt =~ "Goal: " <> goal

    signal.metadata.prompt
  end

  # The solo drive paragraph: the "\n\n"-separated block that opens with
  # the solo sentence.
  defp solo_paragraph(prompt) do
    prompt |> String.split("\n\n") |> Enum.find(&String.starts_with?(&1, @solo_sentence))
  end

  # ── the four directions ──────────────────────────────────────────────

  test "growth goal, solo: the grow drive renders and no open item is asked for", ctx do
    _space = goal_space!(ctx.agent, @growth_goal)

    prompt = fire_prompt!(ctx.agent, @growth_goal)

    assert prompt =~ @grow_solo
    assert prompt =~ @solo_sentence
    refute prompt =~ "open item"
  end

  test "closing goal: the whole prompt is the hand-copied measured literal", ctx do
    _space = goal_space!(ctx.agent, @closing_goal)
    add_open_tasks!(ctx.project, 3)

    assert fire_prompt!(ctx.agent, @closing_goal) == @closing_literal
  end

  test "a goal with no direction word renders the neutral drive", ctx do
    goal = "Ship 3 demos"
    _space = goal_space!(ctx.agent, goal)

    prompt = fire_prompt!(ctx.agent, goal)

    assert prompt =~ @neutral_solo
    refute prompt =~ "open item"
  end

  test "growth goal with one connected delegate: the grow delegate drive names it", ctx do
    runtime!(ctx.agent, [])
    alpha = agent!("Delegate Alpha")
    runtime!(alpha, ["system_event_prompt"])

    _space = goal_space!(ctx.agent, @growth_goal)

    prompt = fire_prompt!(ctx.agent, @growth_goal)

    assert prompt =~ @grow_delegate <> "#{alpha.name} (#{alpha.id})"
    refute prompt =~ @solo_sentence
    refute prompt =~ "open item"
  end

  # ── positive control ────────────────────────────────────────────────

  test "positive control: a growth and a closing goal fired in one test get different drives",
       ctx do
    space = goal_space!(ctx.agent, @growth_goal)

    grow_para = solo_paragraph(fire_prompt!(ctx.agent, @growth_goal))

    {:ok, _} = Chat.update_space(Repo.get!(Space, space.id), %{goal: @closing_goal})

    close_para = solo_paragraph(fire_prompt!(ctx.agent, @closing_goal))

    assert grow_para == @grow_solo
    assert close_para == @close_solo
    assert grow_para != close_para
  end
end
