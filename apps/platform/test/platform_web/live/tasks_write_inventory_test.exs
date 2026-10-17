defmodule PlatformWeb.TasksWriteInventoryTest do
  @moduledoc """
  Static guard over every `handle_event` head on the /tasks surface (task
  01a1472d stage 1): `tasks_live.ex`, every module under `live/tasks/`,
  including the attached hooks (`lifecycle_hooks.ex`, `mask_hooks.ex`),
  whose clauses are `defp`.

  The RAW FULL list of heads, one entry per clause head (a handler with an
  `edit_mode: false` guard clause appears twice), must equal the union of
  three named lists:

    * `@guarded` — re-checks its target through `Platform.Access.task_target/3`
      (via `PlatformWeb.Tasks.Selection`) before it loads or writes;
    * `@already_gated` — takes a client id but an existing check refuses an
      actor outside the fence (`PlatformWeb.TasksWriteFenceTest` holds one
      refusal test for each);
    * `@not_a_write` — toggles, filters, navigation and buffers that write no
      Tasks row and put no foreign record on screen, or that are noted as
      reads outside this stage.

  Compared as FULL sorted lists, never as derived key sets: a set-equality
  check cannot see a new head of an existing event, and a new handler fails
  here until someone classifies it.
  """

  use ExUnit.Case, async: true

  @web_root Path.expand("../../../lib/platform_web/live", __DIR__)

  @guarded [
    # shell
    {"tasks_live", "assign_agent"},
    # task detail (client ids)
    {"task_detail_component", "detail_update_task_title"},
    {"task_detail_component", "detail_update_task_title"},
    {"task_detail_component", "detail_update_task_field"},
    {"task_detail_component", "detail_update_task_field"},
    {"task_detail_component", "detail_update_task_field"},
    {"task_detail_component", "detail_transition"},
    {"task_detail_component", "plan_approve"},
    {"task_detail_component", "plan_reject"},
    {"task_detail_component", "plan_submit_reject_with_feedback"},
    # task detail (server-held selection)
    {"task_detail_component", "detail_detach_canvas"},
    {"task_detail_component", "detail_save_description"},
    {"task_detail_component", "detail_save_description"},
    {"task_detail_component", "detail_confirm_delete"},
    {"task_detail_component", "detail_submit_reopen"},
    {"task_detail_component", "detail_attach_skill"},
    {"task_detail_component", "detail_detach_skill"},
    {"task_detail_component", "detail_toggle_chat_pin"},
    # review gate
    {"gate_panel_component", "gate_approve_item"},
    {"gate_panel_component", "gate_submit_feedback"},
    # board
    {"board_component", "board_promote_task"},
    {"board_component", "board_drop"},
    # stacks
    {"stacks_component", "stack_open_detail"},
    {"stacks_component", "stack_feedback_approve_item"},
    {"stacks_component", "stack_feedback_reject_item"},
    {"stacks_component", "stack_abandon"},
    {"stacks_component", "stack_abandon"},
    {"stacks_component", "stack_start_planning"},
    {"stacks_component", "stack_save_assignees"},
    {"stacks_component", "stack_clear_member_override"},
    # sidebar (sidebar_select_project is guarded in the shell's handle_info)
    {"sidebar_component", "sidebar_select_project"},
    {"sidebar_component", "sidebar_create_project"},
    {"sidebar_component", "sidebar_create_epic"},
    # creation
    {"task_create_component", "taskcreate_submit"},
    # selection components
    {"assignees_component", "save_assignees"},
    {"merge_control_component", "merge_task_branch"},
    {"supersede_component", "supersede_submit"},
    {"steering_component", "send_steering_message"}
  ]

  @already_gated [
    # Tasks.can_promote_from_quarantine?/2 plus the tasks.read row re-read
    {"task_detail_component", "detail_promote_from_quarantine"},
    # Tenancy.Lifecycle root-admin authorization
    {"lifecycle_hooks", "archive_container"},
    {"lifecycle_hooks", "undo_archive"},
    {"lifecycle_hooks", "confirm_schedule_deletion"}
  ]

  @not_a_write [
    {"tasks_live", "select_task"},
    {"tasks_live", "select_task_and_delete"},
    {"tasks_live", "toggle_create_menu"},
    {"tasks_live", "toggle_settings_menu"},
    {"assignees_component", "open_assignee_modal"},
    {"assignees_component", "close_assignee_modal"},
    {"assignees_component", "set_assignee_modal_mode"},
    {"board_component", "board_open_task_actions"},
    {"board_component", "board_close_task_actions"},
    {"board_component", "board_toggle_done"},
    {"board_component", "board_done_more"},
    {"filters_component", "filter_search"},
    {"filters_component", "filter_by_status"},
    {"filters_component", "filter_scope"},
    {"filters_component", "filter_scope"},
    {"filters_component", "filter_kind"},
    {"filters_component", "filter_toggle_sponsor"},
    {"filters_component", "filter_clear"},
    {"gate_panel_component", "gate_toggle_superseded"},
    {"gate_panel_component", "gate_toggle_feedback"},
    {"gate_panel_component", "gate_canvas_open"},
    {"gate_panel_component", "gate_canvas_close"},
    {"gate_panel_component", "canvas_action_click"},
    {"gate_panel_component", "canvas_form_submit"},
    {"gate_panel_component", "gate_feedback_changed"},
    {"lifecycle_hooks", "toggle_lifecycle_menu"},
    {"lifecycle_hooks", "dismiss_undo_archive"},
    # Reads a client id's cascade preview into the modal: a READ, reported as
    # open by task 01a1472d stage 1, not fixed here.
    {"lifecycle_hooks", "open_delete_modal"},
    {"lifecycle_hooks", "open_delete_modal"},
    {"lifecycle_hooks", "close_delete_modal"},
    {"lifecycle_hooks", "delete_modal_change"},
    {"lifecycle_hooks", "delete_keep_all"},
    {"lifecycle_hooks", "delete_include_all"},
    {"mask_hooks", "toggle_mask_names"},
    {"mask_hooks", "reveal_rail_item"},
    {"mask_hooks", "remask_all"},
    {"sidebar_component", "sidebar_toggle"},
    {"sidebar_component", "sidebar_toggle_projects_section"},
    {"sidebar_component", "sidebar_toggle_epics_panel"},
    {"sidebar_component", "sidebar_select_epic"},
    {"sidebar_component", "sidebar_toggle_project_sheet"},
    {"sidebar_component", "sidebar_close_project_sheet"},
    {"sidebar_component", "sidebar_toggle_project_create_sheet"},
    {"sidebar_component", "sidebar_close_project_create_sheet"},
    {"sidebar_component", "sidebar_validate_project"},
    {"sidebar_component", "sidebar_toggle_epic_sheet"},
    {"sidebar_component", "sidebar_close_epic_sheet"},
    {"sidebar_component", "sidebar_validate_epic"},
    {"stacks_component", "stack_toggle_expand"},
    {"stacks_component", "stack_close_detail"},
    {"stacks_component", "stack_open_feedback_overlay"},
    {"stacks_component", "stack_close_feedback_overlay"},
    {"stacks_component", "canvas_action_click"},
    {"stacks_component", "canvas_form_submit"},
    {"stacks_component", "stack_toggle_feedback_reject"},
    {"stacks_component", "stack_update_feedback_reject_text"},
    {"stacks_component", "stack_open_assignee_modal"},
    {"stacks_component", "stack_open_assignee_modal"},
    {"stacks_component", "stack_close_assignee_modal"},
    {"stacks_component", "stack_set_assignee_modal_mode"},
    {"stacks_component", "stack_open_graph_expand"},
    {"stacks_component", "stack_close_graph_expand"},
    {"steering_component", "toggle_execution_log"},
    {"steering_component", "steering_changed"},
    {"steering_component", "cancel_steering_upload"},
    {"steering_component", "steering_mention_query"},
    {"steering_component", "steering_mention_query"},
    {"steering_component", "steering_mention_clear"},
    {"steering_component", "gate_canvas_open"},
    {"steering_component", "canvas_open"},
    {"steering_component", "canvas_action_click"},
    {"steering_component", "canvas_form_submit"},
    {"supersede_component", "supersede_open"},
    {"supersede_component", "supersede_close"},
    {"supersede_component", "supersede_reason_changed"},
    {"task_create_component", "taskcreate_toggle_fab"},
    {"task_create_component", "taskcreate_toggle_sheet"},
    {"task_create_component", "taskcreate_close_sheet"},
    {"task_create_component", "taskcreate_validate"},
    {"task_create_component", "taskcreate_toggle_validation_mode"},
    {"task_create_component", "taskcreate_toggle_auto_merge"},
    {"task_create_component", "taskcreate_toggle_auto_approve_plan"},
    {"task_create_component", "taskcreate_cancel_upload"},
    {"task_detail_component", "detail_close"},
    {"task_detail_component", "detail_toggle_edit_mode"},
    {"task_detail_component", "detail_open_deploy_target_config"},
    {"task_detail_component", "detail_start_edit_title"},
    {"task_detail_component", "detail_start_edit_title"},
    {"task_detail_component", "detail_start_edit_description"},
    {"task_detail_component", "detail_start_edit_description"},
    {"task_detail_component", "detail_cancel_edit_description"},
    {"task_detail_component", "detail_request_delete"},
    {"task_detail_component", "detail_cancel_delete"},
    {"task_detail_component", "detail_open_reopen_modal"},
    {"task_detail_component", "detail_close_reopen_modal"},
    {"task_detail_component", "detail_reopen_reason_changed"},
    {"task_detail_component", "plan_toggle_reject_feedback"},
    {"task_detail_component", "plan_update_reject_feedback_text"},
    {"task_detail_component", "plan_expand"},
    {"task_detail_component", "plan_collapse"}
  ]

  defp files do
    [Path.join(@web_root, "tasks_live.ex")] ++ Path.wildcard(Path.join(@web_root, "tasks/*.ex"))
  end

  defp raw_heads do
    for path <- files(),
        [_, event] <- Regex.scan(~r/defp? handle_event\(\s*"([a-z0-9_\-]+)"/, File.read!(path)),
        do: {Path.basename(path, ".ex"), event}
  end

  test "every handle_event head on /tasks is classified, as a full list" do
    raw = Enum.sort(raw_heads())
    classified = Enum.sort(@guarded ++ @already_gated ++ @not_a_write)

    assert raw == classified,
           """
           The /tasks handle_event heads changed. Classify each new head:
           @guarded (re-checks its target through Platform.Access.task_target/3),
           @already_gated, or @not_a_write.

           unclassified: #{inspect(raw -- classified)}
           stale:        #{inspect(classified -- raw)}
           """
  end

  test "the three lists do not overlap" do
    for {a, b} <- [
          {@guarded, @already_gated},
          {@guarded, @not_a_write},
          {@already_gated, @not_a_write}
        ] do
      assert MapSet.disjoint?(MapSet.new(a), MapSet.new(b))
    end
  end

  test "the scan is not silently empty and reaches the hooks' defp heads" do
    raw = raw_heads()
    assert length(raw) > 100
    assert {"lifecycle_hooks", "archive_container"} in raw
    assert {"mask_hooks", "remask_all"} in raw
  end
end
