defmodule PlatformWeb.AdminPromptsLive do
  @moduledoc """
  `/admin/prompts` — the ONE editor over `prompt_templates`, made
  variant-aware by task 019fe6ba (ADR-0048).

  ## Why the variant editor is here and not in Control Center

  There is no second prompt editor. An experiment's variant blobs are edited
  through this surface, beside the template they are variants OF, because two
  editors over one `prompt_templates` row drift — and the drift does not
  surface as a merge conflict or an error. It surfaces months later as "the
  experiment ran the wrong text", by which point the results have been acted
  on. `PlatformWeb.ExperimentsLive`'s Design tab LINKS here; it reimplements
  nothing.

  ## The diff is against the SNAPSHOT, never the live row

  A variant is diffed against the `control` variant's stored blob — the copy
  `Platform.Experiments.activate/2` took at activation — and never against
  `prompt_templates.content` as it stands now.

  This is the specific way this surface would lie. Editing the template moves
  the live row; the running experiment's control does not move with it. A
  diff drawn against the live row would show the author a difference that
  no dispatch will ever render, and it would look completely normal.

  ## The notice states what editing does NOT do

  While an experiment is running on this template, the editor says so, names
  it, and links to it. The failure it prevents: the first person to edit a
  template mid-experiment either believes they have corrupted the run — and
  wastes a day — or believes they have changed it and relies on that change.
  The second is worse, because nothing contradicts them.

  It is deliberately NOT dismissible. The state in which someone dismisses a
  warning is exactly the state in which the misunderstanding does its damage.

  ## The list is a UNION of what exists and what is declared (task `01a0a74d` stage 4)

  A list built from one source can only render that source's members. Reading
  `prompt_templates` alone, this page was structurally unable to show that a
  live cron fires at a slug nobody has: an absence has no row, so it is not
  rendered faintly — it is not rendered at all. That is the same defect as the
  empty dispatch this task is about, one layer up.

  So `@rows` is the union of templates that EXIST and responsibility slugs that
  are DECLARED, sorted together on slug, with the difference marked in place.
  The declared side is read through
  `Platform.Responsibilities.prompt_template_audit/0` — the same public audit
  the boot-time registry check and `mix responsibilities.prompt_audit` go
  through — and is deliberately NOT re-derived here, because three definitions
  of "orphan" is how three surfaces come to disagree.

  Two choices that read as mistakes and are not:

    * **The marked row sits in SORT ORDER, and there is no banner and no badge
      count above the list.** A banner is attached to the list and can be read
      past, and after the second time you see it resolved you stop resolving
      it. A row IS the list: someone scanning `memory.*` meets it in the place
      they were already looking.

    * **The missing key's name renders at FULL weight** — not greyed, not
      shrunk. Greying encodes EXISTENCE; this row must encode CONSEQUENCE, as
      it is the only entry on the page currently causing a live cron to
      deliver an empty prompt. `--color-error` is not used either (a declared
      key with no template is a configuration gap, not a failure, and error
      already means "this save failed" here), nor `--color-primary` (cyan is
      the action colour on this page, and this row is a statement, not an
      action).

  Selecting such a row renders a REFUSAL, not an editor. An empty editor is
  the shape that invites someone to type a body into it without deciding
  whether this key should have one — which is the open question.
  """

  use PlatformWeb, :live_view

  alias Platform.Experiments
  alias Platform.Experiments.Experiment
  alias Platform.Orchestration.{HeartbeatScheduler, PromptTemplate, PromptTemplates}
  alias Platform.Responsibilities

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
    current_user_id = session["current_user_id"] || "unknown"

    {:ok,
     socket
     |> assign(:page_title, "Admin · Prompts")
     |> assign(:current_user_id, current_user_id)
     |> assign_list()
     |> assign(:selected_template, nil)
     |> assign(:missing_key, nil)
     |> assign(:edit_form, nil)
     |> assign(:preview_content, nil)
     |> assign(:save_status, nil)
     |> assign(:running_experiment, nil)
     |> assign(:experiment_variants, [])
     |> assign(:selected_variant, nil)
     |> assign(:variant_diff, nil)}
  end

  @impl true
  def handle_params(%{"slug" => slug}, _url, socket) do
    case PromptTemplates.get_template_by_slug(slug) do
      nil ->
        # A slug with no row is not automatically "not found": it may be a
        # responsibility key declared in source whose template nobody ever
        # wrote, which is exactly the case this page now renders rather than
        # bouncing with a flash.
        case find_missing_key(socket.assigns.declared_missing, slug) do
          nil ->
            {:noreply,
             socket
             |> assign(:selected_template, nil)
             |> assign(:missing_key, nil)
             |> assign(:edit_form, nil)
             |> put_flash(:error, "Template not found.")}

          entry ->
            {:noreply,
             socket
             |> assign(:selected_template, nil)
             |> assign(:edit_form, nil)
             |> assign(:preview_content, nil)
             |> assign(:missing_key, entry)
             |> assign(:page_title, "Admin · #{entry.slug}")}
        end

      template ->
        edit_form = to_form(PromptTemplate.changeset(template, %{}), as: "template")
        preview = render_preview(template.slug, template.content)

        {:noreply,
         socket
         |> assign(:selected_template, template)
         |> assign(:missing_key, nil)
         |> assign(:edit_form, edit_form)
         |> assign(:preview_content, preview)
         |> assign(:save_status, nil)
         |> assign(:page_title, "Admin · #{template.name}")
         |> load_experiment_context(template)}
    end
  end

  def handle_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(:selected_template, nil)
     |> assign(:missing_key, nil)
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
     |> assign(:missing_key, nil)
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
         |> assign_list()
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

  # The one action the refusal pane offers. It does NOT open an empty editor —
  # it writes the row, then navigates to the editor over a row that now
  # exists. The difference is that creating the template is an explicit,
  # attributed act (`updated_by` is the operator) rather than a side effect of
  # someone typing into a blank box they were shown by default.
  #
  # The body comes from `default_content_for_slug/1` when the code declares
  # one, because a slug that HAS a descriptor and no row is a seeding gap and
  # the descriptor is the intended text. When there is no descriptor, the body
  # is a single sentence naming the responsibility key and saying it is
  # unwritten: `content` is `validate_required`, so it cannot be blank, and a
  # sentence that says "nobody has written this" is a better thing for a cron
  # to render than whitespace.
  def handle_event("create_template_for_key", _params, socket) do
    case socket.assigns.missing_key do
      %{slug: slug} = entry when is_binary(slug) ->
        attrs = %{
          "slug" => slug,
          "name" => slug,
          "description" => "Declared by responsibility #{entry.key}.",
          "content" => starting_content_for(slug, entry),
          "updated_by" => socket.assigns.current_user_id
        }

        case PromptTemplates.create_template(attrs) do
          {:ok, template} ->
            {:noreply,
             socket
             |> assign_list()
             |> put_flash(:info, "Created #{template.slug}.")
             |> push_patch(to: ~p"/admin/prompts/#{template.slug}")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not create a template for #{slug}.")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # ── Experiment awareness (task 019fe6ba) ────────────────────────────────

  def handle_event("select_variant", %{"variant" => variant_slug}, socket) do
    {:noreply, assign_variant(socket, variant_slug)}
  end

  def handle_event("select_variant", _params, socket), do: {:noreply, socket}

  # Finds the RUNNING experiment on this template, if any.
  #
  # `list_experiments_for_template/1` deliberately does not filter by status —
  # the dispatch resolver needs terminal rows too — so the status filter is
  # applied here rather than assumed. Only a running experiment produces the
  # notice: a concluded one no longer constrains what an edit does, and a
  # permanent banner about a finished experiment is the kind of notice people
  # learn to stop reading.
  defp load_experiment_context(socket, template) do
    experiment =
      template.slug
      |> Experiments.list_experiments_for_template()
      |> Enum.find(&(&1.status == "running"))

    variants = if experiment, do: Experiments.list_variants(experiment), else: []

    socket
    |> assign(:running_experiment, experiment)
    |> assign(:experiment_variants, variants)
    |> assign_variant(Experiment.control_slug())
  end

  defp assign_variant(socket, variant_slug) do
    socket
    |> assign(:selected_variant, variant_slug)
    |> assign(:variant_diff, diff_against_snapshot(socket, variant_slug))
  end

  # The diff. Both sides come from `experiment_variants` rows: the control
  # side is the SNAPSHOT taken at activation, never
  # `@selected_template.content`.
  #
  # Reading the live template here would be the whole defect — the author
  # would be shown a difference the running experiment does not have, and it
  # would look entirely ordinary. The `selected_template` assign is
  # deliberately not consulted by this function.
  defp diff_against_snapshot(socket, variant_slug) do
    variants = socket.assigns[:experiment_variants] || []
    control_slug = Experiment.control_slug()

    with %{content: control} <- Enum.find(variants, &(&1.slug == control_slug)),
         %{content: chosen} <- Enum.find(variants, &(&1.slug == variant_slug)) do
      line_diff(control, chosen)
    else
      _ -> nil
    end
  end

  # Line-level diff, kept plain on purpose. `:eq` runs are dropped so an
  # unchanged variant yields `[]` — which the template renders as an explicit
  # "identical to the control snapshot" statement rather than as a blank
  # panel. A blank panel is indistinguishable from a diff that failed to
  # render, and this is the state an author sees FIRST, before they have
  # edited anything.
  defp line_diff(control, chosen) do
    control_lines = String.split(control || "", "\n")
    chosen_lines = String.split(chosen || "", "\n")

    control_lines
    |> List.myers_difference(chosen_lines)
    |> Enum.flat_map(fn
      {:eq, _lines} -> []
      {:del, lines} -> Enum.map(lines, &{:del, &1})
      {:ins, lines} -> Enum.map(lines, &{:ins, &1})
    end)
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

  defp starting_content_for(slug, entry) do
    case PromptTemplates.default_content_for_slug(slug) do
      content when is_binary(content) and content != "" ->
        content

      _ ->
        "No body has been written for #{entry.key} (`#{slug}`) yet."
    end
  end

  # ── The declared-but-unbacked union (task 01a0a74d stage 4) ─────────────

  # Both list assigns move together or they disagree, so they are set in one
  # place. `@templates` stays exactly what it was — the header count and the
  # empty state are about templates that exist, and folding orphans into that
  # count would be the badge this design explicitly refuses.
  defp assign_list(socket) do
    templates = PromptTemplates.list_templates()
    declared_missing = declared_missing()

    socket
    |> assign(:templates, templates)
    |> assign(:declared_missing, declared_missing)
    |> assign(:rows, union_rows(templates, declared_missing))
  end

  # Read through the stage-3 public audit, never re-derived here.
  #
  # Only `{:missing, slug}` produces a row. `{:blank, slug}` is excluded on
  # purpose: a blank template HAS a row and is therefore already in the list
  # above, and rendering it twice would make the union list disagree with
  # itself. `:none` and `:resolved` are not defects at all.
  defp declared_missing do
    Responsibilities.prompt_template_audit()
    |> Responsibilities.prompt_template_orphans()
    |> Enum.flat_map(fn
      %{status: {:missing, slug}} = entry -> [Map.put(entry, :slug, slug)]
      _ -> []
    end)
    |> Enum.uniq_by(& &1.slug)
  end

  # Sorted on SLUG, together, because the table is keyed on slug and a row
  # sorted by anything else lands somewhere the reader is not looking. The
  # wireframe labelled the row with the responsibility KEY; the key rides in
  # the utility line instead, so the mono cell stays comparable to its
  # neighbours.
  defp union_rows(templates, declared_missing) do
    existing = MapSet.new(templates, & &1.slug)

    rows =
      Enum.map(templates, &%{kind: :template, slug: &1.slug, template: &1}) ++
        (declared_missing
         |> Enum.reject(&MapSet.member?(existing, &1.slug))
         |> Enum.map(&%{kind: :missing, slug: &1.slug, entry: &1}))

    Enum.sort_by(rows, & &1.slug)
  end

  defp find_missing_key(declared_missing, slug) do
    Enum.find(declared_missing, &(&1.slug == slug))
  end
end
