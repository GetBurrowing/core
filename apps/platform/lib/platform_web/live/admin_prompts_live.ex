defmodule PlatformWeb.AdminPromptsLive do
  use PlatformWeb, :live_view

  alias Platform.Orchestration.{PromptTemplate, PromptTemplates}

  @sample_assigns %{
    "dispatch.planning" => %{
      task_title: "Implement user authentication",
      task_description: "Add OAuth2 login with Google and GitHub providers",
      task_priority: "high",
      skills_reference: "(skills attached to this task)"
    },
    "dispatch.in_progress" => %{
      task_title: "Implement user authentication",
      stage_info: "Plan: v1 (stage 1/3 — Setup OAuth providers)\n",
      repo_url: "https://github.com/org/repo",
      default_branch: "main",
      task_slug: "abc12345",
      skills_reference: "(skills attached to this task)"
    },
    "dispatch.in_review" => %{
      task_title: "Implement user authentication",
      stage_info: "Plan: v1 (stage 3/3 — Review & validation)\n",
      repo_url: "https://github.com/org/repo",
      default_branch: "main",
      task_slug: "abc12345",
      skills_reference: "(skills attached to this task)"
    },
    "dispatch.fallback" => %{
      task_title: "Implement user authentication",
      task_description: "Add OAuth2 login with Google and GitHub providers",
      task_status: "backlog",
      task_priority: "medium",
      stage_info: "",
      skills_reference: "(skills attached to this task)"
    },
    "heartbeat" => %{
      task_title: "Implement user authentication",
      stage_name: "Setup OAuth providers",
      stage_status: "running",
      elapsed: "25 minutes",
      pending_validations: "test_pass, lint_pass"
    }
  }

  @variable_descriptions %{
    "task_title" => "The task's title",
    "task_description" => "The task's description (may be nil)",
    "task_priority" => "Task priority: low, medium, high, critical",
    "task_status" => "Task status: planning, in_progress, in_review, done, etc.",
    "stage_info" => "Formatted plan/stage info line (e.g. 'Plan: v1 (stage 1/3 — Name)\\n')",
    "repo_url" => "Project repository URL",
    "default_branch" => "Project default branch (e.g. main)",
    "task_slug" => "Short task ID for use in branch names",
    "skills_reference" => "Reference to attached skills",
    "stage_name" => "Name of the current stage",
    "stage_status" => "Status of the current stage",
    "elapsed" => "Human-readable elapsed time (e.g. '25 minutes')",
    "pending_validations" => "Comma-separated list of pending validation kinds, or 'none'"
  }

  @impl true
  def mount(_params, session, socket) do
    templates = PromptTemplates.list_templates()
    current_user_id = session["current_user_id"] || "unknown"

    {:ok,
     socket
     |> assign(:page_title, "Admin · Prompts")
     |> assign(:templates, templates)
     |> assign(:current_user_id, current_user_id)
     |> assign(:selected_template, nil)
     |> assign(:edit_form, nil)
     |> assign(:preview_content, nil)
     |> assign(:save_status, nil)}
  end

  @impl true
  def handle_params(%{"slug" => slug}, _url, socket) do
    case PromptTemplates.get_template_by_slug(slug) do
      nil ->
        {:noreply,
         socket
         |> assign(:selected_template, nil)
         |> assign(:edit_form, nil)
         |> put_flash(:error, "Template not found.")}

      template ->
        edit_form = to_form(PromptTemplate.changeset(template, %{}), as: "template")
        preview = render_preview(template.slug, template.content)

        {:noreply,
         socket
         |> assign(:selected_template, template)
         |> assign(:edit_form, edit_form)
         |> assign(:preview_content, preview)
         |> assign(:save_status, nil)
         |> assign(:page_title, "Admin · #{template.name}")}
    end
  end

  def handle_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(:selected_template, nil)
     |> assign(:edit_form, nil)
     |> assign(:preview_content, nil)}
  end

  # ── Events ──────────────────────────────────────────────────────────────

  @impl true
  def handle_event("select_template", %{"slug" => slug}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/prompts/#{slug}")}
  end

  def handle_event("back_to_index", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_template, nil)
     |> assign(:edit_form, nil)
     |> assign(:preview_content, nil)
     |> push_patch(to: ~p"/admin/prompts")}
  end

  def handle_event("validate_template", %{"template" => params}, socket) do
    template = socket.assigns.selected_template

    changeset =
      template
      |> PromptTemplate.changeset(params)
      |> Map.put(:action, :validate)

    preview = render_preview(template.slug, Map.get(params, "content", template.content))

    {:noreply,
     socket
     |> assign(:edit_form, to_form(changeset, as: "template"))
     |> assign(:preview_content, preview)
     |> assign(:save_status, nil)}
  end

  def handle_event("preview_template", _params, socket) do
    template = socket.assigns.selected_template
    content = get_in(socket.assigns, [:edit_form, :params, "content"]) || template.content
    preview = render_preview(template.slug, content)
    {:noreply, assign(socket, :preview_content, preview)}
  end

  def handle_event("save_template", %{"template" => params}, socket) do
    template = socket.assigns.selected_template
    current_user_id = socket.assigns.current_user_id

    attrs = Map.put(params, "updated_by", current_user_id)

    case PromptTemplates.update_template(template, attrs) do
      {:ok, updated} ->
        edit_form = to_form(PromptTemplate.changeset(updated, %{}), as: "template")
        preview = render_preview(updated.slug, updated.content)

        {:noreply,
         socket
         |> assign(:selected_template, updated)
         |> assign(:edit_form, edit_form)
         |> assign(:preview_content, preview)
         |> assign(:templates, PromptTemplates.list_templates())
         |> assign(:save_status, :saved)
         |> put_flash(:info, "Template saved.")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:edit_form, to_form(changeset, as: "template"))
         |> put_flash(:error, "Could not save template.")}
    end
  end

  def handle_event("reset_template", _params, socket) do
    template = socket.assigns.selected_template
    current_user_id = socket.assigns.current_user_id

    default_content = default_content_for(template.slug)

    case PromptTemplates.update_template(template, %{
           "content" => default_content,
           "updated_by" => current_user_id
         }) do
      {:ok, updated} ->
        edit_form = to_form(PromptTemplate.changeset(updated, %{}), as: "template")
        preview = render_preview(updated.slug, updated.content)

        {:noreply,
         socket
         |> assign(:selected_template, updated)
         |> assign(:edit_form, edit_form)
         |> assign(:preview_content, preview)
         |> assign(:save_status, :saved)
         |> put_flash(:info, "Template reset to default.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not reset template.")}
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp render_preview(slug, content) do
    assigns = Map.get(@sample_assigns, slug, %{})
    interpolate(content, assigns)
  end

  defp interpolate(content, assigns) do
    Regex.replace(~r/\{\{(\w+)\}\}/, content, fn _match, key ->
      atom_key =
        try do
          String.to_existing_atom(key)
        rescue
          ArgumentError -> nil
        end

      value =
        (atom_key && Map.get(assigns, atom_key)) ||
          Map.get(assigns, key) ||
          "(#{key})"

      to_string(value)
    end)
  end

  defp variable_descriptions, do: @variable_descriptions

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

  defp default_content_for(slug) do
    PromptTemplates.default_content_for_slug(slug) || ""
  end
end
