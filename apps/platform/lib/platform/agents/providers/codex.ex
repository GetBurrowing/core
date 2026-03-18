defmodule Platform.Agents.Providers.Codex do
  @moduledoc """
  Codex provider adapter for the lightweight chat-agent path.

  Mirrors the working OpenClaw/OpenAI Codex transport shape:
  - base URL: https://chatgpt.com/backend-api
  - endpoint: /codex/responses
  - auth: Bearer Codex OAuth access token + chatgpt-account-id from JWT claims
  - response format: SSE events with response.output_text.* items
  """

  @behaviour Platform.Agents.Providers.Provider

  @default_base_url "https://chatgpt.com/backend-api"
  @jwt_claim_path "https://api.openai.com/auth"
  @models [
    %{id: "gpt-5.4", provider: "openai-codex", auth_mode: "oauth"}
  ]

  @impl true
  def chat(credentials, messages, opts \\ []) do
    with {:ok, resolved} <- resolve_credentials(credentials),
         {:ok, response} <- do_chat(resolved, messages, opts) do
      {:ok, response}
    end
  end

  @impl true
  def stream(_credentials, _messages, _opts \\ []) do
    {:error, :streaming_not_implemented}
  end

  @impl true
  def models(credentials) do
    with {:ok, _resolved} <- resolve_credentials(credentials) do
      {:ok, @models}
    end
  end

  @impl true
  def validate_credentials(credentials) do
    with {:ok, _resolved} <- resolve_credentials(credentials) do
      :ok
    end
  end

  defp do_chat(resolved, messages, opts) do
    model = Keyword.get(opts, :model, default_model())
    started_at = System.monotonic_time()

    body = build_body(model, messages, opts)

    case Req.post(req_client(),
           url: resolve_url(Keyword.get(opts, :base_url)),
           body: Jason.encode!(body),
           headers: request_headers(resolved, Keyword.get(opts, :session_id))
         ) do
      {:ok, %{status: 200, body: resp_body}} when is_binary(resp_body) ->
        duration_ms = elapsed_ms(started_at)
        parsed = parse_sse(resp_body)

        emit_telemetry(
          [:platform, :agent, :model_called],
          %{
            duration_ms: duration_ms,
            input_tokens: get_in(parsed, [:usage, "input_tokens"]) || 0,
            output_tokens: get_in(parsed, [:usage, "output_tokens"]) || 0
          },
          %{
            provider: "openai-codex",
            model: parsed.model || model,
            auth_mode: Atom.to_string(resolved.auth_mode),
            credential_slug: resolved.credential_slug,
            finish_reason: parsed.finish_reason,
            account_id: resolved.account_id
          }
        )

        {:ok,
         %{
           content: parsed.content,
           model: parsed.model || model,
           usage: parsed.usage || %{},
           finish_reason: parsed.finish_reason,
           raw: parsed.events
         }}

      {:ok, %{status: status, body: resp_body}} ->
        duration_ms = elapsed_ms(started_at)
        reason = normalize_http_error(status, resp_body)

        emit_telemetry(
          [:platform, :agent, :model_error],
          %{duration_ms: duration_ms},
          %{
            provider: "openai-codex",
            model: model,
            auth_mode: Atom.to_string(resolved.auth_mode),
            credential_slug: resolved.credential_slug,
            status: status,
            error: inspect(reason)
          }
        )

        {:error, reason}

      {:error, reason} ->
        duration_ms = elapsed_ms(started_at)

        emit_telemetry(
          [:platform, :agent, :model_error],
          %{duration_ms: duration_ms},
          %{
            provider: "openai-codex",
            model: model,
            auth_mode: Atom.to_string(resolved.auth_mode),
            credential_slug: resolved.credential_slug,
            error: inspect(reason)
          }
        )

        {:error, {:request_failed, reason}}
    end
  end

  defp build_body(model, messages, opts) do
    %{}
    |> Map.put("model", model)
    |> Map.put("store", false)
    |> Map.put("stream", true)
    |> Map.put("instructions", normalize_system_prompt(Keyword.get(opts, :system)))
    |> Map.put("input", convert_messages(messages))
    |> Map.put("text", %{"verbosity" => Keyword.get(opts, :text_verbosity, "medium")})
    |> Map.put("include", ["reasoning.encrypted_content"])
    |> maybe_put("prompt_cache_key", Keyword.get(opts, :session_id))
    |> Map.put("tool_choice", "auto")
    |> Map.put("parallel_tool_calls", true)
  end

  defp convert_messages(messages) do
    messages
    |> Enum.flat_map(&convert_message/1)
  end

  defp convert_message(%{} = message) do
    role = normalize_role(fetch_value(message, :role) || "user")
    content = normalize_content(fetch_value(message, :content))

    case {role, String.trim(content)} do
      {_role, ""} ->
        []

      {"assistant", text} ->
        [
          %{
            "type" => "message",
            "role" => "assistant",
            "status" => "completed",
            "id" => assistant_message_id(text),
            "content" => [
              %{
                "type" => "output_text",
                "text" => text,
                "annotations" => []
              }
            ]
          }
        ]

      {role, text} ->
        [
          %{
            "role" => role,
            "content" => [
              %{
                "type" => "input_text",
                "text" => text
              }
            ]
          }
        ]
    end
  end

  defp assistant_message_id(text) do
    binary = :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
    "msg_" <> String.slice(binary, 0, 24)
  end

  defp resolve_credentials(credentials) when is_map(credentials) do
    token =
      fetch_value(credentials, :access_token) ||
        fetch_value(credentials, :token) ||
        fetch_value(credentials, :api_key)

    cond do
      is_binary(token) and token != "" ->
        case extract_account_id(token) do
          {:ok, account_id} ->
            {:ok,
             %{
               token: token,
               account_id: account_id,
               auth_mode: :oauth,
               credential_slug: fetch_value(credentials, :credential_slug)
             }}

          {:error, reason} ->
            {:error, reason}
        end

      true ->
        {:error, :missing_credentials}
    end
  end

  defp resolve_credentials(credentials) when is_binary(credentials) do
    resolve_credentials(%{access_token: credentials})
  end

  defp resolve_credentials(_other), do: {:error, :missing_credentials}

  defp extract_account_id(token) do
    with [_, payload, _] <- String.split(token, "."),
         {:ok, decoded} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(decoded),
         %{"chatgpt_account_id" => account_id} when is_binary(account_id) <-
           get_in(claims, [@jwt_claim_path]) do
      {:ok, account_id}
    else
      _ -> {:error, :invalid_codex_token}
    end
  end

  defp request_headers(resolved, session_id) do
    headers = [
      {"authorization", "Bearer #{resolved.token}"},
      {"chatgpt-account-id", resolved.account_id},
      {"openai-beta", "responses=experimental"},
      {"originator", "pi"},
      {"user-agent", "pi (elixir; codex-provider)"},
      {"accept", "text/event-stream"},
      {"content-type", "application/json"}
    ]

    case session_id do
      nil -> headers
      value -> headers ++ [{"session_id", to_string(value)}]
    end
  end

  defp resolve_url(nil), do: @default_base_url <> "/codex/responses"
  defp resolve_url(base_url), do: String.trim_trailing(base_url, "/") <> "/codex/responses"

  defp parse_sse(raw) do
    events =
      raw
      |> String.split("\n\n", trim: true)
      |> Enum.flat_map(fn chunk ->
        data =
          chunk
          |> String.split("\n")
          |> Enum.filter(&String.starts_with?(&1, "data:"))
          |> Enum.map(&String.replace_prefix(&1, "data:", ""))
          |> Enum.join("\n")
          |> String.trim()

        cond do
          data in ["", "[DONE]"] ->
            []

          true ->
            case Jason.decode(data) do
              {:ok, event} -> [event]
              _ -> []
            end
        end
      end)

    content =
      events
      |> Enum.flat_map(fn
        %{"type" => "response.output_text.done", "text" => text} when is_binary(text) -> [text]
        _ -> []
      end)
      |> Enum.join("")

    completed =
      Enum.find(events, fn
        %{"type" => type} when type in ["response.completed", "response.done"] -> true
        _ -> false
      end) || %{}

    response = Map.get(completed, "response", %{})

    %{
      content: content,
      model: response["model"],
      finish_reason: response["status"] || "completed",
      usage: Map.get(response, "usage", %{}),
      events: events
    }
  end

  defp normalize_http_error(429, body), do: {:rate_limited, nil, body}

  defp normalize_http_error(status, body) when status in [401, 403],
    do: {:auth_error, status, body}

  defp normalize_http_error(status, body), do: {:api_error, status, body}

  defp normalize_role(role) when is_binary(role), do: role
  defp normalize_role(role), do: to_string(role)

  defp normalize_content(content) when is_binary(content), do: content
  defp normalize_content(content), do: to_string(content || "")

  defp normalize_system_prompt(nil), do: nil
  defp normalize_system_prompt(prompt) when is_binary(prompt), do: String.trim(prompt)
  defp normalize_system_prompt(prompt), do: to_string(prompt)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fetch_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp default_model, do: "gpt-5.4"

  defp elapsed_ms(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :millisecond)
  end

  defp req_client do
    Application.get_env(
      :platform,
      :codex_req_client,
      Req.new(headers: [{"accept", "text/event-stream"}], receive_timeout: 60_000)
    )
  end

  defp emit_telemetry(event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)
  end
end
