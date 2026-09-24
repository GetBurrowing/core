defmodule Platform.Deploy do
  @moduledoc """
  Context module for platform-executed deploy strategies (task 019f5e66).

  Some deploy strategies run entirely inside the platform — the plan
  engine transitions the task's deploy stage to `running` and immediately
  invokes a handler here that produces the deploy artifact (a file, a
  container, a merged branch, etc.) and evaluates the stage's
  `test_pass` validation with the outcome.

  For those strategies the assigned agent never has to push evidence —
  in fact there's often no agent involved at all. Other strategies
  (`pr_merge`, `docker_deploy`) are still driven by the agent + webhooks
  and dispatch here as a no-op.

  ## Registered strategies

    * `"project_files"` — writes an exported Markdown copy of a
      deliverable canvas into a target project's files space. See
      `Platform.Deploy.ProjectFiles`.
    * `"email"` — mails the deliverable from a named org mail account and
      sender. Runs inside the plan engine's transaction, so it only QUEUES
      the send (`Platform.Mail.Dispatch.enqueue/3`); `Platform.Mail.Outbox`
      delivers after commit and resolves `test_pass`. See
      `Platform.Deploy.Email`.

  ## Adding a strategy

  1. Add a `dispatch/3` clause below that pattern-matches on the
     strategy `"type"`.
  2. Register the strategy in `Platform.Tasks.DeployStageBuilder`
     (stage_def + `@valid_strategy_types`), and in
     `Platform.Tasks.Task`'s `@deploy_target_config_strategies` if it reads
     `task.deploy_target_config`.
  3. Add the deploy-stage instructions branch in
     `Platform.Orchestration.HeartbeatScheduler.deploy_strategy_instructions/3`
     so the agent (if any) knows the platform is auto-executing.

  ## Return contract

  `dispatch/3` NEVER raises and NEVER propagates an error tuple that
  the caller (`Platform.Tasks.PlanEngine.inject_deploy_stage/4`) has to
  handle. Every failure is logged and (for strategies that own a
  validation) surfaced through `PlanEngine.evaluate_validation/2` on
  the stage's own `test_pass` row — that keeps the state machine's
  liveness invariant (each dispatched stage eventually resolves).
  """

  require Logger

  alias Platform.Deploy.Email
  alias Platform.Deploy.ProjectFiles
  alias Platform.Tasks.{Stage, Task}

  @doc """
  Route to a strategy handler based on the resolved strategy type.

  * `task` — the task that just entered `deploying`. The handler may
    preload additional associations off `task.project` etc.
  * `strategy` — the map returned by `Platform.Tasks.resolve_deploy_strategy/1`
    (`%{"type" => "project_files", ...}` etc).
  * `deploy_stage` — the freshly-injected deploy stage row (already in
    `running`, with its validations created but still `pending`).

  Returns `:ok` after any handler-side reporting is done. The atom is
  informational only — the plan engine ignores the return.
  """
  @spec dispatch(Task.t(), map() | nil, Stage.t()) :: :ok
  def dispatch(%Task{} = task, %{"type" => "project_files"} = _strategy, %Stage{} = deploy_stage) do
    _ = ProjectFiles.execute(task, deploy_stage)
    :ok
  rescue
    e ->
      Logger.error(
        "[Deploy.dispatch] project_files handler crashed for task #{task.id}: " <>
          Exception.message(e)
      )

      :ok
  catch
    :exit, reason ->
      Logger.error(
        "[Deploy.dispatch] project_files handler exited for task #{task.id}: #{inspect(reason)}"
      )

      :ok
  end

  def dispatch(%Task{} = task, %{"type" => "email"} = _strategy, %Stage{} = deploy_stage) do
    _ = Email.execute(task, deploy_stage)
    :ok
  rescue
    e ->
      Logger.error(
        "[Deploy.dispatch] email handler crashed for task #{task.id}: " <> Exception.message(e)
      )

      :ok
  catch
    :exit, reason ->
      Logger.error(
        "[Deploy.dispatch] email handler exited for task #{task.id}: #{inspect(reason)}"
      )

      :ok
  end

  # Any other strategy (docker_deploy, pr_merge, fly, skill_driven,
  # manual, or missing/nil) is a no-op here — evidence for those flows
  # comes from webhooks or the assigned agent.
  def dispatch(%Task{}, _strategy, %Stage{}), do: :ok
end
