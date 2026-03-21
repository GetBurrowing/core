defmodule Platform.Federation.NodeContextTest do
  use ExUnit.Case, async: true

  alias Platform.Federation.NodeContext

  # The NodeContext GenServer is started by the application supervisor,
  # so the ETS table is already available.

  setup do
    agent_id = Ecto.UUID.generate()
    on_exit(fn -> NodeContext.clear_space(agent_id) end)
    %{agent_id: agent_id}
  end

  describe "set_space/2 and get_space/1" do
    test "stores and retrieves a space for an agent", %{agent_id: agent_id} do
      space_id = Ecto.UUID.generate()

      assert :ok = NodeContext.set_space(agent_id, space_id)
      assert NodeContext.get_space(agent_id) == space_id
    end

    test "overwrites previous space on re-set", %{agent_id: agent_id} do
      space_a = Ecto.UUID.generate()
      space_b = Ecto.UUID.generate()

      NodeContext.set_space(agent_id, space_a)
      NodeContext.set_space(agent_id, space_b)

      assert NodeContext.get_space(agent_id) == space_b
    end

    test "returns nil for unknown agent" do
      assert NodeContext.get_space(Ecto.UUID.generate()) == nil
    end
  end

  describe "clear_space/1" do
    test "removes the stored space", %{agent_id: agent_id} do
      NodeContext.set_space(agent_id, Ecto.UUID.generate())
      assert :ok = NodeContext.clear_space(agent_id)
      assert NodeContext.get_space(agent_id) == nil
    end
  end

  describe "TTL expiry" do
    test "entry expires after TTL via the expiry message", %{agent_id: agent_id} do
      space_id = Ecto.UUID.generate()
      NodeContext.set_space(agent_id, space_id)

      # Verify it's there
      assert NodeContext.get_space(agent_id) == space_id

      # Manually expire by inserting with a past expires_at, then sending the expire message
      past = System.monotonic_time(:millisecond) - 1
      :ets.insert(Platform.Federation.NodeContext, {agent_id, space_id, past})

      # Reading should detect the expired entry and return nil
      assert NodeContext.get_space(agent_id) == nil
    end
  end
end
