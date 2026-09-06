defmodule Platform.Meetings.SpeakingWindow do
  @moduledoc """
  The two ends of an agent's `:speaking` state, as seen from
  `Platform.Meetings.say/4` (task `01a07400` stage 2).

  `dispatched/4` opens the window at the point core broadcasts the
  `meeting_say` frame; `acked/2` closes it when the runtime's receipt comes
  back. Everything either one needs to work out — which meeting the room
  belongs to, whether the ack is from the agent that actually spoke, how
  long the audio could plausibly run — is resolved here.

  ## Why this module exists rather than four lines in `meetings.ex`

  `say/4` and `record_agent_say_ack/2` are among the most contended
  functions in the codebase; several tasks touch them in the same week.
  A helper with a one-line call site at each end means this feature's
  footprint in `meetings.ex` is two inserted lines that no reformatting,
  reordering or neighbouring edit can tangle with. It is the same shape
  `Platform.Meetings.SayTelemetry` uses at the same two sites, and for the
  same reason.

  ## The meeting id is resolved from the room's SPACE, not the room

  `AgentActivity` keys on `meetings.id` — the shell topic
  (`meeting:<id>`) and the rail are both per-meeting entities — while
  `say/4` holds a `%Room{}`, which is the LiveKit room. `Meetings.
  meeting_id_for_space/2` is the existing bridge, and the same one
  `deliver_transcript_segment/2` uses for `:heard`.

  It is called with `DateTime.utc_now/0` as the "not ended before" bound,
  so an utterance in a room whose only meeting finished hours ago does not
  inherit that meeting's id. A room with no live meeting row yields `nil`
  and both functions become silent no-ops — there is no rail to paint, and
  a say must never fail over a state that is at most a UI nicety.

  ## The ack is checked against the agent that spoke

  `acked/2` reads the `SayRegistry` entry `say/4` wrote and clears nothing
  unless that entry's `agent_id` matches the runtime that acked. That is
  the same guard `post_spoken_utterance/2` applies before putting text in
  chat, applied here for the smaller version of the same problem: a forged
  or misrouted ack must not be able to blank another agent's `:speaking`.

  A registry miss — an expired, replayed or never-dispatched id — clears
  nothing either. The row's ttl covers it.
  """

  alias Platform.Meetings
  alias Platform.Meetings.AgentActivity
  alias Platform.Meetings.SayRegistry

  @doc """
  Open `agent`'s `:speaking` window for `utterance_id` in `room`.

  Called immediately after the `meeting_say` broadcast succeeds — after,
  because the state is "core has sent the audio", and a broadcast that
  failed sent nothing.

  `text` is the dispatched text, and only its length is used: it sets the
  row's ttl through `AgentActivity.speaking_ttl_ms/1`, so the backstop for
  a runtime that dies mid-playout is proportional to how much there was to
  play.

  Returns `:ok` in every case, including the ones where it does nothing.
  Nothing in `say/4` may fail because of the activity rail.
  """
  @spec dispatched(map(), map(), binary(), binary()) :: :ok
  def dispatched(%{space_id: space_id}, %{id: agent_id}, utterance_id, text)
      when is_binary(agent_id) and is_binary(utterance_id) and is_binary(text) do
    case live_meeting_id(space_id) do
      nil ->
        :ok

      meeting_id ->
        AgentActivity.mark_speaking(meeting_id, agent_id, utterance_id,
          char_count: String.length(text)
        )

        :ok
    end
  end

  def dispatched(_room, _agent, _utterance_id, _text), do: :ok

  @doc """
  Close the `:speaking` window `utterance_id` opened, if `agent_id` is the
  agent it was opened for.

  Called on EVERY ack, not only a `"spoken"` one. A `"failed"` receipt
  means the audio is not playing either, and leaving the window open on it
  would show the one state that is definitely false.

  The utterance id is passed through to `AgentActivity.clear_speaking/3`,
  which refuses to close a window a LATER utterance opened — see that
  function.

  Returns `:ok` in every case.
  """
  @spec acked(binary() | nil, binary()) :: :ok
  def acked(agent_id, utterance_id) when is_binary(agent_id) and is_binary(utterance_id) do
    with %{agent_id: ^agent_id, space_id: space_id} <- SayRegistry.get(utterance_id),
         meeting_id when is_binary(meeting_id) <- live_meeting_id(space_id) do
      AgentActivity.clear_speaking(meeting_id, agent_id, utterance_id)
    else
      _ -> :ok
    end
  end

  def acked(_agent_id, _utterance_id), do: :ok

  defp live_meeting_id(space_id) when is_binary(space_id),
    do: Meetings.meeting_id_for_space(space_id, DateTime.utc_now())

  defp live_meeting_id(_space_id), do: nil
end
