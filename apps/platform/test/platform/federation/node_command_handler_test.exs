defmodule Platform.Federation.NodeCommandHandlerTest do
  use ExUnit.Case, async: true

  alias Platform.Federation.NodeCommandHandler

  describe "deprecated canvas commands" do
    for name <-
          ~w(canvas.present canvas.navigate canvas.hide canvas.a2ui_push canvas.a2ui_reset canvas.a2ui.pushJSONL canvas.a2ui.reset) do
      test "#{name} returns COMMAND_DEPRECATED" do
        assert {:error, "COMMAND_DEPRECATED", message} =
                 NodeCommandHandler.handle(unquote(name), %{}, %{agent_id: nil})

        assert message =~ "ADR 0036"
      end
    end
  end

  describe "canvas.eval stub" do
    test "returns a placeholder result" do
      assert {:ok, %{result: nil, note: note}} =
               NodeCommandHandler.handle("canvas.eval", %{}, %{agent_id: nil})

      assert is_binary(note)
    end
  end

  describe "canvas.snapshot stub" do
    test "returns a placeholder result" do
      assert {:ok, %{snapshot: nil, note: note}} =
               NodeCommandHandler.handle("canvas.snapshot", %{}, %{agent_id: nil})

      assert is_binary(note)
    end
  end

  describe "unknown command" do
    test "returns UNKNOWN_COMMAND" do
      assert {:error, "UNKNOWN_COMMAND", _} =
               NodeCommandHandler.handle("bogus.cmd", %{}, %{agent_id: nil})
    end
  end
end
