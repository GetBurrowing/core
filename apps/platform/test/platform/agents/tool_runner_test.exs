defmodule Platform.Agents.ToolRunnerTest do
  use Platform.DataCase, async: false

  alias Platform.Agents.ToolRunner
  alias Platform.Chat

  defmodule StubProvider do
    def chat(_credentials, messages, opts) do
      if pid = Application.get_env(:platform, :tool_runner_test_pid) do
        send(pid, {:provider_called, messages, opts})
      end

      case last_tool_output(messages) do
        nil ->
          {:ok,
           %{
             content: "",
             model: Keyword.fetch!(opts, :model),
             usage: %{},
             tool_calls: [
               %{
                 "name" => "canvas_create",
                 "call_id" => "call-1",
                 "arguments" =>
                   Jason.encode!(%{
                     "title" => "Fresh Dashboard",
                     "document" => %{
                       "version" => 1,
                       "revision" => 1,
                       "root" => %{
                         "id" => "root",
                         "type" => "stack",
                         "props" => %{"gap" => 12},
                         "children" => [
                           %{
                             "id" => "heading-1",
                             "type" => "heading",
                             "props" => %{"value" => "Fresh Dashboard", "level" => 2},
                             "children" => []
                           }
                         ]
                       },
                       "theme" => %{},
                       "bindings" => %{},
                       "meta" => %{}
                     }
                   })
               }
             ]
           }}

        _output ->
          {:ok,
           %{
             content: "Created the dashboard.",
             model: Keyword.fetch!(opts, :model),
             usage: %{},
             tool_calls: []
           }}
      end
    end

    defp last_tool_output(messages) do
      messages
      |> Enum.reverse()
      |> Enum.find_value(fn
        %{"type" => "function_call_output", "output" => output} -> output
        _ -> nil
      end)
    end
  end

  setup do
    previous_provider = Application.get_env(:platform, :quick_agent_provider_module)
    previous_pid = Application.get_env(:platform, :tool_runner_test_pid)
    previous_auth = Application.get_env(:platform, :codex_auth_file)
    previous_model = Application.get_env(:platform, :chat_agent_model)

    Application.put_env(:platform, :quick_agent_provider_module, StubProvider)
    Application.put_env(:platform, :tool_runner_test_pid, self())
    Application.put_env(:platform, :chat_agent_model, "gpt-5.4")

    on_exit(fn ->
      Application.put_env(:platform, :quick_agent_provider_module, previous_provider)
      Application.put_env(:platform, :tool_runner_test_pid, previous_pid)
      Application.put_env(:platform, :codex_auth_file, previous_auth)
      Application.put_env(:platform, :chat_agent_model, previous_model)
    end)

    :ok
  end

  test "canvas_create persists a canonical document" do
    Application.put_env(:platform, :codex_auth_file, write_auth_file!())

    {:ok, space} =
      Chat.create_space(%{
        name: "Canvas Test",
        slug: "canvas-test-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: Ecto.UUID.generate(),
        display_name: "Zip",
        joined_at: DateTime.utc_now()
      })

    assert {:ok, %{content: "Created the dashboard."}} =
             ToolRunner.run(
               "system prompt",
               [%{"role" => "user", "content" => "Create a dashboard canvas"}],
               tool_context: %{space_id: space.id, participant_id: participant.id}
             )

    assert_receive {:provider_called, _messages, opts}, 500
    assert opts[:model] == "gpt-5.4"

    canvases = Chat.list_canvases(space.id)
    assert length(canvases) == 1

    [canvas] = canvases
    assert canvas.document["version"] == 1
    assert canvas.document["root"]["type"] == "stack"

    [heading] = canvas.document["root"]["children"]
    assert heading["type"] == "heading"
    assert heading["props"]["value"] == "Fresh Dashboard"

    [message] = Chat.list_messages(space.id, limit: 5)
    assert message.content_type == "canvas"
    assert message.canvas_id == canvas.id
  end

  defp write_auth_file! do
    dir = Path.join(System.tmp_dir!(), "tool-runner-auth-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "auth.json")

    File.write!(
      path,
      Jason.encode!(%{
        "auth_mode" => "chatgpt",
        "tokens" => %{
          "access_token" => "test-access-token",
          "refresh_token" => "test-refresh-token"
        }
      })
    )

    path
  end
end
