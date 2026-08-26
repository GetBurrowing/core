defmodule Platform.Agents.Providers.OllamaTest do
  use ExUnit.Case, async: true

  alias Platform.Agents.Providers.Ollama

  @base_url "http://ollama.test:11434"

  setup do
    {:ok, _} = Application.ensure_all_started(:req)

    Req.Test.stub(:ollama_provider_test, fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:ollama_request, conn, Jason.decode!(raw_body)})

      Req.Test.json(conn, %{
        "model" => "gemma4",
        "choices" => [
          %{
            "index" => 0,
            "finish_reason" => "stop",
            "message" => %{"role" => "assistant", "content" => "hello from ollama"}
          }
        ],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 3, "total_tokens" => 8}
      })
    end)

    Application.put_env(
      :platform,
      :ollama_req_client,
      Req.new(plug: {Req.Test, :ollama_provider_test})
    )

    on_exit(fn ->
      Application.delete_env(:platform, :ollama_req_client)
    end)

    :ok
  end

  describe "chat/3 chat_template_kwargs" do
    test "forwards chat_template_kwargs onto the request body when supplied" do
      assert {:ok, response} =
               Ollama.chat(
                 %{},
                 [%{"role" => "user", "content" => "hi"}],
                 base_url: @base_url,
                 model: "gemma4",
                 chat_template_kwargs: %{"enable_thinking" => false}
               )

      assert response.content == "hello from ollama"

      assert_receive {:ollama_request, conn, request}

      assert conn.request_path == "/chat/completions"
      assert request["chat_template_kwargs"] == %{"enable_thinking" => false}

      # The native Ollama flag must survive alongside it.
      assert request["think"] == false
      assert request["model"] == "gemma4"
    end

    test "omits chat_template_kwargs entirely when the caller does not supply it" do
      assert {:ok, response} =
               Ollama.chat(
                 %{},
                 [%{"role" => "user", "content" => "hi"}],
                 base_url: @base_url,
                 model: "gemma4"
               )

      assert response.content == "hello from ollama"

      assert_receive {:ollama_request, _conn, request}

      refute Map.has_key?(request, "chat_template_kwargs")
      assert request["think"] == false
    end
  end
end
