defmodule Platform.Goals.ToolDefinitions do
  @moduledoc """
  Definitions of the `goals` bundle's agent tools (task 01a1dfc1-05b0,
  Goals 3/8 stage 4), in `Platform.Federation.ToolSurface`'s rubric shape
  (`Platform.Social.ToolDefinitions` is the model). The behaviour lives in
  `Platform.Goals.Tools`.

  Ten tools, every name starting `goal_`: three read (`goal_list`,
  `goal_get`, `goal_wake_up_get`), four close a wake-up (`goal_do`,
  `goal_ask`, `goal_wait`, `goal_retro`), and three added by Goals 5/8 (task
  01a1dfc1-7625): `goal_takeaway_add` records a research finding, and
  `goal_proposal_get` / `goal_propose` work a New goal conversation. The
  goal-scoped tools are for the goal's coach only; the proposal tools are for
  the agent a person started the conversation with. No tool creates a goal:
  only the person's own click does.

  ## Grantable, not a default grant

  Like `social` and `play`, `goals` is loadable but absent from the default
  tool profile: an admin grants it per runtime, and `goals.use` gates it.
  """

  @no_connected_source "No connected number source exists yet: offer a source from sources, normally \"self_reported\", where the person enters the number by hand."

  @proposal_only "Only a conversation a person started with you; any other id, seen or not, answers not_found. You cannot start one or name the person."

  @one_outcome "A check-in takes exactly one of goal_do, goal_ask or goal_wait; a retro takes exactly goal_retro; a second close is refused."

  @coach_only "Only the goal's coach may use this: any other goal, seen or not, answers not_found."

  @names ~w(goal_list goal_get goal_wake_up_get goal_do goal_ask goal_wait goal_retro
             goal_takeaway_add goal_proposal_get goal_propose)

  @takeaway_id %{
    type: "string",
    required: false,
    description:
      "The takeaway of this goal the suggestion came from (an entry of kind takeaway, from goal_get)."
  }

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

  @closed_result "%{wake_up: %{id, goal_id, status, outcome, closed_at, entry_id}, entry: %{id, kind, title, body, prediction, predicted_by, predicted_change, reading_id, details}, ask: ask or null, task: %{id, title, status, assignee_agent_id} or null (the first task), tasks: [%{id, title, status, assignee_agent_id}]}"

  @refusals "Refusals carry a code: wake_up_closed (already closed or marked unanswered), mode_forbids_do, mode_forbids_task, outreach_off, ask_cap_reached, task_cap_reached, too_many_tasks, project_not_available, assignee_not_available, addressee_cannot_see_goal, prediction_required, reason_required, invalid (with messages), not_found."

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
          "Read one goal you coach: settings, stops, notebook entries, readings, the number, open asks with their answers, tagged tasks with their assignees, the contributor agents you may give tasks to, and the clock. " <>
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
          "%{goal, stops, entries, readings, number_status (reading or cannot_measure), number (for cannot_measure only %{reason, source_key, source_label}, never a value), asks, tasks (each with assignee_agent_id and assignee_name), contributors: [%{agent_id, name, space_id, space_name}], clock}",
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
          "%{wake_up: %{id, goal_id, kind, status, outcome, due_at, respond_by, closed_at}, briefing, text, allowed: %{do, do_with_task, assign, ask, wait, retro} each true or the refusal code that applies now (assign: mode_forbids_do, mode_forbids_task, no_contributors or task_cap_reached)}",
        limitations:
          @coach_only <>
            " With goal_id and no open wake-up, answers no_open_wake_up.",
        when_to_use: "When woken, before choosing between goal_do, goal_ask and goal_wait."
      },
      %{
        name: "goal_do",
        description:
          "Close a wake-up by recording an action you took or started, optionally creating up to #{Platform.Goals.Limits.max_tasks_per_wake_up()} tasks tagged to the goal, each for you or a contributor agent. " <>
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
            takeaway_id: @takeaway_id,
            task: %{
              type: "object",
              required: false,
              schema: %{
                oneOf: [
                  %{type: "object"},
                  %{
                    type: "array",
                    items: %{type: "object"},
                    minItems: 1,
                    maxItems: Platform.Goals.Limits.max_tasks_per_wake_up()
                  }
                ]
              },
              description:
                "One task, or an array of 1 to #{Platform.Goals.Limits.max_tasks_per_wake_up()} tasks, to create tagged to the goal: %{project_id, title, description, kind?, priority?, assignee_agent_id?}; assignee_agent_id is a contributor goal_wake_up_get lists, and absent means you. Not allowed for advise or coach goals."
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
            },
            takeaway_id: @takeaway_id
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
      },
      %{
        name: "goal_takeaway_add",
        description:
          "Record a research finding (a takeaway) on a goal you coach. It shows under \"What we've learned\" on the goal page, with its sources.",
        parameters: %{
          goal_id: %{type: "string", required: true, description: "A goal you coach."},
          title: %{type: "string", required: true, description: "The finding, in one line."},
          body: %{type: "string", required: true, description: "A short read: what was found."},
          sources: %{
            type: "array",
            required: true,
            description:
              "Where it comes from: at least one and at most 8 objects, each with a non-blank name and an optional url.",
            schema: %{type: "array", items: %{type: "object"}}
          },
          doing: %{
            type: "string",
            required: false,
            description: "One sentence for \"What we're doing about it\"."
          }
        },
        returns: "%{entry: %{id, kind, title, body, sources, details, occurred_at}}",
        limitations:
          @coach_only <>
            " A finding without a named source is refused with code source_required; a goal holds at most 20 takeaways (takeaway_cap_reached).",
        when_to_use:
          "After a person confirms a new goal, and whenever research turns up something worth steering by. Cite it later with takeaway_id on goal_do or goal_ask."
      },
      %{
        name: "goal_proposal_get",
        description:
          "Read the New goal conversations people started with you. Without proposal_id: the open ones. With proposal_id: what is settled so far, the person's name, the number sources and the allowed values. " <>
            @no_connected_source,
        parameters: %{
          proposal_id: %{
            type: "string",
            required: false,
            description: "A conversation id (from the start signal or the list)."
          }
        },
        returns:
          "Without id: %{conversations: [%{id, space_id, started_at, ready}], total}. With id: %{id, space_id, status, revision, draft, replies, settled, ready, expires_at, person: %{user_id, name}, sources: [%{key, label, kind}], allowed: %{agent_mode, rhythm, outreach, kind}}",
        limitations: @proposal_only,
        when_to_use:
          "When a person starts a New goal conversation with you, and before each goal_propose."
      },
      %{
        name: "goal_propose",
        description:
          "Record what you and the person have settled in a New goal conversation. This records a proposal the person sees; it creates nothing. The goal is created only when the person presses Create goal. " <>
            "Settle each of the four settings (number source, your part, rhythm, nudges) by asking in the conversation and offering your suggested default as the first reply. " <>
            "Never ask the person for a goal type. " <> @no_connected_source,
        parameters: %{
          proposal_id: %{type: "string", required: true, description: "The conversation id."},
          title: %{type: "string", required: false, description: "The goal, in one line."},
          why: %{type: "string", required: false, description: "Why it matters to them."},
          unit: %{type: "string", required: false, description: "What the number counts."},
          target_value: %{
            type: "string",
            required: false,
            description: "The final target, as a decimal string."
          },
          stops: %{
            type: "array",
            required: false,
            description:
              "The journey, in order, at most 12: objects with label, target_value, due_on (YYYY-MM-DD), caption, theme, criteria. Replaces the whole list.",
            schema: %{type: "array", items: %{type: "object"}}
          },
          source_key: %{
            type: "string",
            required: false,
            description:
              "A key from goal_proposal_get's sources, or null for no number yet. Normally self_reported."
          },
          source_settings: %{
            type: "object",
            required: false,
            description: "Settings for the source, if it takes any."
          },
          agent_mode: %{
            type: "string",
            required: false,
            description: "Your part: do, advise or coach.",
            enum: Platform.Goals.Goal.agent_modes()
          },
          rhythm: %{
            type: "string",
            required: false,
            description: "How often you check in.",
            enum: Platform.Goals.Goal.rhythms()
          },
          rhythm_weekday: %{
            type: "integer",
            required: false,
            description: "1 (Monday) to 7, for a weekly or biweekly rhythm."
          },
          outreach: %{
            type: "string",
            required: false,
            description: "How much you nudge.",
            enum: Platform.Goals.Goal.outreaches()
          },
          kind: %{
            type: "string",
            required: false,
            description:
              "Your suggestion only (default personal): a new goal is always created personal; shared only changes a line on the person's screen.",
            enum: Platform.Goals.Goal.kinds()
          },
          replies: %{
            type: "array",
            required: false,
            description:
              "Up to four short answers (at most 40 characters each) the person can tap under your latest message. Replaces the list.",
            schema: %{type: "array", items: %{type: "string"}}
          },
          ready: %{
            type: "boolean",
            required: false,
            description:
              "True when the summary is ready for the person: needs title, agent_mode, rhythm, outreach, and rhythm_weekday for weekly or biweekly."
          }
        },
        returns:
          "%{id, space_id, status, revision, draft, replies, settled, ready, expires_at}: revision rises by one on every call.",
        limitations:
          @proposal_only <>
            " Absent keys are left alone. Refusals: proposal_closed (final), unknown_source, proposal_incomplete (names what is missing), invalid (with messages); nothing is written.",
        when_to_use:
          "Each time the conversation settles something, and with ready true when the summary is complete."
      }
    ]
  end
end
