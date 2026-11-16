defmodule Platform.Goals.ToolDefinitions do
  @moduledoc """
  Definitions of the `goals` bundle's agent tools (task 01a1dfc1-05b0,
  Goals 3/8 stage 4), in `Platform.Federation.ToolSurface`'s rubric shape
  (`Platform.Social.ToolDefinitions` is the model). The behaviour lives in
  `Platform.Goals.Tools`.

  Seven tools, every name starting `goal_`: three read (`goal_list`,
  `goal_get`, `goal_wake_up_get`) and four close a wake-up (`goal_do`,
  `goal_ask`, `goal_wait`, `goal_retro`). Every tool is for the goal's coach only.

  ## Grantable, not a default grant

  Like `social` and `play`, `goals` is loadable but absent from the default
  tool profile: an admin grants it per runtime, and `goals.use` gates it.
  """

  @one_outcome "A check-in takes exactly one of goal_do, goal_ask or goal_wait; a retro takes exactly goal_retro; a second close is refused."

  @coach_only "Only the goal's coach may use this: any other goal, seen or not, answers not_found."

  @names ~w(goal_list goal_get goal_wake_up_get goal_do goal_ask goal_wait goal_retro)

  @doc "The sentence every description carries."
  @spec one_outcome() :: String.t()
  def one_outcome, do: @one_outcome

  @doc "Every tool name this bundle defines."
  @spec names() :: [String.t()]
  def names, do: @names

  @prediction %{
    prediction: %{
      type: "string",
      required: true,
      description: "What you expect this to change, in one plain sentence."
    },
    predicted_by: %{
      type: "string",
      required: true,
      description:
        "ISO-8601 date (YYYY-MM-DD) by which the prediction can be judged; after today."
    },
    predicted_change: %{
      type: "string",
      required: false,
      description: "The change in the goal's number you expect, as a decimal string."
    }
  }

  @wake_up_id %{
    type: "string",
    required: true,
    description: "The wake-up to close (from the wake-up prompt or goal_wake_up_get)."
  }

  @closed_result "%{wake_up: %{id, goal_id, status, outcome, closed_at, entry_id}, entry: %{id, kind, title, body, prediction, predicted_by, predicted_change, reading_id, details}, ask: ask or null, task: %{id, title, status} or null}"

  @refusals "Refusals carry a code: wake_up_closed (already closed or marked unanswered), mode_forbids_do, mode_forbids_task, outreach_off, ask_cap_reached, task_cap_reached, project_not_available, addressee_cannot_see_goal, prediction_required, reason_required, invalid (with messages), not_found."

  @doc "The tool definitions, in the ToolSurface rubric shape."
  @spec definitions() :: [map()]
  def definitions do
    [
      %{
        name: "goal_list",
        description:
          "List the goals you coach, with each goal's settings and whether a wake-up is open. " <>
            @one_outcome,
        parameters: %{},
        returns:
          "%{goals: [%{id, title, status, agent_mode, rhythm, outreach, next_wake_at, stalled, open_wake_up_id, open_wake_up_kind}], total}",
        limitations:
          "Only goals whose coach is you; a goal you can merely see as a space participant is not listed.",
        when_to_use: "First, to find the goal_id of a goal you coach."
      },
      %{
        name: "goal_get",
        description:
          "Read one goal you coach: settings, stops, notebook entries, readings, the number, open asks with their answers, tagged tasks and the clock. " <>
            @one_outcome,
        parameters: %{
          goal_id: %{type: "string", required: true, description: "The goal id."},
          entries_limit: %{
            type: "integer",
            required: false,
            description: "Newest notebook entries to return (default 20, maximum 50)."
          },
          readings_limit: %{
            type: "integer",
            required: false,
            description: "Newest readings to return (default 10, maximum 50)."
          }
        },
        returns:
          "%{goal, stops, entries, readings, number_status (reading or cannot_measure), number (for cannot_measure only %{reason, source_key, source_label}, never a value), asks, tasks, clock}",
        limitations:
          @coach_only <>
            " When the number cannot be measured no value is returned; do not state or estimate one.",
        when_to_use: "Before closing a wake-up, to see what the goal has done so far."
      },
      %{
        name: "goal_wake_up_get",
        description:
          "Read a wake-up of a goal you coach: its status, respond_by, briefing and which outcomes are allowed now. " <>
            @one_outcome,
        parameters: %{
          wake_up_id: %{
            type: "string",
            required: false,
            description: "The wake-up id. Send this or goal_id."
          },
          goal_id: %{
            type: "string",
            required: false,
            description: "A goal you coach; returns its open wake-up."
          }
        },
        returns:
          "%{wake_up: %{id, goal_id, kind, status, outcome, due_at, respond_by, closed_at}, briefing, text, allowed: %{do, do_with_task, ask, wait, retro} each true or the refusal code that applies now}",
        limitations:
          @coach_only <>
            " With goal_id and no open wake-up, answers no_open_wake_up.",
        when_to_use: "When woken, before choosing between goal_do, goal_ask and goal_wait."
      },
      %{
        name: "goal_do",
        description:
          "Close a wake-up by recording an action you took or started, optionally creating one task tagged to the goal. " <>
            @one_outcome,
        parameters:
          Map.merge(@prediction, %{
            wake_up_id: @wake_up_id,
            title: %{type: "string", required: true, description: "What you did."},
            body: %{type: "string", required: false, description: "Detail of the action."},
            sources: %{
              type: "array",
              required: false,
              description: "Sources you relied on, as objects.",
              schema: %{type: "array", items: %{type: "object"}}
            },
            undo_note: %{
              type: "string",
              required: false,
              description: "How a person could undo the action."
            },
            task: %{
              type: "object",
              required: false,
              description:
                "One task to create, tagged to the goal: %{project_id, title, description, kind?, priority?}. Not allowed for advise or coach goals."
            }
          }),
        returns: @closed_result,
        limitations:
          @coach_only <>
            " Advise goals refuse goal_do; coach goals refuse a task. " <> @refusals,
        when_to_use: "When the goal's mode lets you act and an action is due."
      },
      %{
        name: "goal_ask",
        description:
          "Close a wake-up by queueing a question, offer or practice for a person's next brief. " <>
            @one_outcome,
        parameters:
          Map.merge(@prediction, %{
            wake_up_id: @wake_up_id,
            kind: %{
              type: "string",
              required: true,
              description: "question, offer or practice.",
              enum: ~w(question offer practice)
            },
            title: %{type: "string", required: true, description: "The ask, short."},
            body: %{type: "string", required: false, description: "Detail of the ask."},
            payload: %{
              type: "object",
              required: false,
              description:
                "Question: moved [{direction: up|flat|down, text}], suggestions [{title, why?, takeaway_id?}]. " <>
                  "Offer: draft or url, optionally idea {why, measure, steps: [text], takeaway_id?}. " <>
                  "Practice: cards [{front, back}]. Idea steps and practice cards must be nonempty."
            },
            addressed_user_ids: %{
              type: "array",
              required: false,
              description: "People to ask (default: the goal's owner). Each must see the goal.",
              schema: %{type: "array", items: %{type: "string"}}
            }
          }),
        returns: @closed_result,
        limitations:
          @coach_only <>
            " Outreach off refuses every ask; gentle allows one open ask, pushy three. " <>
            @refusals,
        when_to_use: "When a person's input is what moves the goal next."
      },
      %{
        name: "goal_wait",
        description:
          "Close a wake-up by recording that nothing is due, and why. " <> @one_outcome,
        parameters:
          Map.merge(
            Map.new(@prediction, fn {k, v} -> {k, %{v | required: false}} end),
            %{
              wake_up_id: @wake_up_id,
              reason: %{type: "string", required: true, description: "Why nothing is due now."},
              until: %{
                type: "string",
                required: false,
                description: "ISO-8601 date until which you expect to wait."
              }
            }
          ),
        returns: @closed_result,
        limitations: @coach_only <> " " <> @refusals,
        when_to_use: "When no action or ask is due at this check-in."
      },
      %{
        name: "goal_retro",
        description:
          "Close a retro with what happened and what comes next. Verdicts come from the stored wake-up and cannot be supplied. " <>
            @one_outcome,
        parameters: %{
          wake_up_id: @wake_up_id,
          title: %{
            type: "string",
            required: true,
            description: "Retro title, non-blank, at most 200 characters."
          },
          summary: %{
            type: "string",
            required: true,
            description: "What happened, non-blank; the notebook body."
          },
          worked: %{
            type: "array",
            required: false,
            description:
              "Up to max_retro_rows maps: non-blank label, optional percent (0..100), optional note."
          },
          didnt_work: %{
            type: "array",
            required: false,
            description: "Up to max_retro_rows maps with non-blank text."
          },
          dropped: %{
            type: "array",
            required: false,
            description:
              "Up to max_retro_rows maps: entry_id of an action in this goal, optional reason."
          },
          learned: %{
            type: "array",
            required: false,
            description: "Up to max_retro_rows non-blank strings."
          },
          next_push: %{
            type: "object",
            required: false,
            description:
              "Non-blank title and suggestions (up to max_retro_rows maps: tag keep|start|stop, non-blank title, optional why and takeaway_id of this goal)."
          },
          stop_id: %{
            type: "string",
            required: false,
            description: "Optional stop of this goal being reviewed."
          },
          check_in_change: %{
            type: "object",
            required: false,
            description:
              "Proposal: summary (non-blank, at most 500), set with one or more rhythm, rhythm_weekday, outreach, retro_every; must differ from current settings."
          },
          goal_change: %{
            type: "object",
            required: false,
            description:
              "Proposal: summary (non-blank, at most 500), kind target|scope|end, set: target exactly {target_value: number}; scope title and/or why; end exactly {status: finished}. Must differ from current settings."
          }
        },
        returns:
          "%{wake_up: %{id, goal_id, kind, status, outcome, closed_at, entry_id}, entry: %{id, kind, title, body, reading_id, details}}",
        limitations:
          @coach_only <>
            " Send at most one change proposal. When the stored retro requires a goal change, goal_change is required and check_in_change is refused. Verdicts and window cannot be supplied. Shape and rule refusals are recoverable; wake_up_closed and not_found are final.",
        when_to_use: "When goal_wake_up_get reports kind retro; this is its only closing tool."
      }
    ]
  end
end
