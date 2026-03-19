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
                   Jason.encode!(%{"title" => "Fresh Metrics", "canvas_type" => "dashboard"})
               }
             ]
           }}

        output ->
          if is_binary(output) and String.contains?(output, "requires initial_state.metrics") do
            {:ok,
             %{
               content: "",
               model: Keyword.fetch!(opts, :model),
               usage: %{},
               tool_calls: [
                 %{
                   "name" => "canvas_create",
                   "call_id" => "call-2",
                   "arguments" =>
                     Jason.encode!(%{
                       "title" => "Fresh Metrics",
                       "canvas_type" => "dashboard",
                       "initial_state" => %{
                         "metrics" => [
                           %{"label" => "Revenue", "value" => "$99k", "trend" => "↑"},
                           %{"label" => "Users", "value" => "12,340", "trend" => "↑"},
                           %{"label" => "Churn", "value" => "1.8%", "trend" => "↓"}
                         ]
                       }
                     })
                 }
               ]
             }}
          else
            {:ok,
             %{
               content: "Created the dashboard.",
               model: Keyword.fetch!(opts, :model),
               usage: %{},
               tool_calls: []
             }}
          end
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

  test "canvas_create retries when required initial_state is missing and only persists the successful canvas" do
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
    [row] = get_in(canvas.state, ["root", "children"])
    assert row["type"] == "row"
    assert length(row["children"]) == 3

    [message] = Chat.list_messages(space.id, limit: 5)
    assert message.content_type == "canvas"
    assert message.structured_content["canvas_id"] == canvas.id
  end

  test "canvas_create can infer dashboard metrics from the user request when the model omits initial_state" do
    Application.put_env(:platform, :codex_auth_file, write_auth_file!())

    {:ok, space} =
      Chat.create_space(%{
        name: "Infer Canvas Test",
        slug: "infer-canvas-test-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: Ecto.UUID.generate(),
        display_name: "Zip",
        joined_at: DateTime.utc_now()
      })

    user_message =
      "Create a dashboard canvas titled Retry Metrics with metrics Revenue=$123k ↑, Users=9,876 ↑, Churn=1.2% ↓, NPS=81 →. Use canvas_create with full initial_state."

    assert {:ok, %{content: "Created the dashboard."}} =
             ToolRunner.run(
               "system prompt",
               [%{"role" => "user", "content" => user_message}],
               tool_context: %{
                 space_id: space.id,
                 participant_id: participant.id,
                 user_message: user_message
               }
             )

    [canvas] = Chat.list_canvases(space.id)
    [row] = get_in(canvas.state, ["root", "children"])
    assert length(row["children"]) == 4

    first_card = Enum.at(row["children"], 0)
    first_value = Enum.at(first_card["children"], 1)
    assert first_value["props"]["value"] == "$123k"
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
