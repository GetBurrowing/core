defmodule PlatformWeb.Components.ChatMessageEditorGroupTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  test "editing explains that group recipients remain the send-time audience" do
    html =
      render_component(&PlatformWeb.Components.ChatMessageEditor.chat_message_editor/1,
        msg: %{id: "message", content: "@[group:12345678-1234-1234-1234-123456789abc|Team]"}
      )

    assert html =~
             "Group recipients are set when a message is sent. Send a new message to notify a new group."
  end
end
