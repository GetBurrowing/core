defmodule Platform.Federation.VoiceAskTools do
  @moduledoc """
  Definitions for the `voice_ask` bundle (task 01a17b10 stage 4): the meeting
  voice runtime asks the install's Burrow agent a question through the normal
  chat attention path and reads Burrow's streamed answer back. Behaviour is in
  `Platform.Meetings.VoiceAsk`.

  ## Why a bundle of its own, not `meetings`

  `Platform.Federation.ToolAuthorization` grants per BUNDLE. `meetings` also
  carries `meeting_create` (creates durable meetings and their chat spaces in
  any project the owner can reach), `intent_ack` and `meeting_activity_push`.
  The voice persona's seed (`mix platform.seed_meeting_voice_agent`)
  deliberately holds only `messaging` and `context_read`; granting `meetings`
  to give it two read/ask tools would hand it `meeting_create` too. So the two
  tools live in a narrow bundle that holds exactly them, and the seed grants
  that bundle.

  Both tools require `chat.write`: asking posts one chat message in the
  meeting's space under the caller's own participant, which is the same write
  `send_media` and `react` already need.
  """

  @names ~w(voice_ask_agent voice_ask_poll)

  @doc "Every tool name in the bundle."
  def names, do: @names

  def definitions do
    [
      %{
        name: "voice_ask_agent",
        description:
          "Ask the install's Burrow agent (or another agent in the space) a question on behalf of the meeting. Posts the question as a chat message in `space_id`, authored by YOU and addressed to the agent with an @-mention, so the normal attention routing dispatches it. The agent's answer streams back into the same space; read it with voice_ask_poll using the returned ask_id.",
        parameters: %{
          space_id: %{
            type: "string",
            required: true,
            description: "The meeting's chat space id. You must be a participant of it."
          },
          question: %{
            type: "string",
            required: true,
            description: "The question, as plain text. At most 2000 characters; blank is refused."
          },
          agent_id: %{
            type: "string",
            required: false,
            description:
              "The agent to ask. Defaults to the install's Burrow agent. It must be on the space's agent roster."
          },
          meeting_id: %{
            type: "string",
            required: false,
            description: "The meeting the question comes from, recorded on the message."
          }
        },
        returns:
          "%{ask_id, agent_id, status: \"pending\", message_id}. `agent_id` is the agent that will answer.",
        limitations:
          "The agent must already be in the space's agent roster: an agent cannot summon another agent into a space. Agent-to-agent wakes are rate-limited (once per agent per space per 30 seconds), so a second ask to the same agent inside that window may never be delivered. The answer is waited for a limited time (60 seconds by default) and then reads as `timeout`.",
        when_to_use:
          "When someone in the meeting asks something that needs Burrow (the install's orchestrator and infra desk) rather than your own knowledge."
      },
      %{
        name: "voice_ask_poll",
        description:
          "Read the answer to a voice_ask_agent question as it streams in. Blocks until the answer text is longer than `since`, the answer is complete, or `wait_ms` passes, then returns the FULL text so far.",
        parameters: %{
          ask_id: %{
            type: "string",
            required: true,
            description: "The ask_id voice_ask_agent returned."
          },
          since: %{
            type: "integer",
            required: false,
            description:
              "How many characters (Unicode code points) of the text you already have. Default 0."
          },
          wait_ms: %{
            type: "integer",
            required: false,
            description:
              "How long to wait for new text, in milliseconds. Default 1500, at most 5000."
          }
        },
        returns:
          "%{ask_id, text, done, status: \"pending\" | \"streaming\" | \"done\" | \"timeout\" | \"unknown\", answered_by, variant}. `text` is the full cumulative answer. `done` is true once nothing more will arrive (status `done` or `timeout`, or `unknown`). `answered_by` is the answering agent's id, never yours.",
        limitations:
          "Only the agent that created the ask may poll it. An ask is forgotten shortly after it finishes; polling it then returns status `unknown`.",
        when_to_use: "Right after voice_ask_agent, in a loop until `done` is true."
      }
    ]
  end
end
