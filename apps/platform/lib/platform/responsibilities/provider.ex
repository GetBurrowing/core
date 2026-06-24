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
end
