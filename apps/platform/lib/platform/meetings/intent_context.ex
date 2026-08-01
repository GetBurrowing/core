defmodule Platform.Meetings.IntentContext do
  @moduledoc """
  The context slots every mid-meeting intent responsibility gathers, and
  the formatters that render them into a prompt.

  ## Why this is shared rather than per-handler

  `Handlers.MeetingActionItems` established the shape in task
  `019fb90f-36e3`: an intent responsibility does not work from "the
  transcript". It works from **one classified utterance**, **the few
  lines around it**, and **whatever artifact it is reconciling
  against**. The first two are identical for every intent; only the
  third differs. Copying the first two into each new handler would be
  five copies of the payload-field names the dispatcher broadcasts, and
  the dispatcher's own docs are explicit that most of those fields
  degrade to nil mid-meeting — so five copies of the nil-handling too.

  ## Nothing here refuses

  Every slot reports its own `missing?` and returns a usable map.
  Mid-meeting, a transcript row that does not exist yet and a space with
  no canvases yet are both the NORMAL state at the first utterance of a
  meeting, not errors. The single refusal belongs to each handler's
  `build_prompt/1` and is the one case that genuinely has nothing to
  work from: a blank excerpt.

  ## Sentinels, not empty strings

  Each formatter renders absence as an explicit parenthetical. A marker
  that interpolates to `""` leaves its heading in the prompt with
  nothing under it, which reads to a model as a section that was
  truncated rather than a section that is empty — and an empty section
  is meaningful here (it is how the model knows this is the first
  action item, or that no canvas exists yet).
  """

  require Logger

  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.SummaryPrompt

  # Bounded for the same reason `IntentClassifier` bounds its own
  # context window: the cost of this slot must be a constant, not a
  # function of how long the meeting has been running. Every utterance
  # would otherwise pay for the whole meeting again.
  @transcript_window_size 8

  @doc "How many trailing transcript segments `transcript_window/1` returns."
  @spec transcript_window_size() :: pos_integer()
  def transcript_window_size, do: @transcript_window_size

  @doc """
  The classified utterance itself, read straight off the payload
  `IntentDispatcher` broadcasts.

  Nothing is defaulted except `chunk_excerpt`, which is normalised to
  `""` so the downstream refusal check is a string operation rather
  than a nil check. `speaker` is left as-is INCLUDING nil: the
  dispatcher recovers it heuristically by matching excerpt text against
  transcript segments, so "we could not attribute this line" must not
  be rendered as an attribution.
  """
  @spec meeting_intent(map()) :: map()
  def meeting_intent(payload) do
    excerpt = payload |> field(:chunk_excerpt) |> text()

    %{
      intent_id: field(payload, :intent_id),
      meeting_id: field(payload, :meeting_id),
      room_id: field(payload, :room_id),
      classified_intent: field(payload, :classified_intent),
      confidence: field(payload, :confidence),
      chunk_excerpt: excerpt,
      speaker: field(payload, :speaker),
      missing?: String.trim(excerpt) == ""
    }
  end

  @doc """
  The tail of the room's in-progress transcript, so the model can
  resolve "that", "she" and "by then" against what was actually said
  just before the classified line.
  """
  @spec transcript_window(map()) :: map()
  def transcript_window(payload) do
    case fetch_transcript(field(payload, :transcript_id)) do
      %{} = transcript ->
        window = Enum.take(transcript.segments || [], -@transcript_window_size)
        formatted = SummaryPrompt.format_segments(window)

        %{
          transcript_id: transcript.id,
          segments: window,
          formatted_text: formatted,
          missing?: window == [] or String.trim(formatted) == ""
        }

      nil ->
        %{
          transcript_id: field(payload, :transcript_id),
          segments: [],
          formatted_text: "",
          missing?: true
        }
    end
  end

  @doc """
  Every canvas already in the meeting's chat space — id, title and the
  root node kind — so the recipient can decide whether to create a new
  one or patch an existing one.

  This is deliberately an INVENTORY, not a typed artifact. The recipient
  is an agent holding `canvas_describe` / `canvas_create` /
  `canvas_patch`; it needs to know what is there and can read the detail
  itself. Handing it a server-side reconciliation of one blessed canvas
  is how `meetings.action_items` acquired an 800-line module that its
  native assignee never reaches.
  """
  @spec space_canvases(String.t() | nil) :: map()
  def space_canvases(space_id) when is_binary(space_id) and space_id != "" do
    canvases =
      space_id
      |> Chat.list_canvases()
      |> Enum.map(&%{id: &1.id, title: &1.title, kind: root_kind(&1)})

    %{space_id: space_id, canvases: canvases, missing?: canvases == []}
  rescue
    # A sandbox-owned Repo call from a test whose ownership chain has
    # gone away, or a space id that no longer resolves. Absence of an
    # inventory must not fail the dispatch — the recipient can still
    # create a canvas.
    error ->
      Logger.debug("[IntentContext] canvas inventory unavailable: #{inspect(error)}")
      %{space_id: space_id, canvases: [], missing?: true}
  end

  def space_canvases(_), do: %{space_id: nil, canvases: [], missing?: true}

  @doc """
  Resolve the chat space the recipient should write into: the payload's
  own `space_id` when the dispatcher stamped one, else the meeting's
  chat space.
  """
  @spec space_id(map()) :: String.t() | nil
  def space_id(payload) do
    case present(field(payload, :space_id)) do
      nil -> meeting_space_id(field(payload, :meeting_id))
      space_id -> space_id
    end
  end

  # ── formatters ────────────────────────────────────────────────────────────

  @doc "Render the classified utterance for the system turn."
  @spec format_intent(map()) :: String.t()
  def format_intent(intent) when is_map(intent) do
    """
    - Intent: #{value(Map.get(intent, :classified_intent))}
    - Confidence: #{value(Map.get(intent, :confidence))}
    - Speaker: #{value(Map.get(intent, :speaker))}
    - Said: #{value(present(Map.get(intent, :chunk_excerpt)))}
    """
    |> String.trim()
  end

  def format_intent(_), do: "(no classified intent)"

  @doc """
  The ack contract, rendered for one intent.

  ## Why this is in code and not in the tunable template row

  Every other part of an intent prompt is editable live via
  `prompt_template_update` — that is the point of the templates. This
  part is not, because it is **protocol rather than instruction**, and
  the failure mode of losing it is silent and expensive.

  The dispatcher marks a row `:dispatched` before handing it off, which
  arms the queue's 90s ack window AND holds the meeting's serial
  cursor: nothing else in that meeting dispatches until this row reaches
  a terminal status. On the responsibility path the platform cannot
  close the row itself — `handle_output/3` and `handle_refusal/3` are
  reachable only from the EXTERNAL dispatch path, and the live
  assignees are native. So the recipient's ack is the only thing that
  can release the cursor.

  Measured on 2026-07-31, before this existed: `meetings.action_items`
  shipped with a prompt containing no mention of `intent_ack` and no
  `intent_id`, and `Router.@native_trigger_scalar_keys` did not carry
  the id either. Every classified action item therefore rode the full
  90-second window and landed `:timed_out`, serialising a busy meeting
  at roughly one intent per ninety seconds.

  A template edit that dropped this section would reintroduce exactly
  that, and nothing would go red — the meeting would just get slower.
  So it is composed onto the front of the system turn in
  `build_prompt/1`, where a prompt author cannot remove it by accident.

  Returns `""` when there is no intent id to ack against, rather than
  rendering instructions naming a nil handle. That happens only for a
  direct `Router.fire/2` from a console, which has no queue row behind
  it and nothing to release.
  """
  @spec ack_preamble(map()) :: String.t()
  def ack_preamble(intent) when is_map(intent) do
    case present(Map.get(intent, :intent_id)) do
      nil ->
        ""

      intent_id ->
        """
        ## Before anything else: the meeting is waiting on you

        This work came off a live meeting's intent queue. The queue is **serial** — it holds one intent per meeting in flight, and nothing else classified in this meeting reaches anybody until you report back. The window is 90 seconds.

        Your handle for this one is `intent_id: #{intent_id}`.

        - Starting work? `intent_ack(intent_id: "#{intent_id}", status: "working")`. Send it before you begin, not after.
        - Finished? `intent_ack(intent_id: "#{intent_id}", status: "completed")`.
        - Not yours, or not actionable? `intent_ack(intent_id: "#{intent_id}", status: "rejected")` with a one-line `note` saying why.

        **An honest `rejected` is a good outcome.** It unblocks the meeting immediately and it teaches the classifier — rejections are recorded as corrections and become examples that sharpen future routing. Guessing at work that is not yours is the bad outcome, and silence is the worst one: it costs the meeting the full ninety seconds and tells nobody anything.

        Never leave this unacked to see whether it resolves itself.
        """
        |> String.trim()
    end
  end

  def ack_preamble(_), do: ""

  @doc """
  Compose the ack contract onto the front of a rendered system prompt.

  Every intent handler's `build_prompt/1` goes through here rather than
  returning `system_prompt(context)` directly, so the contract is
  applied in one place and cannot be present on four keys and missing
  on the fifth. See `ack_preamble/1` for why it is not in the template.

  The contract goes FIRST, before the tuned body. A recipient that
  stops reading early must still have seen the thing that unblocks the
  meeting.
  """
  @spec with_ack(map(), String.t()) :: String.t()
  def with_ack(intent, body) when is_map(intent) and is_binary(body) do
    case ack_preamble(intent) do
      "" -> body
      preamble -> preamble <> "\n\n" <> body
    end
  end

  def with_ack(_intent, body) when is_binary(body), do: body

  @doc "Render the surrounding transcript lines, or say there are none yet."
  @spec format_window(map()) :: String.t()
  def format_window(%{missing?: true}), do: "(no surrounding transcript captured yet)"

  def format_window(%{formatted_text: text}) when is_binary(text) and text != "", do: text

  def format_window(_), do: "(no surrounding transcript captured yet)"

  @doc """
  Render the canvas inventory. An empty space is stated as empty rather
  than omitted — "there is nothing here yet" is how the recipient knows
  to create rather than patch.
  """
  @spec format_canvases(map()) :: String.t()
  def format_canvases(%{missing?: false, canvases: canvases})
      when is_list(canvases) and canvases != [] do
    canvases
    |> Enum.map_join("\n", fn c ->
      "- #{value(present(c.title))} (id: #{value(c.id)}, root: #{value(c.kind)})"
    end)
  end

  def format_canvases(_), do: "(no canvases in this meeting's space yet)"

  @doc "Render org identity, or say it is unavailable."
  @spec format_identity(map() | nil) :: String.t()
  def format_identity(%{content: content, missing?: false}) when is_binary(content) do
    String.trim(content)
  end

  def format_identity(_), do: "(no org identity available)"

  @doc "Render a value for a prompt, never as a bare empty string."
  @spec value(any()) :: String.t()
  def value(nil), do: "(unknown)"
  def value(value) when is_binary(value), do: value
  def value(value), do: to_string(value)

  # ── internals ─────────────────────────────────────────────────────────────

  defp fetch_transcript(nil), do: nil

  defp fetch_transcript(transcript_id) when is_binary(transcript_id) do
    Meetings.get_transcript(transcript_id)
  rescue
    _ -> nil
  end

  defp fetch_transcript(_), do: nil

  defp meeting_space_id(meeting_id) when is_binary(meeting_id) and meeting_id != "" do
    case Meetings.get_meeting(meeting_id) do
      %{chat_space_id: space_id} -> present(space_id)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp meeting_space_id(_), do: nil

  defp root_kind(%{document: %{"root" => %{"type" => type}}}) when is_binary(type), do: type
  defp root_kind(%{document: %{"type" => type}}) when is_binary(type), do: type
  defp root_kind(_), do: nil

  defp field(payload, key) when is_map(payload) and is_atom(key),
    do: Map.get(payload, key) || Map.get(payload, Atom.to_string(key))

  defp field(_payload, _key), do: nil

  defp text(value) when is_binary(value), do: value
  defp text(_), do: ""

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil
end
