defmodule Platform.ExternalAgents.DispatcherTest do
  @moduledoc """
  Tests for `Platform.ExternalAgents.Dispatcher` (ADR-0041 M6 stage 5).

  Exercises both endpoint kinds (openai_compat + ollama_native), the
  output contract validator wiring, the error path, and the telemetry
  surface. Mirrors the Req.Test stub pattern from
  `Platform.ExternalAgentsTest`'s probe describe-block — register a
  named stub, point the dispatcher's injected Req client at it via
  `Application.put_env/3`, clear the env on exit.
  """
  use ExUnit.Case, async: false

  alias Platform.ExternalAgents.{ContractValidator, Dispatcher, EphemeralCredentials}
  alias Platform.Responsibilities.Responsibility

  @telemetry_called [:platform, :external_agent, :called]
  @telemetry_error [:platform, :external_agent, :error]

  setup do
    {:ok, _} = Application.ensure_all_started(:req)

    Application.put_env(
      :platform,
      :external_agents_dispatcher_req_client,
      Req.new(plug: {Req.Test, :external_agents_dispatcher_test})
    )

    on_exit(fn ->
      Application.delete_env(:platform, :external_agents_dispatcher_req_client)
    end)

    :ok
  end

  defp attach_telemetry(events) do
    handler_id = "dispatcher-telemetry-#{System.unique_integer([:positive, :monotonic])}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  defp build_agent(endpoint_kind, overrides \\ %{}) do
    %{
      id: Ecto.UUID.generate(),
      slug: "ext-test-#{System.unique_integer([:positive])}",
      kind: "external",
      endpoint_kind: endpoint_kind,
      base_url: "https://api.example.test",
      model: "test-model",
      vault_key: nil,
      metadata: %{}
    }
    |> Map.merge(overrides)
  end

  defp build_responsibility(overrides \\ %{}) do
    %Responsibility{
      key: "test.dispatch",
      feature: "test",
      trigger_kind: "cron",
      trigger_config: %{"expression" => "0 * * * *"},
      scope: "global",
      context_provided: [],
      output_contract: nil,
      default_prompt_template: "summarise: {topic}",
      cost_profile: "low_freq_capable",
      enabled: true,
      metadata: %{}
    }
    |> Map.merge(overrides)
  end

  describe "openai_compat" do
    test "200 returns parsed content, hits /chat/completions with Bearer header, fires :called telemetry" do
      attach_telemetry([@telemetry_called, @telemetry_error])
      test_pid = self()

      Req.Test.stub(:external_agents_dispatcher_test, fn conn ->
        send(test_pid, {:dispatch_req, conn})

        Req.Test.json(conn, %{
          "id" => "chatcmpl_test",
          "model" => "test-model",
          "choices" => [
            %{
              "index" => 0,
              "finish_reason" => "stop",
              "message" => %{"role" => "assistant", "content" => "openai answer"}
            }
          ]
        })
      end)

      agent = build_agent("openai_compat")
      :ok = EphemeralCredentials.put(agent.id, "sk-test-token")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

      responsibility = build_responsibility()

      assert {:ok, "openai answer"} =
               Dispatcher.dispatch(responsibility, agent, %{topic: "monthly metrics"})

      assert_receive {:dispatch_req, conn}
      assert conn.request_path == "/chat/completions"

      headers = Map.new(conn.req_headers)
      assert headers["authorization"] == "Bearer sk-test-token"
      assert headers["content-type"] == "application/json"

      {:ok, body, _conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["model"] == "test-model"
      assert decoded["stream"] == false
      assert is_list(decoded["messages"])
      assert hd(decoded["messages"])["role"] == "user"
      # Verify {topic} got substituted into the prompt
      assert hd(decoded["messages"])["content"] =~ "monthly metrics"

      assert_receive {:telemetry, @telemetry_called, %{duration_ms: _}, meta}
      assert meta.endpoint_kind == "openai_compat"
      assert meta.agent_slug == agent.slug
      assert meta.responsibility_key == "test.dispatch"
    end
  end

  describe "ollama_native" do
    test "200 returns parsed content, hits /api/chat with NO auth header, fires :called telemetry" do
      attach_telemetry([@telemetry_called, @telemetry_error])
      test_pid = self()

      Req.Test.stub(:external_agents_dispatcher_test, fn conn ->
        send(test_pid, {:dispatch_req, conn})

        Req.Test.json(conn, %{
          "model" => "llama3",
          "message" => %{"role" => "assistant", "content" => "ollama answer"},
          "done" => true
        })
      end)

      agent =
        build_agent("ollama_native", %{
          base_url: "http://localhost:11434",
          model: "llama3"
        })

      responsibility = build_responsibility()

      assert {:ok, "ollama answer"} =
               Dispatcher.dispatch(responsibility, agent, %{topic: "weekly"})

      assert_receive {:dispatch_req, conn}
      assert conn.request_path == "/api/chat"

      refute Enum.any?(conn.req_headers, fn
               {"authorization", _} -> true
               _ -> false
             end)

      assert_receive {:telemetry, @telemetry_called, %{duration_ms: _}, meta}
      assert meta.endpoint_kind == "ollama_native"
    end
  end

  describe "error paths" do
    test "500 returns {:error, {:http_error, 500, body}} and fires :error telemetry" do
      attach_telemetry([@telemetry_called, @telemetry_error])

      Req.Test.stub(:external_agents_dispatcher_test, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, ~s({"error":"boom"}))
      end)

      agent = build_agent("openai_compat")
      :ok = EphemeralCredentials.put(agent.id, "sk-test")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

      responsibility = build_responsibility()

      assert {:error, {:http_error, 500, _body}} =
               Dispatcher.dispatch(responsibility, agent, %{topic: "x"})

      assert_receive {:telemetry, @telemetry_error, %{duration_ms: _}, meta}
      assert meta.endpoint_kind == "openai_compat"
      assert meta.reason =~ "http_error"
    end

    test "transport error surfaces without crashing" do
      Req.Test.stub(:external_agents_dispatcher_test, fn conn ->
        Req.Test.transport_error(conn, :nxdomain)
      end)

      agent =
        build_agent("ollama_native", %{
          base_url: "http://nowhere.test",
          model: "llama3"
        })

      responsibility = build_responsibility()

      assert {:error, %Req.TransportError{reason: :nxdomain}} =
               Dispatcher.dispatch(responsibility, agent, %{})
    end
  end

  describe "ContractValidator" do
    test ":freeform / nil contract passes the raw string through" do
      assert {:ok, "hello"} = ContractValidator.validate("hello", nil)
      assert {:ok, "hello"} = ContractValidator.validate("hello", :freeform)
      assert {:ok, "hello"} = ContractValidator.validate("hello", %{})
      assert {:ok, "hello"} = ContractValidator.validate("hello", %{"type" => "freeform"})
    end

    test ":json contract — valid JSON → decoded map" do
      assert {:ok, %{"answer" => 42}} =
               ContractValidator.validate(~s({"answer": 42}), :json)

      assert {:ok, %{"answer" => 42}} =
               ContractValidator.validate(~s({"answer": 42}), %{"type" => "object"})

      assert {:ok, %{"answer" => 42}} =
               ContractValidator.validate(~s({"answer": 42}), %{"type" => "json"})
    end

    test ":json contract — invalid JSON → {:error, {:contract_violation, :invalid_json}}" do
      assert {:error, {:contract_violation, :invalid_json}} =
               ContractValidator.validate("not json at all", :json)

      assert {:error, {:contract_violation, :invalid_json}} =
               ContractValidator.validate("{broken", %{"type" => "object"})
    end

    test "non-string input is a contract violation" do
      assert {:error, {:contract_violation, :invalid_payload}} =
               ContractValidator.validate(123, :freeform)
    end
  end

  describe "contract integration with dispatch/3" do
    setup do
      test_pid = self()

      Req.Test.stub(:external_agents_dispatcher_test, fn conn ->
        send(test_pid, {:dispatch_req, conn})

        Req.Test.json(conn, %{
          "choices" => [
            %{
              "message" => %{"role" => "assistant", "content" => ~s({"verdict": "ship"})}
            }
          ]
        })
      end)

      :ok
    end

    test ":json contract on responsibility decodes the assistant content" do
      agent = build_agent("openai_compat")
      :ok = EphemeralCredentials.put(agent.id, "sk-test")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

      responsibility = build_responsibility(%{output_contract: %{"type" => "object"}})

      assert {:ok, %{"verdict" => "ship"}} =
               Dispatcher.dispatch(responsibility, agent, %{topic: "ship-it"})
    end

    test ":freeform contract returns the raw assistant content" do
      agent = build_agent("openai_compat")
      :ok = EphemeralCredentials.put(agent.id, "sk-test")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

      # Default output_contract is nil → freeform
      responsibility = build_responsibility()

      assert {:ok, ~s({"verdict": "ship"})} =
               Dispatcher.dispatch(responsibility, agent, %{topic: "ship-it"})
    end
  end
end
