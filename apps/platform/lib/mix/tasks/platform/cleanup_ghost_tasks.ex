defmodule Mix.Tasks.Platform.CleanupGhostTasks do
  @moduledoc """
  One-shot, idempotent cleanup for the two known orphan/ghost tasks
  surfaced by task `019e24ac` (see the stage-1 audit writeup).

  Both rows were soft-deleted before stage 4's synchronous teardown
  landed, so the live gateway can still have residual `TaskRouter`
  processes (and possibly active execution leases) registered for
  them. This task drives each ghost id to the new `cancelled` terminal
  status, stamps `deleted_at` if not already set, and sweeps the
  router registry + lease table directly. Safe to re-run.

  ## Usage

      mix platform.cleanup_ghost_tasks
      mix platform.cleanup_ghost_tasks --task-id <uuid>     # one-off override
      mix platform.cleanup_ghost_tasks --task-id <uuid> --task-id <uuid>

  With no `--task-id` flags, the hardcoded list of known ghosts is used.

  ## Why a Mix task instead of a data migration

  Re-runnable from any node via `bin/platform eval` after deploy, and
  decoupled from schema migration ordering — the migration to add the
  `cancelled` status (stage 3) has to run first, but this cleanup is
  pure data sweep and ordering becomes irrelevant once the enum value
  exists in Postgres.
  """

  use Mix.Task

  alias Platform.Orchestration.{RuntimeSupervision, TaskRouterSupervisor}
  alias Platform.Tasks
  alias Platform.Tasks.Task

  @shortdoc "Cancel and tear down the two known orphan/ghost tasks"

  @ghost_task_ids [
    "019df569-028c-704a-acb4-00b7d096f430",
    "019df569-6051-7fa9-a638-9bc88dcce694"
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [task_id: [:string, :keep]],
        aliases: [t: :task_id]
      )

    Mix.Task.run("app.start")

    task_ids =
      case Keyword.get_values(opts, :task_id) do
        [] -> @ghost_task_ids
        ids -> ids
      end

    log("cleanup_ghost_tasks: processing #{length(task_ids)} task id(s)")

    Enum.each(task_ids, &cleanup_one/1)

    log("cleanup_ghost_tasks: done")
    :ok
  end

  @doc false
  # Public for testability — the Mix task indirection is thin so the
  # interesting per-id logic is exposed for direct assertion.
  def cleanup_one(task_id) when is_binary(task_id) do
    case Tasks.get_task_record(task_id) do
      nil ->
        log("  #{short(task_id)}: row absent, skipping")
        sweep_registry(task_id, :absent)
        :absent

      %Task{status: "cancelled", deleted_at: deleted_at} = task when not is_nil(deleted_at) ->
        log("  #{short(task_id)}: already cancelled + soft-deleted, sweeping registry only")
        sweep_registry(task.id, :already_cleaned)
        :already_cleaned

      %Task{} = task ->
        log(
          "  #{short(task_id)}: status=#{task.status} deleted_at=#{inspect(task.deleted_at)} → cancelling"
        )

        case maybe_cancel(task) do
          {:ok, cancelled} ->
            cancelled
            |> maybe_stamp_deleted_at()
            |> log_outcome(task_id)

            # `transition_task_status/2` already runs the stage-4 teardown
            # synchronously, but if the task was already cancelled (and we
            # only stamped deleted_at), no teardown ran — sweep just in case.
            sweep_registry(task.id, :post_cancel)

            :cleaned

          {:error, reason} ->
            log("  #{short(task_id)}: cancel failed — #{inspect(reason)}")
            :error
        end
    end
  end

  # If status is already `cancelled` we don't re-transition (the
  # transition table makes `cancelled → cancelled` invalid anyway), but
  # we may still need to stamp deleted_at and sweep the registry.
  defp maybe_cancel(%Task{status: "cancelled"} = task), do: {:ok, task}

  defp maybe_cancel(%Task{} = task), do: Tasks.transition_task_status(task, "cancelled")

  defp maybe_stamp_deleted_at(%Task{deleted_at: nil} = task) do
    case Tasks.soft_delete_task(task) do
      {:ok, deleted} ->
        log("    stamped deleted_at=#{inspect(deleted.deleted_at)}")
        deleted

      {:error, :restricted_status} ->
        # Shouldn't happen — `cancelled` isn't restricted — but log
        # rather than crash so the second ghost still gets processed.
        log("    soft_delete refused (restricted_status) — leaving deleted_at unset")
        task

      {:error, changeset} ->
        log("    soft_delete failed: #{inspect(changeset.errors)}")
        task
    end
  end

  defp maybe_stamp_deleted_at(%Task{} = task), do: task

  defp log_outcome(%Task{} = task, original_id) do
    log("    #{short(original_id)}: status=#{task.status} deleted_at=#{inspect(task.deleted_at)}")
  end

  defp sweep_registry(task_id, context) do
    router_result = TaskRouterSupervisor.stop_assignment(task_id)
    lease_count = RuntimeSupervision.abandon_current_lease_for_task(task_id, "execution")

    case {router_result, lease_count, context} do
      {:ok, 0, _} -> log("    swept: router stopped, no active lease")
      {:ok, n, _} -> log("    swept: router stopped, #{n} lease(s) abandoned")
      {{:error, :not_found}, 0, _} -> log("    swept: nothing to clean")
      {{:error, :not_found}, n, _} -> log("    swept: #{n} lease(s) abandoned (no router)")
    end

    :ok
  end

  defp short(id) when is_binary(id), do: String.slice(id, 0, 8)

  defp log(msg) do
    if function_exported?(Mix, :shell, 0) do
      Mix.shell().info(msg)
    else
      IO.puts(msg)
    end
  end
end
