defmodule Platform.Federation.NodeCommandHandlerTest do
  use ExUnit.Case, async: true

  alias Platform.Federation.NodeCommandHandler

  @canvas_commands ~w(canvas.present canvas.navigate canvas.eval canvas.snapshot canvas.a2ui_push canvas.a2ui_reset canvas.hide)

  describe "handle/2" do
    for cmd <-
          ~w(canvas.present canvas.navigate canvas.eval canvas.snapshot canvas.a2ui_push canvas.a2ui_reset canvas.hide) do
      test "#{cmd} returns ok" do
        assert {:ok, %{status: "received", command: unquote(cmd)}} =
                 NodeCommandHandler.handle(unquote(cmd), %{"url" => "https://example.com"})
      end
    end

    test "unknown command returns error" do
      assert {:error, "UNKNOWN_COMMAND", "Unknown command: bogus.cmd"} =
               NodeCommandHandler.handle("bogus.cmd", %{})
    end
  end
end
