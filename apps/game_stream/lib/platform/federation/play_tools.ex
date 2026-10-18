defmodule Platform.Federation.PlayTools do
  @moduledoc """
  Definitions of the `play` bundle's agent tools (task 01a0db5f stage 2,
  playable review builds). Mirrors `Platform.Federation.ExperimentTools`:
  the definitions live here, the behaviour lives in
  `Platform.GameStream.Tools`, and `Platform.Federation.ToolSurface` carries
  only the bundle entry, one `tools_for_bundle/1` clause and one prefix
  `execute/3` clause.

  ## Listed only while `GAME_STREAM_ENABLED` is set

  `definitions/0` returns `[]` with the flag off, so a runtime granted
  `play` sees no tool from this bundle and `ToolSurface.tool_definitions/0`
  is exactly main's. A direct `ToolSurface.execute("play_session_" <> _, …)`
  with the flag off returns the structured `game_stream_disabled` refusal
  before anything else runs; over either transport the same refusal text is
  what `ToolAuthorization.deny_message/1` reports for these names.

  ## The bundle is NOT a default grant

  `play` is grantable (`AgentRuntime.valid_bundles/0`) but absent from
  `@default_allowed_bundles`: it drives a physical GPU on the operator's LAN
  machine, so only a runtime an admin deliberately granted it can see or
  call these tools.
  """

  @names ~w(play_session_start play_session_stop play_session_status)

  @doc "Every tool name this bundle defines, whether or not the flag is on."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc "The structured refusal every `play_session_*` call gets while the flag is off."
  @spec disabled_error() :: map()
  def disabled_error do
    %{
      error: "game_stream is disabled: GAME_STREAM_ENABLED is unset",
      code: :game_stream_disabled,
      recoverable: false,
      suggestion:
        "Playable review builds are off on this install. An operator enables them by " <>
          "setting GAME_STREAM_ENABLED=true."
    }
  end

  @doc "The tool definitions, in the ToolSurface rubric shape; `[]` while the flag is off."
  @spec definitions() :: [map()]
  def definitions do
    if Platform.GameStream.enabled?(), do: all_definitions(), else: []
  end

  @doc false
  # The definitions regardless of the flag, for tests that pin their shape.
  def all_definitions do
    [
      %{
        name: "play_session_start",
        description:
          "Start a playable review build of a task: the play host checks out the EXACT tip sha of the task's review branch, builds it and streams it into a game_stream canvas in the task's execution space. The canvas is created and attached to the task for you.",
        parameters: %{
          task_id: %{
            type: "string",
            required: true,
            description: "UUID of a task in status in_review whose branch has been pushed."
          },
          idle_timeout_s: %{
            type: "integer",
            required: false,
            description:
              "Seconds without input before the host ends the session (default 600, clamped 60..3600)."
          },
          force_relay: %{
            type: "boolean",
            required: false,
            description:
              "When true the viewer connects through TURN only (iceTransportPolicy relay), so a viewer on the LAN can measure the relayed path. Default false. Has no effect beyond failing to connect when no TURN server is configured."
          }
        },
        returns:
          "%{session_id, canvas_id, view_url, review_sha, branch, state} — review_sha is the full 40-hex commit being built; state starts at \"building\". canvas_id/view_url are null (with canvas_error) if the canvas could not be created or attached; the session still runs.",
        limitations:
          "Refused with not_in_review unless the task is in_review, and with no_review_branch when its branch does not exist — it NEVER falls back to main. no_play_host when no play host is connected; host_busy when the host is already running a session (one at a time in v1).",
        when_to_use:
          "When a human wants to play a game task's review build, or to check that the build runs, before approving it."
      },
      %{
        name: "play_session_stop",
        description:
          "Stop a play session: the host kills the game it launched and the session ends.",
        parameters: %{
          session_id: %{type: "string", required: true, description: "The session id."}
        },
        returns:
          "%{session_id, state, ended_reason} — state is \"ended\" (or the terminal state it already had).",
        limitations:
          "Not-found for an unknown session and for one that ended more than a minute ago.",
        when_to_use: "When play is finished, or before starting a session for a different task."
      },
      %{
        name: "play_session_status",
        description:
          "Read a play session's state (building, connecting, live, ended, failed), its detail line and the commit it builds.",
        parameters: %{
          session_id: %{type: "string", required: true, description: "The session id."}
        },
        returns:
          "%{session_id, task_id, state, detail, elapsed_ms, review_sha, branch, ended_reason}",
        limitations:
          "Live state is in memory: a core restart ends every session, and an ended session is readable for about a minute.",
        when_to_use: "To follow a session you started, or to explain a failed one."
      }
    ]
  end
end
