defmodule PlatformWeb.ChatLive.PresenceHooksTest do
  @moduledoc """
  `PresenceHooks.apply_agent_typing/3` after task 01a1557a-8f80 stage 3.

  This file used to pin the shape of a cross-LiveView write: typing wrote
  `:composite_status` into the shell's agents meter, wrapped in
  `%AsyncResult{}` through `ShellLive.async_ok/2`. The meter, its assigns and
  the helper were deleted with the utility-bar agents dropdown, so what is
  left to pin is that typing still drives this LiveView's own typing state
  and writes nothing into the shell's deleted assigns.
  """

  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias PlatformWeb.ChatLive.PresenceHooks

  describe "sender_name/2 for a federation_inbound message (task 01a199c7)" do
    @pid "fed-participant"
    @via_map %{@pid => %{name: "Pat (via Red Star)"}}

    test "shows the plain remote author, not the stored \"(via ...)\" name" do
      msg = %{
        participant_id: @pid,
        author_display_name: "Pat (via Red Star)",
        metadata: %{"source" => "federation_inbound", "remote_author" => "Pat"}
      }

      assert PresenceHooks.sender_name(@via_map, msg) == "Pat"
      assert PresenceHooks.sender_name(%{}, msg) == "Pat"
      refute PresenceHooks.sender_name(@via_map, msg) =~ "(via"
    end

    test "every other message keeps the participant's name" do
      for metadata <- [
            %{"source" => "email_inbound", "remote_author" => "Pat"},
            %{"remote_author" => "Pat"},
            %{"source" => "federation_inbound", "remote_author" => ""},
            %{"source" => "federation_inbound"},
            %{}
          ] do
        msg = %{participant_id: @pid, author_display_name: "snap", metadata: metadata}
        assert PresenceHooks.sender_name(@via_map, msg) == "Pat (via Red Star)", inspect(metadata)
      end
    end
  end

  describe "apply_agent_typing/3" do
    test "typing: true records the typing agent and the thinking status" do
      socket = build_socket(%{active_space: nil, agent_typing_pids: MapSet.new()})

      {:halt, updated} = PresenceHooks.apply_agent_typing(socket, true, "agent-1")

      assert MapSet.member?(updated.assigns.agent_typing_pids, "agent-1")
      assert updated.assigns.agent_status == :thinking
    end

    test "writes none of the deleted shell meter assigns" do
      socket = build_socket(%{active_space: nil, agent_typing_pids: MapSet.new()})

      {:halt, updated} = PresenceHooks.apply_agent_typing(socket, true, "agent-1")

      # Positive control: the call did write this LiveView's own state.
      assert MapSet.member?(updated.assigns.agent_typing_pids, "agent-1")

      for key <- [:composite_status, :principal_name, :roster_items] do
        refute Map.has_key?(updated.assigns, key),
               "apply_agent_typing/3 wrote #{inspect(key)}, an assign of the deleted agents meter"
      end
    end
  end

  # Build a minimal LV socket with the assigns the function under test reads.
  # The `__changed__` map is what `Phoenix.Component.assign/3` and
  # `Phoenix.Component.update/3` use to track which assigns have been touched.
  defp build_socket(assigns) do
    %Socket{assigns: Map.put(assigns, :__changed__, %{})}
  end
end
