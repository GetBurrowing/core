defmodule Platform.Experiments.Surfaces.MeetingBriefSynthesis do
  @moduledoc """
  Provider, model, prompt and context bounds for the native meeting synthesis
  pass (task 01a16974-e3db-7000-97e9-8ec9611189bc). The meeting is the sticky
  subject. Unlike dreaming, this native pass selects its own model, so model
  is an arm. Metric: `meeting_synthesis_resolution_rate`.

  Control snapshots the meeting summary provider. A provider-less install
  refuses control; an experiment must not enable outbound model calls.
  """

  @behaviour Platform.Experiments.Surface

  alias Platform.Meetings.Config

  @target "meetings.brief_synthesis"
  @providers ~w(anthropic openai ollama)
  @keys ~w(provider model system_prompt lookback_days max_sources min_confidence)
  @confidences ~w(high medium low)
  @max_model 128
  @max_system_prompt 4000
  @lookback_days_range 1..90
  @max_sources_range 1..200

  @impl true
  def key, do: "meetings.brief_synthesis"

  @impl true
  def subject_type, do: "meeting"

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
          "description" => "Provider adapter for the synthesis pass."
        },
        "model" => %{
          "type" => "string",
          "max_length" => @max_model,
          "description" => "Model name passed to the provider."
        },
        "system_prompt" => %{
          "type" => "string",
          "max_length" => @max_system_prompt,
          "description" =>
            "Additional directive appended to the DB-backed synthesis system prompt."
        },
        "lookback_days" => %{
          "type" => "integer",
          "minimum" => @lookback_days_range.first,
          "maximum" => @lookback_days_range.last,
          "description" => "Lookback window for related meetings, in days."
        },
        "min_confidence" => %{"type" => "string", "enum" => @confidences},
        "max_sources" => %{
          "type" => "integer",
          "minimum" => @max_sources_range.first,
          "maximum" => @max_sources_range.last,
          "description" => "Maximum candidate sources sent to the provider."
        }
      }
    }
  end

  @impl true
  def validate_payload(payload) when is_map(payload) do
    provider = field(payload, "provider", :provider)
    model = field(payload, "model", :model)
    system_prompt = field(payload, "system_prompt", :system_prompt)
    lookback_days = field(payload, "lookback_days", :lookback_days)
    max_sources = field(payload, "max_sources", :max_sources)

    min_confidence = field(payload, "min_confidence", :min_confidence) || "medium"

    errors =
      provider_errors(provider) ++
        string_errors("model", model, @max_model) ++
        string_errors("system_prompt", system_prompt, @max_system_prompt) ++
        integer_errors("lookback_days", lookback_days, @lookback_days_range) ++
        integer_errors("max_sources", max_sources, @max_sources_range) ++
        confidence_errors(min_confidence) ++
        unknown_key_errors(payload)

    case errors do
      [] ->
        {:ok,
         normalize(%{
           "provider" => provider,
           "model" => model,
           "system_prompt" => system_prompt,
           "lookback_days" => lookback_days || 14,
           "max_sources" => max_sources || 60,
           "min_confidence" => min_confidence
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
          "lookback_days" => 14,
          "max_sources" => 60,
          "min_confidence" => "medium"
        }
        |> Map.reject(fn {_k, v} -> is_nil(v) end)
      )
      |> case do
        {:ok, payload} -> {:ok, payload}
        {:error, reasons} -> {:error, {:invalid_config, reasons}}
      end
    end
  end

  defp confidence_errors(value) when value in @confidences, do: []
  defp confidence_errors(_value), do: ["min_confidence must be high, medium or low"]

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
