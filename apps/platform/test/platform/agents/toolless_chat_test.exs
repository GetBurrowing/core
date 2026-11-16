defmodule Platform.Agents.ToollessChatTest do
  @moduledoc """
  `Platform.Agents.ToollessChat` (task 01a0d415 stage 3): the provider call
  extracted from `Platform.Security.LlmEnrichment.call_provider/4`. The
  property under test is TOOL-LESS BY CONSTRUCTION: whatever a caller passes,
  no `:tools` key reaches the provider.

  Credentials (task 01a1e670 stage 1): the provider's `:api_key` is the
  secret the agent's `vault_key` resolves to, never the slug. The first test
  here used to assert `%{api_key: "k"}` for `vault_key: "k"`, which encoded
  that bug; it now asserts the C6a/C6b behaviour below.

  async: false — the credential tests attach a global telemetry handler and
  swap `:ollama_req_client` in Application env.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Providers.Ollama
  alias Platform.Agents.ToollessChat
  alias Platform.Vault

  @resolved_event [:platform, :external_agents, :credential_resolved]

  defmodule RecordingProvider do
    @moduledoc false
    def chat(credentials, messages, opts) do
      send(self(), {:chat, credentials, messages, opts})
      {:ok, %{content: "hello"}}
    end
  end

  defmodule StringKeyProvider do
    @moduledoc false
    def chat(_c, _m, _o), do: {:ok, %{"content" => "string-keyed"}}
  end

  defmodule RaisingProvider do
    @moduledoc false
    def chat(_c, _m, _o), do: raise("boom")
  end

  defmodule ThrowingProvider do
    @moduledoc false
    def chat(_c, _m, _o), do: throw(:nope)
  end

  defmodule ErrorProvider do
    @moduledoc false
    def chat(_c, _m, _o), do: {:error, :timeout}
  end

  defmodule OddShapeProvider do
    @moduledoc false
    def chat(_c, _m, _o), do: {:ok, %{choices: []}}
  end

  @agent %{base_url: "http://llm.local/v1", model: "m", vault_key: "k"}
  @messages [%{role: "user", content: "hi"}]

  test "a caller-supplied tools opt never reaches the provider" do
    assert {:ok, "hello"} =
             ToollessChat.call(RecordingProvider, @agent, @messages,
               tools: [%{"type" => "function", "function" => %{"name" => "delete_all"}}],
               tool_choice: "required",
               temperature: 0.0,
               max_tokens: 64
             )

    # The agent has no id, so "k" is never resolved and never sent as a key.
    assert_received {:chat, credentials, @messages, opts}
    assert credentials == %{}
    refute Keyword.has_key?(opts, :tools)
    refute Keyword.has_key?(opts, :tool_choice)

    assert opts == [
             base_url: "http://llm.local/v1",
             model: "m",
             temperature: 0.0,
             max_tokens: 64
           ]
  end

  test "base_url and model come from the agent, never from opts" do
    ToollessChat.call(RecordingProvider, %{}, @messages, base_url: "http://evil", model: "x")

    assert_received {:chat, %{}, _messages, opts}
    assert opts == []
  end

  test "a string-keyed content reply is accepted" do
    assert {:ok, "string-keyed"} = ToollessChat.call(StringKeyProvider, @agent, @messages)
  end

  test "a raising provider returns :error and logs with the caller's tag" do
    log =
      capture_log(fn ->
        assert :error =
                 ToollessChat.call(RaisingProvider, @agent, @messages,
                   log_tag: "[Tag]",
                   log_context: "key=x"
                 )
      end)

    assert log =~ "[Tag] provider raised key=x"
  end

  test "a throwing provider, an error tuple and an odd shape all return :error" do
    capture_log(fn ->
      assert :error = ToollessChat.call(ThrowingProvider, @agent, @messages)
      assert :error = ToollessChat.call(ErrorProvider, @agent, @messages)
      assert :error = ToollessChat.call(OddShapeProvider, @agent, @messages)
    end)
  end

  describe "credentials (task 01a1e670 stage 1)" do
    defp attach_resolved_forwarder do
      handler_id = "toolless-resolved-#{System.unique_integer([:positive])}"
      pid = self()

      :telemetry.attach(
        handler_id,
        @resolved_event,
        fn _event, _measurements, metadata, _config ->
          send(pid, {:credential_resolved, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    defp stub_ollama! do
      name = :"toolless_chat_#{System.unique_integer([:positive])}"
      pid = self()

      Req.Test.stub(name, fn conn ->
        send(pid, {:ollama_auth, Plug.Conn.get_req_header(conn, "authorization")})

        Req.Test.json(conn, %{
          "model" => "m",
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]
        })
      end)

      previous = Application.fetch_env(:platform, :ollama_req_client)
      Application.put_env(:platform, :ollama_req_client, Req.new(plug: {Req.Test, name}))

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:platform, :ollama_req_client, value)
          :error -> Application.delete_env(:platform, :ollama_req_client)
        end
      end)
    end

    defp agent(vault_key) do
      %{
        id: Ecto.UUID.generate(),
        base_url: "http://toolless-chat.example.local/v1",
        model: "m",
        vault_key: vault_key
      }
    end

    test "a nil or blank vault_key is %{} and never calls resolve_credential" do
      attach_resolved_forwarder()

      for key <- [nil, "", "   "] do
        a = agent(key)
        assert ToollessChat.agent_credentials(a) == %{}
        assert {:ok, "hello"} = ToollessChat.call(RecordingProvider, a, @messages)
        assert_received {:chat, credentials, _messages, _opts}
        assert credentials == %{}
      end

      refute_received {:credential_resolved, _}
    end

    test "resolving vault_key sends the secret, not the slug" do
      stub_ollama!()
      a = agent("toolless-slug-#{System.unique_integer([:positive])}")
      secret = "toolless-secret-#{System.unique_integer([:positive])}"
      {:ok, _} = Vault.put(a.vault_key, :api_key, secret, scope: {:agent, a.id})

      assert {:ok, "ok"} = ToollessChat.call(Ollama, a, @messages)

      assert_received {:ollama_auth, [header]}
      assert header == "Bearer " <> secret
      refute header =~ a.vault_key
    end

    test "a vault_key that does not resolve sends no Authorization header" do
      stub_ollama!()
      a = agent("toolless-missing-#{System.unique_integer([:positive])}")

      assert ToollessChat.agent_credentials(a) == %{}
      assert {:ok, "ok"} = ToollessChat.call(Ollama, a, @messages)
      assert_received {:ollama_auth, []}
    end
  end
end
