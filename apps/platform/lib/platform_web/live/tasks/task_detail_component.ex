defmodule PlatformWeb.Tasks.TaskDetailComponent do
  @moduledoc """
  Task detail + inline edit + plan approval for `PlatformWeb.TasksLive`.

  Task 01a008f6 stage 4. The single largest region of the Tasks surface.

  ## Why detail and plans land together

  Plans & Approval has no render region of its own — its markup is
  interleaved INSIDE the task detail body (the plan-stage cards sit between
  the Skills strip and the Execution Log) plus one `~H` function component
  (`plan_body/1`) that lived in `tasks_live.ex`. Extracting detail alone
  would strand a three-assign concern whose markup renders inside another
  component's template.

  ## Boundary with Execution & Steering (stage 5)

  This component owns the detail panel container, its header, the detail
  body through the plan-stage cards, and the reopen-with-feedback modal.
  Execution & Steering (the execution log, the steering composer with its
  `allow_upload` plumbing, the Outputs strip) and the merge-control cluster
  do NOT move here — they are rendered through the `:steering` and
  `:panel_footer` slots, which keeps them evaluated in the SHELL's assign
  scope and their events untargeted (so they still land on `TasksLive`)
  until stage 5 replaces the slot content with its own component.

  The gate panel (pending-review items, per-item feedback, the review
  canvas modal) is stage 6's. Its markup that sits inside the detail body
  moved with the surrounding region, but its events stay UNTARGETED so they
  continue to land on the shell.

  ## Owned assigns (single writer: this component)

  Detail: `:edit_mode`, `:editing_task_title_id`, `:editing_description`,
  `:confirm_delete`, `:show_reopen_modal`, `:reopen_reason`.

  Plans: `:expanded_plans`, `:reject_plan_open`, `:reject_plan_feedback_text`.

  ## Read-only attrs (owned by the shell, never written here)

  `:selected_task`, `:show_detail`, `:current_user_id`,
  `:current_user_email`, `:my_pinned_task_ids`, `:selected_task_canvases`,
  `:attached_skills`, `:available_skills`, `:pending_reviews`,
  `:superseded_reviews`, `:review_canvases` (the last three are pure
  passthrough to `GatePanelComponent` — stage 6), `:agents`,
  `:agents_by_id`, `:agent_names`, `:users`, `:users_by_id`.

  Per the ownership table fixed in stage 2, the component NEVER writes any
  of those. Writes that must land in shell state are REQUESTED:

    * `send(self(), {:detail_flash, kind, message})`
    * `send(self(), {:detail_refresh})` — board + selected-task reload
    * `send(self(), {:detail_closed})` — teardown + `push_patch(~p"/tasks")`
    * `send(self(), {:detail_task_transitioned, task})`

  `:detail_epoch` is a shell-owned counter bumped by
  `TasksLive.assign_selected_task/2`. It replaces the shell's old direct
  writes to `:edit_mode` / `:expanded_plans`: when the epoch changes, this
  component resets its own local state. That keeps the pre-refactor
  behaviour (selecting or reloading a task drops you out of edit mode and
  re-folds plan revisions) without a second writer.

  ## Events

  All 28 events carry their feature prefix, renamed at extraction time with
  templates and tests in the same commit and no back-compat aliases.
  """
  use PlatformWeb, :live_component

  require Logger

  import Ecto.Query

  alias Platform.Repo
  alias Platform.Skills
  alias Platform.Tasks
  alias Platform.Tasks.CanvasAttachments
  alias Platform.Tasks.ChatPins
  alias Platform.Tasks.PlanRejection
  alias Platform.Tasks.{Plan, Task}

  import PlatformWeb.Tasks.StatusLabels, only: [status_label: 1, phase_label: 1]

  import PlatformWeb.Tasks.TaskDisplay,
    only: [
      agent_name_for: 2,
      assignee_name: 2,
      current_phase_label: 1,
      deletable_task?: 1,
      deploy_target_label: 1,
      phase_assignee_id: 2,
      pinned_by_me?: 3,
      priority_badge_class: 1,
      project_deploy_targets: 1,
      relative_time: 1,
      sponsor?: 2,
      sponsor_name: 2,
      task_display_status: 1,
      unmet_dependency_count: 1
    ]

  @doc false
  def mount(socket) do
    {:ok, reset_local_state(socket, nil)}
  end

  @doc false
  def update(assigns, socket) do
    epoch = assigns[:detail_epoch]
    changed_epoch? = Map.get(socket.assigns, :detail_epoch) != epoch

    socket = assign(socket, assigns)

    socket =
      if changed_epoch? do
        reset_local_state(socket, assigns[:selected_task])
      else
        socket
      end

    {:ok, socket}
  end

  # Local (component-owned) state is reset whenever the shell signals a new
  # selection or a reload via `:detail_epoch`. Mirrors what
  # `TasksLive.assign_selected_task/2` used to write directly.
  defp reset_local_state(socket, task) do
    socket
    |> assign(:edit_mode, false)
    |> assign(:editing_task_title_id, nil)
    |> assign(:editing_description, false)
    |> assign(:confirm_delete, false)
    |> assign(:show_reopen_modal, false)
    |> assign(:reopen_reason, "")
    |> assign(:expanded_plans, MapSet.new(default_expanded_plan_ids(task)))
    |> assign(:reject_plan_open, nil)
    |> assign(:reject_plan_feedback_text, "")
  end

  # ── Shell notifications ─────────────────────────────────────────────────
  #
  # The component never writes shell assigns. It asks. `TasksLive` carries
  # the matching `handle_info/2` clauses.

  defp flash(kind, message), do: send(self(), {:detail_flash, kind, message})
  defp request_refresh, do: send(self(), {:detail_refresh})

  # ── Panel lifecycle ─────────────────────────────────────────────────────

  def handle_event("detail_close", _params, socket) do
    send(self(), {:detail_closed})
    {:noreply, socket}
  end

  # Linked-canvases strip — × button on each chip (stage 5 of
  # task_attach_canvas). Delegates to the CanvasAttachments context and
  # broadcasts `:task_updated` on the board topic so any sibling LiveView
  # session viewing the same task re-renders its strip within the 2s
  # budget. Idempotent — `{:error, :not_found}` from a duplicate click is a
  # no-op. `{:error, :task_forbidden}` lands in the same no-op arm.
  def handle_event("detail_detach_canvas", %{"canvas-id" => canvas_id}, socket) do
    case socket.assigns[:selected_task] do
      %Task{id: task_id} = task ->
        actor = {:user, socket.assigns[:current_user_id]}
        _ = CanvasAttachments.detach_canvas(actor, task_id, canvas_id)
        Tasks.broadcast_board({:task_updated, task})
        request_refresh()
        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  # ── Inline edit events (title / generic field / description) ────────────

  # Detail-panel edit-mode toggle. When toggling OFF, also clear any
  # in-progress inline edits so disengaging doesn't leave a stranded
  # textarea visible.
  def handle_event("detail_toggle_edit_mode", _params, socket) do
    socket =
      if socket.assigns.edit_mode do
        socket
        |> assign(:edit_mode, false)
        |> assign(:editing_task_title_id, nil)
        |> assign(:editing_description, false)
      else
        assign(socket, :edit_mode, true)
      end

    {:noreply, socket}
  end

  # Configure-a-deploy-target affordance fires when the readonly value block
  # is in `:none` state (see `deploy_target_display/1`). Flips the detail
  # pane into `edit_mode` so the existing edit-mode dropdown becomes
  # interactive.
  def handle_event("detail_open_deploy_target_config", _params, socket) do
    {:noreply, assign(socket, :edit_mode, true)}
  end

  # Server-side defense-in-depth: when @edit_mode is false the affordances
  # that emit these events aren't rendered, but a stray invocation from
  # elsewhere (devtools, legacy hook) must not be able to mutate the task.
  def handle_event("detail_start_edit_title", _params, %{assigns: %{edit_mode: false}} = socket),
    do: {:noreply, socket}

  def handle_event("detail_start_edit_title", %{"task-id" => task_id}, socket) do
    {:noreply, assign(socket, :editing_task_title_id, task_id)}
  end

  def handle_event("detail_update_task_title", _params, %{assigns: %{edit_mode: false}} = socket),
    do: {:noreply, socket}

  def handle_event(
        "detail_update_task_title",
        %{"value" => raw_title, "task-id" => task_id},
        socket
      ) do
    new_title = String.trim(raw_title)

    socket =
      cond do
        new_title == "" ->
          flash(:error, "Title cannot be empty.")
          assign(socket, :editing_task_title_id, nil)

        true ->
          case Tasks.get_task_record(task_id) do
            nil ->
              flash(:error, "Task not found.")
              assign(socket, :editing_task_title_id, nil)

            task ->
              if task.title == new_title do
                # No-op: same title, just clear the editing state.
                assign(socket, :editing_task_title_id, nil)
              else
                case Tasks.update_task(task, %{title: new_title}) do
                  {:ok, _updated} ->
                    # Refresh the originating session immediately. The
                    # broadcast also fires for other connected sessions.
                    request_refresh()
                    assign(socket, :editing_task_title_id, nil)

                  {:error, _changeset} ->
                    flash(:error, "Could not update title.")
                    assign(socket, :editing_task_title_id, nil)
                end
              end
          end
      end

    {:noreply, socket}
  end

  # ── Generic field update (priority / deploy_target / sponsor_user_id) ──
  #
  # Whitelisted to avoid arbitrary attribute writes from the wire. Empty
  # strings normalize to `nil` (used by deploy_target's "(none)" option and
  # by sponsor_user_id's "No Sponsor" option). Other unknown fields flash a
  # generic error.
  #
  # `assignee_id` is intentionally NOT in this list. Per ADR 0044, the
  # canonical writer for assignee is `save_assignees` (Configure modal),
  # which routes through `Tasks.set_phase_assignees/2` so the write survives
  # the next phase transition.

  @editable_task_fields ~w(priority deploy_target sponsor_user_id)

  def handle_event("detail_update_task_field", _params, %{assigns: %{edit_mode: false}} = socket),
    do: {:noreply, socket}

  def handle_event(
        "detail_update_task_field",
        %{"field" => field, "value" => value, "task-id" => task_id},
        socket
      )
      when field in @editable_task_fields do
    normalized = if value == "", do: nil, else: value

    attrs = %{String.to_existing_atom(field) => normalized}

    case Tasks.get_task_record(task_id) do
      nil ->
        flash(:error, "Task not found.")

      task ->
        # Thread the acting human as the actor so the M4 (019f9251)
        # sponsor-assigned producer can skip the self-sponsor case.
        actor = {:user, socket.assigns[:current_user_id]}

        case Tasks.update_task(task, attrs, actor: actor) do
          {:ok, _updated} ->
            request_refresh()

          {:error, %Ecto.Changeset{} = cs} ->
            flash(:error, "Could not update #{field}: #{changeset_error(cs, field)}")

          {:error, _} ->
            flash(:error, "Could not update #{field}.")
        end
    end

    {:noreply, socket}
  end

  def handle_event("detail_update_task_field", %{"field" => field}, socket) do
    flash(:error, "Field '#{field}' is not editable.")
    {:noreply, socket}
  end

  # ── Description editor events (toggle render ↔ textarea) ───────────────
  #
  # Boolean assign rather than per-task id because only one detail panel is
  # open at a time. Save persists via Tasks.update_task/2; Cancel just
  # discards local state without touching the DB.

  def handle_event(
        "detail_start_edit_description",
        _params,
        %{assigns: %{edit_mode: false}} = socket
      ),
      do: {:noreply, socket}

  def handle_event("detail_start_edit_description", _params, socket) do
    {:noreply, assign(socket, :editing_description, true)}
  end

  def handle_event("detail_cancel_edit_description", _params, socket) do
    {:noreply, assign(socket, :editing_description, false)}
  end

  def handle_event("detail_save_description", _params, %{assigns: %{edit_mode: false}} = socket),
    do: {:noreply, socket}

  def handle_event("detail_save_description", %{"description" => new_desc}, socket) do
    task = socket.assigns.selected_task

    cond do
      is_nil(task) ->
        :ok

      task.description == new_desc ->
        # No-op when unchanged; just close the editor.
        :ok

      true ->
        case Tasks.update_task(task, %{description: new_desc}) do
          {:ok, _updated} -> request_refresh()
          {:error, _changeset} -> flash(:error, "Could not save description.")
        end
    end

    {:noreply, assign(socket, :editing_description, false)}
  end

  # ── Task deletion events ────────────────────────────────────────────────

  def handle_event("detail_request_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, true)}
  end

  def handle_event("detail_cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, false)}
  end

  def handle_event("detail_confirm_delete", _params, socket) do
    task = socket.assigns.selected_task

    if task do
      case Tasks.soft_delete_task(task) do
        {:ok, _deleted} ->
          flash(:info, "Task deleted.")
          send(self(), {:detail_closed})

        {:error, :restricted_status} ->
          flash(:error, "Cannot delete a task that is #{status_label(task.status)}.")

        {:error, _reason} ->
          flash(:error, "Failed to delete task.")
      end
    end

    {:noreply, assign(socket, :confirm_delete, false)}
  end

  def handle_event("detail_transition", %{"id" => task_id, "status" => new_status}, socket) do
    task = Tasks.get_task_detail(task_id)

    if task do
      # LiveView is user-facing regardless of session state — thread the
      # `{:user, _}` actor through so `Tasks.require_approved_plan_for/3`
      # can fire the sponsor-bypass rule (ADR 0042 §sponsor-bypass).
      case Tasks.transition_task(task, new_status, {:user, socket.assigns[:current_user_id]}) do
        {:ok, updated} ->
          flash(:info, "Task moved to #{new_status}.")
          send(self(), {:detail_task_transitioned, Tasks.get_task_detail(updated.id)})

        {:error, :invalid_transition} ->
          flash(:error, "Cannot transition to #{new_status} from #{task.status}.")

        {:error, :no_approved_plan} ->
          flash(
            :error,
            "Cannot start execution: this task has no approved plan. Create and approve a plan first."
          )

        {:error, :no_deploy_target_resolved} ->
          flash(
            :error,
            "Cannot deploy: no deploy target set. Set one on this task or configure a project default."
          )

        {:error, reason} ->
          flash(:error, "Transition failed: #{inspect(reason)}")
      end
    else
      flash(:error, "Task not found.")
    end

    {:noreply, socket}
  end

  # ── Reopen-with-feedback modal ──────────────────────────────────────────

  def handle_event("detail_open_reopen_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_reopen_modal, true)
     |> assign(:reopen_reason, "")}
  end

  def handle_event("detail_close_reopen_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_reopen_modal, false)
     |> assign(:reopen_reason, "")}
  end

  def handle_event("detail_reopen_reason_changed", params, socket) do
    # The textarea phx-change can ship the value either as a top-level
    # `"reason"` string or wrapped under a form prefix; accept either.
    reason =
      cond do
        is_binary(Map.get(params, "reason")) -> Map.get(params, "reason")
        is_binary(Map.get(params, "value")) -> Map.get(params, "value")
        true -> ""
      end

    {:noreply, assign(socket, :reopen_reason, reason)}
  end

  def handle_event("detail_submit_reopen", params, socket) do
    task = socket.assigns.selected_task

    # Allow the form-submitted `reason` to override the assign for the rare
    # race where phx-change hasn't landed yet.
    reason =
      case Map.get(params, "reason") do
        v when is_binary(v) -> v
        _ -> socket.assigns.reopen_reason
      end

    cond do
      is_nil(task) ->
        flash(:error, "No task selected.")
        {:noreply, close_reopen(socket)}

      String.trim(reason || "") == "" ->
        # Defensive: the Submit button is disabled client-side, but if the
        # event makes it through we keep the modal open and surface the
        # validation error rather than silently no-oping.
        flash(:error, "A reason is required to reopen the task.")
        {:noreply, socket}

      true ->
        by_user_id = socket.assigns[:current_user_id]

        case Tasks.reopen_with_feedback(task.id, reason, by_user_id) do
          {:ok, _task} ->
            flash(:info, "Task reopened.")
            request_refresh()
            {:noreply, close_reopen(socket)}

          {:error, :reason_required} ->
            flash(:error, "A reason is required to reopen the task.")
            {:noreply, socket}

          {:error, :not_done} ->
            flash(:error, "Only tasks in `done` can be reopened.")
            request_refresh()
            {:noreply, close_reopen(socket)}

          {:error, :no_plan} ->
            flash(:error, "Cannot reopen: this task has no active plan to reject.")
            {:noreply, close_reopen(socket)}

          {:error, reason} ->
            flash(:error, "Reopen failed: #{inspect(reason)}")
            {:noreply, socket}
        end
    end
  end

  # ── Skills ──────────────────────────────────────────────────────────────

  def handle_event("detail_attach_skill", %{"skill_id" => skill_id}, socket) do
    task = socket.assigns.selected_task

    if task && skill_id != "" do
      Skills.attach_skill(skill_id, "task", task.id)
      send(self(), {:detail_skills_changed})
    end

    {:noreply, socket}
  end

  def handle_event("detail_detach_skill", %{"skill_id" => skill_id}, socket) do
    task = socket.assigns.selected_task

    if task do
      Skills.detach_skill(skill_id, "task", task.id)
      send(self(), {:detail_skills_changed})
    end

    {:noreply, socket}
  end

  # ── Pin-to-Chat toggle (task 019f62a1 stage 4) ─────────────────────────
  #
  # Sponsor-only affordance in the task detail header. The DOM `:if` gate
  # already omits the button for non-sponsors, but the server re-checks:
  # LiveView events can be forged via CDP / `liveSocket.push`, and the pin
  # write is the earliest point that a fresh backlog task materialises a
  # `chat_spaces` row. A bypass would let any authenticated user pin — and
  # thereby materialise the exec space — for any task they can see.
  def handle_event("detail_toggle_chat_pin", _params, socket) do
    task = socket.assigns[:selected_task]
    user_id = socket.assigns[:current_user_id]
    email = socket.assigns[:current_user_email]

    cond do
      is_nil(task) ->
        # No task open — event fired against a stale panel. Silent noop.
        :ok

      is_nil(email) ->
        # Anonymous session or user record hard-deleted between mount and
        # click. Can't attribute a pin — refuse with a flash.
        flash(:error, "You need to be signed in to pin tasks to Chat.")

      not sponsor?(task, user_id) ->
        Logger.warning(
          "[TaskDetailComponent] detail_toggle_chat_pin refused for user_id=#{inspect(user_id)} " <>
            "task_id=#{task.id} — non-sponsor bypass attempt (task sponsor_user_id=" <>
            "#{inspect(task.sponsor_user_id)})"
        )

        flash(:error, "Only the task sponsor can pin this task.")

      true ->
        participant = %{kind: "user", id: email}

        if pinned_by_me?(task, user_id, socket.assigns.my_pinned_task_ids) do
          # The MapSet update happens on the broadcast round-trip; `unpin/3`
          # fires `:task_pin_removed`, which the shell's handle_info drops
          # from `:my_pinned_task_ids`.
          _ = ChatPins.unpin(task.id, participant, email)
          flash(:info, "Unpinned from Chat.")
        else
          case ChatPins.pin(task.id, participant, email) do
            {:ok, _} ->
              flash(:info, "Pinned to Chat.")

            {:error, reason} ->
              Logger.warning(
                "[TaskDetailComponent] detail_toggle_chat_pin pin/3 failed for task_id=" <>
                  "#{task.id} reason=#{inspect(reason)}"
              )

              flash(:error, "Could not pin this task to Chat.")
          end
        end
    end

    {:noreply, socket}
  end

  # ── Plan review events ──────────────────────────────────────────────────

  def handle_event("plan_approve", %{"plan-id" => plan_id}, socket) do
    plan = fetch_plan(plan_id)

    if plan && plan.status == "pending_review" do
      case Tasks.approve_plan(plan, socket.assigns[:current_user_id]) do
        {:ok, _} ->
          flash(:info, "Plan approved.")
          request_refresh()

        {:error, reason} ->
          # Log the reason: an approval failure used to produce a constant
          # flash and NO server-side output at all, which made a production
          # outage effectively invisible.
          Logger.error(
            "plan_approve failed for plan #{plan.id} (task #{plan.task_id}): #{inspect(reason)}"
          )

          flash(:error, "Failed to approve plan.")
      end
    else
      flash(:error, "Plan not found or not pending review.")
    end

    {:noreply, socket}
  end

  # Rejection without feedback is still a valid power-user shortcut; the
  # inline drawer below is the gold path.
  def handle_event("plan_reject", %{"plan-id" => plan_id}, socket) do
    plan = fetch_plan(plan_id)

    if plan && plan.status == "pending_review" do
      case Tasks.reject_plan(plan, socket.assigns[:current_user_id]) do
        {:ok, _} ->
          flash(:info, "Plan rejected.")
          request_refresh()

        {:error, _} ->
          flash(:error, "Failed to reject plan.")
      end
    else
      flash(:error, "Plan not found or not pending review.")
    end

    {:noreply, socket}
  end

  # ── Reject-with-feedback inline UI (task 019e30be stage 1) ──────────────

  def handle_event("plan_toggle_reject_feedback", %{"plan-id" => plan_id}, socket) do
    next = if socket.assigns.reject_plan_open == plan_id, do: nil, else: plan_id

    {:noreply,
     socket
     |> assign(:reject_plan_open, next)
     |> assign(:reject_plan_feedback_text, "")}
  end

  def handle_event("plan_update_reject_feedback_text", %{"value" => text}, socket) do
    {:noreply, assign(socket, :reject_plan_feedback_text, text)}
  end

  def handle_event("plan_submit_reject_with_feedback", %{"plan-id" => plan_id}, socket) do
    plan = fetch_plan(plan_id)
    feedback = String.trim(socket.assigns.reject_plan_feedback_text || "")

    cond do
      is_nil(plan) or plan.status != "pending_review" ->
        flash(:error, "Plan not found or not pending review.")
        {:noreply, socket}

      feedback == "" ->
        # Keep the drawer open and surface a flash so the reviewer knows the
        # textarea isn't optional — the whole point is to capture the "why"
        # for the next planner (ContextAssembler reads rejection_reason).
        flash(:error, "Please describe what needs to change before rejecting.")
        {:noreply, socket}

      true ->
        rejected_by = socket.assigns[:current_user_id]

        case Tasks.reject_plan(plan, rejected_by, feedback) do
          {:ok, rejected_plan} ->
            # Also post the feedback into the task's execution space so the
            # planner re-dispatch picks it up via AttentionRouter. Invoked
            # from the CALLER (not inside `Tasks.reject_plan/3`) because
            # reject_plan runs inside `reopen_with_feedback/3`'s transaction
            # and wrapping a chat post in it would risk rolling back the
            # rejection if the post fails.
            PlanRejection.post_feedback(rejected_plan, rejected_by, feedback)
            flash(:info, "Plan rejected with feedback.")
            request_refresh()

            {:noreply,
             socket
             |> assign(:reject_plan_open, nil)
             |> assign(:reject_plan_feedback_text, "")}

          {:error, _} ->
            flash(:error, "Failed to reject plan.")
            {:noreply, socket}
        end
    end
  end

  # ── Plan revision folding events ───────────────────────────────────────

  def handle_event("plan_expand", %{"plan-id" => plan_id}, socket) do
    case Platform.UUID.cast(plan_id) do
      {:ok, uuid} ->
        {:noreply,
         assign(socket, :expanded_plans, MapSet.put(socket.assigns.expanded_plans, uuid))}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("plan_collapse", %{"plan-id" => plan_id}, socket) do
    case Platform.UUID.cast(plan_id) do
      {:ok, uuid} ->
        {:noreply,
         assign(socket, :expanded_plans, MapSet.delete(socket.assigns.expanded_plans, uuid))}

      :error ->
        {:noreply, socket}
    end
  end

  defp close_reopen(socket) do
    socket
    |> assign(:show_reopen_modal, false)
    |> assign(:reopen_reason, "")
  end

  defp fetch_plan(plan_id) do
    case Platform.UUID.cast(plan_id) do
      {:ok, uuid} -> Repo.get(Plan, uuid)
      :error -> nil
    end
  end

  # Plan-approval markup. A `Phoenix.Component` function component in the
  # same module — a pure render helper, explicitly permitted by ADR-0035
  # and NOT a fourth shape. Split out because the detail + plans region is
  # the largest in the Tasks surface and the LiveComponent would otherwise
  # be one unreadable ~1,200-line `render/1`.
  attr(:task, :any, required: true)
  attr(:expanded_plans, :any, required: true)
  attr(:reject_plan_open, :any, default: nil)
  attr(:reject_plan_feedback_text, :string, default: "")
  attr(:target, :any, required: true)

  defp plan_panel(assigns) do
    ~H"""
    <%!-- Plan stages --%>
    <div :if={@task.plans != []} class="space-y-2">
      <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
        Plan
      </h3>
      <% {rejected_plans, active_plans} = partition_plans(@task) %>

      <%!-- Folded rejected revisions (oldest first). Each row is a clickable
             summary that reveals the full plan body when expanded. --%>
      <div
        :for={plan <- rejected_plans}
        class="rounded-box border border-base-300/60 bg-base-200/20 overflow-hidden"
      >
        <% expanded? = plan_expanded?(@expanded_plans, plan) %>
        <button
          type="button"
          data-role="plan-summary"
          data-plan-id={plan.id}
          phx-click={if expanded?, do: "plan_collapse", else: "plan_expand"}
          phx-target={@target}
          phx-value-plan-id={plan.id}
          class="flex h-8 w-full items-center gap-2 px-3 text-xs text-base-content/50 hover:bg-base-200/40 transition-colors"
        >
          <span class={[
            "hero-chevron-right size-3 shrink-0 transition-transform",
            expanded? && "rotate-90"
          ]}>
          </span>
          <span class="flex-1 text-left truncate">{plan_summary_label(plan)}</span>
        </button>
        <div
          :if={expanded?}
          data-role="plan-body"
          data-plan-id={plan.id}
          class="border-t border-base-300/60 p-3 space-y-2 bg-base-200/30"
        >
          <%!-- Full rejection reason. Renders nothing for legacy rows
                 where `rejection_reason` is nil so the body doesn't grow
                 an empty box. --%>
          <div
            :if={present?(plan.rejection_reason)}
            data-role="plan-rejection-reason"
            data-plan-id={plan.id}
            class="rounded border border-base-300/60 bg-base-100/40 px-3 py-2"
          >
            <p class="text-[10px] uppercase tracking-wider text-base-content/50 mb-1">
              Rejection reason
            </p>
            <p class="text-xs italic text-base-content/70 whitespace-pre-wrap">
              {plan.rejection_reason}
            </p>
          </div>
          <.plan_body plan={plan} />
        </div>
      </div>

      <%!-- Active plans render in full, exactly as before. --%>
      <div
        :for={plan <- active_plans}
        data-role="plan-body"
        data-plan-id={plan.id}
        class={"rounded-box border p-3 space-y-2 #{if plan.status == "pending_review", do: "border-warning bg-warning/5", else: "border-base-300 bg-base-200/30"}"}
      >
        <div class="flex items-center justify-between">
          <span class="text-xs font-medium">v{plan.version}</span>
          <span :if={plan.status == "pending_review"} class="badge badge-warning badge-xs">
            pending review
          </span>
          <span :if={plan.status != "pending_review"} class="badge badge-outline badge-xs">
            {plan.status}
          </span>
        </div>
        <%!-- Approve / Reject buttons — prominent, above stages. Only the
               active pending_review plan gets these; folded rejected
               revisions never re-render the buttons.

               Reject is now a toggle: it opens an inline feedback drawer
               (see the `:if={@reject_plan_open == plan.id}` block below)
               and the actual rejection fires from the Confirm button
               inside that drawer via `submit_reject_with_feedback`. The
               legacy `reject_plan` event is still handled server-side
               for tests / power users wiring the click directly. --%>
        <div :if={plan.status == "pending_review"} class="flex gap-2">
          <button
            class="btn btn-sm btn-success flex-1"
            phx-click="plan_approve"
            phx-target={@target}
            phx-value-plan-id={plan.id}
          >
            Approve Plan
          </button>
          <button
            class="btn btn-sm btn-ghost btn-error"
            phx-click="plan_toggle_reject_feedback"
            phx-target={@target}
            phx-value-plan-id={plan.id}
            data-role="plan-reject-toggle"
            data-plan-id={plan.id}
            aria-expanded={@reject_plan_open == plan.id}
          >
            <span :if={@reject_plan_open == plan.id} class="hero-x-mark size-3 mr-1"></span>
            {if @reject_plan_open == plan.id, do: "Cancel", else: "Reject"}
          </button>
        </div>

        <%!-- Inline reject-with-feedback drawer. Mirrors the per-review-
               item pattern shipped in the stack-feedback overlay (~line
               2563): a labelled textarea + Confirm / Cancel pair below
               the toggle. The 16px `text-base` class on touch keeps iOS
               from triggering form-zoom; the `pb-[env(safe-area-inset-
               bottom)]` echoes the FAB safe-area handling so the buttons
               stay reachable when the iOS keyboard pops the form into the
               bottom of the viewport. --%>
        <div
          :if={plan.status == "pending_review" and @reject_plan_open == plan.id}
          data-role="plan-reject-feedback-form"
          data-plan-id={plan.id}
          class="mt-2 space-y-2 rounded-lg border border-error/30 bg-error/5 p-3 pb-[max(0.75rem,env(safe-area-inset-bottom))]"
        >
          <label
            for={"plan-reject-feedback-#{plan.id}"}
            class="block text-[10px] uppercase tracking-wider text-base-content/60"
          >
            What needs to change?
          </label>
          <textarea
            id={"plan-reject-feedback-#{plan.id}"}
            name="feedback"
            rows="3"
            class="textarea textarea-bordered w-full text-base resize-y min-h-[5rem]"
            placeholder="Describe what the next plan should do differently…"
            phx-keyup="plan_update_reject_feedback_text"
            phx-target={@target}
            phx-debounce="150"
            data-role="plan-reject-feedback-text"
            data-plan-id={plan.id}
          >{@reject_plan_feedback_text}</textarea>
          <div class="flex gap-2">
            <button
              type="button"
              class={[
                "btn btn-sm btn-error flex-1",
                String.trim(@reject_plan_feedback_text || "") == "" && "btn-disabled opacity-50"
              ]}
              disabled={String.trim(@reject_plan_feedback_text || "") == ""}
              aria-disabled={
                if(String.trim(@reject_plan_feedback_text || "") == "",
                  do: "true",
                  else: "false"
                )
              }
              phx-click="plan_submit_reject_with_feedback"
              phx-target={@target}
              phx-value-plan-id={plan.id}
              data-role="plan-reject-feedback-submit"
              data-plan-id={plan.id}
            >
              Confirm rejection
            </button>
            <button
              type="button"
              class="btn btn-sm btn-ghost"
              phx-click="plan_toggle_reject_feedback"
              phx-target={@target}
              phx-value-plan-id={plan.id}
              data-role="plan-reject-feedback-cancel"
              data-plan-id={plan.id}
            >
              Cancel
            </button>
          </div>
        </div>
        <.plan_body plan={plan} />
      </div>
    </div>
    """
  end

  defp stage_status_icon("passed"), do: "hero-check-circle text-success"
  defp stage_status_icon("failed"), do: "hero-x-circle text-error"
  defp stage_status_icon("running"), do: "hero-arrow-path text-info animate-spin"
  defp stage_status_icon("skipped"), do: "hero-minus-circle text-base-content/40"
  defp stage_status_icon(_), do: "hero-clock text-base-content/40"

  @doc false
  def render(assigns) do
    ~H"""
    <div id={@id} class="contents">
      <%!-- Task detail panel (slide-in from right). Bottom edge stops at
             the top of the bottom-nav, including iOS home-indicator safe-
             area: `--bottom-nav-height` is the nav's content row (56px on
             phones, 0 on desktop) and the nav adds
             `env(safe-area-inset-bottom)` below itself for the indicator.
             Without that env() addition the panel and nav don't meet on iOS
             — there's a ~34px gap where the panel ends above the nav's
             safe-area. Replaces PR #331's inner-scroller `pb-[calc(...)]`,
             which left visible dead space below content. --%>
      <div
        :if={@show_detail && @selected_task}
        class="fixed top-0 bottom-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px))] right-0 z-30 flex w-full max-w-lg flex-col border-l border-base-300 bg-base-100 shadow-xl safe-area-top"
      >
        <div class="flex items-center justify-between border-b border-base-300 px-4 py-3">
          <%= cond do %>
            <% @edit_mode and @editing_task_title_id == @selected_task.id -> %>
              <input
                type="text"
                name="value"
                value={@selected_task.title}
                phx-blur="detail_update_task_title"
                phx-target={@myself}
                phx-value-task-id={@selected_task.id}
                phx-hook="InlineEdit"
                data-submit-event="detail_update_task_title"
                data-task-id={@selected_task.id}
                data-role="detail-title-input"
                class="input input-sm input-bordered text-sm font-semibold flex-1 mr-2"
                id={"detail-title-input-#{@selected_task.id}"}
              />
            <% @edit_mode -> %>
              <h2
                id={"detail-title-#{@selected_task.id}"}
                class="text-sm font-semibold truncate cursor-text rounded px-1 -mx-1 flex-1 border border-dashed border-base-300 hover:border-base-content/40 hover:bg-base-200"
                phx-click="detail_start_edit_title"
                phx-target={@myself}
                phx-value-task-id={@selected_task.id}
                data-role="detail-title"
                data-editable="true"
                title="Click to edit"
              >
                {@selected_task.title}
              </h2>
            <% true -> %>
              <h2
                id={"detail-title-#{@selected_task.id}"}
                class="text-sm font-semibold truncate flex-1"
                data-role="detail-title"
                data-editable="false"
              >
                {@selected_task.title}
              </h2>
          <% end %>
          <div class="flex items-center gap-1">
            <span
              :if={@edit_mode}
              class="badge badge-sm badge-primary badge-outline"
              data-role="edit-mode-indicator"
            >
              Edit mode
            </span>
            <button
              class={[
                "btn btn-sm btn-square max-sm:h-11 max-sm:w-11 max-sm:min-h-[44px] max-sm:min-w-[44px]",
                if(@edit_mode, do: "btn-primary", else: "btn-ghost")
              ]}
              phx-click="detail_toggle_edit_mode"
              phx-target={@myself}
              title="Toggle edit mode"
              aria-label="Toggle edit mode"
              data-role="edit-mode-toggle"
              data-edit-mode={to_string(@edit_mode)}
              aria-pressed={to_string(@edit_mode)}
            >
              <span class="hero-pencil-square size-4"></span>
            </button>
            <button
              :if={deletable_task?(@selected_task)}
              class="btn btn-sm btn-ghost btn-square text-error max-sm:h-11 max-sm:w-11 max-sm:min-h-[44px] max-sm:min-w-[44px]"
              phx-click="detail_request_delete"
              phx-target={@myself}
              title="Delete task"
              aria-label="Delete task"
            >
              <span class="hero-trash size-4"></span>
            </button>
            <%!-- Pin-to-Chat toggle (task 019f62a1 stage 4). Sponsor-only via
                   DOM `:if` — the server-side re-check inside `toggle_task_chat_pin`
                   is the real gate; the `:if` just keeps non-sponsors from seeing
                   a non-functional button. Rendered for every status (including
                   `backlog`) so a fresh task can be promoted into the rail before
                   the plan engine ever creates its execution space. The pin write
                   lazily materialises `chat_spaces` via `ExecutionSpace.find_or_create/1`.
                   Icon `hero-map-pin(-solid)` — deliberately NOT `hero-bookmark`,
                   which is already the message-level pin glyph. --%>
            <button
              :if={sponsor?(@selected_task, @current_user_id)}
              class={[
                "btn btn-sm btn-square max-sm:h-11 max-sm:w-11 max-sm:min-h-[44px] max-sm:min-w-[44px]",
                if(pinned_by_me?(@selected_task, @current_user_id, @my_pinned_task_ids),
                  do: "btn-primary",
                  else: "btn-ghost"
                )
              ]}
              phx-click="detail_toggle_chat_pin"
              phx-target={@myself}
              data-role="task-chat-pin-toggle"
              aria-pressed={
                to_string(pinned_by_me?(@selected_task, @current_user_id, @my_pinned_task_ids))
              }
              aria-label={
                if pinned_by_me?(@selected_task, @current_user_id, @my_pinned_task_ids),
                  do: "Unpin task from Chat",
                  else: "Pin task to Chat"
              }
              title={
                if pinned_by_me?(@selected_task, @current_user_id, @my_pinned_task_ids),
                  do: "Unpin from Chat",
                  else: "Pin to Chat"
              }
            >
              <span class={[
                if(pinned_by_me?(@selected_task, @current_user_id, @my_pinned_task_ids),
                  do: "hero-map-pin-solid",
                  else: "hero-map-pin"
                ),
                "size-4"
              ]}>
              </span>
            </button>
            <button
              class="btn btn-sm btn-ghost btn-square max-sm:h-11 max-sm:w-11 max-sm:min-h-[44px] max-sm:min-w-[44px]"
              phx-click="detail_close"
              phx-target={@myself}
              aria-label="Close task details"
            >
              <span class="hero-x-mark size-4"></span>
            </button>
          </div>
        </div>

        <%!-- Inner scroller. The panel container (above) is bounded by
               `--bottom-nav-height`, so the scroll viewport already ends at
               the top of the bottom-tab nav and standard `p-4` padding
               suffices on every viewport. --%>
        <div class="flex-1 overflow-y-auto p-4 space-y-5">
          <%!-- Delete confirmation --%>
          <div
            :if={@confirm_delete}
            class="rounded-box border border-error bg-error/10 p-4 space-y-3"
          >
            <p class="text-sm font-medium text-error">
              Are you sure you want to delete this task?
            </p>
            <div class="flex gap-2">
              <button
                phx-click="detail_confirm_delete"
                phx-target={@myself}
                class="btn btn-error btn-sm"
              >
                Yes, Delete
              </button>
              <button
                phx-click="detail_cancel_delete"
                phx-target={@myself}
                class="btn btn-ghost btn-sm"
              >
                Cancel
              </button>
            </div>
          </div>

          <%!-- Status + Priority --%>
          <div class="flex flex-wrap items-center gap-2">
            <% {detail_status_label, detail_status_class} = task_display_status(@selected_task) %>
            <span class={detail_status_class}>{detail_status_label}</span>
            <span :if={@selected_task.priority} class={priority_badge_class(@selected_task.priority)}>
              {String.capitalize(@selected_task.priority)}
            </span>
            <span :if={@selected_task.project} class="text-xs text-base-content/50">
              {(@selected_task.project && @selected_task.project.name) || "—"}
            </span>
            <span :if={@selected_task.epic} class="text-xs text-base-content/50">
              / {(@selected_task.epic && @selected_task.epic.name) || "—"}
            </span>
          </div>

          <%!-- Why this is blocked (task 01a004ad stage 3).

                 The watchdog writes a careful sentence onto
                 `metadata["blocked_reason"]` when it escalates, and until this
                 block existed nothing anywhere read it. `blocked_explanation/1`
                 (this module) is the single source of truth for which of the
                 two branches renders; this template only paints what it returns
                 and never inspects metadata itself.

                 Design direction is binding (canvas "Blocked reason: design
                 direction"): the sentence IS the design. No icon, no warning
                 triangle, no alert box, no coloured fill — a reader who
                 navigated here already knows something is wrong, and chrome
                 competes with the only thing carrying information. `--color-error`
                 appears exactly once, as the 3px left border, inheriting the
                 treatment agent messages use for identity.

                 The sentence WRAPS FREELY — deliberately no `truncate` and no
                 `line-clamp-*`. The watchdog names a stage, a count, a duration
                 and a prior action; clamping drops the last clause, which is what
                 was already retried automatically, i.e. the useful part.

                 The dependency copy says in words that nothing is needed from the
                 reader. A bare list of task names does not: readers supply
                 "someone do something" from the word Blocked alone, and that is
                 false for the whole dependency-gated half of this population.

                 Render-only against `unmet_dependencies` — this block writes no
                 metadata. `:none` renders nothing at all: no empty block, no
                 border, no "no reason recorded" placeholder.

                 `{:dependencies, []}` is treated the same as `:none`. It is
                 reachable: `unmet_dependency_count/1` counts metadata ids while
                 `dependency_summary/1` resolves the `dependencies` FIELD, so a
                 task whose metadata lists unmet ids the field never recorded
                 returns an empty row list. Rendering that branch anyway would
                 print "Waiting on 0 tasks", which is worse than silence.

                 The card face is
                 deliberately unchanged; the card says "stopped", the panel says
                 "why". --%>
          <% blocked_why = blocked_explanation(@selected_task) %>
          <div
            :if={blocked_why != :none and blocked_why != {:dependencies, []}}
            class="flex flex-col gap-1 border-l-[3px] border-error pl-3"
            data-role="blocked-explanation"
          >
            <span class="text-xs font-semibold uppercase tracking-widest text-neutral">
              Why this is blocked
            </span>
            <%= case blocked_why do %>
              <% {:reason, sentence, blocked_at} -> %>
                <p class="text-sm text-base-content">{sentence}</p>
                <span :if={blocked_at} class="text-xs text-neutral">
                  {relative_time(blocked_at)}
                </span>
              <% {:dependencies, blocked_deps} -> %>
                <p class="text-sm text-base-content">
                  {if length(blocked_deps) == 1,
                    do:
                      "Waiting on 1 task. This clears itself when it finishes; nothing is needed from you.",
                    else:
                      "Waiting on #{length(blocked_deps)} tasks. This clears itself when they finish; nothing is needed from you."}
                </p>
                <ul class="flex flex-col gap-1 text-xs">
                  <li
                    :for={dep <- blocked_deps}
                    class="flex items-center gap-2 rounded bg-base-200 px-2 py-1"
                  >
                    <span class={"#{dependency_status_icon(dep.status)} size-4 shrink-0"}></span>
                    <span class="truncate flex-1">
                      {dep.title || "(missing dependency)"}
                    </span>
                    <span
                      :if={dep.status}
                      class="text-[10px] uppercase tracking-wider text-base-content/40"
                    >
                      {status_label(dep.status)}
                    </span>
                  </li>
                </ul>
              <% :none -> %>
            <% end %>
          </div>

          <%!-- Linked-canvases strip (stage 5 of task_attach_canvas).
                 Renders chips for canvases attached via the task_attach_canvas
                 MCP tool (typically agent-uploaded evidence). Soft-deleted
                 canvases stay in the strip with `text-error` styling so the
                 user can detach the stale row rather than the chip silently
                 disappearing.

                 Clickthrough to `/canvases/:id` (task 019e2c4b stage 3) — this
                 strip is the route's first in-app consumer and the reason
                 agent-attached deliverables became clickable. A plain `href`,
                 NOT `navigate`: the standalone page lives in its own
                 `:canvas_standalone` live_session precisely so the
                 `:enforce_external_scope` HTTP plug re-runs, and an anchor makes
                 that full round-trip unconditional instead of leaning on
                 LiveView's cross-live_session redirect behaviour.

                 Soft-deleted rows (`canvas_present == false`) stay UNLINKED: the
                 chip is a detach affordance at that point, not a destination.

                 The × button posts `detach_canvas` which calls the context +
                 broadcasts :task_updated for sibling sessions. --%>
          <div
            :if={@selected_task_canvases != []}
            class="flex flex-wrap items-center gap-2"
            data-role="linked-canvases-strip"
          >
            <span class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
              Canvases
            </span>
            <span
              :for={entry <- @selected_task_canvases}
              class="badge badge-outline gap-1"
              data-role="linked-canvas-chip"
              data-canvas-id={entry.canvas_id}
            >
              <.link
                :if={entry.canvas_present}
                href={~p"/canvases/#{entry.canvas_id}"}
                class="canvas-chip-title hover:underline"
                data-role="linked-canvas-chip-link"
                title={entry.title || "(untitled)"}
              >
                {entry.title || "(untitled)"}
              </.link>
              <span
                :if={not entry.canvas_present}
                class="canvas-chip-title text-error"
                data-role="linked-canvas-chip-deleted"
                title={entry.title || "(deleted canvas)"}
              >
                {entry.title || "(deleted canvas)"}
              </span>
              <button
                type="button"
                phx-click="detail_detach_canvas"
                phx-target={@myself}
                phx-value-canvas-id={entry.canvas_id}
                class="btn btn-xs btn-ghost btn-circle"
                aria-label="Detach canvas"
              >
                <span class="hero-x-mark size-3"></span>
              </button>
            </span>
          </div>

          <%!-- Priority + deploy_target metadata.
                 Off (read-only): plain badges/labels.
                 On (edit_mode): <select>s wired to the generic `update_task_field`
                 event, wrapped in a dashed border affordance to signal "click to
                 edit". Hidden `field`/`task-id` inputs travel with the change
                 because `phx-change` only carries form params. --%>
          <% project_targets = project_deploy_targets(@selected_task.project) %>
          <% dropdown_value = deploy_target_dropdown_value(@selected_task) %>
          <div class="grid grid-cols-2 gap-3">
            <%= if @edit_mode do %>
              <form
                phx-change="detail_update_task_field"
                phx-target={@myself}
                class="flex flex-col gap-1 rounded border border-dashed border-base-300 hover:border-base-content/40 p-1"
                data-role="priority-form"
                data-editable="true"
              >
                <input type="hidden" name="field" value="priority" />
                <input type="hidden" name="task-id" value={@selected_task.id} />
                <label
                  for={"priority-select-#{@selected_task.id}"}
                  class="text-xs font-semibold uppercase tracking-wider text-base-content/50"
                >
                  Priority
                </label>
                <select
                  id={"priority-select-#{@selected_task.id}"}
                  name="value"
                  data-role="priority-select"
                  class="select select-sm select-bordered cursor-pointer"
                >
                  <option
                    :for={p <- Platform.Tasks.Task.priorities()}
                    value={p}
                    selected={@selected_task.priority == p}
                  >
                    {String.capitalize(p)}
                  </option>
                </select>
              </form>

              <form
                phx-change="detail_update_task_field"
                phx-target={@myself}
                class="flex flex-col gap-1 rounded border border-dashed border-base-300 hover:border-base-content/40 p-1"
                data-role="deploy-target-form"
                data-editable="true"
              >
                <input type="hidden" name="field" value="deploy_target" />
                <input type="hidden" name="task-id" value={@selected_task.id} />
                <label
                  for={"deploy-target-select-#{@selected_task.id}"}
                  class="text-xs font-semibold uppercase tracking-wider text-base-content/50"
                >
                  Deploy target
                </label>
                <select
                  id={"deploy-target-select-#{@selected_task.id}"}
                  name="value"
                  data-role="deploy-target-select"
                  data-selected-value={dropdown_value}
                  disabled={project_targets == []}
                  class="select select-sm select-bordered cursor-pointer"
                >
                  <option
                    value=""
                    selected={dropdown_value == ""}
                    data-role="deploy-target-dropdown-inherit-option"
                  >
                    {edit_mode_inherit_option_label(@selected_task, project_targets)}
                  </option>
                  <option
                    :for={t <- project_targets}
                    value={t}
                    selected={dropdown_value == t}
                  >
                    {deploy_target_label(t)}
                  </option>
                </select>
              </form>
            <% else %>
              <div class="flex flex-col gap-1" data-role="priority-readonly" data-editable="false">
                <span class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                  Priority
                </span>
                <span class={[
                  "badge badge-sm",
                  if(@selected_task.priority,
                    do: priority_badge_class(@selected_task.priority),
                    else: "badge-ghost"
                  )
                ]}>
                  {if @selected_task.priority,
                    do: String.capitalize(@selected_task.priority),
                    else: "—"}
                </span>
              </div>

              <div
                class="flex flex-col gap-1"
                data-role="deploy-target-readonly"
                data-editable="false"
              >
                <span class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                  Deploy target
                </span>
                <.deploy_target_display task={@selected_task} target={@myself} />
              </div>
            <% end %>
          </div>

          <%!-- Assignee — no top-level display row. Per ADR 0044 (as amended
                 by Rowan on 2026-07-08 stage-3 rejection), the per-phase
                 "Assignees" section below is the SINGLE affordance for both
                 reading and writing the assignee: it shows the breakdown by
                 phase (contextually useful — the current phase is highlighted
                 in `text-primary`) and its Configure button opens the
                 canonical writer modal. The prior readonly "Current assignee"
                 badge duplicated the derived current-phase pointer and has
                 been removed. --%>

          <%!-- Sponsor (ADR 0042 stage 4). Nullable human shepherd distinct from
                 the technical assignee above. Edit mode: always show the picker so
                 a nil sponsor can be filled in. Readonly: hide the row entirely
                 when nil to avoid a permanent "No Sponsor" chip cluttering the
                 panel. Reuses the same `update_task_field` phx-change flow as
                 the assignee dropdown; `sponsor_user_id` is whitelisted in the
                 handler and the generic branch normalizes "" → nil for the
                 nullable FK. --%>
          <div class="flex flex-col gap-1">
            <%= if @edit_mode do %>
              <form
                phx-change="detail_update_task_field"
                phx-target={@myself}
                class="flex flex-col gap-1 rounded border border-dashed border-base-300 hover:border-base-content/40 p-1"
                data-role="sponsor-form"
                data-editable="true"
              >
                <input type="hidden" name="field" value="sponsor_user_id" />
                <input type="hidden" name="task-id" value={@selected_task.id} />
                <label
                  for={"sponsor-select-#{@selected_task.id}"}
                  class="text-xs font-semibold uppercase tracking-wider text-base-content/50"
                >
                  Sponsor
                </label>
                <select
                  id={"sponsor-select-#{@selected_task.id}"}
                  name="value"
                  data-role="sponsor-select"
                  class="select select-sm select-bordered cursor-pointer"
                >
                  <option value="" selected={is_nil(@selected_task.sponsor_user_id)}>
                    No Sponsor
                  </option>
                  <option
                    :for={user <- @users}
                    value={user.id}
                    selected={@selected_task.sponsor_user_id == user.id}
                  >
                    {user.name || user.email}
                  </option>
                </select>
              </form>
            <% else %>
              <div
                :if={@selected_task.sponsor_user_id}
                data-role="sponsor-readonly"
                data-editable="false"
                class="flex flex-col gap-1"
              >
                <span class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                  Sponsor
                </span>
                <span class="badge badge-sm badge-outline">
                  {sponsor_name(@selected_task, @users_by_id)}
                </span>
              </div>
            <% end %>
          </div>

          <%!-- Reporter + Dates + Assignee name --%>
          <div class="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-base-content/50">
            <span :if={@selected_task.reported_by}>
              <span class="text-base-content/40">Reporter:</span> {@selected_task.reported_by}
            </span>
            <span :if={assignee_name(@selected_task, @agent_names)}>
              <span class="text-base-content/40">Assigned:</span> {assignee_name(
                @selected_task,
                @agent_names
              )}
            </span>
            <span :if={@selected_task.inserted_at}>
              <span class="text-base-content/40">Created:</span> {Calendar.strftime(
                @selected_task.inserted_at,
                "%b %d, %Y"
              )}
            </span>
            <span :if={@selected_task.updated_at}>
              <span class="text-base-content/40">Updated:</span> {relative_time(
                @selected_task.updated_at
              )}
            </span>
          </div>

          <%!-- Dependencies — listed in author order, with a status icon per
                 row. Hidden entirely when the task has no deps. Resolved via
                 a single Repo.all per render (detail panel only). --%>
          <% deps = dependency_summary(@selected_task) %>
          <div :if={deps != []} id="task-dependencies" class="flex flex-col gap-2">
            <span class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
              Dependencies
            </span>
            <ul class="flex flex-col gap-1 text-xs">
              <li
                :for={dep <- deps}
                class="flex items-center gap-2 rounded bg-base-200 px-2 py-1"
              >
                <span class={"#{dependency_status_icon(dep.status)} size-4 shrink-0"}></span>
                <span class="truncate flex-1">
                  {dep.title || "(missing dependency)"}
                </span>
                <span
                  :if={dep.status}
                  class="text-[10px] uppercase tracking-wider text-base-content/40"
                >
                  {status_label(dep.status)}
                </span>
              </li>
            </ul>
          </div>

          <%!-- Assignees by phase — opens a modal that lets the user wire one
                 agent for the whole task (Simple) or different agents per phase
                 (Advanced). --%>
          <div :if={@agents != []} class="flex flex-col gap-2">
            <div class="flex items-center justify-between gap-2">
              <span class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                Assignees
              </span>
              <button
                type="button"
                phx-click="open_assignee_modal"
                phx-target="#tasks-assignees"
                class="btn btn-xs btn-ghost gap-1"
              >
                <span class="hero-cog-6-tooth size-3"></span> Configure
              </button>
            </div>
            <div class="grid grid-cols-3 gap-1 text-[11px]">
              <div :for={phase <- ~w(planning execution review)} class="rounded bg-base-200 p-1.5">
                <p class="text-[10px] uppercase tracking-wider text-base-content/40">
                  {phase_label(phase)}
                </p>
                <p class={[
                  "truncate font-medium",
                  phase == current_phase_label(@selected_task) && "text-primary"
                ]}>
                  {agent_name_for(@agents_by_id, phase_assignee_id(@selected_task, phase)) ||
                    "Unassigned"}
                </p>
              </div>
            </div>
          </div>

          <%!-- Per ADR 0029, plan approval is the start signal. The user
                 approves a plan from the plan-review panel below; that
                 transitions the task to in_progress automatically. No separate
                 manual "Start Task" button. --%>

          <%!-- Transition buttons --%>
          <div :if={available_transitions(@selected_task.status) != []} class="flex flex-wrap gap-2">
            <button
              :for={{target_status, label} <- available_transitions(@selected_task.status)}
              class={transition_btn_class(target_status)}
              phx-click="detail_transition"
              phx-target={@myself}
              phx-value-id={@selected_task.id}
              phx-value-status={target_status}
            >
              {label}
            </button>
          </div>

          <%!-- Reopen-with-feedback button (done tasks only).
                 Sits adjacent to the transition-buttons block so it reads as a
                 top-level task action. Opens a modal that captures a free-form
                 reason; Tasks.reopen_with_feedback/3 rejects the active plan and
                 moves the task back to `planning`. --%>
          <div :if={@selected_task.status == "done"} class="flex flex-wrap gap-2">
            <button
              type="button"
              phx-click="detail_open_reopen_modal"
              phx-target={@myself}
              data-role="reopen-task-button"
              class="btn btn-sm btn-warning gap-1"
            >
              <span class="hero-arrow-uturn-left size-4"></span> Reopen with feedback
            </button>
          </div>

          <%!-- Return-to-planning button (in-flight tasks only: in_progress,
                 in_review, deploying). Mirrors the reopen block but uses
                 btn-error tone because supersede kills any in-flight executor
                 work. Opens a confirm modal; Tasks.supersede_current_plan/3
                 marks the current plan `superseded` and drops the task back to
                 `planning`. Branch and any open PR are left intact. --%>
          <div
            :if={@selected_task.status in ~w(in_progress in_review deploying)}
            class="flex flex-wrap gap-2"
          >
            <button
              type="button"
              phx-click="supersede_open"
              phx-target="#tasks-supersede"
              data-role="supersede-plan-button"
              class="btn btn-sm btn-error gap-1"
            >
              <span class="hero-arrow-uturn-left size-4"></span> Return to planning
            </button>
          </div>

          <%!-- Description — click "Edit" to swap the rendered markdown for a
                 textarea + Save/Cancel. Toggle, not split-preview, per the
                 plan's "cheaper path that's still nice". Edit button is only
                 rendered when @edit_mode is true; in read-only mode the
                 rendered markdown is the only thing visible. --%>
          <div
            class={[
              "space-y-1",
              @edit_mode &&
                "rounded border border-dashed border-base-300 hover:border-base-content/40 p-1"
            ]}
            data-role="description-block"
            data-editable={to_string(@edit_mode)}
          >
            <div class="flex items-center justify-between gap-2">
              <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                Description
              </h3>
              <button
                :if={@edit_mode and !@editing_description}
                type="button"
                phx-click="detail_start_edit_description"
                phx-target={@myself}
                data-role="description-edit-button"
                class="btn btn-xs btn-ghost gap-1"
              >
                <span class="hero-pencil-square size-3"></span> Edit
              </button>
            </div>

            <%= if @edit_mode and @editing_description do %>
              <form
                id="task-description-form"
                phx-hook="ButtonLoading"
                phx-submit="detail_save_description"
                phx-target={@myself}
                data-role="description-form"
                class="space-y-2"
              >
                <textarea
                  name="description"
                  rows="8"
                  data-role="description-textarea"
                  class="textarea textarea-bordered w-full text-sm font-mono"
                >{@selected_task.description}</textarea>
                <div class="flex gap-2">
                  <button type="submit" class="btn btn-primary btn-sm" data-role="description-save">
                    Save
                  </button>
                  <button
                    type="button"
                    phx-click="detail_cancel_edit_description"
                    phx-target={@myself}
                    class="btn btn-ghost btn-sm"
                    data-role="description-cancel"
                  >
                    Cancel
                  </button>
                </div>
              </form>
            <% else %>
              <div
                :if={@selected_task.description}
                id={"task-desc-#{@selected_task.id}"}
                data-role="description-rendered"
                class="prose prose-sm max-w-none text-sm text-base-content/80 chat-markdown task-markdown"
              >
                {Platform.Chat.ContentRenderer.render_message(@selected_task.description)}
              </div>
              <p
                :if={!@selected_task.description}
                data-role="description-empty"
                class="text-sm text-base-content/40 italic"
              >
                {if @edit_mode,
                  do: "No description yet — click Edit to add one.",
                  else: "No description yet."}
              </p>
            <% end %>
          </div>

          <%!-- Reviews & Validation (task 01a008f6 stage 6). The pending-review
                 list, the earlier-submissions disclosure and the review-canvas
                 modal all live in PlatformWeb.Tasks.GatePanelComponent, which
                 owns the four gate assigns outright. What arrives here are
                 read-only lists the shell already loads for SteeringComponent. --%>
          <.live_component
            module={PlatformWeb.Tasks.GatePanelComponent}
            id="tasks-gate-panel"
            pending_reviews={@pending_reviews}
            superseded_reviews={@superseded_reviews}
            review_canvases={@review_canvases}
            current_user_id={@current_user_id}
          />

          <%!-- Skills --%>
          <div class="space-y-2">
            <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 flex items-center gap-1">
              <span class="hero-book-open size-3"></span> Skills
            </h3>

            <%!-- Attached skill chips --%>
            <div :if={@attached_skills != []} class="flex flex-wrap gap-2">
              <div
                :for={{skill, source} <- @attached_skills}
                class={
                    "flex items-center gap-1 rounded-full px-2 py-0.5 text-xs " <>
                      if source == "task",
                        do: "bg-primary/10 text-primary border border-primary/20",
                        else: "bg-base-200 text-base-content/60 border border-base-300"
                  }
              >
                <span class="font-medium">{skill.name}</span>
                <span :if={source != "task"} class="text-[10px] opacity-70">
                  (from {String.capitalize(source)})
                </span>
                <button
                  :if={source == "task"}
                  phx-click="detail_detach_skill"
                  phx-target={@myself}
                  phx-value-skill_id={skill.id}
                  class="ml-0.5 text-primary/60 hover:text-primary"
                  title="Remove skill"
                >
                  <span class="hero-x-mark size-3"></span>
                </button>
              </div>
            </div>

            <%!-- Attach dropdown — only shows skills not already task-level attached --%>
            <% task_skill_ids =
              @attached_skills
              |> Enum.filter(fn {_, src} -> src == "task" end)
              |> Enum.map(fn {skill, _} -> skill.id end)
              |> MapSet.new() %>

            <% attachable =
              Enum.reject(@available_skills, fn s -> MapSet.member?(task_skill_ids, s.id) end) %>

            <div :if={attachable != []}>
              <form phx-change="detail_attach_skill" phx-target={@myself}>
                <select
                  class="select select-bordered select-xs w-full max-w-xs"
                  name="skill_id"
                >
                  <option value="">Attach a skill…</option>
                  <option :for={skill <- attachable} value={skill.id}>{skill.name}</option>
                </select>
              </form>
            </div>
          </div>

          <.plan_panel
            task={@selected_task}
            expanded_plans={@expanded_plans}
            reject_plan_open={@reject_plan_open}
            reject_plan_feedback_text={@reject_plan_feedback_text}
            target={@myself}
          />

          {render_slot(@steering)}
        </div>

        {render_slot(@panel_footer)}
      </div>

      <%!-- Reopen-with-feedback modal (mirrors the assignee-modal shape:
             mobile-first bottom sheet on small screens, centered dialog on
             >=sm). Submit is disabled client-side until the textarea has
             non-whitespace content; the server also re-validates and surfaces
             `:reason_required` as a flash if the client check is bypassed. --%>
      <div
        :if={@show_reopen_modal && @selected_task}
        class="fixed inset-0 z-50 flex items-end sm:items-center justify-center"
        id="reopen-modal"
      >
        <%!-- Backdrop --%>
        <div
          class="absolute inset-0 bg-black/40"
          phx-click="detail_close_reopen_modal"
          phx-target={@myself}
        />

        <%!-- Sheet / dialog --%>
        <div class="relative w-full max-w-lg rounded-t-2xl sm:rounded-2xl bg-base-100 shadow-2xl pb-[env(safe-area-inset-bottom)] max-h-[90vh] overflow-y-auto">
          <%!-- Header --%>
          <div class="flex items-center justify-between border-b border-base-300 px-4 py-3">
            <div class="min-w-0">
              <h2 class="text-base font-semibold">Reopen with feedback</h2>
              <p class="mt-0.5 text-xs text-base-content/60 truncate">
                {@selected_task.title}
              </p>
            </div>
            <button
              type="button"
              phx-click="detail_close_reopen_modal"
              phx-target={@myself}
              class="btn btn-sm btn-ghost btn-square"
              aria-label="Close"
            >
              <span class="hero-x-mark size-4"></span>
            </button>
          </div>

          <%!-- Form body --%>
          <form
            id="task-reopen-form"
            phx-hook="ButtonLoading"
            phx-submit="detail_submit_reopen"
            phx-target={@myself}
            class="flex flex-col gap-3 px-4 py-4"
          >
            <div class="flex flex-col gap-1">
              <label
                for="reopen-reason-textarea"
                class="text-xs font-semibold uppercase tracking-wider text-base-content/60"
              >
                Why is this being reopened?
              </label>
              <textarea
                id="reopen-reason-textarea"
                name="reason"
                data-role="reopen-reason-textarea"
                rows="5"
                phx-change="detail_reopen_reason_changed"
                phx-target={@myself}
                placeholder="Describe what's wrong, what's missing, or what should change. The active plan will be rejected with this reason and the task will return to planning."
                class="textarea textarea-bordered w-full text-sm"
              >{@reopen_reason}</textarea>
              <p
                :if={String.trim(@reopen_reason) == ""}
                class="text-xs text-base-content/50"
                data-role="reopen-reason-hint"
              >
                A reason is required so the planner has context for the next revision.
              </p>
            </div>

            <div class="flex items-center justify-end gap-2 pt-1">
              <button
                type="button"
                phx-click="detail_close_reopen_modal"
                phx-target={@myself}
                class="btn btn-ghost btn-sm"
              >
                Cancel
              </button>
              <button
                type="submit"
                data-role="reopen-submit-button"
                class="btn btn-warning btn-sm"
                disabled={String.trim(@reopen_reason) == ""}
              >
                Reopen task
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end

  # Pulls the first changeset error message for the given field if any —
  # the inline-edit handlers only ever write one field at a time, so this
  # is enough to surface a meaningful flash without dragging in the full
  # `traverse_errors` machinery.
  defp changeset_error(%Ecto.Changeset{errors: errors}, field) do
    field_atom =
      if is_atom(field) do
        field
      else
        try do
          String.to_existing_atom(field)
        rescue
          ArgumentError -> nil
        end
      end

    case Keyword.get(errors, field_atom) do
      {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc ->
          String.replace(acc, "%{#{k}}", to_string(v))
        end)

      _ ->
        "invalid value"
    end
  end

  attr(:task, :any, required: true)
  attr(:target, :any, required: true)

  defp deploy_target_display(assigns) do
    {config_label, strategy_name} =
      case assigns.task.deploy_target_config do
        %{"strategy" => strat} = cfg -> {deploy_target_config_label(cfg), strat}
        _ -> {nil, nil}
      end

    assigns =
      assigns
      |> assign(:config_label, config_label)
      |> assign(:strategy_name, strategy_name)
      |> assign(:resolution, Platform.Tasks.resolve_deploy_target(assigns.task))

    ~H"""
    <%= if @config_label do %>
      <div
        data-role="deploy-target-value"
        data-state="strategy"
        data-strategy={@strategy_name}
        class="flex items-center gap-2 flex-wrap"
      >
        <span class="inline-flex items-center gap-1 rounded-full border border-base-content/20 bg-base-100 px-2 py-0.5 text-xs">
          {@config_label}
        </span>
      </div>
    <% else %>
      <div
        data-role="deploy-target-value"
        data-state={deploy_target_state_name(@resolution)}
        class="flex items-center gap-2 flex-wrap"
      >
        <%= case @resolution do %>
          <% {:explicit, value} -> %>
            <span class="badge badge-sm badge-outline">{deploy_target_label(value)}</span>
          <% {:inherited, value} -> %>
            <span class="badge badge-sm badge-outline">{deploy_target_label(value)}</span>
            <span class="text-xs text-base-content/50">Inherited from project</span>
          <% :none -> %>
            <span class="badge badge-sm badge-warning gap-1">
              <span class="hero-exclamation-triangle size-3"></span> No target set
            </span>
            <button
              type="button"
              phx-click="detail_open_deploy_target_config"
              phx-target={@target}
              data-role="configure-deploy-target-button"
              class="btn btn-xs btn-ghost text-warning"
            >
              Configure a deploy target
            </button>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp deploy_target_state_name({:explicit, _}), do: "explicit"
  defp deploy_target_state_name({:inherited, _}), do: "inherited"
  defp deploy_target_state_name(:none), do: "none"

  # Strategy-aware label for `deploy_target_config` (task 019f5e66 stage 6).
  #
  # Each registered strategy renders as a self-describing string suitable for
  # the readonly detail row — no more raw JSON blobs leaking through. Unknown
  # or malformed configs return `nil` so the caller falls back to the legacy
  # `deploy_target` string rendering.
  #
  # `project_files` performs one lookup for the target project's name so the
  # label can render `"Project Files: <project>/<folder>"` instead of a bare
  # UUID. The lookup is best-effort — if the target project is missing (soft-
  # deleted, cross-tenant, etc.) the label degrades to just the folder.
  defp deploy_target_config_label(%{"strategy" => "project_files"} = cfg) do
    folder = string_or_nil(Map.get(cfg, "folder"))
    project_name = lookup_project_name(Map.get(cfg, "project_id"))

    case {project_name, folder} do
      {nil, nil} -> "Project Files"
      {nil, folder} -> "Project Files: #{folder}"
      {name, nil} -> "Project Files: #{name}"
      {name, folder} -> "Project Files: #{name}/#{folder}"
    end
  end

  defp deploy_target_config_label(%{"strategy" => "docker_deploy"} = cfg) do
    case string_or_nil(Map.get(cfg, "target")) do
      nil -> "Docker"
      target -> "Docker: #{target}"
    end
  end

  defp deploy_target_config_label(%{"strategy" => "pr_merge"}), do: "PR merge"

  defp deploy_target_config_label(%{"strategy" => "skill_driven"} = cfg) do
    slug = string_or_nil(Map.get(cfg, "skill_slug")) || string_or_nil(Map.get(cfg, "skill_id"))

    case slug do
      nil -> "Skill"
      s -> "Skill: #{s}"
    end
  end

  defp deploy_target_config_label(%{"strategy" => "manual"}), do: "Manual"
  defp deploy_target_config_label(_), do: nil

  defp string_or_nil(v) when is_binary(v) and v != "", do: v
  defp string_or_nil(_), do: nil

  defp lookup_project_name(id) when is_binary(id) and id != "" do
    case Platform.Tasks.get_project(id) do
      %Platform.Tasks.Project{name: name} -> name
      _ -> nil
    end
  end

  defp lookup_project_name(_), do: nil

  # Edit-mode dropdown pre-selection value (ADR 0044 v3 stage 2).
  #
  # The edit-mode <select> must reflect the SAME resolved value the readonly
  # view shows — otherwise the user sees "production · Inherited from project"
  # in read mode, clicks edit, and finds "(inherit from project)" pre-selected.
  # That mismatch was the v1 bug: users had to re-pick the value they were
  # already implicitly inheriting.
  #
  # Precedence mirrors `Platform.Tasks.resolve_deploy_target/1`:
  #   * explicit task.deploy_target wins
  #   * inherited value (project default / sole-entry list) is pre-selected
  #   * `:none` falls through to the empty-string placeholder
  #
  # Returns the string that should match the <option value=...> attribute; the
  # empty-string placeholder round-trips to nil via the existing coercion in
  # `update_task_field` handler.
  defp deploy_target_dropdown_value(task) do
    case Platform.Tasks.resolve_deploy_target(task) do
      {:explicit, value} -> value
      {:inherited, value} -> value
      :none -> ""
    end
  end

  # Label for the empty-value option in the edit-mode dropdown.
  # When the project has NO deploy targets configured, the placeholder can't
  # promise inheritance — it explicitly names the empty state so the user
  # knows why the dropdown is disabled.
  defp edit_mode_inherit_option_label(_task, project_targets) do
    if Enum.any?(project_targets),
      do: "(inherit from project)",
      else: "(none — no targets configured)"
  end

  # Resolves a task's declared dependency ids into `[%{id, title, status}]`
  # rows in the order the user authored them. Issues a single `Repo.all`,
  # so it's safe to call in the detail panel (one task per render) but NOT
  # per-card on the kanban. Missing/deleted ids come back as
  # `%{id: id, title: nil, status: nil}` so the template can render a
  # placeholder + gray ✗ icon.
  defp dependency_summary(%Task{} = task) do
    ids = Tasks.dependency_task_ids(task)

    case ids do
      [] ->
        []

      ids ->
        rows =
          Repo.all(
            from(t in Task,
              where: t.id in ^ids,
              select: %{id: t.id, title: t.title, status: t.status}
            )
          )

        by_id = Map.new(rows, &{&1.id, &1})
        Enum.map(ids, &Map.get(by_id, &1, %{id: &1, title: nil, status: nil}))
    end
  end

  defp dependency_summary(_), do: []

  # Heroicon class + colour for a dependency's status icon.
  defp dependency_status_icon("done"), do: "hero-check-circle-solid text-success"
  defp dependency_status_icon("in_progress"), do: "hero-play-circle-solid text-info"

  defp dependency_status_icon(status)
       when status in ~w(blocked planning backlog in_review deploying),
       do: "hero-pause-circle-solid text-warning"

  defp dependency_status_icon(_), do: "hero-x-circle-solid text-base-content/40"

  # ── Blocked-explanation helpers ────────────────────────────────────────
  #
  # Ported from `TasksLive` (task 01a004ad), which landed on main after this
  # branch was cut. They live HERE, not on the shell, because the branch
  # moved `dependency_summary/1` and the detail panel's markup into this
  # component — the helpers sit next to their only two callers (the panel
  # below and `dependency_summary/1`). `TasksLive` keeps a public
  # `defdelegate` surface so the read-side tests and any external caller
  # still reach them at the pre-extraction address.

  # The human sentence `Tasks.stamp_blocked_reason/2` stamps onto
  # `metadata["blocked_reason"]` when the router escalates. Missing,
  # non-binary and blank-after-trim all read as absent so the caller never
  # renders an empty line.
  @doc false
  def blocked_reason(%Task{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "blocked_reason") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  def blocked_reason(_), do: nil

  # Companion timestamp for `blocked_reason/1`. Anything that does not parse
  # as ISO-8601 reads as absent — a garbled stamp must not crash the panel
  # nor render as the epoch.
  @doc false
  def blocked_reason_at(%Task{metadata: metadata}) when is_map(metadata) do
    with value when is_binary(value) <- Map.get(metadata, "blocked_reason_at"),
         {:ok, at, _offset} <- DateTime.from_iso8601(value) do
      at
    else
      _ -> nil
    end
  end

  def blocked_reason_at(_), do: nil

  # Single dispatcher for "why is this task blocked?". Precedence is part of
  # the contract: an escalation sentence wins over unmet dependencies,
  # because a watchdog-exhausted task needs a person even if it also carries
  # stale dependency ids. Any non-`blocked` status is `:none` whatever the
  # metadata says.
  @doc false
  def blocked_explanation(%Task{status: "blocked"} = task) do
    case blocked_reason(task) do
      nil ->
        if unmet_dependency_count(task) > 0 do
          {:dependencies, dependency_summary(task)}
        else
          :none
        end

      sentence ->
        {:reason, sentence, blocked_reason_at(task)}
    end
  end

  def blocked_explanation(_), do: :none

  # ── Per-phase assignee helpers (used by the assignee modal templates) ───

  defp available_transitions("backlog"), do: [{"planning", "Start Planning"}]
  # ADR 0029: plan approval is the start signal. From `planning`, the only
  # manual transition is back to backlog to abandon. Entering execution is
  # gated by `Tasks.require_approved_plan_for/2` and triggered by approving
  # a plan, which transitions the task directly into `in_progress`.
  defp available_transitions("planning"), do: [{"backlog", "Back"}]

  defp available_transitions("in_progress"),
    do: [{"in_review", "Submit for Review"}, {"done", "Mark Done"}]

  # Review outcomes flow through validations / review requests, not blunt status buttons.
  defp available_transitions("in_review"), do: []

  # Deploying outcomes flow through deploy stage validations, not manual transitions.
  defp available_transitions("deploying"), do: []

  defp available_transitions("blocked"),
    do: [{"backlog", "To Backlog"}, {"in_progress", "Resume"}]

  defp available_transitions("done"), do: []
  defp available_transitions(_), do: []

  defp transition_btn_class(status) do
    case status do
      "done" -> "btn btn-sm btn-success"
      "in_review" -> "btn btn-sm btn-warning"
      "in_progress" -> "btn btn-sm btn-info"
      _ -> "btn btn-sm btn-ghost"
    end
  end

  # Returns `{rejected_plans, active_plans}` where `rejected_plans` are the
  # plans with `status == "rejected"` sorted oldest-first by `version`, and
  # `active_plans` is everything else in the order it was preloaded (the
  # heex render path historically just iterated `task.plans` directly).
  def partition_plans(%Task{plans: plans}), do: partition_plans(plans)

  def partition_plans(plans) when is_list(plans) do
    {rejected, active} = Enum.split_with(plans, &(&1.status == "rejected"))
    {Enum.sort_by(rejected, & &1.version), active}
  end

  def partition_plans(_), do: {[], []}

  # IDs of plans that should be expanded by default — every non-rejected
  # plan, so existing behavior (active plan shown in full) is preserved.
  defp default_expanded_plan_ids(%Task{plans: plans}), do: default_expanded_plan_ids(plans)

  defp default_expanded_plan_ids(plans) when is_list(plans) do
    plans
    |> Enum.reject(&(&1.status == "rejected"))
    |> Enum.map(& &1.id)
  end

  defp default_expanded_plan_ids(_), do: []

  defp plan_expanded?(%MapSet{} = expanded_plans, %Plan{id: id}),
    do: MapSet.member?(expanded_plans, id)

  defp plan_expanded?(_expanded_plans, _plan), do: false

  # Treats nil and whitespace-only strings as absent. Used by the
  # template to skip rendering empty rejection-reason boxes on legacy
  # rows pre-migration.
  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  # Human-readable summary string used in the folded row for a rejected
  # plan revision. When the plan was auto-superseded by a newer revision
  # (`superseded_by_plan_id` non-nil + `:superseded_by` association
  # loaded), render a concise "superseded by vN on DATE" label and skip
  # the rejection_reason excerpt — the supersession IS the reason and
  # the canned excerpt would just be redundant. Otherwise (manual reject
  # via the 019dfad1 free-text path, or legacy/edge cases) fall through
  # to the original "rejected on DATE — \"reason excerpt\"" rendering.
  def plan_summary_label(
        %Plan{superseded_by_plan_id: sup_id, superseded_by: %Plan{} = sup} = plan
      )
      when not is_nil(sup_id) do
    "Plan v#{plan.version} — superseded by v#{sup.version}#{format_supersession_date(plan.updated_at)}"
  end

  def plan_summary_label(%Plan{version: version, updated_at: %DateTime{} = updated_at} = plan) do
    base = "Plan v#{version} — rejected on #{Calendar.strftime(updated_at, "%Y-%m-%d")}"
    append_rejection_excerpt(base, plan.rejection_reason)
  end

  def plan_summary_label(
        %Plan{version: version, updated_at: %NaiveDateTime{} = updated_at} = plan
      ) do
    base = "Plan v#{version} — rejected on #{Calendar.strftime(updated_at, "%Y-%m-%d")}"
    append_rejection_excerpt(base, plan.rejection_reason)
  end

  def plan_summary_label(%Plan{version: version} = plan) do
    base = "Plan v#{version} — rejected"
    append_rejection_excerpt(base, plan.rejection_reason)
  end

  # Date suffix for the supersession label. Mirrors the format used by
  # the rejected-on rendering. Tolerates missing/non-loaded timestamps
  # gracefully — falls back to no suffix rather than crashing the row.
  defp format_supersession_date(%DateTime{} = dt),
    do: " on #{Calendar.strftime(dt, "%Y-%m-%d")}"

  defp format_supersession_date(%NaiveDateTime{} = dt),
    do: " on #{Calendar.strftime(dt, "%Y-%m-%d")}"

  defp format_supersession_date(_), do: ""

  # Appends a truncated, quoted rejection-reason excerpt to the summary
  # label. Truncation cap is 60 chars with a single-character ellipsis
  # appended past that. nil/blank reason → no change (legacy rows).
  defp append_rejection_excerpt(label, nil), do: label
  defp append_rejection_excerpt(label, ""), do: label

  defp append_rejection_excerpt(label, reason) when is_binary(reason) do
    excerpt =
      if String.length(reason) > 60 do
        String.slice(reason, 0, 60) <> "…"
      else
        reason
      end

    "#{label} — \"#{excerpt}\""
  end

  # Function component: renders the inner body of a plan. Each stage card
  # carries its own per-stage validations (test_pass / lint_pass /
  # manual_approval) inline — there is no longer a trailing flat list of
  # validations under the stage list. Task-level `e2e_behavior` validations
  # live on a synthetic "Task-level review" stage (see
  # PlanEngine.route_e2e_behavior_validations/1) and render in a dedicated
  # section below the stages list so they read as a task-wide gate.
  attr(:plan, :any, required: true)

  defp plan_body(assigns) do
    {stages, e2e_validations} = split_e2e_behavior_validations(assigns.plan.stages || [])

    assigns =
      assigns
      |> Map.put(:stages, stages)
      |> Map.put(:e2e_validations, e2e_validations)

    ~H"""
    <div data-role="plan-body-inner" class="space-y-3">
      <div
        :for={stage <- @stages}
        data-role="stage-card"
        data-stage-id={stage.id}
        class="space-y-1"
      >
        <div class="flex items-center gap-2 text-sm">
          <span class={"size-4 #{stage_status_icon(stage.status)}"}></span>
          <span class="flex-1">{stage.name}</span>
          <span class="text-xs text-base-content/40">{stage.status}</span>
        </div>
        <div
          :if={stage.description}
          class="prose prose-sm max-w-none text-xs text-base-content/60 chat-markdown task-markdown mt-1 ml-6"
        >
          {Platform.Chat.ContentRenderer.render_message(stage.description)}
        </div>
        <%!-- Per-stage validation badges (inline, inside the stage card) --%>
        <div
          :if={is_list(stage.validations) and stage.validations != []}
          data-role="stage-validations"
          class="ml-6 flex flex-wrap gap-1.5"
        >
          <span
            :for={v <- stage.validations}
            data-role="stage-validation-badge"
            data-validation-kind={v.kind}
            data-validation-id={v.id}
            class={"badge badge-sm gap-1 #{validation_badge_class(v.status)}"}
            title={"#{v.kind} — #{v.status}"}
          >
            <span class={"size-3 #{stage_status_icon(v.status)}"}></span>
            <span>{v.kind}</span>
            <a
              :if={validation_evidence_link(v)}
              href={validation_evidence_link(v)}
              target="_blank"
              class="link link-hover ml-1 text-[10px] uppercase tracking-wide"
            >
              evidence
            </a>
          </span>
        </div>
      </div>

      <%!-- E2E Behavior — task-level behavioral review gate (one or more per task —
          the planner-authored adversarial test plan, user-approved at plan time). --%>
      <div
        :if={@e2e_validations != []}
        data-role="e2e-behavior-section"
        class="mt-3 rounded-box border border-base-300 bg-base-200/30 p-3 space-y-2"
      >
        <div class="flex items-center gap-2">
          <span class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
            E2E Behavior
          </span>
          <span class="text-[10px] text-base-content/40">
            task-level review · {length(@e2e_validations)} test cases
          </span>
        </div>

        <div
          :for={v <- @e2e_validations}
          data-role="e2e-behavior-validation"
          data-validation-id={v.id}
          class="space-y-2 rounded border border-base-300 bg-base-100/40 p-2 text-xs"
        >
          <div class="flex items-center gap-2">
            <span class={"size-3 #{stage_status_icon(v.status)}"}></span>
            <span class={"badge badge-xs #{validation_badge_class(v.status)}"}>{v.status}</span>
            <span :if={v.evaluated_by} class="text-base-content/50">
              by {v.evaluated_by}
            </span>
            <a
              :if={validation_evidence_link(v)}
              href={validation_evidence_link(v)}
              target="_blank"
              class="link link-hover ml-auto text-[10px] uppercase tracking-wide"
            >
              evidence
            </a>
          </div>

          <%= for {label, key} <- [
                {"Setup", "setup"},
                {"Actions", "actions"},
                {"Expected", "expected"}
              ] do %>
            <% value = e2e_payload_field(v, key) %>
            <div :if={value} data-role={"e2e-#{key}"} class="space-y-0.5">
              <div class="text-[10px] font-semibold uppercase tracking-wider text-base-content/50">
                {label}
              </div>
              <pre class="whitespace-pre-wrap break-words rounded bg-base-100 p-2 text-[11px] leading-snug text-base-content/80">{value}</pre>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ── plan_body helpers ────────────────────────────────────────────────────

  # Pull e2e_behavior validations out of the per-stage flow and surface them
  # as a dedicated task-level section. The plan engine routes them to a
  # synthetic "Task-level review" stage (see
  # PlanEngine.route_e2e_behavior_validations/1); if that stage carries ONLY
  # e2e_behavior validations and has no description authored by a planner,
  # we hide the now-empty stage card to avoid duplicate rendering.
  defp split_e2e_behavior_validations(stages) when is_list(stages) do
    {hidden_stages, kept_stages, e2es} =
      Enum.reduce(stages, {[], [], []}, fn stage, {hidden, kept, e2e_acc} ->
        validations = if is_list(stage.validations), do: stage.validations, else: []

        {e2e_here, rest} =
          Enum.split_with(validations, fn v -> v.kind == "e2e_behavior" end)

        new_e2e_acc = e2e_acc ++ e2e_here

        cond do
          # Stage entirely dedicated to e2e_behavior — drop it from the stage
          # list; the dedicated section will render the validations.
          e2e_here != [] and rest == [] ->
            {[stage | hidden], kept, new_e2e_acc}

          # Stage carries e2e_behavior alongside other validations — keep
          # the stage but strip the e2e validations off it.
          true ->
            updated_stage = %{stage | validations: rest}
            {hidden, [updated_stage | kept], new_e2e_acc}
        end
      end)

    _ = hidden_stages
    {Enum.reverse(kept_stages), e2es}
  end

  defp split_e2e_behavior_validations(_), do: {[], []}

  # Color/style mapping for validation badges. Reuses DaisyUI badge utility
  # classes so no new CSS is needed.
  defp validation_badge_class("passed"), do: "badge-success"
  defp validation_badge_class("failed"), do: "badge-error"
  defp validation_badge_class("running"), do: "badge-info"
  defp validation_badge_class(_), do: "badge-ghost"

  # Evidence on a Validation is a free-form map. Surface a link only when the
  # planner / evaluator wrote a `url`, `evidence_url`, `link`, or `canvas_id`
  # entry — otherwise the badge stays plain.
  defp validation_evidence_link(%{evidence: evidence}) when is_map(evidence) do
    Map.get(evidence, "url") || Map.get(evidence, :url) ||
      Map.get(evidence, "evidence_url") || Map.get(evidence, :evidence_url) ||
      Map.get(evidence, "link") || Map.get(evidence, :link)
  end

  defp validation_evidence_link(_), do: nil

  # Pull a single string field from an e2e_behavior evaluation_payload,
  # tolerant of string or atom keys.
  defp e2e_payload_field(%{evaluation_payload: payload}, key) when is_map(payload) do
    case Map.get(payload, key) || Map.get(payload, safe_atom(key)) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp e2e_payload_field(_, _), do: nil

  defp safe_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp safe_atom(_), do: nil
end
