defmodule Platform.Agents.Providers.Ollama do
  @moduledoc """
  Ollama provider adapter for the Agent Runtime.

  Targets Ollama's OpenAI-compatible Chat Completions endpoint at
  `<base_url>/chat/completions`, so any OpenAI-shape request works. No
  authentication is required by default — if the deployment fronts Ollama
  with an auth proxy, an optional `api_key` credential is sent as a Bearer
  token.

  Base URL and model are driven by caller options since Ollama is almost
  always self-hosted and varies per deployment.
  """

  @behaviour Platform.Agents.Providers.Provider

  @impl true
  def chat(credentials, messages, opts \\ []) do
    base_url = Keyword.get(opts, :base_url) || default_base_url()

    unless is_binary(base_url) and base_url != "" do
      raise ArgumentError, "Ollama provider requires :base_url (or default_base_url/0)"
    end

    model = Keyword.get(opts, :model) || raise ArgumentError, "Ollama provider requires :model"
    url = String.trim_trailing(base_url, "/") <> "/chat/completions"

    body =
      %{
        "model" => model,
        "messages" => normalize_messages(messages, Keyword.get(opts, :system)),
        "stream" => false,
        # Disable chain-of-thought for reasoning-capable models (e.g. gemma4)
        # so `message.content` carries the answer directly. Callers that
        # actually want CoT can pass `think: true`.
        "think" => Keyword.get(opts, :think, false)
      }
      |> maybe_put("temperature", Keyword.get(opts, :temperature))
      |> maybe_put("max_tokens", Keyword.get(opts, :max_tokens))
      |> maybe_put("chat_template_kwargs", Keyword.get(opts, :chat_template_kwargs))

    headers = request_headers(credentials)
    started_at = System.monotonic_time()

    case Req.post(req_client(), url: url, json: body, headers: headers) do
      {:ok, %{status: 200, body: resp_body}} when is_map(resp_body) ->
        duration_ms = elapsed_ms(started_at)
        choice = first_choice(resp_body)
        usage = Map.get(resp_body, "usage", %{})

        emit_telemetry(
          [:platform, :agent, :model_called],
          %{
            duration_ms: duration_ms,
            input_tokens: usage["prompt_tokens"] || 0,
            output_tokens: usage["completion_tokens"] || 0
          },
          %{
            provider: "ollama",
            model: resp_body["model"] || model,
            base_url: base_url,
            finish_reason: choice["finish_reason"]
          }
        )

        {:ok,
         %{
           content: extract_message_content(choice),
           model: resp_body["model"] || model,
           usage: usage,
           finish_reason: choice["finish_reason"],
           raw: resp_body
         }}

      {:ok, %{status: status, body: resp_body}} ->
        duration_ms = elapsed_ms(started_at)

        emit_telemetry(
          [:platform, :agent, :model_error],
          %{duration_ms: duration_ms},
          %{provider: "ollama", model: model, base_url: base_url, status: status}
        )

        {:error, {:http_error, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def stream(_credentials, _messages, _opts \\ []) do
    {:error, :streaming_not_implemented}
  end

  @impl true
  def models(_credentials) do
    {:ok, []}
  end

  @impl true
  def validate_credentials(_credentials), do: :ok

  # ── Private ──────────────────────────────────────────────────────────────

  defp default_base_url do
    System.get_env("OLLAMA_BASE_URL")
  end

  defp request_headers(credentials) do
    base = [{"content-type", "application/json"}]

    case credentials do
      %{api_key: key} when is_binary(key) and key != "" ->
        [{"authorization", "Bearer #{key}"} | base]

      _ ->
        base
    end
  end

  defp normalize_messages(messages, system) do
    system_prefix =
      case system do
        sys when is_binary(sys) and sys != "" -> [%{"role" => "system", "content" => sys}]
        _ -> []
      end

    system_prefix ++ Enum.map(messages, &normalize_message/1)
  end

  defp normalize_message(%{role: role, content: content}),
    do: %{"role" => to_string(role), "content" => content}

  defp normalize_message(%{"role" => _} = m), do: m

  defp first_choice(%{"choices" => [choice | _]}) when is_map(choice), do: choice
  defp first_choice(_), do: %{}

  defp extract_message_content(%{"message" => %{"content" => content}}) when is_binary(content),
    do: content

  defp extract_message_content(_), do: ""

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp elapsed_ms(started_at) do
    System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)
  end

  defp emit_telemetry(event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)
  rescue
    _ -> :ok
  end

  # How long a single model call is allowed to take, in milliseconds. An
  # order of magnitude above the measured worst case: production summaries
  # run 10.3s for 64 output tokens and 26.7s for ~970 output tokens on a
  # 21k-token prompt, so a full 2048-token completion extrapolates to ~45s
  # on an unloaded box. The sibling adapters hardcode 60s, which would leave
  # under 15s of headroom on a self-hosted model whose throughput varies with
  # concurrent load. Config-driven so an operator can lower it without a
  # deploy.
  @default_receive_timeout_ms 300_000

  @doc """
  The default receive timeout in milliseconds, honouring
  `:ollama_receive_timeout`. Read this rather than restating the number.
  """
  @spec receive_timeout_ms() :: pos_integer()
  def receive_timeout_ms do
    Application.get_env(:platform, :ollama_receive_timeout, @default_receive_timeout_ms)
  end

  @doc """
  The `Req` client used for chat completions.

  Public so tests can assert on the options the adapter actually ships with;
  `:ollama_req_client` overrides it wholesale for injection.
  """
  @spec req_client() :: Req.Request.t()
  def req_client do
    Application.get_env(
      :platform,
      :ollama_req_client,
      Req.new(
        headers: [{"accept", "application/json"}],
        receive_timeout: receive_timeout_ms()
      )
    )
  end
end
