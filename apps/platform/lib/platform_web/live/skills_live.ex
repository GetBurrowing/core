defmodule PlatformWeb.SkillsLive do
  use PlatformWeb, :live_view

  alias Platform.Skills
  alias Platform.Skills.Skill
  alias Platform.Tasks

  @impl true
  def mount(_params, _session, socket) do
    skills = Skills.list_skills()

    {:ok,
     socket
     |> assign(:page_title, "Skills")
     |> assign(:skills, skills)
     |> assign(:selected_skill, nil)
     |> assign(:show_detail, false)
     |> assign(:show_skill_sheet, false)
     |> assign(:edit_form, nil)
     |> assign(:create_form, to_form(Skill.changeset(%Skill{}, %{}), as: "skill"))
     |> assign(:confirm_delete, false)
     |> assign(:save_status, nil)
     |> assign(:skill_attachments_grouped, nil)
     |> assign(:all_projects, [])
     |> assign(:all_epics, [])}
  end

  @impl true
  def handle_params(%{"slug" => slug}, _url, socket) do
    case Skills.get_skill_by_slug(slug) do
      nil ->
        {:noreply,
         socket
         |> assign(:selected_skill, nil)
         |> assign(:show_detail, false)
         |> put_flash(:error, "Skill not found.")}

      skill ->
        edit_form = to_form(Skill.changeset(skill, %{}), as: "skill")
        grouped = Skills.entities_for_skill(skill.id)

        {:noreply,
         socket
         |> assign(:selected_skill, skill)
         |> assign(:show_detail, true)
         |> assign(:edit_form, edit_form)
         |> assign(:confirm_delete, false)
         |> assign(:save_status, nil)
         |> assign(:skill_attachments_grouped, grouped)
         |> assign(:all_projects, Tasks.list_projects())
         |> assign(:all_epics, Tasks.list_epics_for_project(nil))
         |> assign(:page_title, "Skills · #{skill.name}")}
    end
  end

  def handle_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(:selected_skill, nil)
     |> assign(:show_detail, false)
     |> assign(:edit_form, nil)}
  end

  # ── Events ──────────────────────────────────────────────────────────────

  @impl true
  def handle_event("select_skill", %{"slug" => slug}, socket) do
    {:noreply, push_patch(socket, to: ~p"/skills/#{slug}")}
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_skill, nil)
     |> assign(:show_detail, false)
     |> assign(:edit_form, nil)
     |> assign(:confirm_delete, false)
     |> assign(:skill_attachments_grouped, nil)
     |> push_patch(to: ~p"/skills")}
  end

  # ── Create sheet ────────────────────────────────────────────────────────

  def handle_event("toggle_skill_sheet", _params, socket) do
    showing = !socket.assigns.show_skill_sheet

    socket =
      if showing do
        socket
        |> assign(:show_skill_sheet, true)
        |> assign(:create_form, to_form(Skill.changeset(%Skill{}, %{}), as: "skill"))
      else
        assign(socket, :show_skill_sheet, false)
      end

    {:noreply, socket}
  end

  def handle_event("close_skill_sheet", _params, socket) do
    {:noreply, assign(socket, :show_skill_sheet, false)}
  end

  def handle_event("validate_create", %{"skill" => params}, socket) do
    changeset =
      %Skill{}
      |> Skill.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :create_form, to_form(changeset, as: "skill"))}
  end

  def handle_event("create_skill", %{"skill" => params}, socket) do
    case Skills.create_skill(params) do
      {:ok, _skill} ->
        {:noreply,
         socket
         |> assign(:show_skill_sheet, false)
         |> assign(:skills, Skills.list_skills())
         |> put_flash(:info, "Skill created.")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:create_form, to_form(changeset, as: "skill"))
         |> put_flash(:error, "Could not create skill.")}
    end
  end

  # ── Edit / Save ─────────────────────────────────────────────────────────

  def handle_event("validate_edit", %{"skill" => params}, socket) do
    skill = socket.assigns.selected_skill

    changeset =
      skill
      |> Skill.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:edit_form, to_form(changeset, as: "skill"))
     |> assign(:save_status, nil)}
  end

  def handle_event("save_skill", %{"skill" => params}, socket) do
    skill = socket.assigns.selected_skill

    case Skills.update_skill(skill, params) do
      {:ok, updated} ->
        edit_form = to_form(Skill.changeset(updated, %{}), as: "skill")

        {:noreply,
         socket
         |> assign(:selected_skill, updated)
         |> assign(:edit_form, edit_form)
         |> assign(:skills, Skills.list_skills())
         |> assign(:save_status, :saved)
         |> put_flash(:info, "Skill saved.")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:edit_form, to_form(changeset, as: "skill"))
         |> put_flash(:error, "Could not save skill.")}
    end
  end

  # ── Attachment management ────────────────────────────────────────────────

  def handle_event("attach_skill_to_project", %{"project_id" => project_id}, socket) do
    skill = socket.assigns.selected_skill

    if skill && project_id != "" do
      Skills.attach_skill(skill.id, "project", project_id)
      grouped = Skills.entities_for_skill(skill.id)
      {:noreply, assign(socket, :skill_attachments_grouped, grouped)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("detach_skill_from_project", %{"project_id" => project_id}, socket) do
    skill = socket.assigns.selected_skill

    if skill do
      Skills.detach_skill(skill.id, "project", project_id)
      grouped = Skills.entities_for_skill(skill.id)
      {:noreply, assign(socket, :skill_attachments_grouped, grouped)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("attach_skill_to_epic", %{"epic_id" => epic_id}, socket) do
    skill = socket.assigns.selected_skill

    if skill && epic_id != "" do
      Skills.attach_skill(skill.id, "epic", epic_id)
      grouped = Skills.entities_for_skill(skill.id)
      {:noreply, assign(socket, :skill_attachments_grouped, grouped)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("detach_skill_from_epic", %{"epic_id" => epic_id}, socket) do
    skill = socket.assigns.selected_skill

    if skill do
      Skills.detach_skill(skill.id, "epic", epic_id)
      grouped = Skills.entities_for_skill(skill.id)
      {:noreply, assign(socket, :skill_attachments_grouped, grouped)}
    else
      {:noreply, socket}
    end
  end

  # ── Delete ──────────────────────────────────────────────────────────────

  def handle_event("delete_skill", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, true)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, false)}
  end

  def handle_event("confirm_delete", _params, socket) do
    skill = socket.assigns.selected_skill

    case Skills.delete_skill(skill) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:selected_skill, nil)
         |> assign(:show_detail, false)
         |> assign(:confirm_delete, false)
         |> assign(:skills, Skills.list_skills())
         |> put_flash(:info, "Skill deleted.")
         |> push_patch(to: ~p"/skills")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not delete skill.")}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp relative_time(nil), do: ""

  defp relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86400)}d ago"
      true -> Calendar.strftime(dt, "%b %d")
    end
  end
end
