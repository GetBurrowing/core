defmodule Platform.Agents.Providers.OllamaTest.SlowPlug do
  @moduledoc """
  A real HTTP endpoint that stalls before answering.

  Used to exercise the adapter over a live socket: a `Req.Test` stub runs
  in-process and never touches Finch, so a `receive_timeout` assertion made
  against a stub can pass while the option does nothing.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    Process.sleep(Keyword.fetch!(opts, :sleep_ms))

    body =
      Jason.encode!(%{
        "model" => "gemma4",
        "choices" => [
          %{
            "index" => 0,
            "finish_reason" => "stop",
            "message" => %{"role" => "assistant", "content" => "slow but complete"}
          }
        ],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 3, "total_tokens" => 8}
      })

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, body)
  end
end

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

  describe "receive_timeout" do
    setup do
      # The file-level setup installs a Req.Test stub client. These tests are
      # about the socket, so they run against the adapter's own default client.
      Application.delete_env(:platform, :ollama_req_client)
      :ok
    end

    test "(a) the adapter's default Req client carries a receive_timeout of at least 300s" do
      receive_timeout = Ollama.req_client().options[:receive_timeout]

      assert is_integer(receive_timeout),
             "expected the default Ollama Req client to set :receive_timeout, got: " <>
               inspect(receive_timeout)

      assert receive_timeout >= 300_000
    end

    test "(b) the timeout is applied to the request, not merely set on a struct nobody reads" do
      base_url = start_slow_server(1_000)

      client = Req.merge(Ollama.req_client(), receive_timeout: 200)
      Application.put_env(:platform, :ollama_req_client, client)
      on_exit(fn -> Application.delete_env(:platform, :ollama_req_client) end)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               Ollama.chat(%{}, [%{"role" => "user", "content" => "hi"}],
                 base_url: base_url,
                 model: "gemma4"
               )
    end

    test "(d) the :ollama_receive_timeout config key is wired into the default client's timeout" do
      # Unlike (b), which merges a timeout onto the client it injects, this test
      # leaves :ollama_req_client unset and drives the adapter's own default
      # client. The only route from 200ms to the socket is the default setting
      # :receive_timeout from :ollama_receive_timeout — so deleting that option
      # from the default turns this red, which (b) structurally cannot do.
      base_url = start_slow_server(1_000)

      Application.put_env(:platform, :ollama_receive_timeout, 200)
      on_exit(fn -> Application.delete_env(:platform, :ollama_receive_timeout) end)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               Ollama.chat(%{}, [%{"role" => "user", "content" => "hi"}],
                 base_url: base_url,
                 model: "gemma4"
               )
    end

    @tag :slow
    @tag timeout: 120_000
    test "(c) a response that takes longer than Req's 15s default still succeeds" do
      base_url = start_slow_server(16_000)

      assert {:ok, response} =
               Ollama.chat(%{}, [%{"role" => "user", "content" => "hi"}],
                 base_url: base_url,
                 model: "gemma4"
               )

      assert response.content == "slow but complete"
    end
  end

  # Starts a real Bandit server on a free loopback port that sleeps `sleep_ms`
  # before responding, and returns its base URL.
  defp start_slow_server(sleep_ms) do
    port = free_port()

    start_supervised!(
      {Bandit,
       plug: {Platform.Agents.Providers.OllamaTest.SlowPlug, sleep_ms: sleep_ms},
       scheme: :http,
       ip: {127, 0, 0, 1},
       port: port,
       startup_log: false}
    )

    "http://127.0.0.1:#{port}"
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
