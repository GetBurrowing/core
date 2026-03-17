defmodule Platform.Agents.QuickAgentTest do
  use ExUnit.Case, async: true

  alias Platform.Agents.{CodexAuth, QuickAgent}

  defmodule StubProvider do
    def chat(credentials, messages, opts) do
      if pid = Application.get_env(:platform, :quick_agent_test_pid) do
        send(pid, {:provider_called, credentials, messages, opts})
      end

      {:ok, %{content: "stub-reply", model: Keyword.fetch!(opts, :model), usage: %{}}}
    end
  end

  setup do
    previous_provider = Application.get_env(:platform, :quick_agent_provider_module)
    previous_pid = Application.get_env(:platform, :quick_agent_test_pid)
    previous_workspace = Application.get_env(:platform, :agent_workspace_path)
    previous_auth = Application.get_env(:platform, :codex_auth_file)
    previous_model = Application.get_env(:platform, :chat_agent_model)

    Application.put_env(:platform, :quick_agent_provider_module, StubProvider)
    Application.put_env(:platform, :quick_agent_test_pid, self())

    on_exit(fn ->
      Application.put_env(:platform, :quick_agent_provider_module, previous_provider)
      Application.put_env(:platform, :quick_agent_test_pid, previous_pid)
      Application.put_env(:platform, :agent_workspace_path, previous_workspace)
      Application.put_env(:platform, :codex_auth_file, previous_auth)
      Application.put_env(:platform, :chat_agent_model, previous_model)
    end)

    :ok
  end

  test "resolves Codex OAuth access token from auth.json" do
    auth_path = write_auth_file!()

    assert {:ok, %{access_token: token, auth_mode: :oauth, source: ^auth_path}} =
             CodexAuth.credentials(path: auth_path)

    assert is_binary(token)
    assert token != ""
  end

  test "routes chat through the configured provider with codex credentials and workspace prompt" do
    workspace = write_workspace!()
    auth_path = write_auth_file!()

    Application.put_env(:platform, :agent_workspace_path, workspace)
    Application.put_env(:platform, :codex_auth_file, auth_path)
    Application.put_env(:platform, :chat_agent_model, "gpt-5.4")

    history = [%{"role" => "user", "content" => "Earlier context"}]

    assert {:ok, %{content: "stub-reply", model: "gpt-5.4"}} =
             QuickAgent.chat("Hello Zip", history: history)

    assert_receive {:provider_called, credentials, messages, opts}, 500

    assert credentials[:auth_mode] == :oauth
    assert is_binary(credentials[:access_token])
    assert messages == history ++ [%{"role" => "user", "content" => "Hello Zip"}]
    assert opts[:model] == "gpt-5.4"
    assert is_binary(opts[:system])
    assert opts[:system] =~ "steady and calm"
  end

  defp write_workspace! do
    path =
      Path.join(System.tmp_dir!(), "quick-agent-workspace-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    File.write!(Path.join(path, "SOUL.md"), "steady and calm")
    File.write!(Path.join(path, "IDENTITY.md"), "Zip")
    path
  end

  defp write_auth_file! do
    dir = Path.join(System.tmp_dir!(), "codex-auth-#{System.unique_integer([:positive])}")
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
