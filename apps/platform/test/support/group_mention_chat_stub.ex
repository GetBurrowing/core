defmodule Platform.GroupMentionChatStub do
  @moduledoc false
  def chat(_message, _opts) do
    send(Application.fetch_env!(:platform, :group_mention_test_pid), :group_chat_called)
    {:ok, %{content: "Group routing probe", model: "test", usage: %{}}}
  end
end
