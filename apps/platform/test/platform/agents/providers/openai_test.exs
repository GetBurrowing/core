defmodule Platform.Agents.Providers.OpenAITest do
  use ExUnit.Case, async: true

  alias Platform.Agents.Providers.OpenAI

  setup do
    {:ok, _} = Application.ensure_all_started(:req)

    Req.Test.stub(:openai_provider_test, fn conn ->
      send(self(), {:openai_request, conn})

      Req.Test.json(conn, %{
        "id" => "chatcmpl_test_123",
        "model" => "gpt-5.4",
        "choices" => [
          %{
            "index" => 0,
            "finish_reason" => "stop",
            "message" => %{
              "role" => "assistant",
              "content" => "hello from openai"
            }
          }
        ],
        "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 8, "total_tokens" => 20}
      })
    end)

    Application.put_env(
      :platform,
      :openai_req_client,
      Req.new(plug: {Req.Test, :openai_provider_test})
    )

    on_exit(fn ->
      Application.delete_env(:platform, :openai_req_client)
    end)

    :ok
  end

  describe "chat/3" do
    test "uses bearer auth for raw api keys and serializes system prompts as system messages" do
      assert {:ok, response} =
               OpenAI.chat(
                 %{"api_key" => "sk-openai-test-key"},
                 [%{"role" => "user", "content" => "hi"}],
                 system: "system prompt"
               )

      assert response.content == "hello from openai"
      assert response.finish_reason == "stop"

      assert response.usage == %{
               "prompt_tokens" => 12,
               "completion_tokens" => 8,
               "total_tokens" => 20
             }

      assert_receive {:openai_request, conn}
      headers = Map.new(conn.req_headers)

      assert conn.request_path == "/v1/chat/completions"
      assert headers["authorization"] == "Bearer sk-openai-test-key"
      assert headers["content-type"] == "application/json"

      {:ok, body, _conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      assert request["model"] == "gpt-5.4"

      assert request["messages"] == [
               %{"role" => "system", "content" => "system prompt"},
               %{"role" => "user", "content" => "hi"}
             ]
    end

    test "uses bearer auth for raw oauth access tokens" do
      assert {:ok, response} =
               OpenAI.chat(
                 %{"access_token" => "oauth-openai-token"},
                 [%{"role" => "user", "content" => "hello"}],
                 system: "oauth-backed"
               )

      assert response.content == "hello from openai"

      assert_receive {:openai_request, conn}
      headers = Map.new(conn.req_headers)
      assert headers["authorization"] == "Bearer oauth-openai-token"
    end
  end

  describe "models/1 and validate_credentials/1" do
    test "returns the oauth model catalog for oauth credentials" do
      assert {:ok, models} = OpenAI.models(%{"access_token" => "oauth-openai-token"})
      assert Enum.map(models, & &1.id) == ["gpt-5.4"]
      assert Enum.map(models, & &1.auth_mode) == ["oauth"]
      assert :ok = OpenAI.validate_credentials(%{"access_token" => "oauth-openai-token"})
    end

    test "returns the api key model catalog for raw api keys" do
      assert {:ok, models} = OpenAI.models("sk-openai-test-key")
      assert Enum.map(models, & &1.id) == ["gpt-5.4"]
      assert Enum.map(models, & &1.auth_mode) == ["api_key"]
      assert :ok = OpenAI.validate_credentials(%{"api_key" => "sk-openai-test-key"})
    end

    test "returns an error when credentials are missing" do
      assert {:error, :missing_credentials} = OpenAI.models(%{})
      assert {:error, :missing_credentials} = OpenAI.validate_credentials(nil)
    end

    test "streaming reports not implemented for now" do
      assert {:error, :streaming_not_implemented} =
               OpenAI.stream(%{"access_token" => "oauth-openai-token"}, [], [])
    end
  end
end
