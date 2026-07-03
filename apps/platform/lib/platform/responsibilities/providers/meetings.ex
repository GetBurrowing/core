defmodule Platform.Responsibilities.Providers.Meetings do
  @moduledoc """
  Provider shim for the `meetings` feature (ADR-0041 M8 stage 6; extended
  by task 019f2451 stage 3 for `meetings.intent_classify`).

  The M6 Router resolves the per-feature provider module by camelcasing
  the responsibility's `feature` field and prepending
  `Platform.Responsibilities.Providers.` (see
  `Platform.Responsibilities.Router.provider_module_for/1`). So a row
  with `feature == "meetings"` looks up
  `Platform.Responsibilities.Providers.Meetings` — **this module**.

  Historically the meeting summary body lived directly in
  `Platform.Responsibilities.Handlers.MeetingSummarize`, which the
  Router COULD NOT see by feature lookup. That meant a router-fired
  `meetings.summarize` dispatch logged
  `[ResponsibilityRouter] no output handler for meetings.summarize` and
  the legacy bridge inside `Platform.Meetings.Summarizer.run_summary/1`
  did the work alone. This shim closes that gap by delegating every
  Provider callback through to the real implementation.

  ## Multi-responsibility routing (task 019f2451 stage 3)

  As of the Meeting Producer role roll-out the `meetings` feature owns
  more than one row (`meetings.summarize` +
  `meetings.intent_classify`). The Router still resolves one module per
  feature, so this shim now dispatches on `responsibility.key` via
  `handler_for/1` and hands off to the concrete handler module. Any
  unmapped key logs a warning and returns
  `{:error, :unknown_meetings_responsibility}` — this is the smoke
  signal for a drift between the built-ins list and this dispatch table.

  ## What this module owns

    * `register/0` — returns the fan-in of every meetings handler's
      spec list, so the boot Registry walks a canonical row per
      responsibility even if a future operator drops one from
      `Platform.Responsibilities.BuiltIns.providers/0` but keeps this
      shim wired.
    * `gather_context/2` — routes to the matching handler after
      normalising the trigger meta so the summariser handler sees the
      same `:payload` shape whether the trigger came from an
      event_topic broadcast (`%{kind: :event_topic, payload: %{...}}`)
      or a direct `fire/2` call where the caller flattened
      `transcript_id` to the top level.
    * `handle_output/2` and `handle_output/3` — route by key so the
      persistence pipeline stays in exactly one place per
      responsibility.
    * `handler_for/1` — public accessor exposing the dispatch table
      itself so integration tests (stage 4) can assert role → bundle →
      responsibility → handler wiring end-to-end without going through
      the Router.

  ## Trigger-meta normalisation

  `Platform.Meetings.Summarizer.run_summary/1`'s router fire passes
  `%{kind: :event_topic, topic: ..., payload: %{transcript_id:, space_id:}}`,
  but a direct `Router.fire(:meetings_summarize, %{transcript_id: ..., ...})`
  call (e.g. an operator nudge from iex) puts the keys at the top
  level. The Handler's `gather_context/2` reads from `:payload`; this
  shim's `gather_context/2` runs first and lifts the top-level fields
  into a synthetic `:payload` so the downstream code path is uniform.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Responsibilities.Handlers
  alias Platform.Responsibilities.Handlers.IntentClassify
  alias Platform.Responsibilities.Handlers.MeetingSummarize
  alias Platform.Responsibilities.Responsibility

  @impl true
  def register, do: MeetingSummarize.register() ++ IntentClassify.register()

  @doc """
  Return the concrete handler module for a given responsibility (or key).
  Public so stage 4's integration test can assert the role → bundle →
  responsibility → handler wiring lands on the expected module without
  reaching through the M6 Router.

  Returns `nil` for any key not owned by this feature so callers can
  branch on the missing case explicitly.
  """
  @spec handler_for(Responsibility.t() | %{key: String.t()} | String.t() | any()) ::
          module() | nil
  def handler_for(%Responsibility{key: key}), do: handler_for(key)
  def handler_for(%{key: key}), do: handler_for(key)
  def handler_for("meetings.summarize"), do: Handlers.MeetingSummarize
  def handler_for("meetings.intent_classify"), do: Handlers.IntentClassify
  def handler_for(_), do: nil

  @impl true
  def gather_context(%Responsibility{} = responsibility, ctx) when is_map(ctx) do
    case handler_for(responsibility) do
      nil ->
        unknown_key(responsibility)

      Handlers.MeetingSummarize ->
        MeetingSummarize.gather_context(responsibility, normalize_meta(ctx))

      handler ->
        handler.gather_context(responsibility, ctx)
    end
  end

  def gather_context(_responsibility, _ctx), do: {:ok, %{}}

  @impl true
  def handle_output(%Responsibility{} = responsibility, parsed) do
    case handler_for(responsibility) do
      nil -> unknown_key(responsibility)
      handler -> handler.handle_output(responsibility, parsed)
    end
  end

  @impl true
  def handle_output(%Responsibility{} = responsibility, parsed, trigger_meta)
      when is_map(trigger_meta) do
    case handler_for(responsibility) do
      nil ->
        unknown_key(responsibility)

      Handlers.MeetingSummarize ->
        MeetingSummarize.handle_output(responsibility, parsed, normalize_meta(trigger_meta))

      handler ->
        handler.handle_output(responsibility, parsed, trigger_meta)
    end
  end

  @doc """
  Provider-level `build_prompt/1` (task 019f2570 bug 1 fix).

  The Router's `dispatch_external/3` calls this after
  `gather_context/2` — when it returns `{:ok, %{system:, user:}}` the
  Router hands the pre-built prompt to
  `Platform.ExternalAgents.Dispatcher.dispatch/4` and skips the
  un-seeded `default_prompt_template` render path.

  The Router stuffs the fired `Responsibility` into the context under
  `:__responsibility__` before calling us so we can dispatch by key.
  We route summariser keys to `MeetingSummarize.build_prompt/1`;
  everything else (e.g. `meetings.intent_classify`) short-circuits to
  `{:error, :no_build_prompt}` so the Router's fallback catch drops us
  back onto the legacy template render path — the pre-019f2570
  behaviour, verbatim.
  """
  @impl true
  @spec build_prompt(map()) ::
          {:ok, %{system: String.t(), user: String.t()}} | {:error, term()}
  def build_prompt(context) when is_map(context) do
    case handler_for(Map.get(context, :__responsibility__)) do
      Handlers.MeetingSummarize -> MeetingSummarize.build_prompt(context)
      _ -> {:error, :no_build_prompt}
    end
  end

  def build_prompt(_), do: {:error, :no_build_prompt}

  # ── internals ─────────────────────────────────────────────────────────────

  defp unknown_key(%Responsibility{key: key}) do
    Logger.warning(
      "[meetings provider] unknown responsibility key=#{inspect(key)} — no handler mapped; " <>
        "add a clause to Providers.Meetings.handler_for/1 or drop the row from BuiltIns.providers/0"
    )

    {:error, :unknown_meetings_responsibility}
  end

  # When the trigger meta already carries a `:payload`/"payload" key we
  # leave it alone — that's the event_topic dispatch shape the Router
  # publishes verbatim. When the meta has top-level transcript_id /
  # space_id (a direct `Router.fire/2` call site), promote them into a
  # synthetic `:payload` so the handler's accessors find them where they
  # expect.
  defp normalize_meta(%{payload: payload} = meta) when is_map(payload), do: meta
  defp normalize_meta(%{"payload" => payload} = meta) when is_map(payload), do: meta

  defp normalize_meta(meta) when is_map(meta) do
    payload =
      meta
      |> Map.take([:transcript_id, :space_id, :room_id])
      |> maybe_add(meta, "transcript_id", :transcript_id)
      |> maybe_add(meta, "space_id", :space_id)
      |> maybe_add(meta, "room_id", :room_id)

    if payload == %{} do
      meta
    else
      Map.put(meta, :payload, payload)
    end
  end

  defp normalize_meta(meta), do: meta

  defp maybe_add(payload, meta, string_key, atom_key) do
    case Map.get(meta, string_key) do
      nil -> payload
      value -> Map.put_new(payload, atom_key, value)
    end
  end
end
