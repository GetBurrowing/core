defmodule Platform.Federation.ToolArgumentsStrictTest do
  @moduledoc """
  Opt-in refusal of undeclared argument keys (task 01a0acc3).

  `task_list` used to drop any key it did not declare and answer with the
  unfiltered list, so a caller passing `assignee_id` read every task on the
  board as its own. These tests pin the refusal through `validate/2` and
  `dispatch/3` — the door both transports use — and pin its SCOPE from the
  other side: the reserved `space_id` key still passes, and a tool that is not
  opted in answers exactly as it did before.

  `ToolSurface.execute/3` is deliberately never called here: it is `@doc false`
  and bypasses argument policy, so a refusal test through it would test
  nothing.
  """
  use Platform.DataCase, async: false

  alias Platform.Federation.ToolArguments
  alias Platform.Federation.ToolSurface
  alias Platform.Tasks

  defp task_list_definition do
    Enum.find(ToolSurface.tool_definitions(), &(&1.name == "task_list"))
  end

  # Derived from the catalogue itself, not from `ToolArguments.declared_keys/1`
  # and not hand-copied, so the test cannot agree with the implementation by
  # sharing its bug.
  defp task_list_declared_keys_from_catalogue do
    task_list_definition()
    |> Map.fetch!(:parameters)
    |> Enum.flat_map(fn {key, spec} ->
      [to_string(key) | Enum.map(Map.get(spec, :aliases, []), &to_string/1)]
    end)
  end

  describe "the strict list itself" do
    test "is exactly task_list — widening it must show up as a diff here" do
      assert ToolArguments.strict_tools() == ["task_list"]
    end

    test "tolerates exactly space_id as a transport key" do
      assert ToolArguments.transport_reserved() == ["space_id"]
    end
  end

  describe "task_list refuses undeclared keys" do
    test "a single unknown key is refused, named, and recoverable (validate/2)" do
      assert {:error, envelope} = ToolArguments.validate("task_list", %{"foo" => 1})

      assert envelope.code == :unknown_parameter
      assert envelope.recoverable == true
      assert envelope.unknown_parameters == ["foo"]
      assert envelope.error == "task_list: unknown parameter(s) foo"
      refute envelope.error =~ "`"
      assert envelope.suggestion =~ "Declared parameters for task_list:"
      assert envelope.suggestion =~ "project_id"
    end

    test "dispatch/3 returns the same refusal and never reaches the handler" do
      assert {:error, envelope} = ToolArguments.dispatch("task_list", %{"foo" => 1}, %{})
      assert envelope.code == :unknown_parameter
      assert envelope.unknown_parameters == ["foo"]
    end

    test "an assignee filter alongside a declared filter names only the undeclared key" do
      {:ok, project} =
        Tasks.create_project(%{name: "Strict #{System.unique_integer([:positive])}"})

      args = %{"assignee" => Ecto.UUID.generate(), "project_id" => project.id}

      assert {:error, envelope} = ToolArguments.dispatch("task_list", args, %{})
      assert envelope.code == :unknown_parameter
      assert envelope.unknown_parameters == ["assignee"]
      assert envelope.error == "task_list: unknown parameter(s) assignee"
      refute envelope.error =~ "project_id"
    end

    # Stage 3 declared assignee_id / assignee_type, and declaring them is the
    # ONLY thing that moved them out of this refusal: the declared set is read
    # from tool_definitions/0, so ToolArguments itself did not change.
    test "assignee_id and assignee_type pass once declared (stage 3); assignee still does not" do
      assert ToolArguments.validate("task_list", %{
               "assignee_id" => Ecto.UUID.generate(),
               "assignee_type" => "agent"
             }) == :ok

      assert {:error, %{code: :unknown_parameter, unknown_parameters: ["assignee"]}} =
               ToolArguments.validate("task_list", %{"assignee" => Ecto.UUID.generate()})
    end

    test "two unknown keys are both named, sorted" do
      assert {:error, envelope} =
               ToolArguments.validate("task_list", %{"zeta" => 1, "assignee" => "x"})

      assert envelope.unknown_parameters == ["assignee", "zeta"]
      assert envelope.error == "task_list: unknown parameter(s) assignee, zeta"
    end
  end

  describe "the reserved transport key" do
    # POSITIVE CONTROL. Both transports read args["space_id"] to build context
    # and the legacy openclaw plugin tells agents to send it to task_list.
    # Refusing it would break working callers.
    test "space_id alone passes validate/2 and dispatch/3 answers with the envelope" do
      args = %{"space_id" => Ecto.UUID.generate()}

      assert ToolArguments.validate("task_list", args) == :ok
      assert {:ok, envelope} = ToolArguments.dispatch("task_list", args, %{})
      assert is_list(envelope.tasks)
      assert Map.has_key?(envelope, :total)
    end

    # The pair to the control above: tolerating space_id must not become
    # tolerating everything.
    test "a non-reserved key alongside space_id is still refused" do
      args = %{"space_id" => Ecto.UUID.generate(), "foo" => 1}

      assert {:error, envelope} = ToolArguments.validate("task_list", args)
      assert envelope.code == :unknown_parameter
      assert envelope.unknown_parameters == ["foo"]
    end
  end

  describe "declared keys pass" do
    test "every declared key and alias of task_list passes, derived from tool_definitions/0" do
      keys = task_list_declared_keys_from_catalogue()

      # Guard against a vacuous pass: the catalogue must actually declare keys.
      assert "project_id" in keys
      assert length(keys) >= 6

      for key <- keys do
        assert ToolArguments.validate("task_list", %{key => "x"}) == :ok,
               "declared key #{key} was refused"
      end

      all = Map.new(keys, &{&1, "x"})
      assert ToolArguments.validate("task_list", all) == :ok
    end

    test "declared_keys/1 matches the catalogue" do
      assert Enum.sort(ToolArguments.declared_keys("task_list")) ==
               Enum.sort(task_list_declared_keys_from_catalogue())
    end
  end

  describe "scope guard: tools not opted in are untouched" do
    test "task_get is not refused for an undeclared key" do
      args = %{"task_id" => Ecto.UUID.generate(), "foo" => 1}

      assert ToolArguments.validate("task_get", args) == :ok

      result = ToolArguments.dispatch("task_get", args, %{})
      refute match?({:error, %{code: :unknown_parameter}}, result)
    end

    test "for every non-strict tool, adding an undeclared key changes nothing validate/2 says" do
      strict = ToolArguments.strict_tools()

      non_strict =
        ToolSurface.tool_definitions()
        |> Enum.map(& &1.name)
        |> Enum.reject(&(&1 in strict))

      assert length(non_strict) > 50

      for tool <- non_strict,
          base <- [%{}, %{"task_id" => Ecto.UUID.generate()}] do
        assert ToolArguments.validate(tool, Map.put(base, "foo_undeclared", 1)) ==
                 ToolArguments.validate(tool, base),
               "#{tool}: an undeclared key changed validate/2's answer"
      end
    end
  end
end
