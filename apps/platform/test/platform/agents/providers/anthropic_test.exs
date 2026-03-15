defmodule Platform.Agents.Providers.AnthropicTest do
  use Platform.DataCase, async: false

  alias Platform.Agents.Providers.Anthropic
  alias Platform.Vault

  setup do
    Req.Test.stub(:anthropic_provider_test, fn conn ->
      send(self(), {:anthropic_request, conn})

      Req.Test.json(conn, %{
        "id" => "msg_test_123",
        "model" => "claude-sonnet-4-6",
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 11, "output_tokens" => 7},
        "content" => [
          %{"type" => "text", "text" => "hello from claude"}
        ]
      })
    end)

    Application.put_env(
      :platform,
      :anthropic_req_client,
      Req.new(plug: {Req.Test, :anthropic_provider_test})
    )

    on_exit(fn ->
      Application.delete_env(:platform, :anthropic_req_client)
    end)

    :ok
  end

  describe "chat/3" do
    test "uses the verified Anthropic OAuth headers for raw oauth tokens" do
      assert {:ok, response} =
               Anthropic.chat(
                 %{"access_token" => "sk-ant-oat01-test-token"},
                 [%{"role" => "user", "content" => "hi"}],
                 system: "system prompt"
               )

      assert response.content == "hello from claude"
      assert response.stop_reason == "end_turn"
      assert response.usage == %{"input_tokens" => 11, "output_tokens" => 7}

      assert_receive {:anthropic_request, conn}
      headers = Map.new(conn.req_headers)

      assert conn.request_path == "/v1/messages"
      assert headers["authorization"] == "Bearer sk-ant-oat01-test-token"
      assert headers["anthropic-version"] == "2023-06-01"

      assert headers["anthropic-beta"] ==
               "claude-code-20250219,oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14"

      assert headers["user-agent"] == "claude-cli/2.1.62"
      assert headers["x-app"] == "cli"
      assert headers["anthropic-dangerous-direct-browser-access"] == "true"
      assert headers["content-type"] == "application/json"
    end

    test "loads oauth credentials from Platform.Vault by slug" do
      slug = "anthropic-oauth-#{System.unique_integer([:positive, :monotonic])}"

      {:ok, _} =
        Vault.put(
          slug,
          :oauth2,
          Jason.encode!(%{
            "access_token" => "sk-ant-oat01-vault-token",
            "refresh_token" => "refresh-token",
            "provider" => "anthropic"
          }),
          provider: "anthropic",
          scope: {:platform, nil}
        )

      assert {:ok, response} =
               Anthropic.chat(
                 %{credential_slug: slug, accessor: {:platform, nil}},
                 [%{role: "user", content: "hello"}],
                 system: "vault-backed"
               )

      assert response.content == "hello from claude"

      assert_receive {:anthropic_request, conn}
      headers = Map.new(conn.req_headers)
      assert headers["authorization"] == "Bearer sk-ant-oat01-vault-token"
    end

    test "uses x-api-key auth for raw API keys" do
      assert {:ok, response} =
               Anthropic.chat(
                 %{"api_key" => "sk-ant-api-test"},
                 [%{"role" => "user", "content" => "hi"}],
                 system: "system prompt"
               )

      assert response.content == "hello from claude"

      assert_receive {:anthropic_request, conn}
      headers = Map.new(conn.req_headers)

      assert headers["x-api-key"] == "sk-ant-api-test"
      assert headers["anthropic-version"] == "2023-06-01"
      assert headers["anthropic-beta"] == "fine-grained-tool-streaming-2025-05-14"
      refute Map.has_key?(headers, "authorization")
    end
  end

  describe "models/1 and validate_credentials/1" do
    test "returns the oauth model catalog for oauth credentials" do
      assert {:ok, models} = Anthropic.models(%{"access_token" => "sk-ant-oat01-test-token"})
      assert Enum.map(models, & &1.id) == ["claude-sonnet-4-6", "claude-opus-4-6"]
      assert :ok = Anthropic.validate_credentials(%{"access_token" => "sk-ant-oat01-test-token"})
    end

    test "returns an error when credentials are missing" do
      assert {:error, :missing_credentials} = Anthropic.models(%{})
      assert {:error, :missing_credentials} = Anthropic.validate_credentials(nil)
    end

    test "streaming reports not implemented for now" do
      assert {:error, :streaming_not_implemented} =
               Anthropic.stream(%{"access_token" => "sk-ant-oat01-test-token"}, [], [])
    end
  end
end
