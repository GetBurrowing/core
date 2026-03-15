defmodule Platform.Agents.RouterTest do
  use Platform.DataCase, async: false

  alias Platform.Agents.{Agent, Router}
  alias Platform.Repo
  alias Platform.Vault

  defp create_agent(attrs) do
    default = %{
      slug: "router-agent-#{System.unique_integer([:positive, :monotonic])}",
      name: "Router Agent",
      status: "active",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    }

    {:ok, agent} =
      default
      |> Map.merge(attrs)
      |> then(&Agent.changeset(%Agent{}, &1))
      |> Repo.insert()

    agent
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:req)
    :ok
  end

  describe "chat/3" do
    test "routes to the primary provider using Vault-backed default credential slugs" do
      Req.Test.stub(:router_primary_anthropic, fn conn ->
        send(self(), {:anthropic_request, conn})

        Req.Test.json(conn, %{
          "id" => "msg_router_primary",
          "model" => "claude-sonnet-4-6",
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 9, "output_tokens" => 4},
          "content" => [%{"type" => "text", "text" => "router primary ok"}]
        })
      end)

      Application.put_env(
        :platform,
        :anthropic_req_client,
        Req.new(plug: {Req.Test, :router_primary_anthropic})
      )

      on_exit(fn ->
        Application.delete_env(:platform, :anthropic_req_client)
      end)

      agent = create_agent(%{model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}})

      {:ok, _} =
        Vault.put(
          "anthropic-oauth",
          :oauth2,
          Jason.encode!(%{"access_token" => "sk-ant-oat01-router-primary"}),
          provider: "anthropic",
          scope: {:platform, nil}
        )

      assert {:ok, response} =
               Router.chat(
                 agent.id,
                 [%{"role" => "user", "content" => "hello"}],
                 system: "stay calm"
               )

      assert response.content == "router primary ok"
      assert response.route.full_model == "anthropic/claude-sonnet-4-6"
      assert response.route.provider == "anthropic"
      assert response.route.provider_key == "anthropic"
      assert response.route.attempted_models == ["anthropic/claude-sonnet-4-6"]
      assert response.route.fallback_count == 0

      assert_receive {:anthropic_request, conn}
      headers = Map.new(conn.req_headers)

      assert headers["authorization"] == "Bearer sk-ant-oat01-router-primary"
      assert headers["anthropic-version"] == "2023-06-01"

      {:ok, body, _conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      assert request["model"] == "claude-sonnet-4-6"
      assert request["system"] == "stay calm"
      assert request["metadata"]["router_model"] == "anthropic/claude-sonnet-4-6"
    end

    test "falls back to the next configured provider when the primary model is rate limited" do
      Req.Test.stub(:router_fallback_anthropic, fn conn ->
        send(self(), {:anthropic_request, conn})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.put_resp_header("retry-after", "7")
        |> Plug.Conn.resp(429, Jason.encode!(%{"error" => %{"type" => "rate_limit"}}))
      end)

      Req.Test.stub(:router_fallback_openai, fn conn ->
        send(self(), {:openai_request, conn})

        Req.Test.json(conn, %{
          "id" => "chatcmpl_router_fallback",
          "model" => "gpt-5.4",
          "choices" => [
            %{
              "index" => 0,
              "finish_reason" => "stop",
              "message" => %{"role" => "assistant", "content" => "fallback ok"}
            }
          ],
          "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 6, "total_tokens" => 18}
        })
      end)

      Application.put_env(
        :platform,
        :anthropic_req_client,
        Req.new(plug: {Req.Test, :router_fallback_anthropic})
      )

      Application.put_env(
        :platform,
        :openai_req_client,
        Req.new(plug: {Req.Test, :router_fallback_openai})
      )

      on_exit(fn ->
        Application.delete_env(:platform, :anthropic_req_client)
        Application.delete_env(:platform, :openai_req_client)
      end)

      agent =
        create_agent(%{
          model_config: %{
            "primary" => "anthropic/claude-sonnet-4-6",
            "fallbacks" => ["openai-codex/gpt-5.4"]
          }
        })

      {:ok, _} =
        Vault.put(
          "anthropic-oauth",
          :oauth2,
          Jason.encode!(%{"access_token" => "sk-ant-oat01-router-fallback"}),
          provider: "anthropic",
          scope: {:platform, nil}
        )

      {:ok, _} =
        Vault.put(
          "openai-oauth",
          :oauth2,
          Jason.encode!(%{"access_token" => "oauth-openai-router-fallback"}),
          provider: "openai",
          scope: {:platform, nil}
        )

      ref = :telemetry_test.attach_event_handlers(self(), [[:platform, :agent, :model_fallback]])

      assert {:ok, response} =
               Router.chat(agent.id, [%{"role" => "user", "content" => "hello"}],
                 system: "fallback flow"
               )

      assert response.content == "fallback ok"
      assert response.route.full_model == "openai-codex/gpt-5.4"
      assert response.route.provider == "openai"
      assert response.route.provider_key == "openai-codex"

      assert response.route.attempted_models == [
               "anthropic/claude-sonnet-4-6",
               "openai-codex/gpt-5.4"
             ]

      assert response.route.fallback_count == 1

      assert_receive {[:platform, :agent, :model_fallback], _ref, measurements, meta}
      assert measurements.system_time > 0
      assert meta.agent_id == agent.id
      assert meta.from_model == "anthropic/claude-sonnet-4-6"
      assert meta.to_model == "openai-codex/gpt-5.4"
      assert meta.reason =~ "rate_limited"

      assert_receive {:anthropic_request, _conn}
      assert_receive {:openai_request, conn}

      headers = Map.new(conn.req_headers)
      assert headers["authorization"] == "Bearer oauth-openai-router-fallback"

      :telemetry.detach(ref)
    end

    test "returns an error when the agent has no configured models" do
      agent = create_agent(%{model_config: %{}})

      assert {:error, :no_models_configured} =
               Router.chat(agent.id, [%{"role" => "user", "content" => "hello"}])
    end
  end

  describe "model_chain/2" do
    test "returns the resolved primary-plus-fallback chain" do
      agent =
        create_agent(%{
          model_config: %{
            "primary" => "anthropic/claude-sonnet-4-6",
            "fallbacks" => ["openai-codex/gpt-5.4", "anthropic/claude-opus-4-6"]
          }
        })

      assert {:ok, chain} = Router.model_chain(agent.id)

      assert chain == [
               "anthropic/claude-sonnet-4-6",
               "openai-codex/gpt-5.4",
               "anthropic/claude-opus-4-6"
             ]
    end
  end
end
