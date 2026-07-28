defmodule Platform.Responsibilities.Handlers.MeetingActionItems do
  @moduledoc """
  `meetings.action_items` responsibility provider (ADR-0041 Meeting Scribe
  bundle stage 3, task 019f2455).

  Implements the M1 `Platform.Responsibilities.Provider` behaviour for
  the per-meeting action-items extraction that fires alongside
  `meetings.summarize` on the canonical `meeting:finished` event the
  `PlatformWeb.LivekitWebhookController` emits via
  `Platform.Meetings.PubSub.broadcast_meeting_finished/2`.

  ## Spec

    * `key` — `"meetings.action_items"`
    * `feature` — `"meetings"`
    * `trigger_kind` — `event_topic` with `topic: "meeting:finished"`
      (same fan-in topic `meetings.summarize` uses — both responsibilities
      co-subscribe and both fire per meeting)
    * `scope` — `per_meeting`
    * `context_provided` — `["org_identity", "meeting_transcript"]`
    * `output_contract` — `%{"action_items" => "list[string]"}`

  ## Output handling (task 019fa56b-c81f stage 3)

  This handler used to be registration-only: `handle_output/3` extracted
  the items, logged the COUNT, and returned `:ok` with the items
  discarded. That made the key fire-into-nothing — once the Router's
  event_topic adapter was repaired (same task, stage 1) it would have
  become a per-meeting LLM spend producing no output at all.

  It now posts the extracted items to the meeting's chat space via
  `Platform.Meetings.post_action_items_to_space/3`, mirroring the second
  half of `MeetingSummarize.handle_output/3`. Behaviours:

    * items present + a resolvable space → posted as a markdown checklist
    * empty item list → logged, NOT posted, returns `:ok`. A meeting with
      no action items is a legitimate outcome and an empty checklist post
      is noise.
    * malformed payload → `extract_items/1` logs its warning, yields `[]`,
      and the empty-list branch applies: nothing posted, `:ok`
    * missing `transcript_id` in `trigger_meta` → `{:error,
      :missing_transcript_id}` (matching `MeetingSummarize`) rather than
      `:ok`, so a mis-shaped trigger is recorded as a failed outcome
      instead of a silent success

  ## Why the string/map fix is here and not in `ContractValidator` (019fa56b-c81f)

  Stage 3's posting code was correct; the key still delivered nothing,
  because nothing ever reached it in the right shape. The root cause is
  one level up: `ContractValidator.classify/1` has no clause for the
  field-map contract shape (`%{"action_items" => "list[string]"}`), so
  it lands on `:unknown`, which is deliberately treated as freeform, so
  `validate/2` returns the raw response STRING.

  Fixing `classify/1` looks like the root fix and is the wrong move.
  EVERY responsibility in the tree declares its contract in that shape —
  `meetings.summarize`, `daily_summary`, `dreaming`, all four
  `security.*`, all four `design.*`, all three `architecture.*`. They
  are all being handed a binary today and the string-typed ones all
  work, because their extractors carry a binary clause. Teaching
  `classify/1` to read a field map as `:json` would route all of them
  through `Jason.decode/1`, and any model that answered a `"string"`
  contract with prose — which is exactly what
  `meetings.summarize` asks for and gets — would stop being a summary
  and start being `{:error, {:contract_violation, :invalid_json}}`. The
  "root fix" would turn a working summariser into a hard failure.

  A softer classifier (try JSON, fall back to the string) avoids that
  but still changes the argument type of every handler in the tree from
  binary to map-when-parseable, and each one would need re-proving. That
  is not this task.

  So the boundary is here: each handler owns the shape it can consume,
  which is the contract `MeetingSummarize` has always honoured. The
  classifier gap is real and worth a follow-up — `propose_long_term`'s
  `extract_proposals/1` has the identical missing binary clause and is
  silently broken the same way — but it is a separate change with a
  blast radius this fix does not need.

  There is deliberately no schema migration: `meeting_transcripts` has a
  `summary` column but no `action_items` column, and the seeded
  `meetings.action_items.v1` prompt promises the model extraction, not
  storage. The space post is the visible delivery; persistence is
  additive later if wanted.

  ## Wildcard-topic note

  Same as `MeetingSummarize` — Phoenix.PubSub has no wildcard subscribe,
  so the `topic_pattern: "meeting:finished:*"` documented here is
  advisory. The router subscribes to the canonical `"meeting:finished"`
  topic and `PubSub.broadcast_meeting_finished/2` mirrors every per-room
  broadcast there.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Meetings
  alias Platform.Responsibilities.ContextProviders
  alias Platform.Responsibilities.Responsibility

  @key "meetings.action_items"
  @feature "meetings"

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

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
          # `MeetingSummarize` so both Meeting Scribe responsibilities
          # fan in from the same publisher.
          "topic" => "meeting:finished",
          "topic_pattern" => "meeting:finished:*",
          "event_match" => "meeting_finished"
        },
        scope: "per_meeting",
        context_provided: ["org_identity", "meeting_transcript"],
        output_contract: %{"action_items" => "list[string]"},
        default_prompt_template: "meetings.action_items.v1",
        cost_profile: "low_freq_capable",
        # `status: "active"` declares this key live now that it has a real
        # landing. It is expressed in `metadata` — not `enabled` — because
        # `Platform.Responsibilities.@upsert_replace_fields` includes
        # `metadata` and deliberately EXCLUDES `enabled` (operator
        # territory, preserved across redeploys). A code-only `enabled`
        # change would be a guaranteed no-op against the existing
        # production row; a `metadata` change propagates on next boot.
        metadata: %{"owner" => "platform.meetings", "status" => "active"}
      }
    ]
  end

  @impl true
  def gather_context(%Responsibility{} = _responsibility, ctx) when is_map(ctx) do
    # Task 019fa56b-c81f e2e fix, defect 2.
    #
    # This used to return `{:ok, %{}}` on the belief that "the router
    # still resolves the shared meetings context slots via the provider
    # shim". It does not. `Router.gather_context_via_provider/3` calls
    # the PROVIDER's `gather_context/2` when one is exported and only
    # falls back to its own `context_provided`-driven slot resolution
    # when it is not — and `Providers.Meetings` does export it. So the
    # empty map WAS the context: `build_prompt/1` had nothing to render
    # over, the Router fell back to the `default_prompt_template` render
    # path, and the un-seeded template name went out as the literal user
    # turn. The live capture is unambiguous:
    #
    #     messages == [{"role":"user","content":"meetings.action_items.v1"}]
    #
    # We now gather exactly the two slots `register/0` declares in
    # `context_provided` — `org_identity` and `meeting_transcript`.
    #
    # NOTE the deliberate absence of `Meetings.claim_router_dispatch/1`.
    # `MeetingSummarize.gather_context/2` claims because stage 2 of this
    # task made the `meeting:finished` dispatch once-per-transcript for
    # THAT key. The claim is keyed by transcript, not by responsibility,
    # so claiming here as well would make the two co-subscribed
    # responsibilities race for a single token and starve whichever one
    # lost. Both are supposed to fire per meeting.
    payload = Map.get(ctx, :payload) || Map.get(ctx, "payload") || %{}
    transcript_id = Map.get(payload, :transcript_id) || Map.get(payload, "transcript_id")
    workspace_id = Map.get(payload, :workspace_id) || Map.get(payload, "workspace_id")

    base_opts = if workspace_id, do: [workspace_id: workspace_id], else: []

    with {:ok, %{org_identity: identity}} <-
           ContextProviders.gather_context(:org_identity, base_opts),
         {:ok, %{meeting_transcript: transcript}} <- gather_transcript(transcript_id) do
      {:ok, %{org_identity: identity, meeting_transcript: transcript}}
    end
  end

  def gather_context(_responsibility, _ctx), do: {:ok, %{}}

  defp gather_transcript(nil) do
    {:ok, %{meeting_transcript: %{transcript_id: nil, missing?: true, formatted_text: ""}}}
  end

  defp gather_transcript(transcript_id) when is_binary(transcript_id) do
    case ContextProviders.gather_context(:meeting_transcript, transcript_id: transcript_id) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, reason} ->
        Logger.warning(
          "[meetings.action_items] transcript gather failed id=#{transcript_id} " <>
            "reason=#{inspect(reason)}"
        )

        {:ok,
         %{meeting_transcript: %{transcript_id: transcript_id, missing?: true, error: reason}}}
    end
  end

  @doc """
  Render the extraction prompt for this responsibility (task
  019fa56b-c81f e2e fix, defect 2).

  Mirrors `MeetingSummarize.build_prompt/1`: `{:ok, %{system:, user:}}`
  when there is transcript text to work on, `{:error, :no_transcript_text}`
  otherwise. The Router hands the returned pair to the Dispatcher as an
  explicit `messages` list, which is what stops the un-seeded
  `default_prompt_template` name from being sent as the prompt.

  Refusing on an empty transcript is the same trade `MeetingSummarize`
  makes and for the same reason: a model round-trip over no content is
  spend with no possible output.
  """
  @spec build_prompt(map()) ::
          {:ok, %{system: String.t(), user: String.t()}} | {:error, :no_transcript_text}
  def build_prompt(context) when is_map(context) do
    transcript = Map.get(context, :meeting_transcript) || %{}
    transcript_text = Map.get(transcript, :formatted_text) || ""

    if is_binary(transcript_text) and String.trim(transcript_text) != "" do
      {:ok,
       %{
         system: system_prompt(context),
         user:
           "Extract the action items from the following meeting transcript:\n\n#{transcript_text}"
       }}
    else
      {:error, :no_transcript_text}
    end
  end

  def build_prompt(_), do: {:error, :no_transcript_text}

  @doc """
  System prompt for the extraction turn.

  Asks for the declared `%{"action_items" => "list[string]"}` contract
  shape, and — because `ContractValidator` hands the handler back a
  RAW STRING for that contract shape rather than a decoded map (see
  `extract_items/1`) — also names the plain-list fallback that
  `extract_items/1` can parse. Both shapes land; the JSON one is asked
  for first because it is the contract of record.
  """
  @spec system_prompt(map()) :: String.t()
  def system_prompt(context \\ %{}) when is_map(context) do
    base = """
    You extract action items from meeting transcripts. Given a transcript with speaker-attributed segments, return ONLY the concrete next steps that were committed to.

    ## Output Format

    Return a JSON object with a single `action_items` key holding an array of strings:

        {"action_items": ["Priya reverts the onboarding flow by Friday", "Alex emails the deploy audit"]}

    If you cannot return JSON, return one action item per line as a plain markdown list instead. Do not wrap the list in prose.

    ## Guidelines
    - One action item per entry, phrased as a single actionable sentence
    - Name the assignee when the transcript identifies one (e.g. "Priya reverts...")
    - Include a due date or deadline when one was stated
    - Do not invent items — only what was actually committed to in the transcript
    - A meeting with no action items is a legitimate outcome: return `{"action_items": []}`
    - Do not include decisions, topics, or summary content — action items only
    """

    case identity_block(Map.get(context, :org_identity)) do
      "" -> String.trim_trailing(base)
      block -> String.trim_trailing(base) <> block
    end
  end

  defp identity_block(%{content: content, missing?: false}) when is_binary(content) do
    case String.trim(content) do
      "" ->
        ""

      trimmed ->
        "\n\n## Grounding context\n\n" <>
          "Use the following platform context for entity names. Do not treat it as " <>
          "meeting content.\n\n### Org identity\n\n" <> trimmed <> "\n"
    end
  end

  defp identity_block(_), do: ""

  @impl true
  def handle_output(%Responsibility{} = responsibility, parsed) do
    handle_output(responsibility, parsed, %{kind: :unknown})
  end

  @impl true
  def handle_output(%Responsibility{} = responsibility, parsed, trigger_meta)
      when is_map(trigger_meta) do
    transcript_id = transcript_id_from(trigger_meta)
    items = extract_items(parsed)

    cond do
      is_nil(transcript_id) ->
        Logger.warning(
          "[meetings.action_items] no transcript_id in trigger_meta — cannot post " <>
            "key=#{responsibility.key} trigger=#{inspect(Map.get(trigger_meta, :kind))}"
        )

        {:error, :missing_transcript_id}

      items == [] ->
        # Not an error. A meeting can legitimately produce no action
        # items, and a malformed payload has already logged its warning
        # in `extract_items/1`. Either way an empty checklist post is
        # noise, so we log and stop.
        Logger.info(
          "[meetings.action_items] no action items for transcript=#{transcript_id} — " <>
            "nothing posted"
        )

        :ok

      true ->
        post_items(transcript_id, space_id_for(trigger_meta, transcript_id), items)
    end
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp post_items(transcript_id, space_id, items)
       when is_binary(space_id) and space_id != "" do
    case Meetings.post_action_items_to_space(space_id, transcript_id, items) do
      :ok ->
        Logger.info(
          "[meetings.action_items] posted #{length(items)} action item(s) " <>
            "transcript=#{transcript_id} space=#{space_id}"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "[meetings.action_items] post_action_items_to_space failed " <>
            "transcript=#{transcript_id} space=#{space_id} reason=#{inspect(reason)}"
        )

        {:error, {:post_failed, reason}}
    end
  end

  defp post_items(transcript_id, _space_id, items) do
    Logger.warning(
      "[meetings.action_items] no space_id for transcript=#{transcript_id} — " <>
        "discarding #{length(items)} action item(s)"
    )

    {:error, :missing_space_id}
  end

  # `MeetingSummarize` reads `space_id` off the trigger payload only. We
  # fall back to the transcript row's own `space_id` because, unlike a
  # summary, action items have no other landing surface — dropping them
  # when a publisher omits the slot would reinstate exactly the
  # fires-into-nothing behaviour this stage exists to remove.
  defp space_id_for(trigger_meta, transcript_id) do
    case space_id_from(trigger_meta) do
      space_id when is_binary(space_id) and space_id != "" ->
        space_id

      _ ->
        case Meetings.get_transcript(transcript_id) do
          %{space_id: space_id} -> space_id
          _ -> nil
        end
    end
  end

  defp transcript_id_from(%{payload: payload}) when is_map(payload),
    do: Map.get(payload, :transcript_id) || Map.get(payload, "transcript_id")

  defp transcript_id_from(%{"payload" => payload}) when is_map(payload),
    do: Map.get(payload, :transcript_id) || Map.get(payload, "transcript_id")

  defp transcript_id_from(meta) when is_map(meta),
    do: Map.get(meta, :transcript_id) || Map.get(meta, "transcript_id")

  defp transcript_id_from(_), do: nil

  defp space_id_from(%{payload: payload}) when is_map(payload),
    do: Map.get(payload, :space_id) || Map.get(payload, "space_id")

  defp space_id_from(%{"payload" => payload}) when is_map(payload),
    do: Map.get(payload, :space_id) || Map.get(payload, "space_id")

  defp space_id_from(meta) when is_map(meta),
    do: Map.get(meta, :space_id) || Map.get(meta, "space_id")

  defp space_id_from(_), do: nil

  defp extract_items(%{"action_items" => list}) when is_list(list),
    do: clean(list)

  defp extract_items(%{action_items: list}) when is_list(list),
    do: clean(list)

  # ── the string/map seam (task 019fa56b-c81f e2e fix, defect 1) ───────────
  #
  # This clause is why the key was unfireable. In production the handler
  # is reached only via `Router.invoke_handle_output/3`, whose `parsed`
  # comes from `ContractValidator.validate/2`. `classify/1` has no clause
  # for the field-map contract shape this responsibility declares
  # (`%{"action_items" => "list[string]"}`), so it falls to `:unknown`,
  # which is treated as freeform, which returns the RAW STRING. The map
  # clauses above are therefore unreachable in production — they only
  # ever matched because all 19 tests in `meeting_action_items_test.exs`
  # call `handle_output/3` directly with a map.
  #
  # `MeetingSummarize.extract_summary/1` has exactly this binary clause,
  # which is the entire reason the summarizer posts and this key did not.
  # Live proof, `server3.log:1392`:
  #
  #     [warning] [meetings.action_items] handler received unexpected
  #     output shape — expected %{action_items: [string]}; got
  #     "{\"action_items\": [\"Ship the adapter fix\", ...]}"
  #
  # ## The rule, pinned
  #
  # A summary is one string so the summarizer can take its whole body
  # verbatim. Action items are plural, so a string has to be split. In
  # order:
  #
  #   1. If the string parses as JSON that carries the contract shape
  #      (`{"action_items": [...]}` or a bare `[...]`), use that. This is
  #      the common case — the model honoured the contract and only the
  #      validator failed to decode it.
  #   2. Otherwise treat it as prose and split on newlines.
  #      a. If ANY line carries a list marker (`-`, `*`, `+`, `•`, `1.`,
  #         `1)`), keep ONLY the marked lines. This drops the "Here are
  #         the action items:" preamble and any markdown heading without
  #         needing to guess at their content.
  #      b. If NO line carries a marker, keep every non-blank line.
  #   3. Strip the marker, trim, drop blanks. Markers are stripped once,
  #      not repeatedly, so a literal item like "- see - the doc" keeps
  #      its inner hyphen.
  #
  # An empty result is not an error: `handle_output/3`'s `items == []`
  # branch already treats "no action items" as a legitimate outcome and
  # posts nothing.
  defp extract_items(text) when is_binary(text) do
    case decode_contract_shape(text) do
      {:ok, list} -> clean(list)
      :error -> clean(split_prose(text))
    end
  end

  defp extract_items(other) do
    Logger.warning(
      "[meetings.action_items] handler received unexpected output shape — " <>
        "expected %{action_items: [string]}; got " <> inspect(other)
    )

    []
  end

  # Only the contract shape counts as a decode. A JSON string, number, or
  # a map without `action_items` falls through to the prose splitter,
  # which is the honest reading: the model did not answer the contract.
  defp decode_contract_shape(text) do
    case Jason.decode(text) do
      {:ok, %{"action_items" => list}} when is_list(list) -> {:ok, list}
      {:ok, list} when is_list(list) -> {:ok, list}
      _ -> :error
    end
  end

  # Markers stripped exactly once — see the rule in `extract_items/1`.
  @list_marker ~r/^\s*(?:[-*+•]|\d+[.)])\s+/

  defp split_prose(text) do
    lines = String.split(text, ~r/\r?\n/)

    case Enum.filter(lines, &Regex.match?(@list_marker, &1)) do
      [] -> lines
      marked -> marked
    end
    |> Enum.map(&String.replace(&1, @list_marker, "", global: false))
  end

  defp clean(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
