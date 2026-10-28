defmodule Platform.Orchestration.BlockerReassessment do
  @moduledoc """
  Durable, bounded verification of explicitly typed dependency waits.

  Completion is a reason to request verification, never evidence of installed
  capability. Verification requests go to the existing owning runtime connection;
  they do not create stage workers or execute commands from metadata.
  """
  import Ecto.Query
  alias Platform.Orchestration.{ExecutionLease, ExecutionSpace, RuntimeSupervision}
  alias Platform.{Repo, Tasks}

  def interval_ms, do: Application.get_env(:platform, :blocker_reassessment_interval_ms, 300_000)
  def attempt_budget, do: Application.get_env(:platform, :blocker_reassessment_attempt_budget, 3)

  def validate_spec(task_id, stage_id, runtime_id, spec) when is_map(spec) do
    refs = spec["dependencies"]
    capability = spec["required_capability"]

    with true <- is_binary(runtime_id) and runtime_id != "",
         {:ok, task} <- current_task(task_id, stage_id),
         true <- is_binary(task.project_id),
         true <- runtime_owner?(task, stage_id, runtime_id),
         true <- is_list(refs) and refs != [] and length(refs) <= 32 and Enum.uniq(refs) == refs,
         true <- is_binary(capability) and byte_size(capability) in 1..256,
         true <- spec["verifier"] == "owning_runtime",
         true <- Enum.all?(refs, &valid_reference?(&1, task)) do
      {:ok,
       Map.put(
         spec
         |> Map.take(["dependencies", "required_capability", "verifier"])
         |> Map.put("dependencies", Enum.sort_by(refs, & &1["task_id"])),
         "task_dependencies",
         Enum.sort(Tasks.dependency_task_ids(task))
       )}
    else
      _ -> {:error, :invalid_dependency_wait}
    end
  end

  def validate_spec(_, _, _, _), do: {:error, :invalid_dependency_wait}

  # Invoked by the normalized execution-event ingress. Legacy payloads remain
  # human holds; no prose parser ever upgrades them into dependency waits.
  def normalize_block(attrs) do
    case attrs.payload["wait_kind"] do
      "dependency" ->
        with {:ok, spec} <-
               validate_spec(attrs.task_id, attrs.stage_id, attrs.runtime_id, attrs.payload) do
          wait =
            Map.merge(spec, %{
              "revision" => attrs.idempotency_key,
              "attempts" => 0,
              "state" => "waiting",
              "next_due_at" => DateTime.to_iso8601(DateTime.utc_now())
            })

          {:ok,
           %{
             attrs
             | payload:
                 Map.merge(attrs.payload, %{
                   "needs_human" => true,
                   "dependency_wait" => wait
                 })
           }}
        end

      nil ->
        {:ok,
         %{
           attrs
           | payload: Map.merge(attrs.payload, %{"wait_kind" => nil, "dependency_wait" => nil})
         }}

      "human" ->
        {:ok, %{attrs | payload: Map.put(attrs.payload, "dependency_wait", nil)}}

      _ ->
        {:error, :invalid_wait_kind}
    end
  end

  @doc "Explicitly classify/re-check a hold; caller identity is authenticated context."
  def recheck(task_id, stage_id, spec, context) do
    runtime = context[:runtime_id]

    with {:ok, _task} <- current_task(task_id, stage_id),
         %ExecutionLease{} = hold <-
           RuntimeSupervision.needs_human_hold(task_id, stage_id, runtime),
         true <- is_binary(context[:agent_id]),
         false <- hold.metadata["wait_kind"] == "human",
         {:ok, spec} <- validate_spec(task_id, stage_id, runtime, spec) do
      result =
        Repo.transaction(fn ->
          lease = locked(hold.id)
          unless RuntimeSupervision.needs_human_hold?(lease), do: Repo.rollback(:hold_closed)
          if lease.metadata["wait_kind"] == "human", do: Repo.rollback(:human_action_required)
          existing = ExecutionLease.dependency_wait(lease)

          wait =
            Map.merge(spec, %{
              "revision" => Ecto.UUID.generate(),
              "attempts" => 0,
              "state" => "waiting",
              "next_due_at" => DateTime.to_iso8601(DateTime.utc_now()),
              "requested_by" => context[:agent_id],
              "requested_runtime" => runtime
            })

          if is_map(existing) and existing["state"] != "exhausted" and
               Map.take(existing, Map.keys(spec)) == spec do
            lease
          else
            save(
              lease,
              Map.merge(lease.metadata, %{"wait_kind" => "dependency", "dependency_wait" => wait})
            )
          end
        end)

      case result do
        {:ok, _} -> reassess(task_id)
        error -> error
      end
    else
      _ -> {:error, :not_owner_or_invalid_wait}
    end
  end

  @doc "Queue a matching completion immediately without resetting an in-flight request or budget."
  def dependency_completed(task_id, dependency_id) do
    Repo.all(from(l in ExecutionLease, where: l.task_id == ^task_id and l.status == "blocked"))
    |> Enum.each(fn candidate ->
      Repo.transaction(fn ->
        lease = locked(candidate.id)
        wait = ExecutionLease.dependency_wait(lease)

        if is_map(wait) and wait["state"] == "waiting" and
             Enum.any?(wait["dependencies"], &(&1["task_id"] == dependency_id)) do
          save(
            lease,
            Map.put(
              lease.metadata,
              "dependency_wait",
              Map.put(wait, "next_due_at", DateTime.to_iso8601(DateTime.utc_now()))
            )
          )
        end
      end)
    end)

    reassess(task_id)
  end

  @doc "Reconcile due waits for one task on startup, completion events and sweeps."
  def reassess(task_id, now \\ DateTime.utc_now()) do
    leases =
      Repo.all(
        from(l in ExecutionLease,
          where: l.task_id == ^task_id and l.status == "blocked"
        )
      )

    results =
      Enum.map(leases, fn lease ->
        result = Repo.transaction(fn -> request_locked(locked(lease.id), now) end)

        case result do
          {:ok, {:request, updated, request}} ->
            # Persist-before-send: a crash leaves a due retry, never an unrecorded
            # request or permission to dispatch. The request token fences replies.
            Tasks.broadcast_board({:blocker_verification_requested, request})
            notice(updated, "Waiting on dependency verification: #{request.required_capability}")
            {:requested, request}

          {:ok, {:failed, updated, reason}} ->
            notice(updated, "Waiting on dependency: #{reason}")
            {:waiting, reason}

          {:ok, other} ->
            other

          error ->
            error
        end
      end)

    {:ok, results}
  end

  defp request_locked(lease, now) do
    wait = ExecutionLease.dependency_wait(lease)

    cond do
      is_nil(wait) ->
        :human_hold

      not due?(wait["next_due_at"], now) ->
        :not_due

      wait["state"] == "exhausted" ->
        :exhausted

      true ->
        case ready(lease, wait) do
          :ok -> request_ready(lease, wait, now)
          {:error, reason} -> failure(lease, wait, now, reason)
        end
    end
  end

  defp request_ready(lease, wait, now) do
    if wait["attempts"] >= attempt_budget() do
      failure(lease, wait, now, :verification_budget_exhausted)
    else
      token = Ecto.UUID.generate()

      wait =
        Map.merge(wait, %{
          "state" => "verifying",
          "attempts" => wait["attempts"] + 1,
          "request_token" => token,
          "requested_at" => DateTime.to_iso8601(now),
          "next_due_at" => DateTime.to_iso8601(DateTime.add(now, interval_ms(), :millisecond))
        })

      updated = save(lease, Map.put(lease.metadata, "dependency_wait", wait))

      {:request, updated,
       %{
         task_id: lease.task_id,
         stage_id: lease.stage_id,
         runtime_id: lease.runtime_id,
         hold_revision: wait["revision"],
         request_token: token,
         required_capability: wait["required_capability"],
         dependencies: wait["dependencies"]
       }}
    end
  end

  @doc "Accept only a fresh owning-runtime attestation for this request and hold."
  def verify(task_id, stage_id, result, context) when is_map(result) do
    runtime = context[:runtime_id]

    with true <- is_boolean(result["verified"]) and is_list(result["evidence_refs"]),
         true <- is_binary(runtime) and is_binary(context[:agent_id]),
         %ExecutionLease{} = hold <-
           RuntimeSupervision.needs_human_hold(task_id, stage_id, runtime) do
      result =
        Repo.transaction(fn ->
          lease = locked(hold.id)
          wait = ExecutionLease.dependency_wait(lease)
          now = DateTime.utc_now()

          unless is_map(wait) and wait["state"] == "verifying" and
                   wait["request_token"] == result["request_token"] and
                   wait["revision"] == result["hold_revision"] and
                   wait["required_capability"] == result["required_capability"] and
                   not due?(wait["next_due_at"], now),
                 do: Repo.rollback(:stale_verification)

          case ready(lease, wait) do
            :ok -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

          evidence = result["evidence_refs"]

          wait =
            Map.merge(wait, %{
              "last_verification_at" => DateTime.to_iso8601(now),
              "last_verification_by" => context[:agent_id],
              "last_verification_runtime" => runtime,
              "evidence_refs" =>
                Enum.filter(evidence, &(is_binary(&1) and byte_size(&1) in 1..2048))
            })

          if result["verified"] == true and is_list(evidence) and evidence != [] and
               Enum.all?(evidence, &(is_binary(&1) and byte_size(&1) in 1..2048)) do
            verified =
              Map.merge(wait, %{
                "state" => "verified",
                "verified_at" => DateTime.to_iso8601(now),
                "verified_by" => context[:agent_id],
                "verified_runtime" => runtime,
                "evidence_refs" => evidence,
                "verification_result" => "passed"
              })

            save(lease, Map.put(lease.metadata, "dependency_wait", verified))
            # Same ingress/persistence/broadcast path used by RuntimeChannel.
            # Actual runtime/agent identity comes from context, never result data.
            case RuntimeSupervision.record_event(
                   %{
                     task_id: task_id,
                     stage_id: stage_id,
                     phase: lease.phase,
                     runtime_id: runtime,
                     event_type: "execution.unblocked",
                     idempotency_key: "dependency-verified:#{lease.id}:#{wait["revision"]}",
                     invoked_by_user_id: lease.invoked_by_user_id,
                     owner_org_id: lease.owner_org_id,
                     payload: %{
                       "stage_id" => stage_id,
                       "needs_human" => false,
                       "reported_by" => context[:agent_id],
                       "description" => "Dependency capability verified",
                       "hold_revision" => wait["revision"],
                       "evidence_refs" => evidence
                     }
                   },
                   defer_broadcast: true
                 ) do
              {:ok, event} -> {:released, event}
              {:error, reason} -> Repo.rollback(reason)
            end
          else
            failure(lease, wait, now, :verification_failed)
            %{released: false, reason: "verification_failed"}
          end
        end)

      case result do
        {:ok, {:released, event}} ->
          RuntimeSupervision.broadcast_recorded_event(event)
          {:ok, %{event_id: event.id, released: true}}

        other ->
          other
      end
    else
      false -> {:error, :invalid_verification}
      _ -> {:error, :not_owner_or_hold_closed}
    end
  end

  def verify(_, _, _, _), do: {:error, :invalid_verification}

  defp failure(lease, wait, now, reason) do
    attempts = if wait["state"] == "verifying", do: wait["attempts"], else: wait["attempts"] + 1
    exhausted = attempts >= attempt_budget()

    wait =
      Map.merge(wait, %{
        "state" => if(exhausted, do: "exhausted", else: "waiting"),
        "attempts" => attempts,
        "reason" => to_string(reason),
        "verification_result" => "failed",
        "last_reassessed_at" => DateTime.to_iso8601(now),
        "next_due_at" =>
          if(exhausted,
            do: nil,
            else: DateTime.to_iso8601(DateTime.add(now, interval_ms(), :millisecond))
          )
      })

    {:failed, save(lease, Map.put(lease.metadata, "dependency_wait", wait)), to_string(reason)}
  end

  defp ready(lease, wait) do
    with true <- RuntimeSupervision.needs_human_hold?(lease),
         {:ok, task} <- current_task(lease.task_id, lease.stage_id),
         {:ok, _} <- validate_spec(lease.task_id, lease.stage_id, lease.runtime_id, wait),
         true <- wait["task_dependencies"] == Enum.sort(Tasks.dependency_task_ids(task)),
         true <-
           Enum.all?(wait["dependencies"], fn ref ->
             Tasks.get_task_record(ref["task_id"]).status == "done"
           end),
         true <-
           Enum.all?(Tasks.dependency_task_ids(task), fn id ->
             case Tasks.get_task_record(id) do
               %{status: "done", deleted_at: nil} -> true
               _ -> false
             end
           end) do
      :ok
    else
      _ -> {:error, :dependency_or_stage_changed}
    end
  end

  defp runtime_owner?(task, stage_id, runtime_id) do
    phase_owner = Platform.Orchestration.PhaseRuntime.resolve(task)

    phase_matches =
      case phase_owner do
        {:ok, %{type: :federated, id: owner}} -> owner == runtime_id
        {:error, :no_assignee} -> true
        _ -> false
      end

    phase_matches and
      case Platform.Orchestration.LeaseManager.get(task.id) do
        %{stage_id: ^stage_id, owner_runtime_id: owner} ->
          owner == runtime_id

        %{} ->
          false

        nil ->
          case phase_owner do
            {:ok, %{type: :federated, id: ^runtime_id}} ->
              true

            {:error, :no_assignee} ->
              match?(
                %ExecutionLease{},
                RuntimeSupervision.needs_human_hold(task.id, stage_id, runtime_id)
              )

            _ ->
              false
          end
      end
  end

  defp valid_reference?(%{"kind" => "task", "task_id" => id}, task) when is_binary(id) do
    if Platform.UUID.valid?(id) and id != task.id do
      case Tasks.get_task_record(id) do
        %{deleted_at: nil, project_id: project_id} when not is_nil(project_id) ->
          owner = Repo.get(Platform.Tasks.Project, task.project_id)
          other = Repo.get(Platform.Tasks.Project, project_id)
          owner && other && owner.org_id == other.org_id

        _ ->
          false
      end
    else
      false
    end
  end

  defp valid_reference?(_, _), do: false

  defp current_task(task_id, stage_id) do
    with true <- Platform.UUID.valid?(task_id) and Platform.UUID.valid?(stage_id),
         %{deleted_at: nil} = task <- Tasks.get_task_record(task_id),
         false <- task.status in ["done", "cancelled"],
         %{stages: stages} <- Tasks.current_plan(task_id),
         true <- Enum.any?(stages, &(&1.id == stage_id and &1.status == "running")) do
      {:ok, task}
    else
      _ -> {:error, :stale_stage}
    end
  end

  defp locked(id),
    do: Repo.one!(from(l in ExecutionLease, where: l.id == ^id, lock: "FOR UPDATE"))

  defp save(lease, metadata),
    do: lease |> ExecutionLease.changeset(%{metadata: metadata}) |> Repo.update!()

  defp due?(nil, _now), do: true

  defp due?(timestamp, now) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, at, _} -> DateTime.compare(at, now) != :gt
      _ -> true
    end
  end

  defp notice(lease, text) do
    if space = ExecutionSpace.find_by_task_id(lease.task_id) do
      ExecutionSpace.post_log(space.id, text)
    end
  end
end
