defmodule Platform.Federation.NodeCommandHandlerTest do
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Agents.Agent
  alias Platform.Federation.NodeCommandHandler
  alias Platform.Federation.NodeContext

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp create_agent(attrs \\ %{}) do
    defaults = %{
      slug: "agent-#{System.unique_integer([:positive])}",
      name: "Test Agent",
      status: "active"
    }

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    agent
  end

  defp create_space(attrs \\ %{}) do
    default = %{name: "Test", slug: "test-#{System.unique_integer([:positive])}", kind: "channel"}
    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  defp setup_agent_in_space(_context \\ %{}) do
    agent = create_agent()
    space = create_space()
    {:ok, participant} = Chat.ensure_agent_participant(space.id, agent.id)
    %{agent: agent, space: space, participant: participant}
  end

  defp ctx_for(agent), do: %{agent_id: agent.id}

  # ── canvas.present ──────────────────────────────────────────────────────────

  describe "canvas.present" do
    test "creates a canvas and returns canvas_id and space_id" do
      %{agent: agent, space: space} = setup_agent_in_space()

      params = %{
        "space_id" => space.id,
        "title" => "Test Canvas",
        "canvas_type" => "custom",
        "url" => "https://example.com"
      }

      assert {:ok, result} = NodeCommandHandler.handle("canvas.present", params, ctx_for(agent))
      assert is_binary(result.canvas_id)
      assert result.space_id == space.id

      # Verify canvas was persisted
      canvas = Chat.get_canvas(result.canvas_id)
      assert canvas != nil
      assert canvas.title == "Test Canvas"
      assert canvas.state["url"] == "https://example.com"
    end

    test "uses NodeContext space when no explicit space_id" do
      %{agent: agent, space: space} = setup_agent_in_space()
      NodeContext.set_space(agent.id, space.id)

      params = %{"title" => "Context Canvas", "url" => "https://example.com"}

      assert {:ok, result} = NodeCommandHandler.handle("canvas.present", params, ctx_for(agent))
      assert result.space_id == space.id

      NodeContext.clear_space(agent.id)
    end

    test "falls back to first agent space when no context" do
      %{agent: agent, space: space} = setup_agent_in_space()

      params = %{"title" => "Fallback Canvas", "url" => "https://example.com"}

      assert {:ok, result} = NodeCommandHandler.handle("canvas.present", params, ctx_for(agent))
      assert result.space_id == space.id
    end
  end

  # ── canvas.navigate ─────────────────────────────────────────────────────────

  describe "canvas.navigate" do
    test "updates canvas state with new URL" do
      %{agent: agent, space: space} = setup_agent_in_space()

      # Create a canvas first
      {:ok, create_result} =
        NodeCommandHandler.handle(
          "canvas.present",
          %{"space_id" => space.id, "url" => "https://old.com"},
          ctx_for(agent)
        )

      # Navigate
      params = %{"canvas_id" => create_result.canvas_id, "url" => "https://new.com"}

      assert {:ok, result} =
               NodeCommandHandler.handle("canvas.navigate", params, ctx_for(agent))

      assert result.canvas_id == create_result.canvas_id

      # Verify state updated
      canvas = Chat.get_canvas(result.canvas_id)
      assert canvas.state["url"] == "https://new.com"
    end

    test "returns error for non-existent canvas" do
      assert {:error, "CANVAS_NOT_FOUND", _} =
               NodeCommandHandler.handle(
                 "canvas.navigate",
                 %{"canvas_id" => Ecto.UUID.generate()},
                 %{agent_id: nil}
               )
    end
  end

  # ── canvas.hide ─────────────────────────────────────────────────────────────

  describe "canvas.hide" do
    test "marks canvas as hidden in metadata" do
      %{agent: agent, space: space} = setup_agent_in_space()

      {:ok, create_result} =
        NodeCommandHandler.handle(
          "canvas.present",
          %{"space_id" => space.id, "url" => "https://example.com"},
          ctx_for(agent)
        )

      params = %{"canvas_id" => create_result.canvas_id}

      assert {:ok, result} = NodeCommandHandler.handle("canvas.hide", params, ctx_for(agent))
      assert result.canvas_id == create_result.canvas_id

      canvas = Chat.get_canvas(result.canvas_id)
      assert canvas.metadata["hidden"] == true
    end
  end

  # ── canvas.a2ui_push ────────────────────────────────────────────────────────

  describe "canvas.a2ui_push" do
    test "updates a2ui content on existing canvas" do
      %{agent: agent, space: space} = setup_agent_in_space()

      {:ok, create_result} =
        NodeCommandHandler.handle(
          "canvas.present",
          %{"space_id" => space.id, "url" => "https://example.com"},
          ctx_for(agent)
        )

      jsonl = ~s({"type":"text","content":"hello"})
      params = %{"canvas_id" => create_result.canvas_id, "jsonl" => jsonl}

      assert {:ok, result} =
               NodeCommandHandler.handle("canvas.a2ui_push", params, ctx_for(agent))

      canvas = Chat.get_canvas(result.canvas_id)
      assert canvas.state["a2ui_content"] == jsonl
    end

    test "creates canvas when no canvas_id provided" do
      %{agent: agent, space: space} = setup_agent_in_space()
      NodeContext.set_space(agent.id, space.id)

      jsonl = ~s({"type":"text","content":"hello"})
      params = %{"jsonl" => jsonl}

      assert {:ok, result} =
               NodeCommandHandler.handle("canvas.a2ui_push", params, ctx_for(agent))

      assert is_binary(result.canvas_id)
      canvas = Chat.get_canvas(result.canvas_id)
      assert canvas.state["a2ui_content"] == jsonl

      NodeContext.clear_space(agent.id)
    end
  end

  # ── canvas.a2ui_reset ───────────────────────────────────────────────────────

  describe "canvas.a2ui_reset" do
    test "clears a2ui content" do
      %{agent: agent, space: space} = setup_agent_in_space()

      {:ok, create_result} =
        NodeCommandHandler.handle(
          "canvas.present",
          %{"space_id" => space.id, "url" => "https://example.com"},
          ctx_for(agent)
        )

      # Push some A2UI content first
      NodeCommandHandler.handle(
        "canvas.a2ui_push",
        %{"canvas_id" => create_result.canvas_id, "jsonl" => "content"},
        ctx_for(agent)
      )

      # Reset
      params = %{"canvas_id" => create_result.canvas_id}

      assert {:ok, result} =
               NodeCommandHandler.handle("canvas.a2ui_reset", params, ctx_for(agent))

      canvas = Chat.get_canvas(result.canvas_id)
      assert canvas.state["a2ui_content"] == nil
    end
  end

  # ── Phase 3 stubs ──────────────────────────────────────────────────────────

  describe "canvas.eval (Phase 3 stub)" do
    test "returns stub result" do
      assert {:ok, %{result: nil, note: note}} =
               NodeCommandHandler.handle("canvas.eval", %{}, %{agent_id: nil})

      assert note =~ "Phase 3"
    end
  end

  describe "canvas.snapshot (Phase 3 stub)" do
    test "returns stub result" do
      assert {:ok, %{snapshot: nil, note: note}} =
               NodeCommandHandler.handle("canvas.snapshot", %{}, %{agent_id: nil})

      assert note =~ "Phase 3"
    end
  end

  # ── Unknown command ─────────────────────────────────────────────────────────

  describe "unknown command" do
    test "returns error" do
      assert {:error, "UNKNOWN_COMMAND", _} =
               NodeCommandHandler.handle("bogus.cmd", %{}, %{agent_id: nil})
    end
  end

  # ── Space resolution ────────────────────────────────────────────────────────

  describe "resolve_space/2 priority" do
    test "explicit space_id takes precedence" do
      %{agent: agent, space: space} = setup_agent_in_space()
      other_space = create_space()

      # Set context to one space
      NodeContext.set_space(agent.id, other_space.id)

      # But pass explicit space_id
      assert {:ok, resolved} =
               NodeCommandHandler.resolve_space(
                 %{"space_id" => space.id},
                 ctx_for(agent)
               )

      assert resolved == space.id
      NodeContext.clear_space(agent.id)
    end

    test "context space used when no explicit space_id" do
      %{agent: agent, space: space} = setup_agent_in_space()
      NodeContext.set_space(agent.id, space.id)

      assert {:ok, resolved} =
               NodeCommandHandler.resolve_space(%{}, ctx_for(agent))

      assert resolved == space.id
      NodeContext.clear_space(agent.id)
    end

    test "falls back to first agent space" do
      %{agent: agent, space: space} = setup_agent_in_space()

      assert {:ok, resolved} =
               NodeCommandHandler.resolve_space(%{}, ctx_for(agent))

      assert resolved == space.id
    end

    test "returns error when no space available" do
      agent = create_agent()

      assert {:error, "NO_SPACE", _} =
               NodeCommandHandler.resolve_space(%{}, ctx_for(agent))
    end
  end
end
