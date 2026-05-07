defmodule Platform.Chat.Canvas.KindsTest do
  use ExUnit.Case, async: true

  alias Platform.Chat.Canvas.Kinds
  alias Platform.Chat.Canvas.Kinds.Embed

  describe "registry contract for embed" do
    test "names/0 includes \"embed\"" do
      assert "embed" in Kinds.names()
    end

    test "get/1 resolves \"embed\" to the Embed module" do
      assert Kinds.get("embed") == Embed
    end

    test "behaviour_ok?/1 is true for the Embed module" do
      assert Kinds.behaviour_ok?(Embed)
    end

    test "summaries/0 includes a non-empty description for embed" do
      summary = Enum.find(Kinds.summaries(), &(&1.kind == "embed"))

      assert summary, "expected an embed entry in Kinds.summaries/0"
      assert is_binary(summary.description)
      assert summary.description != ""
      assert summary.accepts_children == "none"
    end

    test "tool_schemas/0 has an \"embed\" entry that requires srcdoc" do
      schemas = Kinds.tool_schemas()

      assert Map.has_key?(schemas, "embed")
      embed_schema = schemas["embed"]
      assert embed_schema["type"] == "object"

      props_required = embed_schema["properties"]["props"]["required"] || []
      assert "srcdoc" in props_required
    end
  end
end
