defmodule Platform.Responsibilities.Providers.Meetings do
  @moduledoc """
  Provider shim for the `meetings` feature (ADR-0041 M8 stage 6).

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

  ## What this module owns

    * `register/0` — returns the same single-spec list the underlying
      handler does, so the boot Registry walks one canonical row even
      if a future operator drops the handler from
      `Platform.Responsibilities.BuiltIns.providers/0` but keeps this
      shim wired.
    * `gather_context/2` — normalises the trigger meta so the handler
      sees the same `:payload` shape whether the trigger came from an
      event_topic broadcast (`%{kind: :event_topic, payload: %{...}}`)
      or a direct `fire/2` call where the caller flattened
      `transcript_id` to the top level.
    * `handle_output/2` and `handle_output/3` — delegate to
      `Handlers.MeetingSummarize` so the persistence pipeline stays in
      exactly one place.

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

  alias Platform.Responsibilities.Handlers.MeetingSummarize
  alias Platform.Responsibilities.Responsibility

  @impl true
  def register, do: MeetingSummarize.register()

  @impl true
  def gather_context(%Responsibility{} = responsibility, ctx) when is_map(ctx) do
    MeetingSummarize.gather_context(responsibility, normalize_meta(ctx))
  end

  def gather_context(_responsibility, _ctx), do: {:ok, %{}}

  @impl true
  def handle_output(%Responsibility{} = responsibility, parsed) do
    MeetingSummarize.handle_output(responsibility, parsed)
  end

  @impl true
  def handle_output(%Responsibility{} = responsibility, parsed, trigger_meta)
      when is_map(trigger_meta) do
    MeetingSummarize.handle_output(responsibility, parsed, normalize_meta(trigger_meta))
  end

  # ── internals ─────────────────────────────────────────────────────────────

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
