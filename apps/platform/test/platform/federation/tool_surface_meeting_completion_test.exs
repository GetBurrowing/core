defmodule Platform.Federation.ToolSurfaceMeetingCompletionTest do
  use Platform.DataCase, async: true

  alias Platform.Federation.{ReturnSchemas, ToolArguments, ToolSurface}

  @tools ~w(meeting_scribe_complete meeting_triage_file)

  test "completion entrypoints are in the meetings bundle and have return contracts" do
    definitions = ToolSurface.tool_definitions()

    for name <- @tools do
      tool = Enum.find(definitions, &(&1.name == name))
      assert tool.bundle == "meetings"
      assert tool.returns_schema == ReturnSchemas.for_tool(name)
      for key <- [:meeting_id, :run_id, :transcript_id, :canvas_id, :snapshot_hash] do
        assert tool.parameters[key].required
      end
      refute Map.has_key?(tool.parameters, :agent_id)
    end
  end

  test "caller-supplied identity cannot authenticate a filing" do
    args = Map.new(~w(meeting_id run_id transcript_id canvas_id agent_id), &{&1, Ecto.UUID.generate()})
    args = args |> Map.put("action_items", []) |> Map.put("snapshot_hash", "test-snapshot")

    for name <- @tools do
      assert {:error, %{code: :unauthorized}} = ToolArguments.dispatch(name, args, %{})
    end
  end

  test "required canonical identities are checked before dispatch" do
    for name <- @tools do
      assert {:error, _} = ToolArguments.dispatch(name, %{}, %{})
    end
  end
end
