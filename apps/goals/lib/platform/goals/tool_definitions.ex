defmodule Platform.Goals.ToolDefinitions do
  @moduledoc """
  Definitions of the `goals` bundle's agent tools (task 01a1dfc1-05b0,
  Goals 3/8 stage 4), in `Platform.Federation.ToolSurface`'s rubric shape
  (`Platform.Social.ToolDefinitions` is the model). The behaviour lives in
  `Platform.Goals.Tools`.

  Six tools, every name starting `goal_`: three read (`goal_list`,
  `goal_get`, `goal_wake_up_get`) and three close a wake-up (`goal_do`,
  `goal_ask`, `goal_wait`). Every tool is for the goal's coach only.

  ## Grantable, not a default grant

  Like `social` and `play`, `goals` is loadable but absent from the default
  tool profile: an admin grants it per runtime, and `goals.use` gates it.
  """

  @one_outcome "A wake-up takes exactly one of goal_do, goal_ask or goal_wait; a second close is refused."

  @coach_only "Only the goal's coach may use this: any other goal, seen or not, answers not_found."

  @names ~w(goal_list goal_get goal_wake_up_get goal_do goal_ask goal_wait)

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
          "%{goals: [%{id, title, status, agent_mode, rhythm, outreach, next_wake_at, stalled, open_wake_up_id}], total}",
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
          "%{wake_up: %{id, goal_id, status, outcome, due_at, respond_by, closed_at}, briefing, text, allowed: %{do, do_with_task, ask, wait} each true or the refusal code that applies now}",
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
              description: "Kind-specific payload (practice takes cards)."
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
      }
    ]
  end
end
