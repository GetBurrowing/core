defmodule PlatformWeb.AdminPromptsLive do
  use PlatformWeb, :live_view

  alias Platform.Orchestration.{HeartbeatScheduler, PromptTemplate, PromptTemplates}

  # A prompt author reads the preview and the variable sidebar to learn what a
  # placeholder will hold at render time, so a sample value is a contract
  # statement, not decoration. `task_slug` sampled as `abc12345` taught an
  # 8-character branch name that the renderer stopped producing in task
  # 019fb949 — and that truncation was the defect itself, since tasks filed in
  # the same ~65-second bucket share their first hyphen segment and collapse
  # onto one branch. The sample is a full UUID so the preview shows the branch
  # the executor is actually told to create.
  @sample_task_slug "019a1b2c-3d4e-7f80-9abc-def012345678"

  # The task shape `deploy_strategy_instructions_for/3` resolves the repository
  # set and strategy from, for the `dispatch.deploying` preview. A literal
  # `pr_merge` strategy rather than a project default so the preview shows the
  # branch-and-PR flow, which is the one a prompt author is usually editing.
  @sample_deploy_task %{
    id: "019a1b2c-3d4e-7f80-9abc-def012345678",
    deploy_strategy: %{"type" => "pr_merge", "config" => %{"auto_merge" => false}},
    project: %{repo_url: "https://github.com/org/repo", default_branch: "main"}
  }

  @sample_assigns %{
    "dispatch.planning" => %{
      task_title: "Implement user authentication",
      task_description: "Add OAuth2 login with Google and GitHub providers",
      task_priority: "high",
      skills_reference: "(skills attached to this task)",
      federation_preamble: "(federation preamble injected at render time)"
    },
    "dispatch.in_progress" => %{
      task_title: "Implement user authentication",
      stage_info: "Plan: v1 (stage 1/3 — Setup OAuth providers)\n",
      repo_url: "https://github.com/org/repo",
      default_branch: "main",
      task_slug: @sample_task_slug,
      skills_reference: "(skills attached to this task)",
      federation_preamble: "(federation preamble injected at render time)"
    },
    "dispatch.in_review" => %{
      task_title: "Implement user authentication",
      stage_info: "Plan: v1 (stage 3/3 — Review & validation)\n",
      repo_url: "https://github.com/org/repo",
      default_branch: "main",
      task_slug: @sample_task_slug,
      skills_reference: "(skills attached to this task)",
      federation_preamble: "(federation preamble injected at render time)"
    },
    "dispatch.fallback" => %{
      task_title: "Implement user authentication",
      task_description: "Add OAuth2 login with Google and GitHub providers",
      task_status: "backlog",
      task_priority: "medium",
      stage_info: "",
      skills_reference: "(skills attached to this task)",
      federation_preamble: "(federation preamble injected at render time)"
    },
    # `dispatch.deploying` is the ONLY seeded template that both declares
    # `task_slug` and interpolates it, so it is the only place the preview can
    # actually demonstrate the branch contract. It had no sample entry at all,
    # which rendered the branch name as the literal `(task_slug)` — the least
    # useful thing a preview of a branch reference can show.
    "dispatch.deploying" => %{
      task_id: "019a1b2c-3d4e-7f80-9abc-def012345678",
      stage_id: "019a1b2c-3d4e-7f80-9abc-def0123456ff",
      task_title: "Implement user authentication",
      stage_info: "Plan: v1 (stage 3/3 — Deploy)\n",
      repo_url: "https://github.com/org/repo",
      default_branch: "main",
      task_slug: @sample_task_slug,
      deploy_strategy_type: "pr_merge",
      deploy_strategy_config: ~s(%{"auto_merge" => false}),
      federation_preamble: "(federation preamble injected at render time)"
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
    "task_id" => "The task's UUID — required by the ack-first preamble",
    "stage_id" => "The running stage's UUID — required by the ack-first preamble",
    "task_title" => "The task's title",
    "task_description" => "The task's description (may be nil)",
    "task_priority" => "Task priority: low, medium, high, critical",
    "task_status" => "Task status: planning, in_progress, in_review, done, etc.",
    "stage_info" => "Formatted plan/stage info line (e.g. 'Plan: v1 (stage 1/3 — Name)\\n')",
    "repo_url" => "Project repository URL",
    "default_branch" => "Project default branch (e.g. main)",
    "task_slug" => "Full task UUID used for the worktree path and branch name (task/<uuid>)",
    "deploy_strategy_instructions" =>
      "The resolved strategy's own steps, built in code — one PR/CI/merge sequence per " <>
        "repository the deploy touches, including the transitional branch-name recovery step",
    "deploy_strategy_type" => "Resolved deploy strategy: pr_merge, docker_deploy, manual, etc.",
    "deploy_strategy_config" => "Inspected deploy strategy config map",
    "skills_reference" => "Reference to attached skills",
    "federation_preamble" =>
      "Consolidated Claude Code federation guidance (subagent spawn, org memory, skill discovery, evidence chain, tool-name conventions)",
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
    interpolate(content, sample_assigns(slug))
  end

  # `deploy_strategy_instructions` is computed rather than stored in
  # `@sample_assigns` because it is CODE, not copy: task 019fa63a moved the
  # strategy steps out of the template body and into
  # `HeartbeatScheduler.deploy_strategy_instructions/5`. Rendering it through
  # the real function is what stops the preview teaching a deploy flow no
  # dispatch produces — the failure mode task 019fb949 fixed for `task_slug`.
  defp sample_assigns("dispatch.deploying" = slug) do
    sample = Map.get(@sample_assigns, slug, %{})

    Map.put(
      sample,
      :deploy_strategy_instructions,
      HeartbeatScheduler.deploy_strategy_instructions_for(
        @sample_deploy_task,
        sample.default_branch,
        sample.task_slug
      )
    )
  end

  defp sample_assigns(slug), do: Map.get(@sample_assigns, slug, %{})

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
