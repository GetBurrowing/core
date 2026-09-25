defmodule Platform.Experiments.Surfaces.ChatContextSummary do
  @moduledoc """
  The `chat.context_summary` surface: which provider, model, system prompt
  and history window the on-demand "what led to this agent message" summary
  uses. Task 01a0d8de stage 1, the experimentation-layer ADR-0052.

  ## Subject and target

  The subject is the AGENT MESSAGE (`subject_type` `"message"`, subject id =
  the message id), so every viewer of one message is assigned one arm and a
  second click is sticky. The only target is `"chat.context_summary"`
  (`targets/0`); `experiment_create` refuses any other.

  ## Path

  `:draft`: the output is read by a person inside Suite and is never sent
  anywhere. It is not `:dispatch` either; nothing is resolved at a dispatch.

  ## Payload

    * `provider` (required) — `"anthropic" | "openai" | "ollama"`
    * `model` — string, at most 128 chars
    * `system_prompt` — string, at most 4000 chars
    * `max_messages` — integer 1..30, how many prior messages are read
    * `max_tokens` — integer 1..4096

  The control is a snapshot of `Platform.Chat.ContextSummary.Config.summary/0`
  taken at activation. On an install whose configured provider is `:none`
  there is no control to snapshot, so `control_payload/2` refuses and an
  experiment cannot be started: an experiment must never be the thing that
  turns on sending chat text to a model provider. `ContextSummary` enforces
  the same rule on the read side.
  """

  @behaviour Platform.Experiments.Surface

  alias Platform.Chat.ContextSummary.Config

  @target "chat.context_summary"
  @providers ~w(anthropic openai ollama)
  @keys ~w(provider model system_prompt max_messages max_tokens)
  @max_model 128
  @max_system_prompt 4000
  @max_messages_range 1..30
  @max_tokens_range 1..4096

  @impl true
  def key, do: "chat.context_summary"

  @impl true
  def subject_type, do: "message"

  @impl true
  def path, do: :draft

  @doc "The read points this surface is resolved at."
  @impl true
  def targets, do: [@target]

  @doc "The providers a payload may name."
  @spec providers() :: [String.t()]
  def providers, do: @providers

  @impl true
  def payload_schema do
    %{
      "type" => "object",
      "required" => ["provider"],
      "properties" => %{
        "provider" => %{
          "type" => "string",
          "enum" => @providers,
          "description" => "Which provider adapter generates the summary."
        },
        "model" => %{
          "type" => "string",
          "max_length" => @max_model,
          "description" => "Model name passed to the provider."
        },
        "system_prompt" => %{
          "type" => "string",
          "max_length" => @max_system_prompt,
          "description" => "System prompt for the summariser."
        },
        "max_messages" => %{
          "type" => "integer",
          "minimum" => @max_messages_range.first,
          "maximum" => @max_messages_range.last,
          "description" => "How many messages before the agent message are summarised."
        },
        "max_tokens" => %{
          "type" => "integer",
          "minimum" => @max_tokens_range.first,
          "maximum" => @max_tokens_range.last,
          "description" => "Output token cap."
        }
      }
    }
  end

  @impl true
  def validate_payload(payload) when is_map(payload) do
    provider = field(payload, "provider", :provider)
    model = field(payload, "model", :model)
    system_prompt = field(payload, "system_prompt", :system_prompt)
    max_messages = field(payload, "max_messages", :max_messages)
    max_tokens = field(payload, "max_tokens", :max_tokens)

    errors =
      provider_errors(provider) ++
        string_errors("model", model, @max_model) ++
        string_errors("system_prompt", system_prompt, @max_system_prompt) ++
        integer_errors("max_messages", max_messages, @max_messages_range) ++
        integer_errors("max_tokens", max_tokens, @max_tokens_range) ++
        unknown_key_errors(payload)

    case errors do
      [] ->
        {:ok,
         normalize(%{
           "provider" => provider,
           "model" => model,
           "system_prompt" => system_prompt,
           "max_messages" => max_messages,
           "max_tokens" => max_tokens
         })}

      errors ->
        {:error, errors}
    end
  end

  def validate_payload(_payload), do: {:error, ["payload must be an object"]}

  @doc """
  The configured defaults, snapshotted now. `{:error, :not_configured}` when
  the install's provider is `:none` (see the moduledoc).
  """
  @impl true
  def control_payload(_target, _opts \\ []) do
    cfg = Config.summary()

    if cfg.provider == :none do
      {:error, :not_configured}
    else
      validate_payload(
        %{
          "provider" => to_string(cfg.provider),
          "model" => cfg.model,
          "system_prompt" => cfg.system_prompt,
          "max_messages" => cfg.max_messages,
          "max_tokens" => cfg.max_tokens
        }
        |> Map.reject(fn {_k, v} -> is_nil(v) end)
      )
      |> case do
        {:ok, payload} -> {:ok, payload}
        {:error, reasons} -> {:error, {:invalid_config, reasons}}
      end
    end
  end

  defp field(payload, key, atom), do: Map.get(payload, key, Map.get(payload, atom))

  defp provider_errors(p) when p in @providers, do: []

  defp provider_errors(_p),
    do: ["provider must be one of: #{Enum.join(@providers, ", ")}"]

  defp string_errors(_name, nil, _max), do: []

  defp string_errors(name, value, max) when is_binary(value) do
    if String.length(value) > max, do: ["#{name} must be at most #{max} chars"], else: []
  end

  defp string_errors(name, _value, _max), do: ["#{name} must be a string"]

  defp integer_errors(_name, nil, _range), do: []

  defp integer_errors(name, value, range) when is_integer(value) do
    if value in range, do: [], else: [range_error(name, range)]
  end

  defp integer_errors(name, _value, range), do: [range_error(name, range)]

  defp range_error(name, range), do: "#{name} must be an integer in #{range.first}..#{range.last}"

  defp unknown_key_errors(payload) do
    case Enum.reject(Map.keys(payload), &(to_string(&1) in @keys)) do
      [] ->
        []

      keys ->
        ["unknown keys: #{keys |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.join(", ")}"]
    end
  end

  # Blank strings are the same as absent, so a blank model or prompt falls
  # back to the configured default instead of reaching the provider empty.
  defp normalize(map) do
    Enum.reduce(map, %{}, fn
      {_k, nil}, acc ->
        acc

      {k, v}, acc when is_binary(v) ->
        case String.trim(v) do
          "" -> acc
          trimmed -> Map.put(acc, k, trimmed)
        end

      {k, v}, acc ->
        Map.put(acc, k, v)
    end)
  end
end
