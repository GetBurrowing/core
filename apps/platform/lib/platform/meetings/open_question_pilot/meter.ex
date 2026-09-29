defmodule Platform.Meetings.OpenQuestionPilot.Meter do
  @moduledoc """
  The ONE instrument every LM call in the open_question pilot goes through
  (task 01a0e8b5), for both arms: arm A's provider call (via
  `OpenQuestionPilot.MeteredProvider`, handed to `IntentClassifier.decide/1`
  as its `:provider_module`) and arm B's Imp program (via
  `OpenQuestionPilot.ProviderLM`).

  It carries three things:

    1. **A hard call cap.** Every call, live or replayed, takes a ticket
       from an `:atomics` counter with `add_get/3` BEFORE anything else
       happens. Ticket `cap + 1` and beyond return
       `{:error, :budget_exhausted}` without touching the provider. The
       increment and the read are one atomic operation, so concurrent
       callers cannot both slip under the cap. A refused call is logged
       like any other.
    2. **Per-call capture.** Latency and usage (`prompt_tokens`,
       `completion_tokens`) of every call, tagged with its `purpose`
       (`:prompt_arm` or `:imp_program`). Replayed calls report the
       latency that was RECORDED, so a replayed score reproduces the live
       one.
    3. **Cassette record/replay** keyed on `OpenQuestionPilot.Cassette.key/1`.
       `:replay` never falls through to a live call: a miss is logged and
       raised as `Meter.Miss`. Because `IntentClassifier.decide/1` rescues
       everything its provider raises (and would turn the miss into
       `:model_error`), `OpenQuestionPilot.decide/3` also checks
       `misses/1` after each arm and re-raises, so a miss is loud on
       every path.

  Modes: `:live` (call `live_module`), `:record` (call `live_module`,
  keep an entry per call; `flush!/1` writes them to `cassette_path`),
  `:replay` (answer from `cassette`, a `%{key => entry}` map or loaded
  from `cassette_path`).

  State lives in an ETS table owned by the process that called `new/1`.
  """

  alias Platform.Meetings.OpenQuestionPilot.Cassette

  defmodule Miss do
    @moduledoc "A replay call with no recorded entry. Never rescued into a model result."
    defexception [:message]
  end

  @enforce_keys [:ticket, :cap, :table, :mode]
  defstruct [:ticket, :cap, :table, :mode, :live_module, :cassette_path, cassette: %{}]

  @type purpose :: :prompt_arm | :imp_program | :reflection | :selection
  @type t :: %__MODULE__{}

  @doc """
  Build a meter.

    * `:cap` (required) — the most calls this meter will ever make.
    * `:mode` — `:live` (default), `:record` or `:replay`.
    * `:live_module` — provider with `Platform.Agents.Providers.Ollama.chat/3`'s
      contract; required for `:live` and `:record`.
    * `:cassette_path` — file for `:record` (written by `flush!/1`) and
      for `:replay` when `:cassette` is not given.
    * `:cassette` — `%{key => entry}` for `:replay`.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    cap = Keyword.fetch!(opts, :cap)

    unless is_integer(cap) and cap >= 0 do
      raise ArgumentError, "Meter :cap must be a non-negative integer, got: #{inspect(cap)}"
    end

    mode = Keyword.get(opts, :mode, :live)

    unless mode in [:live, :record, :replay] do
      raise ArgumentError, "Meter :mode must be :live, :record or :replay, got: #{inspect(mode)}"
    end

    live_module = Keyword.get(opts, :live_module)

    if mode in [:live, :record] and is_nil(live_module) do
      raise ArgumentError, "Meter in #{inspect(mode)} mode needs :live_module"
    end

    cassette_path = Keyword.get(opts, :cassette_path)

    cassette =
      case {mode, Keyword.fetch(opts, :cassette)} do
        {:replay, {:ok, cassette}} -> cassette
        {:replay, :error} when is_binary(cassette_path) -> Cassette.load(cassette_path)
        {:replay, :error} -> raise ArgumentError, "Meter in :replay mode needs a cassette"
        _ -> %{}
      end

    %__MODULE__{
      ticket: :atomics.new(1, signed: false),
      cap: cap,
      table: :ets.new(:open_question_pilot_meter, [:ordered_set, :public]),
      mode: mode,
      live_module: live_module,
      cassette_path: cassette_path,
      cassette: cassette
    }
  end

  @doc """
  Make one metered provider call. Same return contract as
  `Platform.Agents.Providers.Ollama.chat/3`, plus `{:error, :budget_exhausted}`.
  Raises `Meter.Miss` on a replay miss.
  """
  @spec chat(t(), purpose(), map(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def chat(%__MODULE__{} = meter, purpose, credentials, messages, opts) do
    ticket = :atomics.add_get(meter.ticket, 1, 1)
    key = Cassette.key(messages)

    if ticket > meter.cap do
      log(meter, ticket, %{purpose: purpose, key: key, outcome: :budget_exhausted})
      {:error, :budget_exhausted}
    else
      call(meter, ticket, purpose, key, credentials, messages, opts)
    end
  end

  defp call(%{mode: :replay} = meter, ticket, purpose, key, _credentials, _messages, _opts) do
    case Map.fetch(meter.cassette, key) do
      {:ok, %{"outcome" => "ok", "response" => response} = entry} ->
        log(meter, ticket, %{
          purpose: purpose,
          key: key,
          outcome: :ok,
          replayed: true,
          latency_ms: entry["latency_ms"],
          usage: usage(response["usage"])
        })

        {:ok, atomize_response(response)}

      {:ok, %{"outcome" => "error"} = entry} ->
        log(meter, ticket, %{
          purpose: purpose,
          key: key,
          outcome: :error,
          replayed: true,
          latency_ms: entry["latency_ms"],
          usage: usage(nil)
        })

        {:error, entry["response"]}

      :error ->
        :ets.insert(meter.table, {{:miss, ticket}, key})
        log(meter, ticket, %{purpose: purpose, key: key, outcome: :cassette_miss})

        raise Miss,
          message:
            "open_question pilot cassette miss for key #{key} (#{purpose}) — " <>
              "replay never falls through to a live call"
    end
  end

  defp call(meter, ticket, purpose, key, credentials, messages, opts) do
    started = System.monotonic_time(:millisecond)
    result = meter.live_module.chat(credentials, messages, opts)
    latency = System.monotonic_time(:millisecond) - started

    {outcome, usage, entry} =
      case result do
        {:ok, response} ->
          {:ok, usage(field(response, :usage)),
           Cassette.entry(key, "ok", serialisable_response(response), latency)}

        {:error, reason} ->
          {:error, usage(nil),
           Cassette.entry(key, "error", %{"reason" => inspect(reason)}, latency)}
      end

    if meter.mode == :record, do: :ets.insert(meter.table, {{:recorded, ticket}, entry})

    log(meter, ticket, %{
      purpose: purpose,
      key: key,
      outcome: outcome,
      replayed: false,
      latency_ms: latency,
      usage: usage
    })

    case result do
      {:ok, response} -> {:ok, response}
      # Replay reconstructs the error as the recorded payload, so both
      # modes hand back the same outcome class.
      {:error, reason} -> {:error, %{"reason" => inspect(reason)}}
    end
  end

  @doc "Every call made so far, oldest first."
  @spec calls(t()) :: [map()]
  def calls(%__MODULE__{table: table}) do
    table
    |> :ets.match_object({{:call, :_}, :_})
    |> Enum.map(fn {_k, call} -> call end)
  end

  @doc "The most recent call with this purpose, or nil."
  @spec last(t(), purpose()) :: map() | nil
  def last(meter, purpose),
    do: meter |> calls() |> Enum.filter(&(&1.purpose == purpose)) |> List.last()

  @doc "Tickets taken so far (including refused ones)."
  @spec tickets(t()) :: non_neg_integer()
  def tickets(%__MODULE__{ticket: ref}), do: :atomics.get(ref, 1)

  @doc "Number of replay misses so far."
  @spec misses(t()) :: non_neg_integer()
  def misses(%__MODULE__{table: table}), do: length(:ets.match_object(table, {{:miss, :_}, :_}))

  @doc "Delete the meter's table. The meter must not be used afterwards."
  @spec close(t()) :: :ok
  def close(%__MODULE__{table: table}) do
    :ets.delete(table)
    :ok
  end

  @doc "The cassette keys of every replay miss so far, oldest first."
  @spec miss_keys(t()) :: [String.t()]
  def miss_keys(%__MODULE__{table: table}) do
    table
    |> :ets.match_object({{:miss, :_}, :_})
    |> Enum.sort()
    |> Enum.map(fn {_k, key} -> key end)
  end

  @doc "Write the entries recorded in `:record` mode to `cassette_path`."
  @spec flush!(t()) :: :ok
  def flush!(%__MODULE__{mode: :record, cassette_path: path, table: table})
      when is_binary(path) do
    entries =
      table
      |> :ets.match_object({{:recorded, :_}, :_})
      |> Enum.map(fn {_k, entry} -> entry end)

    Cassette.append!(path, entries)
  end

  defp log(meter, ticket, call) do
    call =
      call
      |> Map.put(:ticket, ticket)
      |> Map.put_new(:replayed, false)
      |> Map.put_new(:latency_ms, nil)
      |> Map.put_new(:usage, usage(nil))

    :ets.insert(meter.table, {{:call, ticket}, call})
  end

  defp usage(usage) when is_map(usage) do
    %{
      prompt_tokens: field(usage, :prompt_tokens) || 0,
      completion_tokens: field(usage, :completion_tokens) || 0
    }
  end

  defp usage(_), do: %{prompt_tokens: 0, completion_tokens: 0}

  defp serialisable_response(response) do
    %{
      "content" => field(response, :content),
      "model" => field(response, :model),
      "finish_reason" => field(response, :finish_reason),
      "usage" => field(response, :usage) || %{}
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

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
end
