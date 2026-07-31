defmodule Platform.Responsibilities.Provider do
  @moduledoc """
  Behaviour every feature module that owns one or more responsibilities
  must implement (ADR-0041 M1 stage 3).

  A "provider" is the code-side counterpart to a row in the
  `responsibilities` table. The boot-time Registry GenServer (M1 stage 4)
  asks every provider module to enumerate the responsibilities it owns,
  upserts those declarations into the table, and then — at runtime — the
  M6 router looks up the row by key, asks the provider for the context
  the LLM will need, dispatches the LLM call, and hands the structured
  output back to the provider for validation and side effects.

  ## Callback semantics

    * `register/0` — pure, no-side-effects. Returns the list of attribute
      maps the provider wants persisted. Called once at boot per process
      lifetime. Each map must satisfy
      `Platform.Responsibilities.Responsibility.changeset/2`. M1 stage 4
      pipes each one through `Platform.Responsibilities.upsert_by_key/1`.

    * `gather_context/2` — called by the M6 router at dispatch time,
      after the trigger fires but before the LLM is invoked. The
      provider returns the context fragments named in
      `responsibility.context_provided` (e.g. transcript text, recent
      chat history, project metadata). The router merges this map into
      the prompt template's variable scope. M1 does not exercise this —
      M6/M8 wire it up — but providers must define the function so the
      callback contract is enforced at compile time via `@behaviour`.

    * `handle_output/2` — called by the M6 router after the LLM
      responds. Receives the structured output the model produced. The
      provider validates it against `responsibility.output_contract` and
      applies whatever side effects the responsibility implies (insert a
      summary row, post a message, fire a webhook, etc.). Returning
      `{:error, term}` lets the router decide whether to retry, log, or
      surface to the operator.

  ## Implementing this behaviour

      defmodule MyApp.Meetings.SummaryProvider do
        @behaviour Platform.Responsibilities.Provider

        @impl true
        def register do
          [
            %{
              key: "meetings.summarize",
              feature: "meetings",
              trigger_kind: "event_topic",
              trigger_config: %{"topic" => "meeting.ended"},
              scope: "per_meeting",
              context_provided: ["transcript"],
              output_contract: %{"summary" => "string"},
              default_prompt_template: "meetings.summarize.v1",
              cost_profile: "low_freq_capable"
            }
          ]
        end

        @impl true
        def gather_context(_responsibility, %{meeting_id: id}) do
          {:ok, %{transcript: Meetings.fetch_transcript(id)}}
        end

        @impl true
        def handle_output(_responsibility, %{"summary" => text}) do
          Meetings.insert_summary(text)
          :ok
        end
      end
  """

  @doc """
  Returns the list of responsibility attribute maps this provider owns.

  Must be pure and free of side effects — the Registry GenServer may
  call this multiple times across boots or hot-reloads.
  """
  @callback register() :: [map()]

  @doc """
  Gather the context fragments named by `responsibility.context_provided`
  for the supplied trigger payload.

  Returns `{:ok, context_map}` on success, where `context_map`'s keys
  match (or are a superset of) the strings in `context_provided`.
  Returns `{:error, term}` if the context cannot be assembled (missing
  record, upstream service down, etc.).
  """
  @callback gather_context(
              responsibility :: Platform.Responsibilities.Responsibility.t(),
              ctx :: map()
            ) :: {:ok, map()} | {:error, term()}

  @doc """
  Validate the LLM's structured output against
  `responsibility.output_contract` and apply the side effects the
  responsibility implies.

  Returns `:ok` on success or `{:error, term}` if validation failed or a
  side effect could not be applied.
  """
  @callback handle_output(
              responsibility :: Platform.Responsibilities.Responsibility.t(),
              output :: map()
            ) :: :ok | {:error, term()}

  @doc """
  M6-stage-6 evolved callback — receives the trigger metadata alongside
  the parsed LLM response. The Router invokes this arity when present
  (via `function_exported?/3`); providers that only implement
  `handle_output/2` keep working unchanged. New providers (e.g. the M8
  `meetings.summarize` provider) should prefer arity 3 because trigger
  metadata is often required to scope the side effect (`meeting_id`,
  `space_id`, `match` captures, etc.).
  """
  @callback handle_output(
              responsibility :: Platform.Responsibilities.Responsibility.t(),
              parsed_response :: term(),
              trigger_meta :: map()
            ) :: :ok | {:error, term()}

  @doc """
  Build the (system + user) LLM prompt from a gathered context map
  (task 019f2570 bug 1 fix).

  The Router probes for this callback in `dispatch_assignee/4` after
  calling `gather_context/2` — for external *and* native/federated
  assignees alike. For an external agent the returned messages are
  passed to `Platform.ExternalAgents.Dispatcher.dispatch/4` verbatim —
  bypassing the un-seeded `default_prompt_template` render path
  entirely so providers own their full prompt end-to-end. For a
  native/federated agent the same rendered text rides the dispatch
  signal as `metadata.prompt`.

  Returning `{:error, term}` short-circuits the dispatch — the Router
  logs at `:warning` and does NOT fire the LLM call. Typical use case:
  return `{:error, :no_transcript_text}` when the transcript slot the
  provider needs is empty so we don't burn a token round-trip on an
  answer the model can't produce.

  Providers that don't implement this callback fall back to the legacy
  `default_prompt_template` render path — full backward compatibility.
  """
  @callback build_prompt(context :: map()) ::
              {:ok, %{system: String.t(), user: String.t()}} | {:error, term()}

  @doc """
  Called when a dispatch was refused BEFORE the model was invoked
  (task 019fb90f-36e3 e2e fix).

  Two refusals reach here, both of them the Router's own decision not to
  call the LLM:

    * `{:context_gather_refused, reason}` — `gather_context/2` returned
      anything other than `{:ok, map}`.
    * `{:build_prompt_refused, reason}` — `build_prompt/1` returned
      `{:error, reason}` on the external path.

  ## Why this callback exists at all

  A refusal is the one dispatch outcome a provider could not observe.
  `handle_output/3` is reachable only from a dispatch that produced a
  model response, so a provider holding per-dispatch state — a queue
  row, a lease, a claim — had no seam at which to release it when the
  Router declined to dispatch. `meetings.action_items` is the worked
  example: `Platform.Meetings.IntentQueue` pins a per-meeting SERIAL
  cursor to the in-flight row, so a refused utterance stalled every
  intent behind it until the 90-second claim watchdog fired.

  The refusal is deliberately surfaced HERE rather than inside the
  feature's own dispatcher. The fork that produced the trigger
  (`Platform.Meetings.IntentDispatcher` → PubSub broadcast → Router) is
  fire-and-forget, so the dispatcher never sees the Router's return
  value and cannot close its own row from there.

  Return `:ok` when the refusal is handled; `{:error, term}` is logged
  and swallowed. The Router's own return value is unchanged either way —
  this callback is a side-effect seam, not a veto. It is NOT called on
  the native path's build_prompt refusal, which currently dispatches
  anyway (see `log_native_prompt_fidelity/3` in the Router).
  """
  @callback handle_refusal(
              responsibility :: Platform.Responsibilities.Responsibility.t(),
              refusal :: {:context_gather_refused | :build_prompt_refused, term()},
              trigger_meta :: map()
            ) :: :ok | {:error, term()}

  # Arity-3 handle_output is optional so M1 providers that still use
  # arity-2 keep compiling without forced churn. The Router probes for
  # the 3-arity version first and falls back to logging "no output
  # handler" if neither is present.
  #
  # `build_prompt/1` is optional so pre-019f2570 providers keep working
  # via the legacy `default_prompt_template` render path in the
  # ExternalDispatcher. New providers implement it to own the full
  # (system + user) prompt end-to-end.
  #
  # `handle_refusal/3` is optional because most providers hold no
  # per-dispatch state and have nothing to release when the Router
  # declines to dispatch. Implement it only when a refusal leaves
  # something of yours in flight.
  @optional_callbacks handle_output: 3, build_prompt: 1, handle_refusal: 3
end
