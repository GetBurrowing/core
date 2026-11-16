defmodule Platform.Goals.ToolsTest do
  # Task 01a1dfc1-05b0, Goals 3/8 stage 4: the `goals` tool bundle, driven
  # end to end through `Platform.Goals.Tools.execute/3`. Flips the global
  # `:goals, :enabled` env and injects the clock, so not async.
  use Platform.DataCase, async: false

  import Platform.GoalsFixtures
  import Platform.Goals.OutcomeFixtures
  import Platform.Goals.NumberAssertions

  alias Platform.Goals
  alias Platform.Goals.{Clock, Extension, ToolDefinitions, Tools, WakeUp}

  setup do: setup_outcome()

  defp call(tool, args, %Platform.Agents.Agent{} = agent),
    do: Tools.execute(tool, args, %{agent_id: agent.id})

  defp date_after(days), do: Date.to_iso8601(Date.add(DateTime.to_date(Clock.now()), days))

  defp predicted(attrs),
    do:
      Map.merge(
        %{"prediction" => "This will help", "predicted_by" => date_after(3)},
        attrs
      )

  defp do_args(wake, extra \\ %{}),
    do: predicted(Map.merge(%{"wake_up_id" => wake.id, "title" => "Did a thing"}, extra))

  defp ask_args(wake, extra \\ %{}),
    do:
      predicted(
        Map.merge(%{"wake_up_id" => wake.id, "kind" => "question", "title" => "Try it?"}, extra)
      )

  defp wait_args(wake), do: %{"wake_up_id" => wake.id, "reason" => "Nothing due yet"}

  defp code({:error, %{code: code}}), do: code
  defp code(other), do: flunk("expected an error envelope, got #{inspect(other)}")

  defp wake_status(wake), do: Repo.one!(from(w in WakeUp, where: w.id == ^wake.id)).status

  test "the bundle has exactly seven goal_ tools, each saying a wake-up takes one outcome" do
    names = ToolDefinitions.names()
    assert names == ~w(goal_list goal_get goal_wake_up_get goal_do goal_ask goal_wait goal_retro)
    assert Enum.all?(names, &String.starts_with?(&1, "goal_"))
    assert Enum.map(ToolDefinitions.definitions(), & &1.name) == names

    for tool <- ToolDefinitions.definitions(),
        key <- [:name, :description, :returns, :limitations, :when_to_use] do
      value = Map.fetch!(tool, key)
      assert is_binary(value) and String.trim(value) != "", "#{tool.name}.#{key} is blank"
    end

    for tool <- ToolDefinitions.definitions() do
      assert tool.description =~ ToolDefinitions.one_outcome()
    end

    for tool <- ToolDefinitions.definitions(), {param, meta} <- tool.parameters do
      assert is_binary(meta.type), "#{tool.name}.#{param}"
      assert is_boolean(meta.required), "#{tool.name}.#{param}"
      assert is_binary(meta.description) and meta.description != "", "#{tool.name}.#{param}"
      refute param in [:agent_id, :coach_agent_id], "#{tool.name} takes #{param}"
    end
  end

  test "do, ask and wait close three wake-ups; goal_get shows them; a second close is refused",
       c do
    project = project(c.org)

    closes =
      for {tool, value} <- [{"goal_do", "10"}, {"goal_ask", "20"}, {"goal_wait", "30"}] do
        {:ok, reading} =
          Goals.log_reading(c.owner, c.goal.id, %{value: value, measured_at: Clock.now()})

        wake = fire(c.goal)
        assert wake.reading_id == reading.id

        assert {:ok, %{goals: [listed], total: 1}} = call("goal_list", %{}, c.coach)
        assert listed.id == c.goal.id
        assert listed.open_wake_up_id == wake.id
        assert listed.stalled == false

        args =
          case tool do
            "goal_do" ->
              do_args(wake, %{
                "task" => %{
                  "project_id" => project.id,
                  "title" => "Follow-up work",
                  "description" => "Useful work"
                }
              })

            "goal_ask" ->
              ask_args(wake)

            "goal_wait" ->
              wait_args(wake)
          end

        assert {:ok, result} = call(tool, args, c.coach)
        assert result.wake_up.status == "closed"
        assert result.entry.reading_id == reading.id
        Jason.encode!(result)
        {tool, wake, reading, Map.put(result, :predicted_by, args["predicted_by"])}
      end

    assert {:ok, got} = call("goal_get", %{"goal_id" => c.goal.id}, c.coach)
    Jason.encode!(got)

    entries = Map.new(got.entries, &{&1.kind, &1})
    assert Enum.sort(Map.keys(entries)) == ~w(action ask wait)

    for {tool, _wake, reading, result} <- closes do
      entry = Enum.find(got.entries, &(&1.id == result.entry.id))
      assert entry.reading_id == reading.id
      assert Enum.any?(got.readings, &(&1.id == reading.id))

      if tool != "goal_wait" do
        assert entry.prediction == "This will help"
        assert entry.predicted_by == result.predicted_by
      end
    end

    assert [ask] = got.asks
    assert ask.entry_id == entries["ask"].id
    assert ask.answers == []
    assert [task] = got.tasks
    assert task.title == "Follow-up work"
    assert got.number_status == "reading"
    assert got.number.latest.value == "30"
    assert %{next_wake_at: _} = got.clock

    for {tool, wake, _reading, _result} <- closes,
        again <- ["goal_do", "goal_ask", "goal_wait"] do
      before = row_counts()

      args =
        case again do
          "goal_do" -> do_args(wake)
          "goal_ask" -> ask_args(wake)
          "goal_wait" -> wait_args(wake)
        end

      assert code(call(again, args, c.coach)) == :wake_up_closed, "#{tool} then #{again}"
      assert row_counts() == before
    end
  end

  test "a non-coach gets exactly the answer for a goal that does not exist", c do
    wake = fire(c.goal)

    space = space!(c.org)
    join_space!(space.id, :user, c.owner.id)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:space, space.id})
    participant = agent!()
    join_space!(space.id, :agent, participant.id)
    assert {:ok, _} = Goals.get_goal(participant, c.goal.id)

    other_coach = agent!()
    _other = goal!(c.owner, c.org, %{coach_agent_id: other_coach.id, title: "Other"})
    idle = agent!()

    args_for = fn id ->
      %{
        "goal_get" => [%{"goal_id" => id}],
        "goal_wake_up_get" => [%{"wake_up_id" => id}, %{"goal_id" => id}],
        "goal_do" => [do_args(%{id: id})],
        "goal_ask" => [ask_args(%{id: id})],
        "goal_wait" => [wait_args(%{id: id})],
        "goal_retro" => [%{"wake_up_id" => id, "title" => "Review", "summary" => "What happened"}]
      }
    end

    for stranger <- [idle, other_coach, participant] do
      assert {:ok, %{goals: listed}} = call("goal_list", %{}, stranger)
      refute Enum.any?(listed, &(&1.id == c.goal.id))

      before = row_counts()

      for tool <- ToolDefinitions.names() -- ["goal_list"] do
        real =
          Map.fetch!(args_for.(c.goal.id), tool) ++
            if(tool == "goal_get", do: [], else: Map.fetch!(args_for.(wake.id), tool))

        random = Map.fetch!(args_for.(Ecto.UUID.generate()), tool)
        malformed = Map.fetch!(args_for.("not-a-uuid"), tool)
        [baseline | _] = Enum.map(random, &call(tool, &1, stranger))

        assert baseline ==
                 {:error,
                  %{
                    code: :not_found,
                    error: "No such goal.",
                    recoverable: false,
                    suggestion: "goal_list shows the goals you coach."
                  }}

        for args <- real ++ random ++ malformed do
          assert call(tool, args, stranger) == baseline,
                 "#{tool} #{inspect(args)} as #{stranger.name}"
        end
      end

      assert row_counts() == before
      assert wake_status(wake) == "open"
    end
  end

  test "switched off: every tool refuses, writes nothing, and nothing is registered", c do
    wake = fire(c.goal)
    Application.put_env(:goals, :enabled, false)
    before = row_counts()
    names = ToolDefinitions.names()

    assert names == ~w(goal_list goal_get goal_wake_up_get goal_do goal_ask goal_wait goal_retro) and
             Enum.all?(names, &String.starts_with?(&1, "goal_"))

    for tool <- names do
      args = do_args(wake, %{"goal_id" => c.goal.id, "reason" => "x"})
      assert code(call(tool, args, c.coach)) == :goals_disabled
    end

    assert row_counts() == before
    assert Repo.one!(from(w in WakeUp, where: w.id == ^wake.id)).status == "open"
    assert Extension.mcp_tool_bundles() == []
    refute "goals" in Platform.Extensions.tool_bundle_names()
    assert Extension.permissions() == []
    assert Platform.Extensions.validate() == :ok
  end

  test "switched on: the bundle is listed, mapped to goals.use and validates" do
    assert "goals" in Platform.Extensions.tool_bundle_names()
    assert Platform.Access.Registry.bundle_permission("goals") == "goals.use"
    assert Platform.Extensions.validate() == :ok
    refute "goals" in Platform.Access.Registry.undeclared_bundles()
    assert [%{name: "goals", tool_names: names}] = Extension.mcp_tool_bundles()
    assert names == ToolDefinitions.names()
  end

  test "no agent in the context is refused, and an agent_id in args is ignored", c do
    for context <- [%{}, %{agent_id: "not-a-uuid"}, %{agent_id: Ecto.UUID.generate()}, nil] do
      for tool <- ToolDefinitions.names() do
        args = %{"agent_id" => c.coach.id, "goal_id" => c.goal.id}
        assert code(Tools.execute(tool, args, context)) == :no_agent
      end
    end
  end

  test "an invented goal_ name is this bundle's unknown_tool", c do
    assert {:error, %{code: :unknown_tool, suggestion: suggestion}} =
             call("goal_madeup", %{}, c.coach)

    for name <- ToolDefinitions.names(), do: assert(suggestion =~ name)

    for name <- ["goal_madeup", "goal_list", "goal_anything_else"] do
      assert %{name: "goals"} = Platform.Extensions.tool_owner(name)
    end
  end

  test "guardrails refuse through the tools, allowed names them first, and wait still closes",
       c do
    project = project(c.org)

    task = %{
      "project_id" => project.id,
      "title" => "Work",
      "description" => "Useful work"
    }

    cases = [
      {%{agent_mode: "advise"}, "do", "goal_do", &do_args(&1), :mode_forbids_do},
      {%{agent_mode: "coach"}, "do_with_task", "goal_do", &do_args(&1, %{"task" => task}),
       :mode_forbids_task},
      {%{agent_mode: "do", outreach: "off"}, "ask", "goal_ask", &ask_args(&1), :outreach_off}
    ]

    for {settings, key, tool, args, refusal} <- cases do
      {:ok, goal} = Goals.update_goal(c.owner, c.goal.id, settings)
      wake = fire(goal)

      assert {:ok, %{allowed: allowed}} =
               call("goal_wake_up_get", %{"wake_up_id" => wake.id}, c.coach)

      assert allowed[key] == refusal
      assert allowed["wait"] == true
      before = row_counts()
      assert {:error, %{code: ^refusal, recoverable: true}} = call(tool, args.(wake), c.coach)
      assert row_counts() == before
      assert wake_status(wake) == "open"
      assert {:ok, _} = call("goal_wait", wait_args(wake), c.coach)
    end

    # Coach mode still allows a do without a task.
    {:ok, goal} = Goals.update_goal(c.owner, c.goal.id, %{agent_mode: "coach"})
    wake = fire(goal)
    {:ok, %{allowed: allowed}} = call("goal_wake_up_get", %{"goal_id" => goal.id}, c.coach)
    assert allowed["do"] == true
    assert {:ok, _} = call("goal_do", do_args(wake), c.coach)

    # Gentle: one open ask, the second is refused.
    {:ok, goal} = Goals.update_goal(c.owner, c.goal.id, %{outreach: "gentle"})
    first = fire(goal)
    {:ok, %{allowed: allowed}} = call("goal_wake_up_get", %{"wake_up_id" => first.id}, c.coach)
    assert allowed["ask"] == true
    assert {:ok, _} = call("goal_ask", ask_args(first), c.coach)

    second = fire(goal)
    {:ok, %{allowed: allowed}} = call("goal_wake_up_get", %{"wake_up_id" => second.id}, c.coach)
    assert allowed["ask"] == :ask_cap_reached
    before = row_counts()

    assert {:error, %{code: :ask_cap_reached, recoverable: true}} =
             call("goal_ask", ask_args(second), c.coach)

    assert row_counts() == before
    assert {:ok, _} = call("goal_wait", wait_args(second), c.coach)

    {:ok, %{allowed: allowed}} = call("goal_wake_up_get", %{"wake_up_id" => second.id}, c.coach)
    assert Map.values(allowed) |> Enum.uniq() == [:wake_up_closed]
  end

  test "missing predictions, a blank reason and a bad field are recoverable refusals", c do
    wake = fire(c.goal)
    before = row_counts()

    assert {:error, %{code: :prediction_required, recoverable: true}} =
             call("goal_do", %{"wake_up_id" => wake.id, "title" => "Work"}, c.coach)

    assert {:error, %{code: :reason_required, recoverable: true}} =
             call("goal_wait", %{"wake_up_id" => wake.id, "reason" => " "}, c.coach)

    assert {:error, %{code: :invalid, messages: messages}} =
             call("goal_do", do_args(wake, %{"predicted_change" => "lots"}), c.coach)

    assert Map.has_key?(messages, :predicted_change)
    assert row_counts() == before
    assert wake_status(wake) == "open"
  end

  test "a goal that cannot be measured returns no number through either read tool", c do
    goal = goal!(c.owner, c.org, %{coach_agent_id: c.coach.id, title: "Unmeasured"})
    wake = fire(goal)

    assert {:ok, read} = call("goal_wake_up_get", %{"wake_up_id" => wake.id}, c.coach)
    Jason.encode!(read)
    assert number_free?(read.briefing["number"])

    block =
      read.text
      |> String.split("## The number\n")
      |> List.last()
      |> String.split("## Since the last check-in")
      |> hd()

    refute Regex.match?(~r/\d/, block)

    assert {:ok, got} = call("goal_get", %{"goal_id" => goal.id}, c.coach)
    assert got.number_status == "cannot_measure"
    assert Enum.sort(Map.keys(got.number)) == [:reason, :source_key, :source_label]
    assert number_free?(got.number)

    # Positive control: a measured goal's number is not number-free.
    {:ok, _} = Goals.log_reading(c.owner, c.goal.id, %{value: 4242, measured_at: Clock.now()})
    assert {:ok, measured} = call("goal_get", %{"goal_id" => c.goal.id}, c.coach)
    assert measured.number_status == "reading"
    refute number_free?(measured.number)
  end
end

