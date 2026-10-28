defmodule Platform.Meetings.Summarizer do
  @moduledoc """
  Async meeting transcript summarization pipeline.

  When a meeting ends, `summarize_async/1` spawns a Task under
  `Platform.TaskSupervisor` that:

  1. Formats the transcript segments into speaker-attributed text
  2. Calls the Anthropic provider to generate a structured summary
  3. Stores the summary on the transcript record
  4. Posts the summary as a system message to the space

  The async pattern keeps the webhook response fast — the caller doesn't
  wait for the LLM round-trip.
  """

  require Logger

  alias Platform.Meetings
  alias Platform.Meetings.Config
  alias Platform.Meetings.SummaryPrompt
  alias Platform.Agents.Providers.Anthropic
  alias Platform.Agents.Providers.Ollama
  alias Platform.Agents.Providers.OpenAI
  alias Platform.Responsibilities.Router, as: ResponsibilityRouter

  # Canonical responsibility key for the M8 router-fired summary path.
  # Mirrors `Platform.Responsibilities.Handlers.MeetingSummarize.key/0`
  # as a literal so the legacy bridge doesn't take a compile-time
  # dependency on the handler module (the handler depends on this
  # module transitively for `complete_transcript/2`).
  @meetings_summarize_key "meetings.summarize"

  # Genuine silence. Byte-identical to the pre-change string — anything
  # reading for it must keep matching.
  @empty_transcript_summary "This meeting had no transcribed content."

  # A transcriber was present and delivered nothing. Deliberately reads
  # as a failure, not as an empty meeting.
  @undelivered_transcript_summary "Transcription did not arrive for this meeting. The meeting was recorded as having a transcriber present, but no transcript content was received."

  @doc """
  Spawns an async task to summarize the given transcript.

  The transcript must have status "processing" and a non-empty segments list.
  Returns `{:ok, pid}` on successful spawn, or `{:error, reason}` if the
  transcript is not ready for summarization.

  A zero-segment transcript returns `{:ok, :empty}` when the meeting was
  genuinely silent, and `{:ok, :failed}` when a transcriber was present
  past the presence threshold and still delivered nothing — the latter
  is a delivery failure and the row is marked `"failed"`.
  """
  def summarize_async(%{id: id, segments: segments, status: status} = transcript)
      when is_list(segments) do
    cond do
      status not in ["processing", "recording"] ->
        Logger.warning("[Summarizer] Transcript #{id} has status #{status}, skipping")
        {:error, :invalid_status}

      segments == [] ->
        Logger.info(
          "[Summarizer] Transcript #{id} has no segments, marking complete with empty summary"
        )

        handle_empty_transcript(transcript)

      true ->
        {:ok, pid} =
          Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
            run_summary(transcript)
          end)

        Logger.info("[Summarizer] Started summary task #{inspect(pid)} for transcript #{id}")
        {:ok, pid}
    end
  end

  def summarize_async(%{id: id}) do
    Logger.warning("[Summarizer] Transcript #{id} missing required fields for summarization")
    {:error, :missing_fields}
  end

  def summarize_async(_), do: {:error, :invalid_transcript}

  @doc """
  Synchronous summary generation — used by tests and when you want to
  wait for the result.

  ## M8 stage 4 dual-write bridge

  When `Platform.Responsibilities.Router.responsibility_filled?(:meetings_summarize)`
  returns `true` (i.e. an agent holds the Meeting Scribe role or an
  operator has set an explicit override), we delegate the dispatch to
  the router's `meetings.summarize` responsibility and skip the legacy
  body entirely. The router then runs the new external-dispatch +
  `Handlers.MeetingSummarize.handle_output/3` path.

  When the responsibility is **unfilled** we fall through to the
  legacy LLM path below — the webhook controller continues to call
  `summarize_async/1` (which calls into here) so this bridge is the
  ONLY seam needed for the M8 cutover. Per the M8 task description we
  keep the legacy body in place for one stable release window before
  deletion.

  ## Fire-result contract (ADR-0046 member 1)

  `Platform.Responsibilities.Router.fire/2` returns
  `{:ok, :dispatched} | {:ok, :unfilled} | {:ok, :unknown_responsibility}
  | {:error, reason}`. Only `{:ok, :dispatched}` hands the summary off;
  every other shape runs `run_summary_legacy/3`, because every other
  shape means no agent is going to produce a summary. Until that task
  landed, the Router returned a flat `:ok` for all four, so a failed
  dispatch — an assigned external agent whose endpoint is down, say —
  was indistinguishable from a successful one and the meeting summary
  was silently lost.

  ## The one error shape that must NOT fall back (019fa56b-c81f stage 2)

  `{:error, {:context_gather_refused, :already_dispatched}}` is the
  exception to the paragraph above. It means
  `Handlers.MeetingSummarize.gather_context/2` lost the atomic claim on
  `meeting_transcripts.router_dispatched_at` to the OTHER dispatch path
  for this same meeting end — the `meeting:finished` broadcast, which
  the Router has actually delivered since stage 1 repaired its
  event_topic adapter. The claim is HELD — that, and only that, is what
  this clause has observed; it reads no process and does not check that
  the holder is still alive. So it returns `:ok` and stops. Running the
  legacy body here would produce the duplicate summary and the duplicate
  `complete_transcript/2` write that the claim exists to prevent. Since
  task 01a0826f stage 1 the claim is RELEASED when the row reaches
  `failed` (`Meetings.fail_transcript/3`), so a holder that dies loudly
  frees the row rather than latching it forever.
  """
  def run_summary(%{id: id, space_id: space_id, segments: segments} = _transcript) do
    if router_meetings_summarize_filled?() do
      Logger.info(
        "[Summarizer] Delegating transcript #{id} to ResponsibilityRouter " <>
          "(meetings.summarize is filled)"
      )

      case ResponsibilityRouter.fire(:meetings_summarize, %{
             kind: :event_topic,
             topic: "meeting:finished",
             payload: %{
               transcript_id: id,
               space_id: space_id
             }
           }) do
        # ADR-0046 member 1: the Router returns
        # `{:ok, :dispatched} | {:ok, :unfilled} | {:ok, :unknown_responsibility}
        # | {:error, reason}` and this bridge branches on all four.
        #
        # `{:ok, :dispatched}` is the only shape that means the summary is
        # somebody else's job now.
        {:ok, :dispatched} ->
          ensure_router_dispatch_stamped(id)
          :ok

        # The bridge gate (`router_meetings_summarize_filled?/0`) and the
        # fire are two separate reads of role state, so an unassign — or a
        # delete of the responsibility row itself — between them lands here.
        # Both shapes mean "the router did not and will not produce a
        # summary", which is exactly the question the `else` branch below
        # answers with `run_summary_legacy/3`. Returning `:ok` here (what
        # this clause did until stage 3 of ADR-0046 member 1) silently drops
        # the meeting summary.
        #
        # `{:ok, :unknown_responsibility}` became reachable through this
        # clause in stage 2, when `Router.fire/2`'s no-row branch moved from
        # the error channel into the ok channel. It is close to unreachable
        # in practice — the gate already required the row to exist WITH an
        # assignee — but it is a real state and it gets the real answer.
        # ── Task 019fa56b-c81f stage 2 — LOST CLAIM, NOT A FAILURE ──
        #
        # `Handlers.MeetingSummarize.gather_context/2` takes an atomic
        # claim on `meeting_transcripts.router_dispatched_at` before the
        # model round-trip. This shape means the OTHER dispatch path for
        # this same meeting end — the `meeting:finished` broadcast the
        # Router has delivered since stage 1 repaired its event_topic
        # adapter — got there first and the claim is HELD.
        #
        # "Held" is the whole of what this clause knows. It reads no
        # process and no liveness; a held claim is not evidence that a
        # summary is being produced right now. Task 01a0826f stage 1
        # made `Meetings.fail_transcript/3` clear `router_dispatched_at`,
        # so a holder that fails loudly releases the row; a holder that
        # dies silently leaves the claim standing until the sweeper
        # notices. The log below therefore states the row's observed
        # status and claim timestamp and nothing else.
        #
        # THIS IS THE OPPOSITE OF THE TWO CLAUSES BELOW. `{:ok, :unfilled}`
        # and `{:ok, :unknown_responsibility}` mean *nobody* holds the
        # work, so the legacy body is the only thing standing between us
        # and a silently lost meeting summary (ADR-0046 member 1). A lost
        # claim means somebody else already holds it, so running the
        # legacy body here would produce the second summary and the
        # second `complete_transcript/2` write that the claim exists to
        # prevent. Return `:ok`; do not fall through.
        {:error, {:context_gather_refused, :already_dispatched}} ->
          # `get_transcript/1` UUID-guards and returns nil rather than
          # raising (meetings.ex:3922) — same discipline as
          # `claim_router_dispatch/1` (meetings.ex:4318): this sits on a
          # dispatch path that must never raise, so a vanished row is
          # reported as `status=missing`, not thrown.
          {claim_status, claimed_at} =
            case Meetings.get_transcript(id) do
              nil -> {"missing", "unknown"}
              row -> {row.status, inspect(row.router_dispatched_at)}
            end

          Logger.info(
            "[Summarizer] transcript #{id} already holds a router dispatch claim " <>
              "(status=#{claim_status} claimed_at=#{claimed_at}) — skipping this " <>
              "duplicate dispatch and NOT running the legacy body. Liveness of the " <>
              "claim holder is not checked here; a claim is released when the row " <>
              "reaches failed (Meetings.fail_transcript/3)."
          )

          :ok

        {:ok, gate_race} when gate_race in [:unfilled, :unknown_responsibility] ->
          Logger.info(
            "[Summarizer] Router reported #{gate_race} for transcript #{id} after the " <>
              "bridge gate said filled — role state raced, falling back to legacy body"
          )

          run_summary_legacy(id, space_id, segments)

        {:error, reason} ->
          Logger.warning(
            "[Summarizer] Router fire failed for transcript #{id} reason=#{inspect(reason)} " <>
              "— falling back to legacy body"
          )

          run_summary_legacy(id, space_id, segments)
      end
    else
      run_summary_legacy(id, space_id, segments)
    end
  end

  # Arm `SummarizerSweeper` for a dispatch that was handed off and may
  # never come back. Task 019ff6f3 stage 3.
  #
  # `Meetings.list_stalled_router_dispatches/1` requires
  # `router_dispatched_at IS NOT NULL`, so a dispatch whose agent never
  # picks the job up is invisible to the sweeper unless SOMETHING stamps
  # the column at hand-off. `Handlers.MeetingSummarize.gather_context/2`
  # stamps it via `claim_router_dispatch/1`, but only on the paths where
  # that handler actually runs — the stall this exists to catch is
  # precisely a dispatch that stalls elsewhere, leaving the column NULL.
  #
  # DEVIATION, deliberate: the stage spec said to stamp BEFORE the fire
  # with `stamp_router_dispatched/1`. That would break every router-path
  # summary. `gather_context/2` runs INSIDE `Router.fire/2` and takes its
  # dedupe claim with `UPDATE ... WHERE router_dispatched_at IS NULL`; an
  # unconditional pre-stamp makes that claim lose, the handler refuses
  # with `{:context_gather_refused, :already_dispatched}`, and the clause
  # below treats a refusal as "somebody else is handling it" — so nobody
  # would be. Stamping AFTER a successful dispatch, conditionally, gets
  # the sweeper coverage the spec wanted without racing the claim: when
  # the handler already claimed, this is a no-op; when nothing claimed,
  # this arms the sweeper.
  defp ensure_router_dispatch_stamped(id) do
    case Meetings.claim_router_dispatch(id) do
      {:ok, :claimed} ->
        :ok

      # The handler's own claim got there first. The column is already
      # stamped, which is all the sweeper needs.
      {:error, :already_dispatched} ->
        :ok

      {:error, :no_such_transcript} ->
        Logger.warning(
          "[Summarizer] cannot stamp router dispatch for transcript #{id} — no such row; " <>
            "a stall on this dispatch will be invisible to SummarizerSweeper"
        )

        :ok
    end
  end

  # Guarded router lookup so a stripped build (no Responsibilities
  # context loaded) or a tests/env that hasn't wired the router still
  # exercises the legacy path. The router itself returns `false` for
  # unknown keys; this guard short-circuits if the module isn't loaded
  # at all.
  defp router_meetings_summarize_filled? do
    if Code.ensure_loaded?(ResponsibilityRouter) and
         function_exported?(ResponsibilityRouter, :responsibility_filled?, 1) do
      ResponsibilityRouter.responsibility_filled?(@meetings_summarize_key)
    else
      false
    end
  rescue
    error ->
      Logger.warning(
        "[Summarizer] responsibility_filled? raised — falling back to legacy: " <>
          Exception.message(error)
      )

      false
  end

  @doc """
  Legacy summary body — direct LLM call + transcript completion, no
  router involvement.

  Made public in task 019f2566 stage 2 so `Platform.Meetings.SummarizerSweeper`
  can drive the fallback path directly for stalled `processing`
  transcripts (i.e. the router fired but no agent ever produced the
  summary). Intra-module callers (`run_summary/1`'s router-unfilled and
  router-fire-failed branches) call in with the same arity.

  Not part of the public API for external consumers — the sweeper and
  `run_summary/1` are the only intended call sites.
  """
  @doc since: "task 019f2566 stage 2"
  def run_summary_legacy(id, space_id, segments) do
    do_run_summary_legacy(id, space_id, segments, legacy_input_hash(id, segments))
  end

  defp legacy_input_hash(id, segments) do
    case Meetings.get_transcript(id) do
      nil -> nil
      transcript -> Platform.Meetings.Transcript.summary_fingerprint(transcript, segments)
    end
  rescue
    DBConnection.OwnershipError ->
      case try_borrow_sandbox() do
        :ok ->
          case Meetings.get_transcript(id) do
            nil -> nil
            transcript -> Platform.Meetings.Transcript.summary_fingerprint(transcript, segments)
          end

        :no_sandbox ->
          nil
      end
  end

  defp do_run_summary_legacy(id, space_id, segments, input_hash) do
    Logger.info(
      "[Summarizer] Generating summary for transcript #{id} (#{length(segments)} segments)"
    )

    formatted_text = SummaryPrompt.format_segments(segments)

    messages = [
      %{
        role: "user",
        content: "Please summarize the following meeting transcript:\n\n#{formatted_text}"
      }
    ]

    cfg = Config.summary()

    opts =
      [
        system: SummaryPrompt.system_prompt(),
        model: cfg.model,
        max_tokens: cfg.max_tokens,
        temperature: cfg.temperature
      ]
      |> maybe_put(:base_url, cfg.base_url)

    case call_llm(cfg, messages, opts) do
      {:ok, summary_text} ->
        Logger.info(
          "[Summarizer] Summary generated for transcript #{id} (#{String.length(summary_text)} chars)"
        )

        case Meetings.complete_transcript(id, summary_text, input_hash) do
          {:ok, _transcript} ->
            if is_binary(space_id) do
              Meetings.post_summary_to_space(space_id, id, summary_text)
            else
              Logger.info("[Summarizer] No space_id for transcript #{id}, skipping summary post")
            end

            :ok

          {:error, reason} ->
            Logger.error("[Summarizer] Failed to complete transcript #{id}: #{inspect(reason)}")
            safe_fail_transcript(id, {:complete_failed, reason}, input_hash)
            {:error, {:complete_failed, reason}}
        end

      {:error, reason} ->
        Logger.error("[Summarizer] LLM call failed for transcript #{id}: #{inspect(reason)}")
        safe_fail_transcript(id, {:llm_failed, reason}, input_hash)
        {:error, {:llm_failed, reason}}
    end
  rescue
    e ->
      Logger.error("[Summarizer] Unexpected error for transcript #{id}: #{Exception.message(e)}")
      safe_fail_transcript(id, {:unexpected, Exception.message(e)}, input_hash)
      {:error, {:unexpected, e}}
  end

  # Wraps `Meetings.fail_transcript/1` so a sandbox-unowned Repo raise
  # (Task.Supervised child with an empty $callers chain) doesn't escape
  # the summarizer's outer rescue. Without this, the LLM-error branch
  # at line ~210 raises → the outer rescue catches → the rescue body's
  # own `fail_transcript` call raises AGAIN and ESCAPES (a rescue block
  # does not wrap itself). See
  # `test/platform/regression/task_supervisor_ownership_leak_test.exs`
  # for the deterministic repro.
  #
  # On OwnershipError we attempt a one-shot recovery: if `Platform.Repo`
  # is running in Sandbox pool mode (test env only) and any of our
  # DataCase-allowed singletons is registered, we grant `self()` access
  # to the sandbox connection through that allowed process and retry
  # once. This lets the retry write land so the transcript reaches a
  # terminal status even in the escape-path unit test. In production
  # (pool != Sandbox) the OwnershipError branch is unreachable — the
  # normal `Repo.update` path succeeds directly.
  #
  # Task 019ff6f3 stage 3: `reason` is threaded through to
  # `Meetings.fail_transcript/3` so the row itself records WHY. Without
  # it a populated transcript ends at `failed` with a NULL summary and
  # the reason exists only in a log line nobody greps.
  defp safe_fail_transcript(id, reason, input_hash) do
    Meetings.fail_summary_input(id, input_hash, reason)
  rescue
    DBConnection.OwnershipError ->
      case try_borrow_sandbox() do
        :ok ->
          Meetings.fail_summary_input(id, input_hash, reason)

        :no_sandbox ->
          Logger.debug(
            "[Summarizer] fail_transcript raised OwnershipError for #{id} — sandbox-unowned Task.Supervised child, treating as no-op"
          )

          {:error, :sandbox_unowned}
      end
  end

  # Attempt to borrow the DataCase sandbox connection via a singleton
  # that the DataCase setup has already allowed. Returns `:ok` if we
  # successfully joined the sandbox owner chain, `:no_sandbox` otherwise.
  # This is a test-only escape hatch — in production the pool is not
  # `Ecto.Adapters.SQL.Sandbox` so we short-circuit before touching any
  # test-only module.
  defp try_borrow_sandbox do
    if Code.ensure_loaded?(Ecto.Adapters.SQL.Sandbox) and sandbox_pool?() do
      singletons = [
        Platform.Responsibilities.Router,
        Platform.Orchestration.TaskRouterWatcher,
        Platform.Chat.AttentionRouter,
        Platform.Agents.ContextBroker,
        Platform.Chat.ContextPlane
      ]

      Enum.find_value(singletons, :no_sandbox, fn name ->
        with pid when is_pid(pid) <- Process.whereis(name),
             :ok <- try_allow(pid, self()) do
          :ok
        else
          _ -> nil
        end
      end)
    else
      :no_sandbox
    end
  end

  defp try_allow(owner_or_allowed, target) do
    case Ecto.Adapters.SQL.Sandbox.allow(Platform.Repo, owner_or_allowed, target) do
      :ok -> :ok
      {:already, _} -> :ok
      _other -> :error
    end
  rescue
    _ -> :error
  end

  defp sandbox_pool? do
    case Platform.Repo.config()[:pool] do
      Ecto.Adapters.SQL.Sandbox -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  # -- Private ---------------------------------------------------------------

  # A zero-segment transcript has two very different causes. If no
  # transcriber was ever present for a meaningful window, nobody spoke
  # and the meeting is genuinely silent — unchanged behaviour, down to
  # the summary string. If a transcriber WAS present past the threshold
  # and still delivered nothing, that is a delivery failure, and
  # reporting it as a cheerful "complete" is how a multi-day outage
  # hides behind a success status on every surface.
  defp handle_empty_transcript(%{} = transcript) do
    if Meetings.transcriber_present_for_threshold?(transcript) do
      handle_undelivered_transcript(transcript)
    else
      complete_silent_transcript(transcript)
    end
  end

  # ── The whole-room guard (task 019ff6f3 stage 3) ──────────────────────
  #
  # A negative claim about a room is only true if it holds for EVERY row
  # in that room. "This meeting had no transcribed content" is exactly
  # such a claim, and it was being written off a single row's emptiness.
  # When a room holds two transcript rows — one populated, one empty —
  # summarising the empty one publishes a flat denial that the meeting
  # happened, while the row that holds the actual conversation sits
  # unsummarised beside it. That is the defect this whole task exists to
  # fix, and it is the general principle: per-row evidence cannot settle
  # a room-scoped question.
  #
  # So: refuse. Do not complete, do not fail, do not invent prose. Leave
  # the empty row where it is and let the populated sibling be
  # summarised by the path that selects it
  # (`Meetings.get_summarizable_transcript_for_room/1`, stage 1).
  defp complete_silent_transcript(%{id: id, room_id: room_id} = transcript)
       when is_binary(room_id) do
    if Meetings.room_has_segments?(room_id) do
      refuse_empty_summary(id, room_id)
    else
      do_complete_silent_transcript(transcript)
    end
  end

  defp complete_silent_transcript(%{} = transcript), do: do_complete_silent_transcript(transcript)

  defp refuse_empty_summary(id, room_id) do
    populated_ids =
      room_id
      |> Meetings.list_transcripts_for_room()
      |> Enum.reject(&(&1.id == id or &1.segments == []))
      |> Enum.map(& &1.id)

    Logger.warning(
      "[Summarizer] REFUSING to summarise empty transcript #{id} as silent: room " <>
        "#{room_id} holds transcribed content on #{inspect(populated_ids)}. A negative " <>
        "claim about a room is only true if it holds for every row in that room."
    )

    {:error, :room_has_populated_transcript}
  end

  defp do_complete_silent_transcript(%{id: id} = transcript) do
    case Meetings.complete_transcript(
           id,
           @empty_transcript_summary,
           Platform.Meetings.Transcript.summary_fingerprint(transcript)
         ) do
      {:ok, _} ->
        Logger.info("[Summarizer] Empty transcript #{id} marked complete (no summary posted)")
        {:ok, :empty}

      {:error, reason} ->
        Logger.error("[Summarizer] Failed to complete empty transcript #{id}: #{inspect(reason)}")
        Meetings.fail_transcript(id, nil, {:complete_empty_failed, reason})
        {:error, reason}
    end
  end

  defp handle_undelivered_transcript(%{id: id} = transcript) do
    case Meetings.fail_transcript(
           id,
           @undelivered_transcript_summary,
           :transcription_not_delivered
         ) do
      {:ok, _} ->
        Logger.error(
          "[Summarizer] Transcript #{id} has no segments despite transcriber presence — " <>
            "marked failed"
        )

        notify_space_of_failure(transcript)
        {:ok, :failed}

      {:error, reason} ->
        Logger.error("[Summarizer] Failed to mark transcript #{id} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Best-effort, exactly like `maybe_dispatch_scribe_attention/1`: the row
  # is already terminal, and a chat post that fails must not flip it back
  # or raise. Swallow and log.
  defp notify_space_of_failure(%{id: id, space_id: space_id}) when is_binary(space_id) do
    case Meetings.post_transcription_failure_to_space(space_id, id) do
      :ok ->
        :ok

      other ->
        Logger.warning(
          "[Summarizer] Could not post transcription-failure notice for #{id}: #{inspect(other)}"
        )

        :ok
    end
  rescue
    error ->
      Logger.warning(
        "[Summarizer] Transcription-failure notice raised for #{id}: #{inspect(error)}"
      )

      :ok
  end

  defp notify_space_of_failure(_transcript), do: :ok

  defp call_llm(%{provider: :none}, _messages, _opts) do
    {:error, :no_summary_provider_configured}
  end

  defp call_llm(%{provider: provider} = cfg, messages, opts) do
    credentials = llm_credentials(cfg)
    adapter = provider_adapter(provider)

    case adapter.chat(credentials, messages, opts) do
      {:ok, %{content: content}} when is_binary(content) ->
        {:ok, content}

      {:ok, %{content: [%{"text" => text} | _]}} ->
        {:ok, text}

      {:ok, other} ->
        Logger.warning("[Summarizer] Unexpected LLM response shape: #{inspect(other)}")
        extract_text_from_response(other)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp provider_adapter(:anthropic), do: Anthropic
  defp provider_adapter(:openai), do: OpenAI
  defp provider_adapter(:ollama), do: Ollama

  defp provider_adapter(other),
    do: raise(ArgumentError, "Unknown summary provider: #{inspect(other)}")

  defp extract_text_from_response(%{content: content}) when is_list(content) do
    text =
      content
      |> Enum.filter(&is_map/1)
      |> Enum.map(&(Map.get(&1, "text") || Map.get(&1, :text, "")))
      |> Enum.join("\n")

    if text == "", do: {:error, :empty_response}, else: {:ok, text}
  end

  defp extract_text_from_response(_), do: {:error, :unrecognized_response}

  defp llm_credentials(%{provider: :anthropic, api_key_env: env}) do
    case api_key_from_env(env) do
      nil -> %{credential_slug: "anthropic"}
      key -> %{api_key: key}
    end
  end

  defp llm_credentials(%{provider: :openai, api_key_env: env}) do
    case api_key_from_env(env) do
      nil -> %{credential_slug: "openai"}
      key -> %{api_key: key}
    end
  end

  defp llm_credentials(%{provider: :ollama, api_key_env: env}) do
    case api_key_from_env(env) do
      nil -> %{}
      key -> %{api_key: key}
    end
  end

  defp llm_credentials(_), do: %{}

  defp api_key_from_env(nil), do: nil
  defp api_key_from_env(name) when is_binary(name), do: System.get_env(name)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
