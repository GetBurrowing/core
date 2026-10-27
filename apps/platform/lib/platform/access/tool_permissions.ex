defmodule Platform.Access.ToolPermissions do
  @moduledoc "Required permission for each MCP tool. Unknown tools are denied."

  alias Platform.Access.Registry
  alias Platform.Extensions

  # Includes tools hidden by runtime flags, so bundle translation is stable.
  @core for {permission, names} <- [
              {"access.manage", ~w(access_explain access_propose access_apply access_undo)},
              {"agents.manage_own",
               ~w(dm_create federation_status feedback_submit principal_search space_create space_leave space_list_agents)},
              {"canvas.read",
               ~w(canvas_describe canvas_list_kinds canvas_template canvas_versions canvas_get canvas_list)},
              {"canvas.write", ~w(canvas_create canvas_patch canvas_restore)},
              {"chat.read",
               ~w(space_get_context space_get_messages space_list space_search_messages)},
              {"chat.write", ~w(react send_media)},
              {"experiments.propose",
               ~w(code_mode_report experiment_conclude experiment_create experiment_exclude experiment_goal_set experiment_promote experiment_start experiment_stop experiment_variant_add)},
              {"experiments.read",
               ~w(dispatch_metrics_list experiment_get experiment_goal_list experiment_list experiment_results experiment_signals_list experiment_surface_list)},
              {"files.read",
               ~w(attachment_get_inline file_get_metadata file_get_text file_list file_search)},
              {"files.write",
               ~w(attachment_upload_inline attachment_upload_start file_add file_delete)},
              {"admin.use",
               ~w(admin_health admin_logs admin_env_names admin_migrations admin_rpc admin_restart admin_deploy admin_rollback)},
              {"mail.use",
               ~w(mail_draft_create mail_draft_update mail_inbound_get mail_inbound_list)},
              {"meetings.join",
               ~w(intent_ack meeting_activity_push meeting_create meeting_say voice_ask_agent voice_ask_poll)},
              {"memory.journal", ~w(memory_create)},
              {"memory.read",
               ~w(memory_search memory_view org_memory_feedback_at_path org_memory_recently_deleted org_memory_recently_edited)},
              {"memory.write", ~w(memory_delete memory_insert memory_rename memory_str_replace)},
              {"prompts.manage", ~w(prompt_template_update)},
              {"prompts.read", ~w(prompt_template_list)},
              {"prototypes.publish", ~w(prototype_publish prototype_rollback)},
              {"prototypes.read", ~w(prototype_versions)},
              {"skills.read", ~w(skill_get skill_list burrow_run burrow_run_describe)},
              {"skills.write", ~w(skill_upsert)},
              {"tasks.manage", ~w(plan_approve plan_reject)},
              {"tasks.read",
               ~w(epic_list execution_lease_list org_list_descendants plan_get project_list review_item_list review_request_get runtime_event_list stack_get stack_list stage_list task_delivery_candidate_list task_dependencies task_get task_list task_list_canvases task_transition_list validation_list)},
              {"tasks.write",
               ~w(alarm_silence design_critique_request epic_create epic_update janitor_hand_back plan_architecture_verdict plan_create plan_submit plan_update project_update report_blocker review_request_create stack_abandon stack_add stack_add_dependency stack_assign_agents stack_attach_canvas stack_complete stack_create stack_detach_canvas stack_eject stack_remove_dependency stack_retry_member_merge stack_start stack_start_planning stack_update stage_architecture_audit stage_complete stage_start task_ack task_attach_canvas task_close_as_delivered task_complete task_create task_design_decline task_detach_canvas task_start task_update validation_evaluate validation_pass validation_payload_amend)},
              {"vault.use", ~w(vault_fetch vault_list)}
            ],
            name <- names,
            into: %{},
            do: {name, permission}

  @core_bundle_names %{
    "access" => ~w(access_explain access_propose access_apply access_undo),
    "admin" =>
      ~w(admin_health admin_logs admin_env_names admin_migrations admin_rpc admin_restart admin_deploy admin_rollback),
    "attachment" => ~w(attachment_upload_inline attachment_get_inline attachment_upload_start),
    "canvas" =>
      ~w(canvas_create canvas_patch canvas_describe canvas_list_kinds canvas_template canvas_versions canvas_restore),
    "code_mode" => ~w(burrow_run burrow_run_describe),
    "context_read" =>
      ~w(space_get_context space_search_messages space_get_messages canvas_list canvas_get principal_search),
    "experiments" =>
      ~w(experiment_surface_list experiment_list experiment_get experiment_create experiment_variant_add experiment_start experiment_stop experiment_conclude experiment_results experiment_signals_list experiment_exclude experiment_goal_set experiment_goal_list experiment_promote dispatch_metrics_list code_mode_report),
    "federation" => ~w(federation_status vault_fetch vault_list feedback_submit),
    "files" => ~w(file_list file_get_text file_get_metadata file_search file_add file_delete),
    "mail" => ~w(mail_draft_create mail_draft_update mail_inbound_list mail_inbound_get),
    "meetings" => ~w(meeting_create meeting_say meeting_activity_push intent_ack),
    "memory" =>
      ~w(memory_view memory_create memory_str_replace memory_insert memory_delete memory_rename memory_search org_memory_recently_edited org_memory_recently_deleted org_memory_feedback_at_path),
    "messaging" => ~w(send_media react),
    "plan" =>
      ~w(plan_create plan_update plan_get plan_submit plan_approve plan_reject validation_payload_amend plan_architecture_verdict stage_architecture_audit stage_start stage_list validation_evaluate validation_pass stage_complete report_blocker validation_list prompt_template_list prompt_template_update),
    "prototype" => ~w(prototype_publish prototype_versions prototype_rollback),
    "review" =>
      ~w(review_request_create review_request_get review_item_list design_critique_request),
    "skill" => ~w(skill_list skill_get skill_upsert),
    "space" => ~w(space_create space_list space_list_agents space_leave dm_create),
    "task" =>
      ~w(project_list org_list_descendants project_update epic_list epic_update epic_create task_create task_get task_transition_list runtime_event_list execution_lease_list task_list task_complete task_close_as_delivered task_delivery_candidate_list task_update task_start task_ack alarm_silence task_dependencies task_attach_canvas task_design_decline task_detach_canvas task_list_canvases stack_create stack_update stack_get stack_list stack_add stack_add_dependency stack_remove_dependency stack_eject stack_abandon stack_complete stack_start stack_retry_member_merge stack_start_planning stack_assign_agents stack_attach_canvas stack_detach_canvas janitor_hand_back),
    "voice_ask" => ~w(voice_ask_agent voice_ask_poll)
  }

  @spec for_tool(String.t()) :: String.t() | nil
  def for_tool(name) when is_binary(name) do
    Map.get(@core, name) || extension_permission(name)
  end

  def for_tool(_), do: nil

  @spec bundle_permissions(String.t()) :: MapSet.t(String.t())
  def bundle_permissions(bundle) when is_binary(bundle) do
    names =
      case Map.fetch(@core_bundle_names, bundle) do
        {:ok, names} ->
          names

        :error ->
          case Extensions.tool_bundle(bundle) do
            %{tool_names: names} -> names
            nil -> []
          end
      end

    names
    |> Enum.map(&for_tool/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  def bundle_permissions(_), do: MapSet.new()

  defp extension_permission(name) do
    case Extensions.tool_owner(name) do
      %{name: bundle} = declaration ->
        Map.get(declaration, :permissions, %{})
        |> Map.get(name, Registry.bundle_permission(bundle))

      nil ->
        nil
    end
  end
end
