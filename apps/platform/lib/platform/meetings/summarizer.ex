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

  @doc """
  Spawns an async task to summarize the given transcript.

  The transcript must have status "processing" and a non-empty segments list.
  Returns `{:ok, pid}` on successful spawn, or `{:error, reason}` if the
  transcript is not ready for summarization.
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
        {:ok, :empty}

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

        case Meetings.complete_transcript(id, summary_text) do
          {:ok, _transcript} ->
            if is_binary(space_id) do
              Meetings.post_summary_to_space(space_id, id, summary_text)
            else
              Logger.info("[Summarizer] No space_id for transcript #{id}, skipping summary post")
            end

            :ok

          {:error, reason} ->
            Logger.error("[Summarizer] Failed to complete transcript #{id}: #{inspect(reason)}")
            safe_fail_transcript(id)
            {:error, {:complete_failed, reason}}
        end

      {:error, reason} ->
        Logger.error("[Summarizer] LLM call failed for transcript #{id}: #{inspect(reason)}")
        safe_fail_transcript(id)
        {:error, {:llm_failed, reason}}
    end
  rescue
    e ->
      Logger.error("[Summarizer] Unexpected error for transcript #{id}: #{Exception.message(e)}")
      safe_fail_transcript(id)
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
  defp safe_fail_transcript(id) do
    Meetings.fail_transcript(id)
  rescue
    DBConnection.OwnershipError ->
      case try_borrow_sandbox() do
        :ok ->
          Meetings.fail_transcript(id)

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

  defp handle_empty_transcript(%{id: id}) do
    summary = "This meeting had no transcribed content."

    case Meetings.complete_transcript(id, summary) do
      {:ok, _} ->
        Logger.info("[Summarizer] Empty transcript #{id} marked complete (no summary posted)")
        :ok

      {:error, reason} ->
        Logger.error("[Summarizer] Failed to complete empty transcript #{id}: #{inspect(reason)}")
        Meetings.fail_transcript(id)
        {:error, reason}
    end
  end

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

      {:ok, %{"content" => [%{"text" => text} | _]}} ->
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
