defmodule Platform.Federation.ToolArgumentsDispatchTest do
  @moduledoc """
  The gate itself: `ToolArguments.validate/2` and the `dispatch/3` composition
  the two federation transports call.

  The regression cases are chosen so that they fail *differently* before the
  gate exists. A gate proven against one symptom would be a gate that happens
  to fix one tool; these four prove it covers the class:

    * `space_list_agents` raises `ArgumentError` from the query builder,
    * `validation_evaluate` raises `Ecto.NoResultsError` from inside a
      `Repo.transaction`,
    * `canvas_get` does not raise at all — it misattributes, reporting that a
      canvas the caller never named does not exist, and telling them not to
      retry,
    * `task_complete` pattern-matches its required key in the clause head, so
      omitting it falls through to the catch-all and reports that a tool which
      exists is unknown.

  Alongside them sit the two cases that constrain the gate from the other
  side: an alias-only call must keep working (live runtimes send it), and an
  exempt parameter must not be enforced.

  `stage_list` was the original query-builder exemplar here and is no longer
  one. Task 019fa609 stage 5 gave it a second entry point (`plan_id` OR
  `task_id`), which makes its requirement CONDITIONAL and therefore not
  something a per-parameter gate can express — both parameters are declared
  `required: false` and the tool refuses on its own, `skill.get`-style. That
  is why the exemplar moved to `space_list_agents`, which fails the same way
  for the same reason and is still gated. `tool_surface_test.exs` owns the
  `stage_list` rule, including a test asserting this module finds nothing to
  enforce there.
  """
  use Platform.DataCase, async: false

  alias Platform.Federation.ToolArguments
  alias Platform.Federation.ToolSurface
  alias Platform.Tasks

  defp create_task do
    {:ok, project} =
      Tasks.create_project(%{name: "Gate Test Project #{System.unique_integer([:positive])}"})

    {:ok, epic} = Tasks.create_epic(%{project_id: project.id, name: "Gate Test Epic"})

    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, epic_id: epic.id, title: "Gate Test Task"})

    task
  end

  describe "validate/2" do
    test "passes when every declared-required key is present" do
      assert ToolArguments.validate("stage_start", %{"stage_id" => Ecto.UUID.generate()}) == :ok
    end

    test "refuses with a per-parameter code, not a generic one" do
      assert {:error, envelope} = ToolArguments.validate("stage_start", %{})

      assert envelope.code == :missing_stage_id,
             "a generic code would put a value on the wire that no tool's documented taxonomy contains"

      assert envelope.error == "stage_start: stage_id is required"
      assert envelope.recoverable == true
      assert envelope.suggestion =~ "stage_id"
      assert envelope.suggestion =~ "tools/list"
    end

    test "the message carries no backticks, so existing `=~` assertions survive" do
      assert {:error, envelope} = ToolArguments.validate("space_list_agents", %{})
      assert envelope.error =~ "space_id is required"
      refute envelope.error =~ "`"
    end

    test "refuses on the first missing parameter in declaration order" do
      assert {:error, envelope} = ToolArguments.validate("react", %{})
      assert envelope.code == :missing_emoji

      assert {:error, envelope} =
               ToolArguments.validate("react", %{"emoji" => "+1", "space_id" => "s"})

      assert envelope.code == :missing_message_id
    end

    test "presence only — an empty list, empty map or zero satisfies the requirement" do
      assert ToolArguments.validate("plan_create", %{
               "task_id" => Ecto.UUID.generate(),
               "stages" => []
             }) == :ok
    end

    test "a blank or whitespace-only string does not satisfy the requirement" do
      assert {:error, %{code: :missing_stage_id}} =
               ToolArguments.validate("stage_start", %{"stage_id" => "   "})

      assert {:error, %{code: :missing_stage_id}} =
               ToolArguments.validate("stage_start", %{"stage_id" => nil})
    end

    test "an alias satisfies the requirement in place of the declared key" do
      assert ToolArguments.validate("task_get", %{"id" => Ecto.UUID.generate()}) == :ok
      assert ToolArguments.validate("stage_complete", %{"id" => Ecto.UUID.generate()}) == :ok
      assert ToolArguments.validate("canvas.create", %{"initial_state" => %{}}) == :ok
    end

    test "exempt parameters are never enforced" do
      # `canvas.create` resolves space_id from the call context; a space-bound
      # runtime legitimately omits it. `document` is still enforced.
      assert {:error, %{code: :missing_document}} = ToolArguments.validate("canvas.create", %{})

      # task_create's title default is an in-source wire-compat promise.
      assert ToolArguments.validate("task_create", %{"project_id" => Ecto.UUID.generate()}) == :ok
    end

    test "a tool with no required parameters always passes" do
      assert ToolArguments.validate("project_list", %{}) == :ok
    end

    test "an unknown tool passes — refusing it is ToolAuthorization's decision" do
      assert ToolArguments.validate("no_such_tool", %{}) == :ok
    end
  end

  describe "dispatch/3 covers the class, not one symptom" do
    test "space_list_agents: today an ArgumentError from the query builder, now a named refusal" do
      assert {:error, envelope} = ToolArguments.dispatch("space_list_agents", %{}, %{})
      assert envelope.code == :missing_space_id
      assert envelope.error =~ "space_id is required"
      assert envelope.recoverable == true
    end

    test "stage_list is deliberately NOT covered here — its rule is conditional" do
      # Not an omission. `plan_id` XOR `task_id` cannot be stated as a
      # per-parameter requirement, so stage 5 declared both `required: false`
      # and moved the check into the handler. The gate finding nothing to
      # enforce is the correct answer, and the refusal still arrives.
      assert ToolArguments.validate("stage_list", %{}) == :ok

      assert {:error, %{code: :missing_plan_reference}} =
               ToolArguments.dispatch("stage_list", %{}, %{})
    end

    test "validation_evaluate: today an Ecto.NoResultsError, now a named refusal" do
      assert {:error, envelope} =
               ToolArguments.dispatch("validation_evaluate", %{"status" => "passed"}, %{})

      assert envelope.code == :missing_validation_id
      assert envelope.error =~ "validation_id is required"
      assert envelope.recoverable == true
    end

    test "canvas_get: today a misattributed unrecoverable 'not found', now a named refusal" do
      # The strongest case in the set. Before the gate this answered
      # `"Canvas not found: "` with `recoverable: false` — the caller is told a
      # canvas they never named does not exist, and told not to retry.
      assert {:error, envelope} = ToolArguments.dispatch("canvas_get", %{}, %{})
      assert envelope.code == :missing_canvas_id
      assert envelope.error =~ "canvas_id is required"
      refute envelope.error =~ "not found"
      assert envelope.recoverable == true
    end

    test "task_complete: today 'Unknown tool', now a named refusal" do
      # The only handler pattern-matching its required key in the clause head,
      # so omitting the key fell through to the catch-all and reported that a
      # tool which plainly exists is unknown.
      assert {:error, envelope} = ToolArguments.dispatch("task_complete", %{}, %{})
      assert envelope.code == :missing_task_id
      assert envelope.error =~ "task_id is required"
      refute envelope.error =~ "Unknown tool"
      assert envelope.recoverable == true
    end
  end

  describe "dispatch/3 does not break callers that work today" do
    test "task_get with the `id` alias and no task_id still succeeds" do
      task = create_task()

      assert {:ok, result} = ToolArguments.dispatch("task_get", %{"id" => task.id}, %{})
      assert result.id == task.id
    end

    test "the alias path reaches the same result as the declared key" do
      task = create_task()

      assert ToolArguments.dispatch("task_get", %{"id" => task.id}, %{}) ==
               ToolArguments.dispatch("task_get", %{"task_id" => task.id}, %{})
    end

    test "a well-formed call is handed through untouched" do
      task = create_task()

      assert ToolArguments.dispatch("task_get", %{"task_id" => task.id}, %{}) ==
               ToolSurface.execute("task_get", %{"task_id" => task.id}, %{})
    end
  end

  describe "the recorded @default_on_absence behaviour changes" do
    # Stage 1 classified these four as honest-but-defaulting: the handler
    # answers without the argument today, so the gate changes an outcome that
    # exists. Shipped knowingly, asserted here so the change is visible in a
    # diff rather than discovered in production.
    test "principal_search no longer answers an empty result set for a search it never ran" do
      # Pre-gate: `Map.get(args, "query", "")` then a min-length check, so this
      # returned `{:ok, %{results: []}}` — indistinguishable from "searched and
      # found nothing".
      assert {:ok, %{results: []}} = ToolSurface.execute("principal_search", %{}, %{})

      assert {:error, envelope} = ToolArguments.dispatch("principal_search", %{}, %{})
      assert envelope.code == :missing_query
      assert envelope.recoverable == true
    end

    test "the other three recorded defaults are refused rather than silently applied" do
      for {tool, param} <- [
            {"plan_create", "stages"},
            {"review_request_create", "items"},
            {"space_search_messages", "query"}
          ] do
        assert {tool, param} in Enum.map(ToolArguments.default_on_absence(), fn {t, p, _b} ->
                 {t, p}
               end),
               "#{tool}.#{param} should still be recorded as a known behaviour change"

        # Supply every OTHER required key so the refusal is unambiguously about
        # this parameter.
        args =
          for other <- ToolArguments.required_params(tool),
              other.key != param,
              into: %{},
              do: {other.key, Ecto.UUID.generate()}

        assert {:error, envelope} = ToolArguments.validate(tool, args)
        assert envelope.code == :"missing_#{param}"
      end
    end
  end
end
