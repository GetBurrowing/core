defmodule Platform.Chat.Canvas.ToolsTest do
  use ExUnit.Case, async: true

  alias Platform.Chat.Canvas.Tools
  alias Platform.Chat.Canvas.Kinds

  describe "definitions/0" do
    test "returns the three canvas tools" do
      defs = Tools.definitions()
      names = Enum.map(defs, & &1["name"])

      assert "canvas.create" in names
      assert "canvas.patch" in names
      assert "canvas.describe" in names
    end

    test "canvas.create requires space_id and document" do
      defn = Enum.find(Tools.definitions(), &(&1["name"] == "canvas.create"))
      required = defn["parameters"]["required"]

      assert "space_id" in required
      assert "document" in required
    end

    test "canvas.patch requires canvas_id, base_revision, and operations" do
      defn = Enum.find(Tools.definitions(), &(&1["name"] == "canvas.patch"))
      required = defn["parameters"]["required"]

      assert "canvas_id" in required
      assert "base_revision" in required
      assert "operations" in required
    end
  end

  describe "document_schema/0" do
    test "is a JSON-schema object with version, revision, root" do
      schema = Tools.document_schema()

      assert schema["type"] == "object"
      assert "version" in schema["required"]
      assert "revision" in schema["required"]
      assert "root" in schema["required"]
    end

    test "version is constrained to 1" do
      schema = Tools.document_schema()
      assert schema["properties"]["version"]["const"] == 1
    end
  end

  describe "node_schema/0" do
    test "is a discriminated union with one entry per registered kind" do
      schema = Tools.node_schema()
      one_of = schema["oneOf"]

      assert is_list(one_of)
      assert length(one_of) == length(Kinds.all())

      kind_consts =
        Enum.map(one_of, fn s -> s["properties"]["type"]["const"] end)
        |> Enum.sort()

      assert kind_consts == Enum.sort(Kinds.names())
    end

    test "kinds whose children == :none do not declare a children property" do
      schema = Tools.node_schema()
      text_entry = Enum.find(schema["oneOf"], &(&1["properties"]["type"]["const"] == "text"))
      refute Map.has_key?(text_entry["properties"], "children")
    end

    test "kinds with child rules declare children array" do
      schema = Tools.node_schema()
      stack_entry = Enum.find(schema["oneOf"], &(&1["properties"]["type"]["const"] == "stack"))
      assert stack_entry["properties"]["children"]["type"] == "array"
    end
  end
end
