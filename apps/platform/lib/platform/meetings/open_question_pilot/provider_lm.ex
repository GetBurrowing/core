defmodule Platform.Meetings.OpenQuestionPilot.ProviderLM do
  @moduledoc """
  The `Imp.LM` client for arm B of the open_question pilot (task 01a0e8b5).

  It routes every Imp request through the SAME transport as arm A
  (`Platform.Agents.Providers.Ollama.chat/3`, via the meter's
  `live_module`) with the SAME options `IntentClassifier.call_provider/5`
  uses: `temperature: 0.0`, `max_tokens: 1024`,
  `chat_template_kwargs: %{"enable_thinking" => false}`, and the agent's
  `base_url` / `model`. Options Imp passes per call are ignored on
  purpose, so the two arms differ in the program, never in sampling.

  Every call goes through `OpenQuestionPilot.Meter` with purpose
  `:imp_program`: hard cap, latency/usage capture, cassette.

  Errors keep their class, and Imp hands them back to the caller
  unchanged (measured on imp 0.6.0):

    * blank content -> `{:error, {:empty_output, finish_reason}}`
    * transport/provider failure -> `{:error, {:model_error, reason}}`
    * cap reached -> `{:error, :budget_exhausted}`

  A replay miss raises `Meter.Miss` and is not caught here.
  """

  @behaviour Imp.LM

  alias Platform.Meetings.OpenQuestionPilot.Meter

  @enforce_keys [:meter]
  defstruct [:meter, agent: %{}, purpose: :imp_program, exhausted: :error]

  @type t :: %__MODULE__{
          meter: Meter.t(),
          agent: map(),
          purpose: Meter.purpose(),
          exhausted: :error | :fatal
        }

  @doc """
  Build a client over `meter` for `agent` (`:base_url`, `:model`, optional
  `:vault_key`).

  Options:

    * `:purpose` — the meter tag, default `:imp_program`; the optimiser's
      reflection model uses `:reflection`.
    * `:exhausted` — `:error` (default) returns `{:error, :budget_exhausted}`,
      which decide/3 counts as an error class. `:fatal` returns
      `{:error, %Imp.OperationalSafetyError{kind: :budget}}`, which Imp's
      optimisers treat as fatal and which ends a GEPA run instead of being
      scored as a bad row.
  """
  @spec new(Meter.t(), map(), keyword()) :: t()
  def new(%Meter{} = meter, agent \\ %{}, opts \\ []) do
    %__MODULE__{
      meter: meter,
      agent: agent,
      purpose: Keyword.get(opts, :purpose, :imp_program),
      exhausted: Keyword.get(opts, :exhausted, :error)
    }
  end

  @doc "The provider options both arms send, for `agent`."
  @spec provider_opts(map()) :: keyword()
  def provider_opts(agent) do
    [
      base_url: Map.get(agent, :base_url),
      model: Map.get(agent, :model),
      temperature: 0.0,
      max_tokens: 1024,
      chat_template_kwargs: %{"enable_thinking" => false}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  @impl Imp.LM
  def generate(%__MODULE__{meter: meter, agent: agent} = lm, messages, _opts) do
    messages = Enum.map(messages, &normalise_message/1)

    case Meter.chat(meter, lm.purpose, credentials(agent), messages, provider_opts(agent)) do
      {:ok, result} ->
        case content(result) do
          {:ok, text} ->
            if String.trim(text) == "",
              do: {:error, {:empty_output, finish_reason(result)}},
              else: {:ok, text}

          :error ->
            {:error, {:model_error, {:unexpected_shape, result}}}
        end

      {:error, :budget_exhausted} when lm.exhausted == :fatal ->
        {:error,
         Imp.OperationalSafetyError.exception(
           kind: :budget,
           reason: {:budget_exhausted, lm.purpose, meter.cap},
           message: "open_question pilot: #{lm.purpose} hard call cap #{meter.cap} reached"
         )}

      {:error, :budget_exhausted} ->
        {:error, :budget_exhausted}

      {:error, reason} ->
        {:error, {:model_error, reason}}
    end
  end

  defp normalise_message(message) do
    %{
      role: to_string(Map.get(message, :role) || Map.get(message, "role")),
      content: to_string(Map.get(message, :content) || Map.get(message, "content") || "")
    }
  end

  # Mirrors `IntentClassifier.agent_credentials/1`.
  defp credentials(agent) do
    case Map.get(agent, :vault_key) do
      key when is_binary(key) and key != "" -> %{api_key: key}
      _ -> %{}
    end
  end

  defp content(%{content: content}) when is_binary(content), do: {:ok, content}
  defp content(%{"content" => content}) when is_binary(content), do: {:ok, content}
  defp content(_), do: :error

  defp finish_reason(result),
    do: Map.get(result, :finish_reason) || Map.get(result, "finish_reason")
end
