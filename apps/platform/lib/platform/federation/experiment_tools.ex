defmodule Platform.Federation.ExperimentTools do
  @moduledoc """
  Definitions of the `experiments` bundle's agent tools (task 01a0d415
  stage 2, the experimentation-layer ADR-0052). Mirrors
  `Platform.Federation.MailDraftTools`: the definitions live here, the
  behaviour lives in `Platform.Experiments.Tools`, and
  `Platform.Federation.ToolSurface` carries only the bundle entry, one
  `tools_for_bundle/1` clause and one prefix `execute/3` clause.

  ## The bundle is NOT a default grant

  `experiments` is deliberately absent from
  `Platform.Agents.AgentRuntime`'s `@default_allowed_bundles`. Holding it is
  the first guardrail: only a runtime an admin granted `experiments` can see
  or call these tools, and `Platform.Federation.ToolAuthorization` refuses a
  call from any other runtime before `execute/3` runs. The Scientist's
  runtime therefore needs this grant, or every tool here is refused.

  There is no send tool, no delete tool, no un-exclude tool and no approval
  tool in this bundle. Launch approval (`Platform.Experiments.approve_launch/2`)
  takes a human user and has no agent form.
  """

  @create_keys ~w(surface_key surface_target name slug hypothesis goal_id metric_spec
                  assignment_policy org_id project_id signal_source
                  observation_window_days stop_rule)

  @doc "The fields `experiment_create` reads; everything else in `args` is ignored."
  @spec arg_keys() :: [String.t()]
  def arg_keys, do: @create_keys

  @doc "The tool definitions, in the ToolSurface rubric shape."
  @spec definitions() :: [map()]
  def definitions do
    [
      %{
        name: "experiment_surface_list",
        description:
          "List the decision points (surfaces) an experiment can vary, with the payload shape each arm must carry. A surface is declared once in code; every experiment on it is data.",
        parameters: %{},
        returns:
          "%{surfaces: [%{key, subject_type, path, payload_schema, targets}], total, has_more} — `total` is the number of registered surfaces returned (this tool has no limit and returns every match); `has_more` is always false here. A server-side payload cap that drops records sets `has_more` to true. path is \"dispatch\" or \"draft\"; there is never a send path. targets is the list of surface_target values the surface is resolved at, or null when any target is accepted (dispatch.prompt: any template slug).",
        limitations:
          "Lists registered surfaces only. A surface not listed here cannot be experimented on and cannot be allowed in guardrails.",
        when_to_use: "Before experiment_create, to pick a surface_key and shape variant payloads."
      },
      %{
        name: "experiment_list",
        description:
          "List experiments you can see, newest first, with status, approval state, tenancy columns and any human stop feedback. Stopped and concluded experiments are both listed and are different statuses.",
        parameters: %{
          status: %{
            type: "string",
            required: false,
            description: "Filter: draft | running | stopped | concluded."
          },
          org_id: %{type: "string", required: false, description: "Filter by org UUID."},
          project_id: %{type: "string", required: false, description: "Filter by project UUID."},
          limit: %{
            type: "integer",
            required: false,
            description: "Max rows, default 50, clamped to 200."
          }
        },
        returns:
          "%{count, limit, total, has_more, experiments: [experiment]} — `count` is the number RETURNED; `total` is the number of experiments matching the filters that the caller may see (same org scope as the rows), counted independent of `limit`; `has_more` is true exactly when matching experiments exist beyond the ones returned. Each experiment carries id, slug, name, status, approval_state, surface_key, surface_target, org_id, project_id, goal_id, stop_feedback, stopped_by_user_id, stopped_at.",
        limitations:
          "A tenant-pinned agent sees its own org's experiments and install-wide ones (org_id null), never a sibling org's. Read `has_more`, not `count == limit`, to tell a truncated list from a complete one.",
        when_to_use:
          "To see what is live, what is awaiting approval, and what a human stopped and why before proposing the next experiment."
      },
      %{
        name: "experiment_get",
        description:
          "Read one experiment in full: its design (surface, metric_spec, assignment_policy, signal_source, observation window, stop rule), its variants and payloads, its approval state and, when a human stopped it, their feedback.",
        parameters: %{
          experiment_id: %{type: "string", required: true, description: "Experiment UUID."}
        },
        returns:
          "%{experiment: experiment with variants: [%{slug, weight, payload}]} — stop_feedback is the stopping person's own words, or null.",
        limitations:
          "Not-found for an unknown id and for a sibling org's experiment (existence is not disclosed).",
        when_to_use:
          "Before starting, stopping or promoting an experiment, or to read stop feedback."
      },
      %{
        name: "experiment_create",
        description:
          "Create an experiment as a DRAFT on a registered surface. The status is always draft whatever you pass; nothing is assigned until experiment_start launches it. Add treatment arms with experiment_variant_add; the control arm is captured at start.",
        parameters: %{
          surface_key: %{
            type: "string",
            required: true,
            description: "A key from experiment_surface_list, e.g. \"dispatch.prompt\"."
          },
          surface_target: %{
            type: "string",
            required: true,
            description:
              "What on the surface is varied — for dispatch.prompt, a prompt template slug. For a surface that lists `targets` in experiment_surface_list, one of those (mail.draft.generator: \"dispatch.in_progress\"; planner.stage_budget: \"dispatch.planning\"); any other is refused."
          },
          name: %{type: "string", required: true, description: "Human-readable name."},
          slug: %{
            type: "string",
            required: false,
            description: "Unique slug. Generated from name when omitted."
          },
          hypothesis: %{type: "string", required: false, description: "What you expect and why."},
          goal_id: %{
            type: "string",
            required: false,
            description: "UUID of the experiment goal (experiment_goal_set) this serves."
          },
          metric_spec: %{
            type: "object",
            required: false,
            description:
              "How the result is measured, e.g. {kind: \"outcome_rate\", labels: [\"screen\"], window_days: 14} or {kind: \"registered\", slug: \"stages_per_plan\"}. An unknown kind or bad parameter is refused."
          },
          assignment_policy: %{
            type: "object",
            required: false,
            description:
              "Which subjects are eligible, as data over the existing policies (task_cohort, epic_scoped, time_window, random_buckets, composite, exclude)."
          },
          org_id: %{
            type: "string",
            required: false,
            description:
              "Org UUID the experiment is for. Derived from project_id when omitted. Null means install-wide, which only an unpinned runtime may create."
          },
          project_id: %{
            type: "string",
            required: false,
            description: "Project UUID. Must belong to org_id when both are given."
          },
          signal_source: %{
            type: "object",
            required: false,
            description: "Where outcome signals come from, e.g. {kind: \"mail_inbound\", ...}."
          },
          observation_window_days: %{
            type: "integer",
            required: false,
            description:
              "Subjects younger than this are counted as pending, never as non-responses."
          },
          stop_rule: %{
            type: "object",
            required: false,
            description:
              "e.g. {min_subjects: 30}. No figure is reported as earned below it, and it cannot be promoted below it."
          }
        },
        returns: "%{experiment: experiment} with status \"draft\".",
        limitations:
          "Refused when the surface is not registered or not in the org's allowed_surfaces (code surface_not_allowed), when a tenant-pinned agent names another org or an install-wide scope (unauthorized), or when a spec does not validate (errors listed per field). Nothing is written on refusal.",
        when_to_use: "When you have a hypothesis for a goal and a surface to test it on."
      },
      %{
        name: "experiment_variant_add",
        description:
          "Add a treatment arm to a DRAFT experiment. The payload is validated against the surface's payload_schema and any errors are returned verbatim. The slug \"control\" is reserved: the control is captured at start.",
        parameters: %{
          experiment_id: %{type: "string", required: true, description: "Experiment UUID."},
          slug: %{type: "string", required: true, description: "Arm slug, unique per experiment."},
          payload: %{
            type: "object",
            required: true,
            description:
              "The arm, in the surface's payload shape. For dispatch.prompt: {content: <the FULL prompt body>}."
          },
          weight: %{
            type: "integer",
            required: false,
            description: "Relative traffic weight, default 1."
          }
        },
        returns: "%{variant: %{slug, weight, payload}}",
        limitations:
          "Only while the experiment is a draft (arms are fixed once it runs). Refused for slug \"control\", a duplicate slug, or an invalid payload (errors listed).",
        when_to_use: "After experiment_create, once per treatment arm, before experiment_start."
      },
      %{
        name: "experiment_start",
        description:
          "Launch a draft experiment under the org's guardrails. Captures the control arm, then either starts it running or, when the org requires human launch approval, marks it pending approval and returns without running it. Pending is success, not a failure to retry.",
        parameters: %{
          experiment_id: %{type: "string", required: true, description: "Experiment UUID."}
        },
        returns: "%{result: \"running\" | \"pending_human_approval\", experiment: experiment}",
        limitations:
          "Refused with a structured refusal (refusal: %{code, limit, current, surface}) for surface_not_allowed, max_live_reached (limit = the org's max_live, current = running experiments in that org) or surface_busy (another running experiment on the same surface and target whose org/project overlaps). Refused when the experiment is not a draft. You cannot approve a launch: only a person can, in the UI.",
        when_to_use: "When the draft has its arms and you want it to start assigning subjects."
      },
      %{
        name: "experiment_stop",
        description:
          "Stop an experiment. Stopped is NOT concluded: it means halted, and both stay visible. Subjects already assigned keep their arm. Optionally record why.",
        parameters: %{
          experiment_id: %{type: "string", required: true, description: "Experiment UUID."},
          feedback: %{
            type: "string",
            required: false,
            description: "Why it is being stopped (max 4000 chars). Stored as stop_feedback."
          }
        },
        returns:
          "%{experiment: experiment} with status \"stopped\", stopped_at set, stopped_by_user_id null (an agent stop).",
        limitations:
          "Refused for an experiment already stopped or concluded. There is no tool that turns stopped into concluded or back.",
        when_to_use:
          "When an experiment is harming outcomes, is confounded, or can no longer answer its question."
      },
      %{
        name: "experiment_conclude",
        description:
          "Conclude a RUNNING experiment: it ran to its end and was decided. Different from experiment_stop.",
        parameters: %{
          experiment_id: %{type: "string", required: true, description: "Experiment UUID."}
        },
        returns: "%{experiment: experiment} with status \"concluded\".",
        limitations:
          "Only a running experiment can be concluded; a stopped experiment stays stopped.",
        when_to_use: "When the stop rule is met and the result has been read and acted on."
      },
      %{
        name: "experiment_results",
        description:
          "Read each arm's result. Every figure travels with its sample size n; value is null whenever the data does not support a figure, and is never 0.0 for missing data.",
        parameters: %{
          experiment_id: %{type: "string", required: true, description: "Experiment UUID."}
        },
        returns:
          "%{experiment_id, rows: [%{variant_slug, value, n, pending, excluded, subjects, min_subjects, reason}]} — reason is measured | insufficient_data | below_stop_rule | no_stop_rule | no_metric; value is null unless reason is measured. pending counts subjects still inside the observation window: not yet, not a non-response.",
        limitations:
          "No comparison between arms, no lift and no projection is computed. insufficient_data means not yet, not no effect.",
        when_to_use: "Before deciding to stop, conclude or promote."
      },
      %{
        name: "experiment_signals_list",
        description:
          "List the labelled outcome signals recorded for an experiment: the label, the subject it was matched to, the labeler's confidence and its short reason. Never the source content.",
        parameters: %{
          experiment_id: %{type: "string", required: true, description: "Experiment UUID."},
          status: %{
            type: "string",
            required: false,
            description: "Filter: labelled | unlabelled | rejected_output."
          }
        },
        returns:
          "%{count, total, has_more, signals: [%{label, subject_id, confidence, reason, status}]} — `count` and `total` are both the number of signals returned (every match); `has_more` is always false here unless a server-side payload cap dropped records.",
        limitations:
          "Returns those five fields only. subject_id is null for a signal that matched no subject; such rows are recorded, not dropped.",
        when_to_use: "To see what outcomes the results are built from."
      },
      %{
        name: "experiment_exclude",
        description:
          "Exclude one assigned subject from an experiment's analysis, with a reason. The assignment row stays, with its arm and the reason, and is never deleted.",
        parameters: %{
          experiment_id: %{type: "string", required: true, description: "Experiment UUID."},
          subject_id: %{type: "string", required: true, description: "The subject's UUID."},
          subject_type: %{
            type: "string",
            required: false,
            description: "Subject type, default \"task\"."
          },
          reason: %{
            type: "string",
            required: true,
            description: "Why it is excluded (required, max 500 chars)."
          }
        },
        returns: "%{assignment: %{subject_type, subject_id, variant_slug, excluded_reason}}",
        limitations:
          "There is no un-exclude and no delete. Refused for a subject that was never assigned.",
        when_to_use:
          "When a subject's outcome is contaminated by something the experiment did not vary."
      },
      %{
        name: "experiment_goal_set",
        description:
          "Create a standing goal experiments are proposed against, or update one you can write by passing goal_id.",
        parameters: %{
          goal_id: %{
            type: "string",
            required: false,
            description: "UUID of an existing goal to update. Omit to create."
          },
          statement: %{
            type: "string",
            required: false,
            description: "The goal in plain words. Required on create."
          },
          metric_spec: %{
            type: "object",
            required: false,
            description: "How progress on the goal is measured (same shape as experiment_create)."
          },
          status: %{
            type: "string",
            required: false,
            description: "active | paused | retired. Default active."
          },
          org_id: %{
            type: "string",
            required: false,
            description: "Org UUID; derived from project_id when omitted."
          },
          project_id: %{type: "string", required: false, description: "Project UUID."}
        },
        returns: "%{goal: %{id, statement, metric_spec, status, org_id, project_id}}",
        limitations:
          "Same tenancy rule as experiment_create: a tenant-pinned agent writes only in its own org, and only an unpinned runtime writes an install-wide goal.",
        when_to_use: "When a person has told you what outcome to pursue."
      },
      %{
        name: "experiment_goal_list",
        description: "List experiment goals you can see.",
        parameters: %{
          status: %{
            type: "string",
            required: false,
            description: "Filter: active | paused | retired."
          },
          org_id: %{type: "string", required: false, description: "Filter by org UUID."}
        },
        returns:
          "%{count, total, has_more, goals: [%{id, statement, metric_spec, status, org_id, project_id}]} — at most 200 goals, newest first. `count` is the number RETURNED; `total` is the number of goals matching the filters that the caller may see, counted independent of the 200 cap; `has_more` is true exactly when the cap cut matching goals.",
        limitations: "A tenant-pinned agent sees its own org's goals and install-wide ones.",
        when_to_use: "At the start of each pass, to know what you are working towards."
      },
      %{
        name: "experiment_promote",
        description:
          "Promote a winning arm so it becomes the default for NEW subjects. For dispatch.prompt it rewrites the template (with a snapshot); for other surfaces it appends a default-history row. Subjects already assigned keep their arm.",
        parameters: %{
          experiment_id: %{type: "string", required: true, description: "Experiment UUID."},
          variant: %{type: "string", required: true, description: "Slug of the winning arm."}
        },
        returns:
          "%{promoted: true, surface_key, seq | template_slug} — seq for a non-prompt surface's history row.",
        limitations:
          "Refused unless the org's guardrails allow auto-promotion (code auto_promote_disabled), and ALWAYS refused for any mail.* surface (surface_not_promotable). Then refused below the stop rule (insufficient_data), inside the 14-day cooldown (cooldown_active, with available_from), or on a concurrent promotion (concurrent_promotion). There is no override for agents.",
        when_to_use: "When an arm has earned a figure that beats control and the org allows it."
      }
    ]
  end
end
