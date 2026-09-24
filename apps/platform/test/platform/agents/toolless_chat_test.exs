defmodule Platform.Agents.ToollessChatTest do
  @moduledoc """
  `Platform.Agents.ToollessChat` (task 01a0d415 stage 3): the provider call
  extracted from `Platform.Security.LlmEnrichment.call_provider/4`. The
  property under test is TOOL-LESS BY CONSTRUCTION: whatever a caller passes,
  no `:tools` key reaches the provider.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Platform.Agents.ToollessChat

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

    assert_received {:chat, %{api_key: "k"}, @messages, opts}
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
end
