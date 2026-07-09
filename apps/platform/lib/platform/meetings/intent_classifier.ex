defmodule Platform.Meetings.IntentClassifier do
  @moduledoc """
  GenServer subscriber that reacts to appended transcript segments
  (task 019f2452 stages 3–4 — Meeting Producer runtime).

  Subscribes ONCE to the canonical
  `Platform.Meetings.PubSub.subscribe_transcript_chunk/0` topic —
  Phoenix.PubSub has no wildcard match and the classifier is a single
  process per node fielding every room's traffic, mirroring the design
  the M6 responsibility router uses for `meeting:finished`.

  ## Guard chain

  `handle_info({:transcript_chunk, payload}, state)` walks two
  guards in order:

    1. **No assignee** — `Platform.Roles.assignee_for("meetings.intent_classify")`
       returns `nil`. Log at `:info` the FIRST time we see a room
       without an assignee (subsequent chunks for that room stay
       silent — the `state.seen_rooms` MapSet is the spam-suppressor).
       Emit telemetry with `%{reason: :no_assignee}`. Assignment IS
       the enable signal — no env-var double-gate.
    2. **Assignee found** — hand off to `classify_and_enqueue/3`.

  ## Stage 4 pipeline (`classify_and_enqueue/3`)

  Runs the real classifier once the guard chain passes:

    1. Render the `"meetings.intent_classify.v1"` prompt template via
       `Platform.Orchestration.PromptTemplates.render_template/2`.
       If the template row is missing (upstream task
       `019f2451-b627-…` has not shipped), fall through to the
       module-attribute `@fallback_intent_prompt` — logged at
       `:warning` on the FIRST fallback per boot only and emitted as
       telemetry `[:platform, :meetings, :intent_classifier, :template_fallback]`.
    2. Call the LLM via the injected `state.provider_module` (default
       `Platform.Agents.Providers.Ollama`). Errors — HTTP 500s,
       timeouts, connection refused — log at `:warning`, emit
       `[:platform, :meetings, :intent_classifier, :model_error]`,
       and return `:ok`. No crash, no queue write, no restart loop.
    3. `Jason.decode/1` the response content. Bad JSON or missing
       required keys emit
       `[:platform, :meetings, :intent_classifier, :parse_error]`
       and drop the chunk.
    4. Compute a `sha256(intent <> target_role <> chunk_text)`
       dedupe key. That IS the idempotence semantic: two classifier
       passes over the same chunk collapse via `:ets.insert_new/2`
       returning `false` inside `IntentQueue.enqueue/3`.
    5. Enqueue via `Platform.Meetings.IntentQueue.enqueue/3` and emit
       the terminal
       `[:platform, :meetings, :intent_classified]` telemetry event
       with `:inserted | :duplicate` derived from the enqueue return.

  Design choices baked in:

    * Classifier does NOT track dispatched state — the dispatcher
      (out of scope for this task) pops-and-forgets from ETS.
    * Confidence threshold is NOT enforced here — the dispatcher
      filters. Everything the model emits lands in the queue so
      downstream analytics can compare accepted-vs-dropped rates.
    * `Req` default receive timeout (~15s) is fine; a dropped chunk
      is fine, another arrives seconds later.

  Supervisor-level toggle:

    * `:start_meeting_intent_classifier` — supervisor gate. When
      `false` (default in `config/test.exs`) the classifier isn't
      booted at all. Tests start their own instance per-case for
      DataCase sandbox ownership.
  """

  use GenServer

  require Logger

  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Roles

  @responsibility_key "meetings.intent_classify"
  @prompt_slug "meetings.intent_classify.v1"
  @default_context_window_size 3

  # Fallback prompt used when the DB row for @prompt_slug hasn't been
  # seeded yet (upstream task 019f2451-b627 owns seeding). Keeps the
  # runtime unblocked during the rollout gap. Uses the same
  # `{{variable_name}}` mustache markers the DB templates use so the
  # rendering shape is identical.
  #
  # Stage 2 (task 019f474d) adds the `{{context_lines}}` block above the
  # current utterance so the classifier resolves pronouns/subjects
  # against the immediately-preceding chunks. Both `transcript_chunk`
  # (legacy) and `meeting_transcript_chunk` (DB template variable) are
  # rendered from the same value so the fallback matches the DB shape.
  @fallback_intent_prompt """
  You are a meeting intent classifier. Given a transcript chunk, classify the intent and identify the target role.
  Respond ONLY with a JSON object matching this schema:
  {"intent": "<string>", "target_role": "<string>", "confidence": <float 0-1>}

  Room: {{room_id}}

  Prior conversation context — DO NOT classify these lines; use only to resolve pronouns, subjects, and topical intent for the CURRENT utterance.

  {{context_lines}}

  Speaker: {{speaker}}
  Transcript chunk: {{transcript_chunk}}
  """

  # ── Public API ────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    :ok = MeetingsPubSub.subscribe_transcript_chunk()
    :ok = MeetingsPubSub.subscribe_meeting_finished()

    Logger.info(
      "[IntentClassifier] started — subscribed to meeting:transcript_chunk + meeting:finished"
    )

    provider_module =
      Keyword.get(opts, :provider_module, Platform.Agents.Providers.Ollama)

    context_window_size =
      Keyword.get(
        opts,
        :context_window_size,
        Application.get_env(
          :platform,
          :intent_classifier_context_window_size,
          @default_context_window_size
        )
      )

    {:ok,
     %{
       seen_rooms: MapSet.new(),
       provider_module: provider_module,
       recent_chunks: %{},
       context_window_size: context_window_size
     }}
  end

  @impl GenServer
  def handle_info({:transcript_chunk, payload}, state) when is_map(payload) do
    room_id = Map.get(payload, :room_id)

    # Push into the per-room context buffer BEFORE the guard chain so the
    # window stays warm even when no assignee is set — the moment a role
    # lands, subsequent chunks classify against real prior context.
    state = push_chunk_into_buffer(state, room_id, payload)

    case Roles.assignee_for(@responsibility_key) do
      nil ->
        handle_no_assignee(room_id, state)

      agent ->
        # `state.recent_chunks[room_id]` is stored newest-first with the
        # current chunk at the head; drop 1 removes the current, take N
        # bounds the window at exactly `context_window_size`.
        prior_chunks =
          state.recent_chunks
          |> Map.get(room_id, [])
          |> Enum.drop(1)
          |> Enum.take(state.context_window_size)

        handle_chunk(payload, agent, prior_chunks, state)
    end
  end

  # Cleanup: when a meeting finishes, drop the per-room buffer entry so
  # long-running nodes don't accumulate transcript windows for rooms
  # that have shut down. Scoped to the room_id in the payload — other
  # active rooms' buffers are untouched.
  def handle_info({:meeting_finished, %{room_id: room_id}}, state)
      when is_binary(room_id) do
    {:noreply, %{state | recent_chunks: Map.delete(state.recent_chunks, room_id)}}
  end

  # Test-only seam: plants a stub fun in the classifier's own process
  # dictionary so the injected `provider_module` (also test-only) can
  # read it. Guarded by a `Mix.env() == :test` check so production
  # builds ignore stray messages of this shape.
  if Mix.env() == :test do
    def handle_info({:__test_plant_stub, from, ref, fun}, state) do
      Process.put(:intent_classifier_stub_fun, fun)
      send(from, {ref, :ok})
      {:noreply, state}
    end
  end

  # Tolerate mis-shaped events without crashing — the transcript-chunk
  # topic is shared with per-room subscribers and future producers may
  # broadcast slightly different payloads.
  def handle_info(_other, state), do: {:noreply, state}

  # ── Chunk buffer ──────────────────────────────────────────────────────────

  # Prepend the current chunk into `state.recent_chunks[room_id]` and
  # trim to `state.context_window_size + 1`. The +1 is deliberate: the
  # window head is the CURRENT chunk; stage 2 reads the prior context
  # as `Enum.drop(window, 1)`. Storing size+1 keeps a full N-chunk
  # window PLUS the current utterance available in one lookup.
  #
  # Silently no-ops when `room_id` is nil — cross-org broadcasts on the
  # canonical topic occasionally carry sparse payloads; we don't want
  # to grow a `nil` key.
  defp push_chunk_into_buffer(state, nil, _payload), do: state

  defp push_chunk_into_buffer(state, room_id, payload) when is_binary(room_id) do
    segment = Map.get(payload, :segment) || %{}

    entry = %{
      text: segment_text(segment),
      speaker: segment_speaker(segment, payload),
      timestamp_ms:
        Map.get(segment, :timestamp_ms) ||
          Map.get(segment, "timestamp_ms") ||
          Map.get(payload, :timestamp_ms) ||
          Map.get(payload, "timestamp_ms")
    }

    keep = state.context_window_size + 1

    window =
      [entry | Map.get(state.recent_chunks, room_id, [])]
      |> Enum.take(keep)

    %{state | recent_chunks: Map.put(state.recent_chunks, room_id, window)}
  end

  # ── Guard branches ────────────────────────────────────────────────────────

  defp handle_no_assignee(room_id, state) do
    {log?, updated_state} =
      if is_binary(room_id) and not MapSet.member?(state.seen_rooms, room_id) do
        {true, %{state | seen_rooms: MapSet.put(state.seen_rooms, room_id)}}
      else
        {false, state}
      end

    if log? do
      Logger.info("[IntentClassifier] no assignee for meetings.intent_classify — room=#{room_id}")
    end

    :telemetry.execute(
      [:platform, :meetings, :intent_classifier, :skipped],
      %{count: 1},
      %{reason: :no_assignee, room_id: room_id}
    )

    {:noreply, updated_state}
  end

  defp handle_chunk(payload, agent, prior_chunks, state) do
    classify_and_enqueue(payload, agent, prior_chunks, state)
    {:noreply, state}
  end

  # ── Stage-4 pipeline ──────────────────────────────────────────────────────

  # 3-arity wrapper — retained so pre-stage-2 callers/tests that don't
  # thread prior context still compile. Delegates to /4 with an empty
  # prior-chunks list, producing the same rendered prompt shape as
  # before stage 2 (with `(no prior context)` substituted for the new
  # `{{context_lines}}` marker).
  @doc false
  @spec classify_and_enqueue(map(), map(), map()) :: :ok
  def classify_and_enqueue(payload, agent, state) do
    classify_and_enqueue(payload, agent, [], state)
  end

  # Public for testability — walks the whole prompt → LLM → parse →
  # enqueue path for a single chunk. Never raises; every failure path
  # logs + emits telemetry + returns `:ok`.
  #
  # `prior_chunks` is the sliding window of the previous N transcript
  # chunks for this room, newest-first, EXCLUDING the current chunk.
  # It's a prompt-render input only — it is NOT part of the dedupe key
  # (Rowan's idempotency requirement: same utterance dedupes regardless
  # of surrounding conversation).
  @doc false
  @spec classify_and_enqueue(map(), map(), [map()], map()) :: :ok
  def classify_and_enqueue(payload, agent, prior_chunks, state) do
    room_id = Map.get(payload, :room_id)
    segment = Map.get(payload, :segment) || %{}
    chunk_text = segment_text(segment)

    prompt = resolve_prompt(payload, segment, chunk_text, room_id, prior_chunks)

    case call_provider(state.provider_module, agent, prompt, chunk_text, room_id) do
      {:ok, content} ->
        case parse_content(content, room_id) do
          {:ok, %{intent: intent, target_role: target_role, confidence: confidence}} ->
            dedupe_key = build_dedupe_key(intent, target_role, chunk_text)

            {:ok, enqueue_result} =
              IntentQueue.enqueue(
                room_id,
                dedupe_key,
                %{
                  intent: intent,
                  target_role: target_role,
                  confidence: confidence,
                  chunk_id: Map.get(segment, :id) || Map.get(payload, :transcript_id),
                  meeting_id: Map.get(payload, :meeting_id),
                  inserted_at_monotonic: System.monotonic_time()
                }
              )

            :telemetry.execute(
              [:platform, :meetings, :intent_classified],
              %{count: 1},
              %{
                meeting_id: Map.get(payload, :meeting_id),
                room_id: room_id,
                intent: intent,
                target_role: target_role,
                confidence: confidence,
                dedupe_key: dedupe_key,
                dedupe_key_hit_or_new: enqueue_result
              }
            )

            :ok

          :error ->
            :ok
        end

      :error ->
        :ok
    end
  end

  # ── Prompt resolution ─────────────────────────────────────────────────────

  defp resolve_prompt(payload, segment, chunk_text, room_id, prior_chunks) do
    assigns = %{
      # Stage 2: DB template uses `{{meeting_transcript_chunk}}`; keep
      # the legacy `{{transcript_chunk}}` marker rendering the same
      # value so the inline fallback prompt and pre-stage-2 tests still
      # interpolate correctly.
      meeting_transcript_chunk: chunk_text,
      transcript_chunk: chunk_text,
      speaker: segment_speaker(segment, payload),
      room_id: room_id,
      context_lines: format_context_lines(prior_chunks),
      context_present: prior_chunks != []
    }

    case PromptTemplates.render_template(@prompt_slug, assigns) do
      {:ok, rendered} ->
        rendered

      {:error, :not_found} ->
        log_fallback_once(room_id)

        :telemetry.execute(
          [:platform, :meetings, :intent_classifier, :template_fallback],
          %{count: 1},
          %{room_id: room_id, slug: @prompt_slug}
        )

        substitute(@fallback_intent_prompt, assigns)
    end
  end

  defp log_fallback_once(room_id) do
    if Process.get(:intent_classify_fallback_logged) do
      :ok
    else
      Process.put(:intent_classify_fallback_logged, true)

      Logger.warning(
        "[IntentClassifier] prompt template #{@prompt_slug} missing — using inline fallback (room=#{room_id})"
      )
    end
  end

  # Render the prior-N context window as chronological (oldest first)
  # `- [MM:SS] speaker: text` lines. Empty list → the sentinel
  # `(no prior context)` string so the rendered prompt is stable in
  # shape regardless of whether the buffer is warm.
  #
  # Buffer entries arrive newest-first (push_chunk_into_buffer/3
  # prepends); reverse before formatting so the LLM sees the
  # conversation in the direction it happened.
  defp format_context_lines([]), do: "(no prior context)"

  defp format_context_lines(prior_chunks) when is_list(prior_chunks) do
    prior_chunks
    |> Enum.reverse()
    |> Enum.map_join("\n", fn entry ->
      speaker = to_string(Map.get(entry, :speaker) || "")
      text = to_string(Map.get(entry, :text) || "")
      "- [#{format_timestamp(Map.get(entry, :timestamp_ms))}] #{speaker}: #{text}"
    end)
  end

  defp format_timestamp(ms) when is_integer(ms) and ms >= 0 do
    total_seconds = div(ms, 1000)
    minutes = div(total_seconds, 60)
    seconds = rem(total_seconds, 60)

    [minutes, seconds]
    |> Enum.map_join(":", &String.pad_leading(Integer.to_string(&1), 2, "0"))
  end

  defp format_timestamp(_), do: "??:??"

  # Minimal {{key}} substitution used only for the inline fallback
  # prompt. Same shape as `PromptTemplates.render_template/2` so
  # switching between DB and fallback is transparent to the LLM.
  defp substitute(template, assigns) do
    Regex.replace(~r/\{\{(\w+)\}\}/, template, fn _match, key ->
      value =
        try do
          atom_key = String.to_existing_atom(key)
          Map.get(assigns, atom_key) || Map.get(assigns, key) || ""
        rescue
          ArgumentError -> Map.get(assigns, key) || ""
        end

      to_string(value)
    end)
  end

  # ── Provider call ─────────────────────────────────────────────────────────

  defp call_provider(provider_module, agent, prompt, chunk_text, room_id) do
    messages = [
      %{role: "system", content: prompt},
      %{role: "user", content: chunk_text}
    ]

    opts =
      [
        base_url: Map.get(agent, :base_url),
        model: Map.get(agent, :model),
        temperature: 0.0,
        max_tokens: 256
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    credentials = agent_credentials(agent)

    try do
      case provider_module.chat(credentials, messages, opts) do
        {:ok, %{content: content}} when is_binary(content) ->
          {:ok, content}

        {:ok, %{"content" => content}} when is_binary(content) ->
          {:ok, content}

        {:ok, other} ->
          emit_model_error(room_id, {:unexpected_shape, other})
          :error

        {:error, reason} ->
          emit_model_error(room_id, reason)
          :error
      end
    rescue
      exception ->
        emit_model_error(room_id, {:raised, Exception.message(exception)})
        :error
    catch
      kind, reason ->
        emit_model_error(room_id, {:caught, kind, reason})
        :error
    end
  end

  defp emit_model_error(room_id, reason) do
    Logger.warning(
      "[IntentClassifier] LLM call failed room=#{inspect(room_id)} reason=#{inspect(reason)}"
    )

    :telemetry.execute(
      [:platform, :meetings, :intent_classifier, :model_error],
      %{count: 1},
      %{room_id: room_id, reason: inspect(reason)}
    )
  end

  # Agents may or may not carry a bearer credential. The Ollama
  # provider only inspects `:api_key` on the credentials map, so we
  # pass an empty map when nothing is set — mirrors the "no auth by
  # default" contract in `Platform.Agents.Providers.Ollama.request_headers/1`.
  defp agent_credentials(agent) do
    case Map.get(agent, :vault_key) do
      key when is_binary(key) and key != "" -> %{api_key: key}
      _ -> %{}
    end
  end

  # ── Response parsing ──────────────────────────────────────────────────────

  defp parse_content(content, room_id) do
    case Jason.decode(content) do
      {:ok, %{"intent" => intent, "target_role" => target_role, "confidence" => confidence}}
      when is_binary(intent) and is_binary(target_role) and is_number(confidence) ->
        {:ok, %{intent: intent, target_role: target_role, confidence: confidence * 1.0}}

      {:ok, decoded} ->
        emit_parse_error(room_id, content, {:missing_or_invalid_keys, decoded})
        :error

      {:error, reason} ->
        emit_parse_error(room_id, content, reason)
        :error
    end
  end

  defp emit_parse_error(room_id, raw, reason) do
    Logger.warning(
      "[IntentClassifier] classifier response parse failed room=#{inspect(room_id)} " <>
        "reason=#{inspect(reason)} preview=#{preview(raw)}"
    )

    :telemetry.execute(
      [:platform, :meetings, :intent_classifier, :parse_error],
      %{count: 1},
      %{room_id: room_id, raw_content: preview(raw)}
    )
  end

  defp preview(binary) when is_binary(binary), do: String.slice(binary, 0, 200)
  defp preview(other), do: inspect(other)

  # ── Dedupe key ────────────────────────────────────────────────────────────

  defp build_dedupe_key(intent, target_role, chunk_text) do
    :sha256
    |> :crypto.hash([intent, target_role, chunk_text || ""])
    |> Base.encode16(case: :lower)
  end

  # ── Payload accessors ─────────────────────────────────────────────────────

  defp segment_text(segment) when is_map(segment) do
    Map.get(segment, :text) || Map.get(segment, "text") || ""
  end

  defp segment_text(_), do: ""

  defp segment_speaker(segment, payload) when is_map(segment) do
    Map.get(segment, :speaker_name) ||
      Map.get(segment, "speaker_name") ||
      Map.get(segment, :participant_identity) ||
      Map.get(segment, "participant_identity") ||
      Map.get(segment, :speaker) ||
      Map.get(segment, "speaker") ||
      Map.get(payload, :speaker) ||
      Map.get(payload, "speaker") ||
      ""
  end

  defp segment_speaker(_, _), do: ""
end
