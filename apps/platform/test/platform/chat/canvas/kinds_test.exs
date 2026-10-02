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
  end

  # Task 01a0ee08 stage 2 (ADR 0055): `describe/0` is an OPTIONAL `Kind`
  # callback, so `behaviour_ok?/1` checks the required callbacks only.
  describe "behaviour_ok?/1 and optional callbacks" do
    defmodule MissingRender do
      @moduledoc false
      # Every required `Kind` callback except `render/1`; no `@behaviour`, so
      # the missing callback is not a compile warning.
      def schema, do: %{}
      def styling, do: %{}
      def children, do: :none
      def defaults, do: %{}
      def events, do: []
      def presence_shape, do: :none
      def validate_props(_props), do: :ok
    end

    test "a kind that does not implement the optional describe/0 still passes" do
      Code.ensure_loaded!(Embed)
      refute function_exported?(Embed, :describe, 0)
      assert {:describe, 0} in Platform.Chat.Canvas.Kind.behaviour_info(:optional_callbacks)
      assert Kinds.behaviour_ok?(Embed)
    end

    test "a kind missing a required callback still fails" do
      refute Kinds.behaviour_ok?(MissingRender)
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
