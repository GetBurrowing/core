defmodule Platform.Meetings.IntentEval.CassetteProvider do
  @moduledoc """
  A provider module (same `chat/3` contract as
  `Platform.Agents.Providers.Ollama`) that either records live responses into
  a cassette or replays them (task `01a03fbb` stage 4).

  It is handed to `Platform.Meetings.IntentClassifier.decide/1` as its
  `:provider_module`, so a replayed run walks the SAME provider-call →
  parse → outcome path production walks. The harness measures the pipeline,
  not the model, and a parallel harness-side copy of the parse step is
  precisely how one population of declines once got split across two
  verdicts.

  Per-call state lives in the process dictionary because `chat/3` is a
  module function with no place to thread a struct through `decide/1`. The
  harness runs its rows sequentially in one process, sets the state before
  each call and reads the recording back after it.
  """

  alias Platform.Meetings.IntentEval.Cassette

  @state_key :intent_eval_cassette_state
  @recorded_key :intent_eval_cassette_recorded

  defmodule Miss do
    @moduledoc """
    Raised if a replay call reaches the provider with no recorded entry.

    Unreachable by construction — the harness pre-checks every key before it
    classifies a single row, precisely so a miss is reported as a missing
    fixture and not rescued into `:model_error` by `decide/1`'s blanket
    `rescue`. It exists so that a future caller who skips the pre-check
    fails loudly instead of silently going to the network.
    """
    defexception [:message]
  end

  @doc """
  Arm the provider for one run.

    * `mode` — `:record` or `:replay`
    * `cassette` — `%{key => entry}` (replay lookups)
    * `live_module` — provider used in `:record` mode
    * `opts_override` — config knobs (temperature, max_tokens,
      chat_template_kwargs) merged over what `decide/1` passes
  """
  def arm(state) do
    Process.put(@state_key, state)
    Process.put(@recorded_key, [])
    :ok
  end

  @doc "Entries recorded since `arm/1`, oldest first."
  def recorded, do: Process.get(@recorded_key, []) |> Enum.reverse()

  @doc "Latency (ms) of the most recent call, live or replayed."
  def last_latency_ms, do: Process.get(:intent_eval_cassette_last_latency_ms)

  @doc """
  Raw content string of the most recent call, live or replayed (`nil` for an
  error outcome).

  The harness counts how many of these are JSON-parseable. Without that count
  a config that declines everything in perfect JSON and a config that answers
  in prose print byte-identical reports — same `parse_error` totals, entirely
  different failures.
  """
  def last_content, do: Process.get(:intent_eval_cassette_last_content)

  # Mirrors `Platform.Agents.Providers.Ollama.chat/3`.
  def chat(credentials, messages, opts \\ []) do
    state = Process.get(@state_key) || raise Miss, message: "cassette provider not armed"
    key = Cassette.key(system_content(messages), user_content(messages))

    case state.mode do
      :replay -> replay(state, key)
      :record -> record(state, credentials, messages, opts, key)
    end
  end

  defp replay(state, key) do
    case Map.fetch(state.cassette, key) do
      {:ok, %{"outcome" => "ok"} = entry} ->
        put_latency(entry["latency_ms"])
        put_content(entry["response"]["content"])
        {:ok, atomize_response(entry["response"])}

      {:ok, %{"outcome" => "error"} = entry} ->
        put_latency(entry["latency_ms"])
        put_content(nil)
        {:error, entry["response"]}

      :error ->
        raise Miss,
          message: "cassette miss for key #{key} — replay must never fall through to a live call"
    end
  end

  defp record(state, credentials, messages, opts, key) do
    opts = Keyword.merge(opts, state.opts_override)
    started = System.monotonic_time(:millisecond)
    result = state.live_module.chat(credentials, messages, opts)
    latency = System.monotonic_time(:millisecond) - started
    put_latency(latency)

    case result do
      {:ok, response} -> put_content(Map.get(response, :content) || Map.get(response, "content"))
      {:error, _} -> put_content(nil)
    end

    entry =
      case result do
        {:ok, response} ->
          Cassette.entry(key, "ok", serialisable_response(response), latency)

        {:error, reason} ->
          Cassette.entry(key, "error", %{"reason" => inspect(reason)}, latency)
      end

    Process.put(@recorded_key, [entry | Process.get(@recorded_key, [])])

    case result do
      {:ok, response} -> {:ok, response}
      # Replay reconstructs the error as the inspected string, so record it
      # the same way: the two modes must produce the same outcome class.
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp put_latency(ms), do: Process.put(:intent_eval_cassette_last_latency_ms, ms)
  defp put_content(content), do: Process.put(:intent_eval_cassette_last_content, content)

  # Only the fields the classifier reads are persisted. `raw` is dropped: it
  # is the whole provider payload, it inflates the cassette by an order of
  # magnitude, and nothing downstream of `decide/1` looks at it.
  defp serialisable_response(response) do
    %{
      "content" => Map.get(response, :content) || Map.get(response, "content"),
      "model" => Map.get(response, :model) || Map.get(response, "model"),
      "finish_reason" => Map.get(response, :finish_reason) || Map.get(response, "finish_reason"),
      "usage" => Map.get(response, :usage) || Map.get(response, "usage") || %{}
    }
  end

  defp atomize_response(response) do
    %{
      content: response["content"],
      model: response["model"],
      finish_reason: response["finish_reason"],
      usage: response["usage"] || %{}
    }
  end

  defp system_content(messages), do: role_content(messages, "system")
  defp user_content(messages), do: role_content(messages, "user")

  defp role_content(messages, role) do
    Enum.find_value(messages, "", fn message ->
      cond do
        Map.get(message, :role) == role -> Map.get(message, :content)
        Map.get(message, "role") == role -> Map.get(message, "content")
        true -> nil
      end
    end)
  end
end
