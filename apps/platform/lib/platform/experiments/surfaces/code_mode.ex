defmodule Platform.Experiments.Surfaces.CodeMode do
  @moduledoc """
  The `dispatch.code_mode` surface: whether a task's dispatches are told to
  work through `suite_run` (one script calling many Burrow tools) or through
  direct, one-at-a-time tool calls. Task 01a114a8 stage 4.

  ## What it varies, and what it does not

  It varies the DIRECTIVE text appended to the planning, in_progress and
  review dispatch prompts (`HeartbeatScheduler.append_experiment_directive/5`).
  It does not grant the `code_mode` bundle: that is a per-runtime
  `tool_profile` entry, set as data in Control Center. A treatment-arm
  dispatch to a runtime without the grant is told to use a tool it cannot
  call, so the rollout grants the bundle to every enrolled runtime first.

  ## Both arms render text, on purpose

  Unlike `planner.stage_budget` and `mail.draft.generator`, whose control
  payload renders nil, the control arm here renders a one-line "do not call
  suite_run on this task". An enrolled runtime HAS the bundle, so without the
  line a control-arm agent could still choose suite_run, and the arm would
  measure the agent's preference rather than the condition. With the line,
  a control-arm suite_run call is a measurable violation
  (`code_mode_report`'s `control_suite_run_violations`), not ambiguity.

  A task NO experiment applies to (`:none`, e.g. a non-cohort agent's task)
  still gets no block at all, so its prompt is byte-identical to a render
  with no experiment.

  ## Assignment

  The subject is the TASK, stratified by agent: `experiment_create` takes a
  `task_cohort` policy on `agent_id`, the dispatched phase's assignee, which
  `HeartbeatScheduler` supplies as a subject attribute. Assignment is sticky
  per task, so every dispatch of one task sees one arm, and each agent is
  compared with itself across tasks. A per-agent arm would confound code
  mode with model and harness.

  ## Target and payload

  The only target is `"dispatch.prompt_directive"` (`targets/0`). The payload
  is `%{"suite_run" => boolean}`; the control is `%{"suite_run" => false}`.

  ## The legacy tool name in the directives, on purpose

  The run tool is `burrow_run` now and `suite_run` is its hidden alias (task
  01a14b9e-50a4 stage 1, `Platform.Federation.ToolAliases`). The payload key
  `"suite_run"` stays because live experiment rows store it. The two
  directives ALSO still say `suite_run` and "Suite tools", byte-identical:
  measured read-only on 2026-10-17 at 21:01Z (both production installs on
  image 95040921), one install had experiment `code-mode-2026-10` RUNNING on
  this surface (the other had none), and changing an arm's text
  mid-experiment would change the condition being measured. The alias keeps
  the directives working. Rename them when no experiment on
  `dispatch.code_mode` is running.
  """

  @behaviour Platform.Experiments.Surface

  alias Platform.Experiments.Surfaces.DispatchPrompt

  @target "dispatch.prompt_directive"

  @treatment_directive """
  Code mode is ON for this task. Suite tools are available to you as bindings inside suite_run scripts.

  1. Call suite_run_describe first, naming only the tools you need (for example task_get, stage_list, validation_pass), to read their typed signatures.
  2. Prefer ONE suite_run script that makes several Suite calls and returns only what you need over many sequential direct tool calls. Calls inside a script are synchronous: suite.task_get({task_id}) returns the data directly.
  3. Pass this task's task_id (and stage_id, when you have one) in the script's inputs, so every inner call is attributed to this dispatch.
  4. A script returns ok:false with an error kind (forbidden, timeout, fuel, memory, call_limit, output_limit, script_error) instead of raising; read the kind before retrying.
  5. Local tools (shell, file reads, git) are unchanged. Code mode covers Suite tool calls only.
  """

  @control_directive "Code mode is OFF for this task: do not call suite_run on this task. Call Suite tools directly, one at a time."

  @impl true
  def key, do: "dispatch.code_mode"

  @impl true
  def subject_type, do: "task"

  @impl true
  def path, do: :dispatch

  @doc "The read point this surface is resolved at."
  @impl true
  def targets, do: [@target]

  @doc "The resolution target, `\"dispatch.prompt_directive\"`."
  @spec target() :: String.t()
  def target, do: @target

  @impl true
  def payload_schema do
    %{
      "type" => "object",
      "required" => ["suite_run"],
      "properties" => %{
        "suite_run" => %{
          "type" => "boolean",
          "description" =>
            "true: the dispatch is told to work through suite_run scripts. false (the control): " <>
              "the dispatch is told not to call suite_run."
        }
      }
    }
  end

  @impl true
  def validate_payload(payload) when is_map(payload) do
    value = Map.get(payload, "suite_run", Map.get(payload, :suite_run))
    unknown = Enum.reject(Map.keys(payload), &(to_string(&1) == "suite_run"))

    errors =
      if(is_boolean(value), do: [], else: ["suite_run must be a boolean"]) ++
        if(unknown == [],
          do: [],
          else: [
            "unknown keys: #{unknown |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.join(", ")}"
          ]
        )

    case errors do
      [] -> {:ok, %{"suite_run" => value}}
      errors -> {:error, errors}
    end
  end

  def validate_payload(_payload), do: {:error, ["payload must be an object"]}

  @impl true
  def control_payload(_target, _opts \\ []), do: {:ok, %{"suite_run" => false}}

  @impl true
  def render_directive(%{"suite_run" => true}), do: String.trim_trailing(@treatment_directive)
  def render_directive(%{"suite_run" => false}), do: @control_directive
  def render_directive(_payload), do: nil

  @impl true
  defdelegate subject_attributes(task_id), to: DispatchPrompt
end
