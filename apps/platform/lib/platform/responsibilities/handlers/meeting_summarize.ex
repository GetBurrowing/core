defmodule Platform.Responsibilities.Handlers.MeetingSummarize do
  @moduledoc """
  `meetings.summarize` responsibility provider (ADR-0041 M8 stages 3–4).

  Implements the M1 `Platform.Responsibilities.Provider` behaviour for
  the per-meeting summary write triggered by the canonical
  `meeting:finished` event the `PlatformWeb.LivekitWebhookController`
  emits via `Platform.Meetings.PubSub.broadcast_meeting_finished/2`.

  ## Spec

    * `key` — `"meetings.summarize"`
    * `feature` — `"meetings"`
    * `trigger_kind` — `event_topic` with `topic: "meeting:finished"`
    * `scope` — `per_meeting`
    * `context_provided` — `["org_identity", "recent_journal", "meeting_transcript"]`
    * `fallback` (metadata) — `{:legacy, {Platform.Meetings.Summarizer, :run_summary, 1}}`
      so M6's router knows what to do when no agent holds the Meeting
      Scribe role.

  ## Stage 4 status

  Stage 3 shipped the registration stub. Stage 4 ports the
  LLM-orchestration body that used to live inline in
  `Platform.Meetings.Summarizer.run_summary/1` (`summarizer.ex:70-127`)
  into `handle_output/3`. The handler:

    * extracts `transcript_id` + `space_id` from the trigger payload
      (`{:meeting_finished, %{transcript_id:, space_id:, room_id:}}`)
    * accepts a bare summary string OR `%{"summary" => text}` /
      `%{summary: text}` as the dispatch's parsed result
    * persists via `Platform.Meetings.complete_transcript/2` and posts
      the summary to the meeting's chat space via
      `Platform.Meetings.post_summary_to_space/3`
    * on failure (rejected payload, complete-write error, or an
      explicit `{:error, _}` from the dispatcher) marks the transcript
      `failed` via `Platform.Meetings.fail_transcript/1` so the UI
      stops spinning

  ## Grounding payoff (M8 stage 4 highlight)

  `build_messages/1` materialises the LLM message list with **verbatim
  ORG_IDENTITY text and the last 7 days of org-journal entries**
  appended as a `## Grounding context` block after the existing summary
  system prompt. This is the M8 deliverable Hal owes the rest of the
  feature: every meeting summary now grounds in named-entity context
  the org actually controls.

  The external-dispatch path doesn't use this directly today — the
  dispatcher renders `default_prompt_template` against the context map
  the router gathered — but the helper is exposed so the legacy
  fallback inside `Platform.Meetings.Summarizer.run_summary/1` can
  reuse the same prompt shape, AND so tests can assert the grounding
  text actually lands in the prompt.

  ## Wildcard-topic note

  Phoenix.PubSub has no wildcard subscribe. The plan called for
  `topic_pattern: "meeting:finished:*"` so per-room broadcasts could
  fan in to a single subscriber. We satisfy that intent by having
  `PubSub.broadcast_meeting_finished/2` mirror every per-room
  broadcast to the canonical `"meeting:finished"` topic — the router
  subscribes there. The original `topic_pattern` lives in `metadata`
  for documentation; the M1 schema only stores the canonical `topic`.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Meetings
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Meetings.SummaryPrompt
  alias Platform.Responsibilities.ContextProviders
  alias Platform.Responsibilities.Responsibility

  @key "meetings.summarize"
  @feature "meetings"

  @doc "Canonical key for this responsibility — exposed for dual-write callers."
  @spec key() :: String.t()
  def key, do: @key

  @doc "Canonical event-topic-trigger topic this provider subscribes to."
  @spec topic() :: String.t()
  def topic, do: MeetingsPubSub.meeting_finished_topic()

  # ── Provider callbacks ─────────────────────────────────────────────────────

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: @feature,
        trigger_kind: "event_topic",
        trigger_config: %{
          # Canonical topic the M6 router subscribes to. Mirrors
          # `PubSub.meeting_finished_topic/0`; kept as a literal here
          # because module-function calls aren't allowed at compile
          # time for compile-config providers.
          "topic" => "meeting:finished",
          # Wildcard hint preserved per the M8 stage 3 plan even
          # though Phoenix.PubSub doesn't honour it — the broadcast
          # helper fans out per-room AND canonical so subscribers
          # only have to hold one subscription.
          "topic_pattern" => "meeting:finished:*",
          # The event tuple shape every subscriber receives. Stored
          # as a string so the schema's map-of-string-values
          # invariant holds at upsert time.
          "event_match" => "meeting_finished"
        },
        scope: "per_meeting",
        context_provided: ["org_identity", "recent_journal", "meeting_transcript"],
        output_contract: %{
          "summary" => "string",
          "action_items" => "list[string]?"
        },
        default_prompt_template: "meetings.summarize.v1",
        cost_profile: "low_freq_capable",
        metadata: %{
          "owner" => "platform.meetings",
          # Encoded as a 3-tuple string so M6's router can resolve a
          # MFA pair at fire time without trusting unsafe deserialisation.
          # Shape: `"<Module>:<function>:<arity>"`.
          "fallback" => "Elixir.Platform.Meetings.Summarizer:run_summary:1",
          "fallback_kind" => "legacy",
          # Task 019f2570 bug 2 fix — override the dispatcher's default
          # (2500) with an explicit ceiling for meeting summaries. The
          # OpenAI-compat concierge at test-host:8084 defaults to ~800 tokens
          # when the field is absent, which truncates summaries mid-
          # sentence. `Dispatcher.request_body/3` reads this hint and
          # forwards it as top-level `max_tokens`. Refreshed on next boot
          # via `Responsibilities.@upsert_replace_fields` (metadata is
          # in the replace set — no migration required).
          "max_tokens" => 2500
        }
      }
    ]
  end

  @doc """
  Gather the summary context — and, first, **claim the dispatch**
  (task 019fa56b-c81f stage 2).

  ## Why the claim lives here

  A meeting end produces two independent decisions to dispatch
  `meetings.summarize` for the same transcript: `Summarizer.run_summary/1`
  fires the responsibility directly (summarizer.ex:101), and the
  `meeting:finished` broadcast fires it through the Router's event_topic
  fan-out (live since stage 1 repaired the adapter). The two run in
  different processes.

  Those two paths diverge above `Router.fire_trigger/3` — `fire/2` for
  the bridge, `fire_matches/3` for the broadcast — and reconverge in
  `dispatch_assignee/4`, whose FIRST act is
  `gather_context_via_provider/3`. This callback is therefore the only
  point both paths cross *before* the external dispatch, which makes it
  the only placement where the claim kills the duplicate LLM round-trip
  and not merely the duplicate write. The Router already treats a
  non-`{:ok, map}` return here as "do not dispatch" (see the ONE RULE
  comment on `Router.gather_context_via_provider/3`), so refusing is an
  existing, documented provider power rather than a new seam.

  Placing it in `handle_output/3` instead — after the model has already
  answered — would be strictly worse in two ways: the losing path would
  still have burned a full dispatch, and the WINNER would then lose its
  own claim at persist time and drop the summary on the floor, which is
  exactly the silent-summary-loss bug ADR-0046 member 1 fixed.

  A refusal surfaces to `Summarizer.run_summary/1` as
  `{:error, {:context_gather_refused, :already_dispatched}}`; that
  function has a dedicated clause for it precisely because it must NOT
  be treated like the other error shapes that fall back to the legacy
  body.

  A missing/absent transcript id is NOT a refusal — `nil` means the
  trigger carried no transcript at all, and `:no_such_transcript` means
  the row is gone. Neither is "somebody else is handling it", so both
  proceed and are handled downstream (`gather_transcript/1` marks the
  slot `missing?: true` and `build_prompt/1` then refuses on empty
  text), preserving the pre-stage behaviour for those cases.
  """
  @impl true
  def gather_context(%Responsibility{} = _responsibility, ctx) when is_map(ctx) do
    payload = Map.get(ctx, :payload) || %{}
    transcript_id = Map.get(payload, :transcript_id) || Map.get(payload, "transcript_id")
    workspace_id = Map.get(payload, :workspace_id) || Map.get(payload, "workspace_id")

    base_opts = if workspace_id, do: [workspace_id: workspace_id], else: []

    with :ok <- claim_dispatch(transcript_id),
         {:ok, %{org_identity: identity}} <-
           ContextProviders.gather_context(:org_identity, base_opts),
         {:ok, %{recent_journal: journal}} <-
           ContextProviders.gather_context(:recent_journal, base_opts),
         {:ok, %{meeting_transcript: transcript}} <-
           gather_transcript(transcript_id) do
      {:ok,
       %{
         org_identity: identity,
         recent_journal: journal,
         meeting_transcript: transcript,
         # Task 019f2566 stage 3 — pass through when the router-supplied
         # trigger context already carries `:agent_kind` (populated by
         # M6's dispatcher-adjacent classify). This slot is what
         # `build_messages/1` / `system_prompt_with_grounding/1` key off
         # to decide whether to prepend the "fire off to a subagent"
         # preamble for federated Claude runtimes like Dalton.
         # `nil` here is fine — the Dispatcher's belt+braces re-classify
         # from the agent it holds fills it in before render.
         agent_kind: Map.get(ctx, :agent_kind)
       }}
    end
  end

  def gather_context(_responsibility, _ctx), do: {:ok, %{}}

  # See the `gather_context/2` doc above for the argument. Only a lost
  # race stops the dispatch; "no transcript in the trigger" and "that
  # transcript row is gone" are not dedupe outcomes and must not be
  # dressed up as one.
  defp claim_dispatch(nil), do: :ok

  defp claim_dispatch(transcript_id) do
    case Meetings.claim_router_dispatch(transcript_id) do
      {:ok, :claimed} ->
        :ok

      {:error, :already_dispatched} ->
        Logger.info(
          "[meetings.summarize] dispatch for transcript #{transcript_id} was already " <>
            "claimed — refusing this duplicate before the model round-trip"
        )

        {:error, :already_dispatched}

      {:error, :no_such_transcript} ->
        Logger.warning(
          "[meetings.summarize] no transcript row for id=#{inspect(transcript_id)} — " <>
            "dispatching unclaimed"
        )

        :ok
    end
  end

  defp gather_transcript(nil) do
    {:ok, %{meeting_transcript: %{transcript_id: nil, missing?: true, formatted_text: ""}}}
  end

  defp gather_transcript(transcript_id) when is_binary(transcript_id) do
    case ContextProviders.gather_context(:meeting_transcript, transcript_id: transcript_id) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, reason} ->
        Logger.warning(
          "[meetings.summarize] transcript gather failed id=#{transcript_id} reason=#{inspect(reason)}"
        )

        {:ok,
         %{meeting_transcript: %{transcript_id: transcript_id, missing?: true, error: reason}}}
    end
  end

  @impl true
  def handle_output(%Responsibility{} = responsibility, parsed) do
    handle_output(responsibility, parsed, %{kind: :unknown})
  end

  @impl true
  def handle_output(%Responsibility{} = responsibility, parsed, trigger_meta)
      when is_map(trigger_meta) do
    transcript_id = transcript_id_from(trigger_meta)
    space_id = space_id_from(trigger_meta)

    input_hash =
      Map.get(trigger_meta, :summary_input_hash) || Map.get(trigger_meta, "summary_input_hash")

    cond do
      is_nil(transcript_id) ->
        Logger.warning(
          "[meetings.summarize] no transcript_id in trigger_meta — cannot persist " <>
            "key=#{responsibility.key} trigger=#{inspect(Map.get(trigger_meta, :kind))}"
        )

        {:error, :missing_transcript_id}

      true ->
        case extract_summary(parsed) do
          {:ok, summary_text} ->
            persist_summary(transcript_id, space_id, summary_text, input_hash)

          {:error, reason} ->
            Logger.warning(
              "[meetings.summarize] rejected dispatch payload transcript_id=#{transcript_id} " <>
                "reason=#{inspect(reason)}"
            )

            _ = safe_fail(transcript_id, input_hash, :invalid_summary_output)
            {:error, reason}
        end
    end
  end

  # ── Prompt construction ───────────────────────────────────────────────────

  @doc """
  Build the (system + user) LLM prompt from the context map
  `gather_context/2` returned (task 019f2570 bug 1 fix).

  Returns `{:ok, %{system:, user:}}` on success. The Router passes the
  result to `Platform.ExternalAgents.Dispatcher.dispatch/4` as
  `messages: [...]`, sidestepping the un-seeded
  `default_prompt_template: "meetings.summarize.v1"` render path — the
  handler owns the full prompt end-to-end.

  Returns `{:error, :no_transcript_text}` when the transcript slot is
  empty so the Router refuses to burn a token round-trip on an answer
  the model can't produce.
  """
  @impl true
  @spec build_prompt(map()) ::
          {:ok, %{system: String.t(), user: String.t()}} | {:error, term()}
  def build_prompt(context) when is_map(context) do
    transcript = Map.get(context, :meeting_transcript) || %{}
    transcript_text = Map.get(transcript, :formatted_text) || ""

    if is_binary(transcript_text) and String.trim(transcript_text) != "" do
      {:ok,
       %{
         system: system_prompt_with_grounding(context),
         user: "Please summarize the following meeting transcript:\n\n#{transcript_text}"
       }}
    else
      {:error, :no_transcript_text}
    end
  end

  def build_prompt(_), do: {:error, :no_transcript_text}

  @doc """
  Build the LLM message list for the meeting summary call.

  Accepts the same context map shape `gather_context/2` returns:

      %{
        org_identity: %{content: "...", missing?: false},
        recent_journal: %{entries_by_date: [{~D[...], [...]}], ...},
        meeting_transcript: %{formatted_text: "...", ...}
      }

  Returns a `[%{role:, content:, system:}]` list — the system message
  carries the canonical `SummaryPrompt.system_prompt/0` body PLUS a
  `## Grounding context` block with verbatim ORG_IDENTITY content and
  date-grouped recent journal bullets. The grounding block is the M8
  stage 4 payoff — every summary now grounds in entity names the org
  actually controls.

  Exposed (not private) so the legacy fallback path inside
  `Platform.Meetings.Summarizer.run_summary/1` can reuse it for prompt
  parity during the cutover window, and so tests can assert the
  grounding payload actually makes it into the system prompt.
  """
  @spec build_messages(map()) :: [map()]
  def build_messages(context) when is_map(context) do
    transcript = Map.get(context, :meeting_transcript) || %{}
    transcript_text = Map.get(transcript, :formatted_text) || ""

    [
      %{
        role: "system",
        content: system_prompt_with_grounding(context)
      },
      %{
        role: "user",
        content: "Please summarize the following meeting transcript:\n\n#{transcript_text}"
      }
    ]
  end

  def build_messages(_), do: build_messages(%{})

  @doc """
  Return the canonical summary system prompt with the `## Grounding
  context` block appended. Pulled out of `build_messages/1` so callers
  that don't need the full message list (e.g. legacy Anthropic
  adapter call sites that pass system + messages separately) can grab
  just the grounded system text.

  When `context[:agent_kind]` is `:fed_conversational` (Dalton — a
  federated conversational Claude runtime) a short preamble is
  prepended instructing the model to hand the summarization work off
  to a Task-tool subagent. For `:ext_single_responsibility` (Hermione)
  or missing kinds no preamble is added — those runtimes are single-
  purpose and don't benefit from meta-instructions about their
  execution shape (task 019f2566 stage 3).
  """
  @spec system_prompt_with_grounding(map()) :: String.t()
  def system_prompt_with_grounding(context) when is_map(context) do
    preamble = kind_preamble(Map.get(context, :agent_kind))
    base = SummaryPrompt.system_prompt()
    grounding = render_grounding_block(context)

    [preamble, base, grounding]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  def system_prompt_with_grounding(_), do: SummaryPrompt.system_prompt()

  # Task 019f2566 stage 3 — kind-specific preamble.
  #
  # The operator's framing: "Claude conversational agent like Dalton should get
  # extra information templated in recommending running the
  # summarization in a subagent, while an external agent like Hermione
  # is single responsibility and thus shouldn't need additional
  # instructions besides the normal prompt".
  defp kind_preamble(:fed_conversational) do
    """
    You are running inside a conversational Claude runtime. IMPORTANT: fire off the summarization work to a dedicated subagent (Task tool) so the main thread stays responsive to the user. Return the summary as plain text in the subagent's final message.
    """
    |> String.trim_trailing()
  end

  defp kind_preamble(_), do: ""

  # ── internals ─────────────────────────────────────────────────────────────

  defp extract_summary(%{"summary" => text}) when is_binary(text) and text != "",
    do: {:ok, text}

  defp extract_summary(%{summary: text}) when is_binary(text) and text != "",
    do: {:ok, text}

  defp extract_summary(text) when is_binary(text) and text != "",
    do: {:ok, text}

  defp extract_summary({:error, reason}), do: {:error, {:dispatch_failed, reason}}
  defp extract_summary(_), do: {:error, :invalid_output_shape}

  defp persist_summary(transcript_id, space_id, summary_text, input_hash) do
    case Meetings.complete_transcript(transcript_id, summary_text, input_hash) do
      {:ok, _transcript} ->
        Logger.info(
          "[meetings.summarize] persisted transcript_id=#{transcript_id} " <>
            "summary_len=#{String.length(summary_text)}"
        )

        if is_binary(space_id) and space_id != "" do
          case Meetings.post_summary_to_space(space_id, transcript_id, summary_text) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "[meetings.summarize] post_summary_to_space failed " <>
                  "transcript_id=#{transcript_id} space_id=#{space_id} reason=#{inspect(reason)}"
              )

              # Persistence already succeeded — surface the post failure
              # but don't fail the transcript a second time.
              {:error, {:post_failed, reason}}
          end
        else
          Logger.info(
            "[meetings.summarize] no space_id for transcript=#{transcript_id} — skipping post"
          )

          :ok
        end

      {:error, reason} ->
        Logger.error(
          "[meetings.summarize] complete_transcript failed " <>
            "transcript_id=#{transcript_id} reason=#{inspect(reason)}"
        )

        _ = safe_fail(transcript_id, input_hash, {:complete_failed, reason})
        {:error, {:complete_failed, reason}}
    end
  end

  # Task 019ff6f3 stage 3: the reason is recorded ON THE ROW via
  # `Meetings.fail_transcript/3`, not only in the Logger.warning below.
  # A failed transcript with a NULL summary and a NULL failure_reason is
  # unreadable on every surface a human actually visits.
  defp safe_fail(transcript_id, input_hash, reason) when is_binary(transcript_id) do
    Meetings.fail_summary_input(transcript_id, input_hash, reason)
  rescue
    error ->
      Logger.warning(
        "[meetings.summarize] fail_transcript raised transcript_id=#{transcript_id} " <>
          "error=#{Exception.message(error)}"
      )

      {:error, {:fail_raised, Exception.message(error)}}
  end

  defp safe_fail(_, _, _), do: :ok

  # ── trigger-meta accessors ────────────────────────────────────────────────

  defp transcript_id_from(%{payload: payload}) when is_map(payload),
    do: Map.get(payload, :transcript_id) || Map.get(payload, "transcript_id")

  defp transcript_id_from(%{"payload" => payload}) when is_map(payload),
    do: Map.get(payload, :transcript_id) || Map.get(payload, "transcript_id")

  defp transcript_id_from(meta) when is_map(meta),
    do: Map.get(meta, :transcript_id) || Map.get(meta, "transcript_id")

  defp space_id_from(%{payload: payload}) when is_map(payload),
    do: Map.get(payload, :space_id) || Map.get(payload, "space_id")

  defp space_id_from(%{"payload" => payload}) when is_map(payload),
    do: Map.get(payload, :space_id) || Map.get(payload, "space_id")

  defp space_id_from(meta) when is_map(meta),
    do: Map.get(meta, :space_id) || Map.get(meta, "space_id")

  # ── grounding block rendering ─────────────────────────────────────────────

  defp render_grounding_block(context) do
    identity = render_identity_block(Map.get(context, :org_identity))
    journal = render_journal_block(Map.get(context, :recent_journal))

    sections = Enum.reject([identity, journal], &(&1 == ""))

    case sections do
      [] ->
        ""

      _ ->
        "\n## Grounding context\n\n" <>
          "Use the following platform context for entity names and recent activity. " <>
          "Prefer verbatim entity names from this section over your own paraphrases.\n\n" <>
          Enum.join(sections, "\n\n")
    end
  end

  defp render_identity_block(%{content: content, missing?: false}) when is_binary(content),
    do: "### Org identity\n\n" <> content

  defp render_identity_block(%{content: content})
       when is_binary(content) and content != "",
       do: "### Org identity\n\n" <> content

  defp render_identity_block(_), do: ""

  defp render_journal_block(%{entries_by_date: entries})
       when is_list(entries) and entries != [] do
    body =
      entries
      |> Enum.map(&render_journal_date/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    if body == "", do: "", else: "### Recent journal (last 7 days)\n\n" <> body
  end

  defp render_journal_block(_), do: ""

  defp render_journal_date({date, entries}) when is_list(entries) and entries != [] do
    date_str =
      case date do
        %Date{} -> Date.to_iso8601(date)
        other -> to_string(other)
      end

    bullets =
      entries
      |> Enum.map(&render_journal_entry/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    if bullets == "", do: "", else: "**#{date_str}**\n#{bullets}"
  end

  defp render_journal_date(_), do: ""

  defp render_journal_entry(%{content: content}) when is_binary(content) and content != "",
    do: "- #{String.trim(content)}"

  defp render_journal_entry(%{"content" => content}) when is_binary(content) and content != "",
    do: "- #{String.trim(content)}"

  defp render_journal_entry(other) when is_binary(other) and other != "",
    do: "- #{String.trim(other)}"

  defp render_journal_entry(_), do: ""
end
