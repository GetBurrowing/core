defmodule Platform.Agents.Providers.Anthropic do
  @moduledoc """
  Anthropic provider adapter for the Agent Runtime.

  Supports either:

    * raw API keys (`x-api-key` auth)
    * OAuth tokens stored in `Platform.Vault` (Bearer auth)

  The OAuth request headers intentionally match the verified production call
  pattern from `Platform.Agents.QuickAgent` / OpenClaw's Anthropic OAuth flow.
  """

  @behaviour Platform.Agents.Providers.Provider

  @api_url "https://api.anthropic.com/v1/messages"
  @api_version "2023-06-01"
  @oauth_beta "claude-code-20250219,oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14"
  @api_key_beta "fine-grained-tool-streaming-2025-05-14"
  @oauth_user_agent "claude-cli/2.1.62"
  @oauth_models [
    %{id: "claude-sonnet-4-6", provider: "anthropic", auth_mode: "oauth"},
    %{id: "claude-opus-4-6", provider: "anthropic", auth_mode: "oauth"}
  ]
  @api_key_models [
    %{id: "claude-sonnet-4-5-20250929", provider: "anthropic", auth_mode: "api_key"}
  ]

  @type resolved_credentials :: %{
          token: String.t(),
          auth_mode: :oauth | :api_key,
          credential_slug: String.t() | nil
        }

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
    with {:ok, resolved} <- resolve_credentials(credentials) do
      {:ok, models_for_auth_mode(resolved.auth_mode)}
    end
  end

  @impl true
  def validate_credentials(credentials) do
    with {:ok, _resolved} <- resolve_credentials(credentials) do
      :ok
    end
  end

  defp do_chat(%{auth_mode: auth_mode} = resolved, messages, opts) do
    model = Keyword.get(opts, :model, default_model(auth_mode))
    started_at = System.monotonic_time()

    body =
      %{
        "model" => model,
        "max_tokens" => Keyword.get(opts, :max_tokens, 2048),
        "messages" => Enum.map(messages, &normalize_message/1)
      }
      |> maybe_put("system", normalize_system_prompt(Keyword.get(opts, :system)))
      |> maybe_put("temperature", Keyword.get(opts, :temperature))
      |> maybe_put("metadata", normalize_map(Keyword.get(opts, :metadata)))

    case Req.post(req_client(), url: @api_url, json: body, headers: request_headers(resolved)) do
      {:ok, %{status: 200, body: resp_body}} when is_map(resp_body) ->
        duration_ms = elapsed_ms(started_at)
        usage = Map.get(resp_body, "usage", %{})

        emit_telemetry(
          [:platform, :agent, :model_called],
          %{
            duration_ms: duration_ms,
            input_tokens: usage["input_tokens"] || 0,
            output_tokens: usage["output_tokens"] || 0
          },
          %{
            provider: "anthropic",
            model: resp_body["model"] || model,
            auth_mode: Atom.to_string(resolved.auth_mode),
            credential_slug: resolved.credential_slug,
            stop_reason: resp_body["stop_reason"]
          }
        )

        {:ok,
         %{
           content: extract_text_content(resp_body),
           model: resp_body["model"] || model,
           usage: usage,
           stop_reason: resp_body["stop_reason"],
           raw: resp_body
         }}

      {:ok, %{status: status, headers: headers, body: resp_body}} ->
        duration_ms = elapsed_ms(started_at)
        reason = normalize_http_error(status, headers, resp_body)

        emit_telemetry(
          [:platform, :agent, :model_error],
          %{duration_ms: duration_ms},
          %{
            provider: "anthropic",
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
            provider: "anthropic",
            model: model,
            auth_mode: Atom.to_string(resolved.auth_mode),
            credential_slug: resolved.credential_slug,
            error: inspect(reason)
          }
        )

        {:error, {:request_failed, reason}}
    end
  end

  defp resolve_credentials(credentials) when is_binary(credentials) do
    {:ok,
     %{
       token: credentials,
       auth_mode: detect_auth_mode(credentials),
       credential_slug: nil
     }}
  end

  defp resolve_credentials(credentials) when is_map(credentials) do
    cond do
      token = fetch_value(credentials, :access_token) ->
        {:ok,
         %{
           token: token,
           auth_mode: :oauth,
           credential_slug: fetch_value(credentials, :credential_slug)
         }}

      token = fetch_value(credentials, :api_key) ->
        {:ok,
         %{
           token: token,
           auth_mode: :api_key,
           credential_slug: fetch_value(credentials, :credential_slug)
         }}

      token = fetch_value(credentials, :token) ->
        auth_mode =
          credentials
          |> fetch_value(:auth_mode)
          |> normalize_auth_mode(token)

        {:ok,
         %{
           token: token,
           auth_mode: auth_mode,
           credential_slug:
             fetch_value(credentials, :credential_slug) || fetch_value(credentials, :slug)
         }}

      slug = fetch_value(credentials, :credential_slug) || fetch_value(credentials, :slug) ->
        resolve_vault_credential(slug, fetch_value(credentials, :accessor))

      true ->
        {:error, :missing_credentials}
    end
  end

  defp resolve_credentials(nil), do: {:error, :missing_credentials}
  defp resolve_credentials(_other), do: {:error, :missing_credentials}

  defp resolve_vault_credential(slug, accessor) do
    opts =
      case accessor do
        nil -> []
        value -> [accessor: value]
      end

    case Platform.Vault.get(slug, opts) do
      {:ok, raw} ->
        parse_vault_payload(raw, slug)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_vault_payload(raw, slug) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, %{"access_token" => token}} when is_binary(token) ->
        {:ok, %{token: token, auth_mode: :oauth, credential_slug: slug}}

      {:ok, %{"api_key" => token}} when is_binary(token) ->
        {:ok, %{token: token, auth_mode: :api_key, credential_slug: slug}}

      _ ->
        {:ok, %{token: raw, auth_mode: detect_auth_mode(raw), credential_slug: slug}}
    end
  end

  defp request_headers(%{auth_mode: :oauth, token: token}) do
    [
      {"authorization", "Bearer #{token}"},
      {"anthropic-version", @api_version},
      {"anthropic-beta", @oauth_beta},
      {"user-agent", @oauth_user_agent},
      {"x-app", "cli"},
      {"anthropic-dangerous-direct-browser-access", "true"},
      {"content-type", "application/json"}
    ]
  end

  defp request_headers(%{auth_mode: :api_key, token: token}) do
    [
      {"x-api-key", token},
      {"anthropic-version", @api_version},
      {"anthropic-beta", @api_key_beta},
      {"content-type", "application/json"}
    ]
  end

  defp default_model(:oauth), do: "claude-sonnet-4-6"
  defp default_model(:api_key), do: "claude-sonnet-4-5-20250929"

  defp models_for_auth_mode(:oauth), do: @oauth_models
  defp models_for_auth_mode(:api_key), do: @api_key_models

  defp detect_auth_mode(token) when is_binary(token) do
    if String.starts_with?(token, "sk-ant-oat"), do: :oauth, else: :api_key
  end

  defp normalize_auth_mode(nil, token), do: detect_auth_mode(token)
  defp normalize_auth_mode(value, _token) when value in [:oauth, "oauth"], do: :oauth

  defp normalize_auth_mode(value, _token) when value in [:api_key, "api_key", "api-key"],
    do: :api_key

  defp normalize_auth_mode(_value, token), do: detect_auth_mode(token)

  defp normalize_message(%{} = message) do
    %{
      "role" => fetch_value(message, :role) || "user",
      "content" => normalize_content(fetch_value(message, :content))
    }
  end

  defp normalize_content(content) when is_binary(content), do: content
  defp normalize_content(content) when is_list(content), do: content
  defp normalize_content(content), do: to_string(content || "")

  defp normalize_system_prompt(nil), do: nil

  defp normalize_system_prompt(prompt) when is_binary(prompt) do
    prompt = String.trim(prompt)
    if prompt == "", do: nil, else: prompt
  end

  defp normalize_system_prompt(prompt), do: to_string(prompt)

  defp normalize_map(nil), do: nil
  defp normalize_map(%{} = map), do: map
  defp normalize_map(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, value) when value == %{}, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp extract_text_content(resp_body) do
    resp_body
    |> Map.get("content", [])
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("", &(&1["text"] || ""))
  end

  defp normalize_http_error(429, headers, body) do
    retry_after = header_value(headers, "retry-after")
    {:rate_limited, retry_after, body}
  end

  defp normalize_http_error(status, _headers, body) when status in [401, 403] do
    {:auth_error, status, body}
  end

  defp normalize_http_error(status, _headers, body) do
    {:api_error, status, body}
  end

  defp header_value(headers, name) do
    headers
    |> Enum.find_value(fn {key, value} ->
      if String.downcase(to_string(key)) == String.downcase(name), do: value, else: nil
    end)
  end

  defp fetch_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp elapsed_ms(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :millisecond)
  end

  defp req_client do
    Application.get_env(
      :platform,
      :anthropic_req_client,
      Req.new(headers: [{"accept", "application/json"}], receive_timeout: 60_000)
    )
  end

  defp emit_telemetry(event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)
  end
end
