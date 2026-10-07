defmodule Platform.CodeMode.DocsTest do
  @moduledoc """
  Task 01a114a8 stage 3: `suite_run_describe` / `Platform.CodeMode.Docs`
  declare exactly the caller's effective tools. The central case is
  negative: a runtime without the `plan` bundle is never shown a `plan_*`
  declaration, because docs that advertise an uncallable tool send a script
  into a `forbidden` it could not have avoided.
  """

  use PlatformWeb.ConnCase, async: false

  import Platform.CodeModeFixtures

  alias Platform.CodeMode.Docs
  alias Platform.Federation.ReturnSchemas
  alias Platform.Federation.ToolAuthorization
  alias Platform.Federation.ToolSurface

  setup do
    %{agent: insert_agent!()}
  end

  # A declaration line for a top-level binding: `  plan_get(args...`.
  # Only inside `declare const suite`, and not the generic `call`.
  defp declared(docs) do
    [_preamble, suite] = String.split(docs, "declare const suite: {", parts: 2)

    ~r/^  ([a-z_.]+)\(/m
    |> Regex.scan(suite)
    |> Enum.map(&List.last/1)
    |> Enum.reject(&(&1 == "call"))
  end

  defp indexed(docs), do: Regex.scan(~r/^suite\.([a-z_.]+)\(/m, docs) |> Enum.map(&List.last/1)

  describe "the effective surface, and nothing else" do
    test "a runtime without `plan` gets no plan_* tool in the index or the declarations",
         %{agent: agent} do
      {runtime, _} = insert_runtime!(agent, bundles(["code_mode", "task"]))

      index = Docs.render(runtime)
      assert "task_get" in indexed(index)
      assert Enum.filter(indexed(index), &String.starts_with?(&1, "plan_")) == []

      {:ok, described} =
        Docs.describe(runtime, %{"tools" => ["task_get", "plan_get", "plan_create"]})

      assert described.tools == ["task_get"]
      assert described.not_available == ["plan_get", "plan_create"]
      assert declared(described.docs) == ["task_get"]

      # A bundle the runtime does not hold declares nothing.
      {:ok, by_bundle} = Docs.describe(runtime, %{"bundle" => "plan"})
      assert by_bundle.tools == []
      assert declared(by_bundle.docs) == []
      refute "plan" in by_bundle.bundles
    end

    test "POSITIVE CONTROL: a runtime WITH `plan` is shown plan_get", %{agent: agent} do
      {runtime, _} = insert_runtime!(agent, bundles(["code_mode", "task", "plan"]))

      assert "plan_get" in indexed(Docs.render(runtime))

      {:ok, described} = Docs.describe(runtime, %{"tools" => ["plan_get"]})
      assert described.tools == ["plan_get"]
      assert described.not_available == []
      assert declared(described.docs) == ["plan_get"]
    end

    test "the index lists exactly the effective tools minus suite_run", %{agent: agent} do
      {runtime, _} = insert_runtime!(agent, bundles(["code_mode", "canvas"]))

      expected = ToolAuthorization.tool_names(runtime) -- ["suite_run"]
      {:ok, index} = Docs.describe(runtime, %{})

      assert Enum.sort(index.tools) == Enum.sort(expected)
      assert Enum.sort(indexed(index.docs)) == Enum.sort(expected)
      refute "suite_run" in index.tools
      assert "suite_run_describe" in index.tools
    end

    test "an external principal's docs hold only chat tools" do
      %{runtime: runtime} = external_runtime!(bundles(["code_mode", "task", "plan"]))

      {:ok, index} = Docs.describe(runtime, %{})
      assert index.tools != []
      assert Enum.all?(index.tools, &ToolSurface.external_chat_tool?/1)
    end
  end

  describe "declarations" do
    setup %{agent: agent} do
      {runtime, _} = insert_runtime!(agent, bundles(["code_mode", "task", "canvas"]))
      %{runtime: runtime}
    end

    test "a typed tool renders its argument and return types", %{runtime: runtime} do
      docs = Docs.render(runtime, tools: ["task_get"])

      assert docs =~ "  task_get(args: {\n"
      assert docs =~ "    task_id: string;"
      assert docs =~ "    blocked_reason_at: string | null;"
      assert docs =~ "    inserted_at: string;"
      assert docs =~ "    sponsor: {\n"
      # The return type is declared, so the prose `Returns:` is not repeated.
      refute docs =~ "Returns:"
      assert docs =~ "When to use:"
    end

    test "an untyped tool returns unknown and carries its prose Returns", %{runtime: runtime} do
      docs = Docs.render(runtime, tools: ["task_create"])
      assert docs =~ ~r/^  task_create\(args\??: \{$/m
      assert docs =~ ~r/^  \}\): unknown;$/m
      assert docs =~ "Returns:"
    end

    test "dotted names nest and non-identifier keys are quoted", %{runtime: runtime} do
      docs = Docs.render(runtime, bundle: "canvas")
      assert docs =~ "\n  canvas: {\n"
      assert docs =~ ~r/^    create\(args/m
      assert docs =~ "call(name: string, args?: Record<string, unknown>): unknown;"
    end

    test "federation_status declares its filters and its union-free row", %{agent: agent} do
      {runtime, _} = insert_runtime!(agent, bundles(["code_mode"]))
      docs = Docs.render(runtime, tools: ["federation_status"])

      assert docs =~ "args?: {"
      assert docs =~ "    online?: boolean;"
      assert docs =~ "    runtime_ids?: Array<string>;"
      assert docs =~ "    fields?: Array<string>;"

      assert docs =~
               ~s(client_build_status?: "reported" | "unresolved" | "not_reported" | "no_client_info";)
    end

    test "a malformed argument is refused recoverably", %{runtime: runtime} do
      assert {:error, %{code: "invalid_tools", recoverable: true}} =
               Docs.describe(runtime, %{"tools" => "task_get"})

      assert {:error, %{code: "invalid_bundle"}} = Docs.describe(runtime, %{"bundle" => 3})
    end
  end

  describe "ts_type/2" do
    test "covers nullable, enums, unions, arrays, open and closed objects" do
      assert Docs.ts_type(%{"type" => ["string", "null"]}) == "string | null"
      assert Docs.ts_type(%{"type" => "string", "enum" => ["a", "b"]}) == ~s("a" | "b")

      assert Docs.ts_type(%{"type" => "array", "items" => %{"type" => "integer"}}) ==
               "Array<number>"

      assert Docs.ts_type(%{"type" => "object"}) == "Record<string, unknown>"

      assert Docs.ts_type(%{"oneOf" => [%{"type" => "boolean"}, %{"type" => "null"}]}) ==
               "boolean | null"

      closed = %{
        "type" => "object",
        "properties" => %{"a" => %{"type" => "string"}, "b-c" => %{"type" => "number"}},
        "required" => ["a"],
        "additionalProperties" => false
      }

      assert Docs.ts_type(closed) == "{\n  a: string;\n  \"b-c\"?: number;\n}"
      assert Docs.ts_type(%{}) == "unknown"
    end
  end

  describe "suite_run_describe over /mcp" do
    test "is in the code_mode bundle, conforms to its schema, and is ledgered", %{agent: agent} do
      {_runtime, token} = insert_runtime!(agent, bundles(["code_mode"]))

      tools = mcp(token, "tools/list", %{})["result"]["tools"] |> Enum.map(& &1["name"])
      assert "suite_run_describe" in tools

      body =
        mcp_call(token, "suite_run_describe", %{"tools" => ["federation_status", "plan_get"]})

      json = result_json(body)

      schema = ExJsonSchema.Schema.resolve(ReturnSchemas.for_tool("suite_run_describe"))
      assert :ok = ExJsonSchema.Validator.validate(schema, json)
      assert json["tools"] == ["federation_status"]
      assert json["not_available"] == ["plan_get"]
    end

    test "a default runtime cannot call it", %{agent: agent} do
      {_runtime, token} = insert_runtime!(agent, bundles([]))
      assert mcp_call(token, "suite_run_describe", %{})["error"]["code"] == -32001
    end
  end

  describe "the suite_run primer" do
    test "is ten lines naming bindings, sync calls, store, limits, error kinds and the describe tool" do
      tool = Enum.find(ToolSurface.tool_definitions(), &(&1.name == "suite_run"))
      lines = String.split(tool.description, "\n")

      assert length(lines) == 10
      text = tool.description
      assert text =~ "suite.task_get({task_id})"
      assert text =~ "synchronous"
      assert text =~ "store.set(key, value, {ttl: seconds})"
      assert text =~ "50 tool calls"

      assert text =~
               "timeout | memory | fuel | call_limit | output_limit | script_error | forbidden"

      assert text =~ "suite_run_describe"
    end
  end

  defp external_runtime!(bundles) do
    org = Platform.Tenancy.get_org_by_slug!("sxi")
    external = Platform.ExternalUserFixtures.create_user!()

    {:ok, _} =
      Platform.Tenancy.mark_membership_external(%{user_id: external.id, org_id: org.id})

    {runtime, token} = insert_runtime!(insert_agent!(), bundles, external.id)
    %{runtime: runtime, token: token}
  end
end
