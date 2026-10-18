defmodule PlatformWeb.ExperimentsLive do
  @moduledoc """
  `/control/experiments` — what we tried, what it cost, and what we are still
  not entitled to claim. Task 019fe6ba, ADR-0048; results, guardrails, launch
  approval and the human controls added by task 01a0d415 stage 6, following
  the design-direction canvas on that task.

  One LiveView serves both the list (`:index`) and the detail (`:show`) with
  its four tabs; the tab is socket state, not a route, so switching tabs
  cannot lose the loaded experiment.

  ## The result cell is ONE unit

  `result_cell/1` prints the figure and its sample size as one string in one
  mono run — `18.4% · n=212` — at full ink on both halves. `n` is never a
  caption, a tooltip or a grey sub-line: an adjacent qualifier is lost the
  moment the value travels into a screenshot or a chat message, and these
  values travel constantly.

  An arm that has not earned a figure prints WORDS in the same place —
  `not enough data · n=3` — and draws no geometry at all. There is no
  zero-width bar in that row's DOM, because a bar of length zero IS zero to
  the eye whatever the label says. Only an earned row renders the
  `data-role="evidence-bar"` element, and the unearned row sits on the flat
  `bg-base-300` ground: the absence of chroma is the signal.

  Exclusions sit on the row they changed: `(7 excluded)` is the summary of a
  `<details>` that opens onto the reasons, read from `excluded_reason`.

  `Platform.Experiments.Results` refuses to carry `value` at all on a row
  that has not cleared its stop rule, so the rule is enforced twice — once
  where the data is built and once where it is drawn.

  ## What this page will not draw

  No lift against control, no projection. Each arm's figure stands alone
  with its own `n` (ADR-0048).

  ## State chips differ in HUE

  Running is `badge-success`, Stopped `badge-warning`, Concluded
  `badge-info`. Stopped and concluded mean opposite things to someone
  deciding whether to promote, so they differ in hue, not in shade, and the
  labels are sentence case: they are states, not labels shouting.

  ## One primary button

  Promote is the only `btn-primary` on the page, pinned to the right of each
  earned row, so a reader scanning the column of figures cannot reach the
  single irreversible action without passing the evidence. Every other
  action is neutral.

  ## Human controls (product decision, 2026-09-24)

  An admin can create, start, approve, stop (with feedback), conclude and
  promote from this page. Every handler calls the same `Platform.Experiments`
  context function the MCP tools call — there is no second write path.

  Stop opens a small form whose feedback is written by
  `Experiments.stop/3` together with who stopped it and when; the stopped
  experiment shows all three, and the Scientist reads the feedback.

  ## Guardrails

  The panel edits the install-wide row or one org's row through
  `Guardrails.save/3`, an upsert on the stage-1 `NULLS NOT DISTINCT` index.
  Every control is pre-filled from the EFFECTIVE value (`Guardrails.for_org/1`):
  with no stored row, the surface checkboxes show the built-in default, so
  saving only a new `max_live` keeps today's surfaces rather than writing the
  column default `[]` and refusing every surface to every agent.

  The mail send path is a line of TEXT, not an unchecked box. A checkbox is
  an invitation; this row states that the system does not do it.

  Launch approval is OFF by default. The pending-approval UI appears only on
  an experiment whose `approval_state` is `pending`, which happens only in an
  org that turned `require_human_approval` on.

  ## Reads are member-visible, writes are admin-only, checked server-side

  These routes sit in `live_session :authenticated`, so any member can read
  the page. Every write handler re-checks `@root_admin?` ITSELF before
  touching the context (`admin_only/2`). Hiding a button is an affordance; a
  forged event from a non-admin client is refused by the handler.
  """

  use PlatformWeb, :live_view

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Experiments
  alias Platform.Experiments.Assignments
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Guardrails
  alias Platform.Experiments.MetricKind
  alias Platform.Experiments.Metrics
  alias Platform.Experiments.Promotion
  alias Platform.Experiments.Surfaces
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Tasks
  alias Platform.Tenancy
  alias PlatformWeb.ExperimentResults

  @tabs ~w(results design assignments promotions)
  @default_tab "results"
  @prompt_surface "dispatch.prompt"
  @max_feedback 4000
  @refused_message "Only root-org admins can change experiments."

  # Pre-filled rather than blank, and required. The results layer fails
  # closed: `ExperimentResults.min_subjects/1` returns nil for an absent or
  # non-integer rule, and a row with no rule can never earn a figure. An
  # experiment created without one therefore looks running forever and can
  # never report — silently inert. A default is cheaper than that failure.
  @default_min_subjects 40

  @empty_create_form %{
    "name" => "",
    "slug" => "",
    "hypothesis" => "",
    "primary_metric" => "",
    "min_subjects" => to_string(@default_min_subjects),
    "surface" => @prompt_surface <> "::",
    "org_id" => "",
    "project_id" => ""
  }

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user_record]

    {:ok,
     socket
     |> assign(:page_title, "Experiments")
     |> assign(:show_create, false)
     |> assign(:show_stop_form, false)
     |> assign(:create_form, @empty_create_form)
     |> assign(:metric_catalog, Metrics.catalog())
     |> assign(:surface_options, surface_options())
     # Org names are for the admin's pickers only; a member's panel shows the
     # install-wide row and lists no foreign org (ADR-0042).
     |> assign(:orgs, if(socket.assigns[:root_admin?], do: sorted_orgs(), else: []))
     |> assign(:projects, Tasks.list_projects_for_user(user))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:experiment, nil)
    |> load_index()
    |> assign_guardrails(socket.assigns[:guard_org_id])
  end

  defp apply_action(socket, :show, %{"slug" => slug}) do
    case Experiments.get_experiment_by_slug(slug) do
      nil ->
        socket
        |> put_flash(:error, "No experiment #{slug}.")
        |> push_navigate(to: ~p"/control/experiments")

      %Experiment{} = experiment ->
        socket
        |> assign(:tab, socket.assigns[:tab] || @default_tab)
        |> load_experiment(experiment)
    end
  end

  defp load_index(socket) do
    experiments = Experiments.list_experiments()

    rows =
      Enum.map(experiments, fn experiment ->
        row = ExperimentResults.headline_row(experiment)
        reasons = experiment |> Assignments.list_assignments() |> exclusion_reasons()
        {experiment, row, Map.get(reasons, row.variant_slug, [])}
      end)

    socket
    |> assign(:rows, rows)
    |> assign(
      :agent_names,
      Experiments.agent_names(Enum.map(experiments, & &1.proposed_by_agent_id))
    )
  end

  defp load_experiment(socket, experiment) do
    assignments = Assignments.list_assignments(experiment)
    rows = ExperimentResults.rows(experiment)

    socket
    |> assign(:experiment, experiment)
    |> assign(:page_title, experiment.name)
    |> assign(:result_rows, rows)
    |> assign(:bar_widths, bar_widths(rows))
    |> assign(:exclusions, exclusion_reasons(assignments))
    |> assign(:variants, Experiments.list_variants(experiment))
    |> assign(:assignments, assignments)
    |> assign(:templates, PromptTemplates.list_templates())
    |> assign(
      :proposer_name,
      proposer(Experiments.agent_names([experiment.proposed_by_agent_id]), experiment)
    )
    |> assign(:stopped_by, stopped_by_name(experiment))
    |> assign(:org_name, org_name(experiment.org_id))
    |> assign(:project_name, project_name(experiment.project_id))
  end

  defp assign_guardrails(socket, org_id) do
    socket
    |> assign(:guard_org_id, org_id)
    |> assign(:guardrails, Guardrails.for_org(org_id))
    |> assign(:guard_stored?, Guardrails.stored_row(org_id) != nil)
    |> assign(:guard_live, Guardrails.live_count(org_id))
    |> assign(:guard_surfaces, guardrail_surfaces())
  end

  @impl true
  def handle_event("select_tab", %{"tab" => tab}, socket) when tab in @tabs do
    {:noreply, assign(socket, :tab, tab)}
  end

  def handle_event("select_tab", _params, socket), do: {:noreply, socket}

  # A read: which row the panel shows. Members may switch it too; only the
  # save below writes.
  def handle_event("guardrails_scope", params, socket) do
    case parse_scope_org(params["org_id"]) do
      {:ok, org_id} -> {:noreply, assign_guardrails(socket, org_id)}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("hide_create", _params, socket) do
    {:noreply, assign(socket, :show_create, false)}
  end

  def handle_event("hide_stop", _params, socket) do
    {:noreply, assign(socket, :show_stop_form, false)}
  end

  # Slug follows the name until someone edits the slug themselves, after
  # which it is left alone — a slug that kept rewriting itself under the
  # author's cursor would be worse than no auto-fill at all.
  def handle_event("create_form_change", params, socket) do
    previous = socket.assigns.create_form
    name = params["name"] || ""
    typed_slug = params["slug"] || ""

    slug =
      if typed_slug == "" or typed_slug == slugify(previous["name"]) do
        slugify(name)
      else
        typed_slug
      end

    form =
      previous
      |> Map.merge(Map.take(params, Map.keys(@empty_create_form)))
      |> Map.put("slug", slug)

    {:noreply, assign(socket, :create_form, form)}
  end

  # ── WRITES. Every one re-checks `@root_admin?` server-side ──────────────
  #
  # The buttons below are hidden from non-admins, and that is an affordance
  # only. A member who fires an event by name over the socket — which costs
  # nothing and needs no button — reaches this code, so this code is where
  # the refusal has to live. Each handler returns an error flash and touches
  # no context function on the way out.

  def handle_event("show_create", _params, socket) do
    admin_only(socket, fn ->
      {:noreply, socket |> assign(:show_create, true) |> assign(:create_form, @empty_create_form)}
    end)
  end

  def handle_event("create_experiment", params, socket) do
    admin_only(socket, fn -> with_user(socket, &create_experiment(socket, params, &1)) end)
  end

  # Drafts only. The refusal is the context's (`{:error, :not_draft}`); this
  # handler renders it. Once an experiment has been activated its
  # assignments ARE the evidence trail.
  def handle_event("delete_experiment", %{"slug" => slug}, socket) do
    admin_only(socket, fn -> with_user(socket, &delete_experiment(socket, slug, &1)) end)
  end

  def handle_event("delete_experiment", _params, socket) do
    admin_only(socket, fn ->
      {:noreply, put_flash(socket, :error, "Name the experiment to delete.")}
    end)
  end

  def handle_event("activate", %{"template_slug" => template_slug}, socket) do
    admin_only(socket, fn ->
      with_user(socket, fn user ->
        case Experiments.activate(socket.assigns.experiment, template_slug, user) do
          {:ok, experiment} ->
            {:noreply,
             socket |> put_flash(:info, "Experiment running.") |> load_experiment(experiment)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, error_message(reason))}
        end
      end)
    end)
  end

  def handle_event("activate", _params, socket) do
    admin_only(socket, fn ->
      {:noreply,
       put_flash(socket, :error, "Name the prompt template to snapshot as the control.")}
    end)
  end

  # A human start: `Experiments.start/2` with the user as actor, the same
  # guarded launch the MCP `experiment_start` takes. A human is never sent to
  # pending approval, and still meets `max_live` and `surface_busy`.
  def handle_event("start", params, socket) do
    admin_only(socket, fn ->
      with_user(socket, fn user ->
        with_experiment(socket, params, fn experiment ->
          case Experiments.start(experiment, user) do
            {:ok, %Experiment{} = running} ->
              {:noreply, socket |> put_flash(:info, "Experiment running.") |> reload(running)}

            {:ok, :pending_human_approval} ->
              {:noreply,
               socket |> put_flash(:info, "Awaiting human approval.") |> reload(experiment)}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, describe_error(reason))}
          end
        end)
      end)
    end)
  end

  def handle_event("approve_launch", params, socket) do
    admin_only(socket, fn ->
      with_user(socket, fn user ->
        with_experiment(socket, params, fn experiment ->
          case Experiments.approve_launch(experiment, user) do
            {:ok, running} ->
              {:noreply,
               socket
               |> put_flash(:info, "Launch approved. Experiment running.")
               |> reload(running)}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, describe_error(reason))}
          end
        end)
      end)
    end)
  end

  def handle_event("show_stop", _params, socket) do
    admin_only(socket, fn -> {:noreply, assign(socket, :show_stop_form, true)} end)
  end

  # Stop WITH feedback (product decision, 2026-09-24): `Experiments.stop/3` records the
  # feedback, who stopped it and when in the transition itself.
  def handle_event("stop", params, socket) do
    admin_only(socket, fn ->
      with_user(socket, fn user ->
        experiment = socket.assigns.experiment
        feedback = params |> Map.get("feedback") |> blank_to_nil()

        cond do
          is_nil(experiment) ->
            {:noreply, put_flash(socket, :error, "Open an experiment to stop it.")}

          experiment.status not in ["running", "draft"] ->
            {:noreply,
             put_flash(socket, :error, "Only a running or draft experiment can be stopped.")}

          is_binary(feedback) and String.length(feedback) > @max_feedback ->
            {:noreply,
             put_flash(socket, :error, "Feedback is at most #{@max_feedback} characters.")}

          true ->
            case Experiments.stop(experiment, user, feedback) do
              {:ok, stopped} ->
                {:noreply,
                 socket
                 |> put_flash(:info, "Experiment stopped.")
                 |> assign(:show_stop_form, false)
                 |> load_experiment(stopped)}

              {:error, changeset} ->
                {:noreply, put_flash(socket, :error, error_message(changeset))}
            end
        end
      end)
    end)
  end

  # Conclude and promote are separate events because they write DIFFERENT
  # things: conclude is a terminal status, promote writes the winning arm
  # as the surface's default. Neither implies the other, exactly as the MCP
  # tools `experiment_conclude` and `experiment_promote` do not.
  def handle_event("conclude", _params, socket) do
    admin_only(socket, fn ->
      with_user(socket, fn user ->
        experiment = socket.assigns.experiment

        if experiment && experiment.status == "running" do
          case Experiments.conclude(experiment, user) do
            {:ok, concluded} ->
              {:noreply,
               socket |> put_flash(:info, "Experiment concluded.") |> load_experiment(concluded)}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, error_message(reason))}
          end
        else
          {:noreply, put_flash(socket, :error, "Only a running experiment can be concluded.")}
        end
      end)
    end)
  end

  def handle_event("promote", %{"variant" => variant_slug}, socket)
      when is_binary(variant_slug) do
    admin_only(socket, fn ->
      with_user(socket, fn user ->
        experiment = socket.assigns.experiment
        row = Enum.find(socket.assigns[:result_rows] || [], &(&1.variant_slug == variant_slug))

        cond do
          is_nil(experiment) or is_nil(row) ->
            {:noreply, put_flash(socket, :error, "No such arm to promote.")}

          not row.earned? ->
            {:noreply,
             put_flash(socket, :error, "This arm has not earned a figure; nothing to promote.")}

          true ->
            opts = [
              actor: user,
              variant: variant_slug,
              trigger: :manual,
              actor_type: "user",
              actor_id: user.id,
              effect: row.value,
              n: row.n
            ]

            case Promotion.promote(experiment, opts) do
              {:ok, _promotion} ->
                {:noreply,
                 socket
                 |> put_flash(:info, "Promoted #{variant_slug}.")
                 |> reload(experiment)}

              {:error, reason} ->
                {:noreply, put_flash(socket, :error, describe_error(reason))}
            end
        end
      end)
    end)
  end

  def handle_event("promote", _params, socket) do
    admin_only(socket, fn ->
      {:noreply, put_flash(socket, :error, "Name the arm to promote.")}
    end)
  end

  # Variants for a non-prompt surface. The payload is validated by the
  # surface itself — the same `validate_payload/1` the MCP tool calls — and
  # its error list is shown verbatim. Prompt variants are edited on
  # `/admin/prompts/:slug`, as before.
  def handle_event("add_variant", params, socket) do
    admin_only(socket, fn -> with_user(socket, &add_variant(socket, params, &1)) end)
  end

  def handle_event("guardrails_save", params, socket) do
    admin_only(socket, fn ->
      with_user(socket, fn user ->
        case parse_scope_org(params["org_id"]) do
          {:error, message} ->
            {:noreply, put_flash(socket, :error, message)}

          {:ok, org_id} ->
            case Guardrails.save(org_id, guardrail_attrs(params), user) do
              {:ok, _row} ->
                {:noreply,
                 socket |> put_flash(:info, "Guardrails saved.") |> assign_guardrails(org_id)}

              {:error, reason} ->
                {:noreply, put_flash(socket, :error, error_message(reason))}
            end
        end
      end)
    end)
  end

  # The add-variant handler's body, with the acting user for the context's
  # install-level re-check (`Experiments.add_variant/3`, task 01a1386d-fb6e
  # stage 2).
  defp add_variant(socket, params, user) do
    experiment = socket.assigns.experiment

    with :ok <- variant_addable(experiment),
         surface when not is_nil(surface) <- Surfaces.get(experiment.surface_key),
         {:ok, slug} <- variant_slug(params["slug"]),
         {:ok, raw} <- decode_payload(params["payload"]),
         {:ok, payload} <- validate_payload(surface, raw),
         {:ok, weight} <- parse_weight(params["weight"]),
         {:ok, _variant} <-
           Experiments.add_variant(
             experiment,
             %{"slug" => slug, "payload" => payload, "weight" => weight},
             user
           ) do
      {:noreply, socket |> put_flash(:info, "Variant added.") |> load_experiment(experiment)}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "This experiment's surface is unknown.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, put_flash(socket, :error, error_message(cs))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, @refused_message)}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  # The create handler's body (`handle_event("create_experiment", …)`), with
  # the acting user for the context's install-level re-check
  # (`Experiments.create_experiment/2`, task 01a1386d-fb6e stage 2).
  defp create_experiment(socket, params, user) do
    # `stop_rule` was DROPPED here once: the field could be rendered,
    # submitted and silently vanish. The shape is exactly what
    # `ExperimentResults.min_subjects/1` reads — a string key over an
    # INTEGER value; the string "40" fails that guard and reads as no rule.
    with {:ok, min_subjects} <- parse_min_subjects(params["min_subjects"]),
         {:ok, surface_attrs} <- parse_surface(params["surface"]),
         {:ok, org_id} <- parse_scope_org(params["org_id"]),
         {:ok, project_id} <- parse_project(params["project_id"]) do
      attrs =
        %{
          "slug" => params["slug"],
          "name" => params["name"],
          "hypothesis" => params["hypothesis"],
          "primary_metric" => params["primary_metric"],
          "stop_rule" => %{"min_subjects" => min_subjects},
          "org_id" => org_id,
          "project_id" => project_id
        }
        |> Map.merge(surface_attrs)

      case Experiments.create_experiment(attrs, user) do
        {:ok, _experiment} ->
          {:noreply,
           socket
           |> put_flash(:info, "Experiment created as a draft.")
           |> assign(:show_create, false)
           |> assign(:create_form, @empty_create_form)
           |> load_index()}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:create_form, merge_create_form(socket, params))
           |> put_flash(:error, error_message(reason))}
      end
    else
      {:error, message} ->
        {:noreply,
         socket
         |> assign(:create_form, merge_create_form(socket, params))
         |> put_flash(:error, message)}
    end
  end

  defp delete_experiment(socket, slug, user) do
    case Experiments.get_experiment_by_slug(slug) do
      nil ->
        {:noreply, put_flash(socket, :error, "No experiment #{slug}.")}

      experiment ->
        case Experiments.delete_experiment(experiment, user) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Draft deleted.")
             |> assign(:experiment, nil)
             |> load_index()
             |> push_patch(to: ~p"/control/experiments")}

          {:error, :not_draft} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Only a draft can be deleted. An activated experiment's assignments are its record."
             )}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, error_message(reason))}
        end
    end
  end

  # The gate. `fun` is not evaluated at all unless the acting user is a root-org
  # admin, so a refused write cannot have run a context function first.
  defp admin_only(socket, fun) do
    if socket.assigns[:root_admin?] do
      fun.()
    else
      {:noreply, put_flash(socket, :error, @refused_message)}
    end
  end

  # Approval, stop and guardrail writes record WHICH human acted, so a write
  # with no user struct in hand is refused rather than recorded as nobody.
  defp with_user(socket, fun) do
    case socket.assigns[:current_user_record] do
      %User{} = user -> fun.(user)
      _ -> {:noreply, put_flash(socket, :error, "Sign in again to change experiments.")}
    end
  end

  defp with_experiment(socket, params, fun) do
    experiment =
      case params do
        %{"slug" => slug} when is_binary(slug) -> Experiments.get_experiment_by_slug(slug)
        _ -> socket.assigns[:experiment]
      end

    case experiment do
      %Experiment{} = experiment -> fun.(experiment)
      nil -> {:noreply, put_flash(socket, :error, "No such experiment.")}
    end
  end

  # After a write from either page, re-read what that page shows.
  defp reload(socket, %Experiment{} = experiment) do
    if socket.assigns[:experiment] do
      load_experiment(socket, Experiments.get_experiment(experiment.id))
    else
      load_index(socket)
    end
  end

  defp merge_create_form(socket, params) do
    Map.merge(socket.assigns.create_form, Map.take(params, Map.keys(@empty_create_form)))
  end

  defp slugify(nil), do: ""

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  # Integer, not a string, and strictly positive — `min_subjects/1` rejects
  # anything else and the experiment would read "no stop rule set" forever.
  defp parse_min_subjects(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> stop_rule_error()
    end
  end

  defp parse_min_subjects(n) when is_integer(n) and n > 0, do: {:ok, n}
  defp parse_min_subjects(_), do: stop_rule_error()

  defp stop_rule_error,
    do: {:error, "Stop rule must be a whole number of subjects, greater than 0."}

  # `"<surface key>::<target>"`. The prompt surface with no target is the
  # original flow: the target template is chosen at activation, which is
  # also when its control is snapshotted.
  defp parse_surface(nil), do: {:ok, %{}}
  defp parse_surface(@prompt_surface <> "::"), do: {:ok, %{}}

  defp parse_surface(value) when is_binary(value) do
    with [key, target] <- String.split(value, "::", parts: 2),
         surface when not is_nil(surface) <- Surfaces.get(key),
         true <- target != "" and target in surface_targets(surface) do
      {:ok, %{"surface_key" => key, "surface_target" => target}}
    else
      _ -> {:error, "Choose a registered surface."}
    end
  end

  defp parse_surface(_), do: {:error, "Choose a registered surface."}

  defp parse_scope_org(nil), do: {:ok, nil}
  defp parse_scope_org(""), do: {:ok, nil}

  defp parse_scope_org(id) when is_binary(id) do
    case Tenancy.get_org(id) do
      nil -> {:error, "No such org."}
      org -> {:ok, org.id}
    end
  end

  defp parse_scope_org(_), do: {:error, "No such org."}

  defp parse_project(nil), do: {:ok, nil}
  defp parse_project(""), do: {:ok, nil}

  defp parse_project(id) when is_binary(id) do
    if Platform.UUID.valid?(id), do: {:ok, id}, else: {:error, "No such project."}
  end

  defp parse_project(_), do: {:error, "No such project."}

  defp variant_addable(%Experiment{status: "draft", surface_key: key})
       when is_binary(key) and key != @prompt_surface,
       do: :ok

  defp variant_addable(_),
    do: {:error, "Variants are added to a draft on a non-prompt surface only."}

  defp variant_slug(slug) when is_binary(slug) do
    slug = String.trim(slug)

    cond do
      slug == "" -> {:error, "Name the variant."}
      slug == Experiment.control_slug() -> {:error, "The control arm is created at start."}
      true -> {:ok, slug}
    end
  end

  defp variant_slug(_), do: {:error, "Name the variant."}

  defp decode_payload(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, "Payload must be a JSON object."}
    end
  end

  defp decode_payload(_), do: {:error, "Payload must be a JSON object."}

  defp validate_payload(surface, raw) do
    case surface.validate_payload(raw) do
      {:ok, payload} -> {:ok, payload}
      {:error, reasons} -> {:error, Enum.join(reasons, "; ")}
    end
  end

  defp parse_weight(nil), do: {:ok, 1}
  defp parse_weight(""), do: {:ok, 1}

  defp parse_weight(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, "Weight must be a whole number greater than 0."}
    end
  end

  defp parse_weight(_), do: {:error, "Weight must be a whole number greater than 0."}

  # Only the keys the form actually sent. `Guardrails.save/3` fills every
  # absent one from the effective value, so a caller that sends only
  # `max_live` changes only `max_live`. The panel always sends
  # `allowed_surfaces[]` (a hidden blank keeps the key present when every box
  # is unticked, which means "none", not "unchanged").
  defp guardrail_attrs(params) do
    %{}
    |> put_present(params, "max_live", & &1)
    |> put_present(params, "allowed_surfaces", fn list ->
      list |> List.wrap() |> Enum.reject(&(&1 in ["", nil]))
    end)
    |> put_present(params, "require_human_approval", &(&1 in ["true", true]))
    |> put_present(params, "allow_auto_promote", &(&1 in ["true", true]))
  end

  defp put_present(acc, params, key, fun) do
    case Map.fetch(params, key) do
      {:ok, value} -> Map.put(acc, key, fun.(value))
      :error -> acc
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp describe_error(%Guardrails.Refusal{
         code: :max_live_reached,
         limit: limit,
         current: current
       }),
       do: "Refused: #{current} of #{limit} live experiments already running in this scope."

  defp describe_error(%Guardrails.Refusal{code: :surface_busy, surface: surface}),
    do: "Refused: another running experiment on #{surface} overlaps this one's scope."

  defp describe_error(%Guardrails.Refusal{message: message}) when is_binary(message),
    do: "Refused: #{message}"

  defp describe_error(%Promotion.Refusal{message: message}) when is_binary(message),
    do: "Refused: #{message}"

  defp describe_error(%Ecto.Changeset{} = changeset), do: error_message(changeset)
  defp describe_error(:unauthorized), do: @refused_message
  defp describe_error(:not_pending), do: "This experiment is not awaiting approval."
  defp describe_error(:not_draft), do: "Only a draft can be started."
  defp describe_error(:unknown_surface), do: "This experiment's surface is not registered."
  defp describe_error(reason) when is_atom(reason), do: "Refused: #{reason}"
  defp describe_error(reason), do: "Refused: #{inspect(reason)}"

  # The short form is what an `<option>` carries: a native option cannot wrap,
  # so every character in it is width the control has to find. The long form
  # is for the helper line below the select, which is ordinary wrapping text.
  defp direction_short(:lower_is_better), do: "lower is better"
  defp direction_short(:higher_is_better), do: "higher is better"
  defp direction_short(:neutral), do: "neutral"
  defp direction_short(_), do: "direction not stated"

  # The catalog entry for the currently-picked slug, or nil before a pick.
  defp selected_metric(_catalog, nil), do: nil
  defp selected_metric(_catalog, ""), do: nil

  defp selected_metric(catalog, slug), do: Enum.find(catalog, &(&1.slug == slug))

  defp direction_label(:lower_is_better), do: "lower is better"
  defp direction_label(:higher_is_better), do: "higher is better"
  defp direction_label(:neutral), do: "neutral — neither direction is a win"
  defp direction_label(_), do: "direction not stated"

  # The context's install-level refusal (task 01a1386d-fb6e stage 2), worded
  # as `admin_only/2`'s.
  defp error_message(:unauthorized), do: @refused_message

  defp error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  # ── Derived display data ────────────────────────────────────────────────

  defp sorted_orgs, do: Tenancy.list_orgs() |> Enum.sort_by(& &1.name)

  defp surface_targets(surface) do
    if Code.ensure_loaded?(surface) and function_exported?(surface, :targets, 0),
      do: surface.targets(),
      else: []
  end

  # Create-form options: the prompt surface (target chosen at activation)
  # and one option per declared target of every other surface.
  defp surface_options do
    prompt = [{@prompt_surface <> "::", "#{@prompt_surface} (template chosen at activation)"}]

    others =
      for surface <- Surfaces.list(),
          surface.key() != @prompt_surface,
          not Guardrails.send_path?(surface.key()),
          target <- surface_targets(surface) do
        {"#{surface.key()}::#{target}", "#{surface.key()} at #{target}"}
      end

    prompt ++ others
  end

  # The checkboxes: registered surfaces ONLY, never a send path (the registry
  # holds none, and the changeset would refuse one).
  defp guardrail_surfaces do
    Surfaces.list() |> Enum.map(& &1.key()) |> Enum.reject(&Guardrails.send_path?/1)
  end

  # `%{variant_slug => [{reason, count}]}` for excluded assignments.
  defp exclusion_reasons(assignments) do
    assignments
    |> Enum.filter(& &1.excluded_reason)
    |> Enum.group_by(& &1.variant_slug)
    |> Map.new(fn {slug, rows} ->
      reasons =
        rows
        |> Enum.frequencies_by(& &1.excluded_reason)
        |> Enum.sort_by(fn {reason, count} -> {-count, reason} end)

      {slug, reasons}
    end)
  end

  # Bar length for EARNED rows only. A ratio is drawn at its own value; any
  # other unit is drawn against the largest earned figure in the experiment,
  # because a duration has no natural full scale. Unearned rows get no entry
  # and no bar.
  defp bar_widths(rows) do
    earned = Enum.filter(rows, & &1.earned?)
    top = earned |> Enum.map(&abs(&1.value || 0.0)) |> Enum.max(fn -> 0.0 end)

    Map.new(earned, fn row ->
      pct =
        case row.unit do
          :ratio -> (row.value || 0.0) * 100
          _ when top > 0 -> abs(row.value || 0.0) / top * 100
          _ -> 0.0
        end

      {row.variant_slug, (pct / 1) |> max(0.0) |> min(100.0) |> Float.round(1)}
    end)
  end

  defp stopped_by_name(%Experiment{stopped_by_user_id: nil}), do: nil

  defp stopped_by_name(%Experiment{stopped_by_user_id: id}) do
    case Accounts.get_user(id) do
      %User{name: name} when is_binary(name) and name != "" -> name
      %User{email: email} -> email
      nil -> "a user who no longer exists"
    end
  end

  defp org_name(nil), do: nil

  defp org_name(id) do
    case Tenancy.get_org(id) do
      nil -> nil
      org -> org.name
    end
  end

  defp project_name(nil), do: nil

  defp project_name(id) do
    case Tasks.get_project(id) do
      nil -> nil
      project -> project.name
    end
  end

  defp window_days(%Experiment{observation_window_days: days}) when is_integer(days), do: days

  defp window_days(%Experiment{metric_spec: %{"window_days" => days}}) when is_integer(days),
    do: days

  defp window_days(_), do: nil

  defp proposer(agent_names, %Experiment{proposed_by_agent_id: id}) when is_binary(id),
    do: Map.get(agent_names, id, "an agent")

  defp proposer(_agent_names, _experiment), do: "a human"

  defp can_start?(%Experiment{status: "draft", approval_state: state} = e) do
    state != "pending" and is_binary(e.surface_key) and is_binary(e.surface_target)
  end

  defp can_start?(_), do: false

  # The metric in words, from the spec when there is one.
  defp metric_words(%Experiment{} = experiment, catalog),
    do: spec_words(MetricKind.parse(experiment.metric_spec), experiment.primary_metric, catalog)

  @doc false
  # The words for a `MetricKind.parse/1` result. Public only so the
  # `{:ok, module, _}` fallback is testable: no kind in `MetricKind.list/0`
  # reaches it today (task 01a11706).
  def spec_words(parsed, primary_metric, catalog) do
    case parsed do
      {:ok, Platform.Experiments.MetricKinds.OutcomeRate, params} ->
        labels = params |> Map.get("labels", []) |> Enum.join(" or ")

        "Share of subjects with a #{labels} signal within #{params["window_days"]} days of assignment"

      {:ok, Platform.Experiments.MetricKinds.DurationBetween, params} ->
        "Time from #{params["from_status"]} to #{params["to_status"]}"

      {:ok, Platform.Experiments.MetricKinds.DispatchUsage, %{"field" => field, "agg" => agg}} ->
        "#{String.capitalize(agg)} #{dispatch_field_label(field)} per dispatch"

      {:ok, _registered, %{"slug" => slug}} ->
        registered_words(slug, catalog)

      # A kind added to `MetricKind.list/0` without words here must still
      # render, never crash the tab (task 01a11706).
      {:ok, module, _params} ->
        "#{module.kind()} metric (no description for this kind yet)"

      :none ->
        registered_words(primary_metric, catalog)

      {:error, _} ->
        "metric spec does not parse, so nothing is measured"
    end
  end

  @dispatch_field_labels %{
    "suite_tool_calls" => "Burrow tool calls",
    "client_turns" => "client turns",
    "client_tokens_in" => "client input tokens",
    "client_tokens_out" => "client output tokens",
    "wall_ms" => "wall time (ms)",
    "outcome_first_pass" => "first-pass outcome",
    "tool_calls_error" => "errored tool calls"
  }

  defp dispatch_field_label(field),
    do: Map.get(@dispatch_field_labels, field, String.replace(field, "_", " "))

  defp registered_words(nil, _catalog), do: "none set"

  defp registered_words(slug, catalog) do
    case Enum.find(catalog, &(&1.slug == slug)) do
      nil -> "#{slug} (not a metric this platform can compute)"
      metric -> "#{metric.label} (#{direction_short(metric.direction)})"
    end
  end

  defp policy_words(policy) when policy in [nil, %{}],
    do: "Weighted random pick across arms; no policy filter."

  defp policy_words(policy), do: Jason.encode!(policy, pretty: true)

  defp signal_words(nil), do: "None. This experiment reads no inbound signals."

  defp signal_words(source) when source == %{},
    do: "None. This experiment reads no inbound signals."

  defp signal_words(%{"kind" => kind} = source) do
    to = if source["to_address"], do: " to #{source["to_address"]}", else: ""

    labels =
      case source["labels"] do
        [_ | _] = labels -> "; labels: #{Enum.join(labels, ", ")}"
        _ -> ""
      end

    "#{kind}#{to}#{labels}"
  end

  defp signal_words(source), do: Jason.encode!(source)

  defp variant_body(%Experiment{surface_key: key}, variant) when key in [nil, @prompt_surface],
    do: variant.content || ""

  defp variant_body(_experiment, variant), do: Jason.encode!(variant.payload || %{}, pretty: true)

  defp format_dt(nil), do: "an unrecorded time"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full overflow-y-auto p-4 md:p-6 space-y-6">
      <%= if @experiment do %>
        {detail(assigns)}
      <% else %>
        {index(assigns)}
      <% end %>
    </div>
    """
  end

  defp index(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <h1 class="text-xl font-bold">Experiments</h1>
        <%!-- Two entry points on purpose: this one persists once the list
              fills, the in-body call-to-action exists only while it is
              empty. Both are hidden from non-admins, and that is an
              affordance only — the refusal lives in `admin_only/2`. --%>
        <button
          :if={@root_admin? and not @show_create}
          type="button"
          phx-click="show_create"
          data-role="new-experiment-button"
          class="btn btn-sm btn-outline"
        >
          <span class="hero-plus size-4" aria-hidden="true"></span> New experiment
        </button>
      </div>

      <p class="text-sm text-base-content max-w-2xl">
        Every experiment ever run, including the ones that made things worse. A result appears
        only once its arm has measured enough to have earned one — until then the cell says so,
        with the sample it has so far.
      </p>

      {create_panel(assigns)}

      <%!-- With zero experiments the sparse state IS the page, so it leads
            somewhere rather than apologising. --%>
      <section
        :if={@rows == [] and not @show_create}
        data-role="empty-list"
        class="bg-base-200 rounded-lg px-6 py-12 text-center space-y-3"
      >
        <h2 class="text-sm font-semibold">No experiments yet.</h2>
        <p class="text-sm text-neutral max-w-md mx-auto">
          An experiment runs one variant against production traffic and reports whether it
          helped — or says it does not know yet.
        </p>
        <button
          :if={@root_admin?}
          type="button"
          phx-click="show_create"
          data-role="empty-create-cta"
          class="btn btn-sm btn-outline"
        >
          Create the first one
        </button>
      </section>

      <%!-- Rows, not a table: at 375px a four-column table pushes RESULT —
            the entire point of this page — behind a horizontal scroll. Each
            row stacks below `sm`; the fused figure never wraps away from
            its n (`whitespace-nowrap` inside `result_cell/1`). --%>
      <section :if={@rows != []} class="space-y-2 shrink-0" data-role="experiment-list">
        <div
          :for={{experiment, row, reasons} <- @rows}
          id={"experiment-row-#{experiment.slug}"}
          data-role="experiment-row"
          class={[
            "rounded-lg p-4 flex flex-col gap-3 md:flex-row md:items-start",
            if(row.earned?, do: "bg-base-200", else: "bg-base-300")
          ]}
        >
          <div class="md:w-72 shrink-0 space-y-1 min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              {status_badge(%{status: experiment.status})}
              {approval_badge(%{experiment: experiment})}
            </div>
            <.link
              navigate={~p"/control/experiments/#{experiment.slug}"}
              class="link link-hover font-medium break-words"
            >
              {experiment.name}
            </.link>
            <div class="text-xs text-base-content/70 break-all">
              {experiment.surface_key || "dispatch.prompt"} · {experiment.slug}
            </div>
          </div>
          <div class="flex-1 min-w-0">
            {result_cell(%{row: row, experiment: experiment, reasons: reasons})}
          </div>
          <div
            :if={experiment.approval_state == "pending"}
            data-role="pending-approval"
            class="md:w-56 shrink-0 space-y-2"
          >
            <p class="text-sm">
              Awaiting human approval, proposed by
              <span class="font-medium" data-role="proposed-by">
                {proposer(@agent_names, experiment)}
              </span>
            </p>
            <button
              :if={@root_admin?}
              type="button"
              phx-click="approve_launch"
              phx-value-slug={experiment.slug}
              data-role="approve-launch-button"
              class="btn btn-sm btn-neutral"
            >
              Approve launch
            </button>
          </div>
        </div>
      </section>

      {guardrails_panel(assigns)}
    </div>
    """
  end

  # THE guardrails panel. Pre-filled from the EFFECTIVE value, so a save
  # that changes one field changes one field — see the moduledoc.
  defp guardrails_panel(assigns) do
    ~H"""
    <section
      data-role="guardrails-panel"
      class="bg-base-200 rounded-lg p-4 md:p-6 space-y-4 max-w-2xl shrink-0"
    >
      <div class="flex flex-wrap items-center justify-between gap-2">
        <h2 class="text-sm font-semibold">Guardrails</h2>
        <span class="text-xs text-base-content/70" data-role="guardrails-source">
          {if @guard_stored?, do: "Stored for this scope", else: "Inherited; saving stores a row"}
        </span>
      </div>
      <p class="text-sm text-base-content">
        What an agent may do unattended. A human acting on this page is held to the live limit
        and to one experiment per surface, and to nothing else here.
      </p>

      <form phx-change="guardrails_scope" data-role="guardrails-scope-form">
        <label class="text-xs font-semibold text-base-content/70" for="guardrails-scope">
          Scope
        </label>
        <select
          id="guardrails-scope"
          name="org_id"
          data-role="guardrails-scope"
          class="select select-sm select-bordered w-full max-w-sm"
        >
          <option value="" selected={is_nil(@guard_org_id)}>Install-wide</option>
          <option :for={org <- @orgs} value={org.id} selected={@guard_org_id == org.id}>
            {org.name}
          </option>
        </select>
      </form>

      <form
        phx-submit="guardrails_save"
        data-role="guardrails-form"
        class="space-y-3"
      >
        <input type="hidden" name="org_id" value={@guard_org_id || ""} />
        <dl class="divide-y divide-base-300 text-sm">
          <div class="py-2 flex flex-wrap items-center justify-between gap-2">
            <dt>Live experiments</dt>
            <dd class="flex items-center gap-2">
              <span class="font-mono whitespace-nowrap" data-role="guardrails-live">
                {@guard_live} of {@guardrails.max_live} used
              </span>
              <input
                :if={@root_admin?}
                type="number"
                name="max_live"
                min="0"
                step="1"
                value={@guardrails.max_live}
                aria-label="Maximum live experiments"
                data-role="guardrails-max-live"
                class="input input-sm input-bordered w-20 font-mono"
              />
            </dd>
          </div>

          <div class="py-2 space-y-2">
            <dt>Surfaces in scope</dt>
            <dd class="space-y-1" data-role="guardrails-surfaces">
              <input :if={@root_admin?} type="hidden" name="allowed_surfaces[]" value="" />
              <label :for={key <- @guard_surfaces} class="flex items-center gap-2 font-mono text-sm">
                <input
                  type="checkbox"
                  name="allowed_surfaces[]"
                  value={key}
                  checked={key in (@guardrails.allowed_surfaces || [])}
                  disabled={not @root_admin?}
                  data-role="guardrails-surface"
                  class="checkbox checkbox-sm"
                />
                {key}
              </label>
            </dd>
          </div>

          <%!-- TEXT, not an unchecked box. A checkbox is an invitation; this
                row states that the system does not do it. --%>
          <div
            class="py-2 flex flex-wrap items-center justify-between gap-2"
            data-role="mail-send-row"
          >
            <dt>Mail send path</dt>
            <dd class="font-mono text-base-content/70">— not available —</dd>
          </div>

          <div class="py-2 flex items-center justify-between gap-2">
            <dt><label for="guardrails-approval">Require human approval to launch</label></dt>
            <dd>
              <input
                :if={@root_admin?}
                type="hidden"
                name="require_human_approval"
                value="false"
              />
              <input
                id="guardrails-approval"
                type="checkbox"
                name="require_human_approval"
                value="true"
                checked={@guardrails.require_human_approval == true}
                disabled={not @root_admin?}
                data-role="guardrails-approval"
                class="checkbox checkbox-sm"
              />
            </dd>
          </div>

          <div class="py-2 flex items-center justify-between gap-2">
            <dt><label for="guardrails-auto-promote">Allow agents to promote</label></dt>
            <dd>
              <input :if={@root_admin?} type="hidden" name="allow_auto_promote" value="false" />
              <input
                id="guardrails-auto-promote"
                type="checkbox"
                name="allow_auto_promote"
                value="true"
                checked={@guardrails.allow_auto_promote == true}
                disabled={not @root_admin?}
                data-role="guardrails-auto-promote"
                class="checkbox checkbox-sm"
              />
            </dd>
          </div>
        </dl>

        <div :if={@root_admin?} class="flex justify-end">
          <button type="submit" data-role="guardrails-save" class="btn btn-sm btn-neutral">
            Save guardrails
          </button>
        </div>
        <p :if={not @root_admin?} class="text-xs text-base-content/70">
          Only root-org admins can change guardrails.
        </p>
      </form>
    </section>
    """
  end

  # The create form. Submitting it makes a DRAFT and nothing else — no
  # assignments, no snapshot, no traffic — because `create_experiment/1`
  # forces the status. Starting stays a separate, deliberate act.
  defp create_panel(assigns) do
    assigns =
      assign(
        assigns,
        :selected_metric,
        selected_metric(assigns.metric_catalog, assigns.create_form["primary_metric"])
      )

    ~H"""
    <section
      :if={@show_create and @root_admin?}
      data-role="create-experiment-panel"
      class="bg-base-200 rounded-lg p-4 md:p-6 max-w-2xl"
    >
      <h2 class="text-sm font-semibold mb-4">New experiment</h2>

      <form
        data-role="create-experiment-form"
        phx-submit="create_experiment"
        phx-change="create_form_change"
        class="space-y-4"
      >
        <div>
          <label class="text-xs font-semibold text-base-content/70" for="create-name">Name</label>
          <input
            id="create-name"
            name="name"
            value={@create_form["name"]}
            required
            data-role="create-name"
            class="input input-sm input-bordered w-full"
          />
        </div>

        <div>
          <label class="text-xs font-semibold text-base-content/70" for="create-slug">Slug</label>
          <input
            id="create-slug"
            name="slug"
            value={@create_form["slug"]}
            required
            data-role="create-slug"
            class="input input-sm input-bordered w-full font-mono"
          />
          <p class="text-xs text-neutral mt-1">Auto-filled from the name, editable.</p>
        </div>

        <div>
          <label class="text-xs font-semibold text-base-content/70" for="create-hypothesis">
            Hypothesis
          </label>
          <textarea
            id="create-hypothesis"
            name="hypothesis"
            rows="3"
            required
            data-role="create-hypothesis"
            class="textarea textarea-sm textarea-bordered w-full"
          >{@create_form["hypothesis"]}</textarea>
          <p class="text-xs text-neutral mt-1">
            What you expect, in a sentence. Written before the result exists, on purpose.
          </p>
        </div>

        <div>
          <label class="text-xs font-semibold text-base-content/70" for="create-surface">
            Surface
          </label>
          <select
            id="create-surface"
            name="surface"
            data-role="create-surface"
            class="select select-sm select-bordered w-full font-mono"
          >
            <option
              :for={{value, label} <- @surface_options}
              value={value}
              selected={@create_form["surface"] == value}
              data-role="surface-option"
            >
              {label}
            </option>
          </select>
          <p class="text-xs text-neutral mt-1">
            The decision point this experiment varies. Only registered surfaces are listed.
          </p>
        </div>

        <div class="grid gap-4 sm:grid-cols-2">
          <div>
            <label class="text-xs font-semibold text-base-content/70" for="create-org">Org</label>
            <select
              id="create-org"
              name="org_id"
              data-role="create-org"
              class="select select-sm select-bordered w-full"
            >
              <option value="" selected={@create_form["org_id"] == ""}>Install-wide</option>
              <option :for={org <- @orgs} value={org.id} selected={@create_form["org_id"] == org.id}>
                {org.name}
              </option>
            </select>
          </div>
          <div>
            <label class="text-xs font-semibold text-base-content/70" for="create-project">
              Project
            </label>
            <select
              id="create-project"
              name="project_id"
              data-role="create-project"
              class="select select-sm select-bordered w-full"
            >
              <option value="" selected={@create_form["project_id"] == ""}>Every project</option>
              <option
                :for={project <- @projects}
                value={project.id}
                selected={@create_form["project_id"] == project.id}
              >
                {project.name}
              </option>
            </select>
          </div>
        </div>

        <div class="grid gap-4 sm:grid-cols-2">
          <div>
            <label class="text-xs font-semibold text-base-content/70" for="create-metric">
              Primary metric
            </label>
            <%!-- A PICKER, not free text. An unrecognised string resolves to
                  `:no_metric`, so a free-text box is a second way to create a
                  silently inert experiment. The option carries LABEL + SHORT
                  DIRECTION only: a native `<option>` neither wraps nor
                  truncates, so the description moves below the control. --%>
            <select
              id="create-metric"
              name="primary_metric"
              required
              data-role="create-metric"
              class="select select-sm select-bordered w-full"
            >
              <option value="" disabled selected={@create_form["primary_metric"] == ""}>
                Choose a metric
              </option>
              <option
                :for={metric <- @metric_catalog}
                value={metric.slug}
                data-role="metric-option"
                data-direction={metric.direction}
                selected={@create_form["primary_metric"] == metric.slug}
              >
                {metric.label} ({direction_short(metric.direction)})
              </option>
            </select>
            <p :if={@selected_metric} class="text-xs text-neutral mt-1" data-role="metric-description">
              {@selected_metric.description}
              <span class="whitespace-nowrap">({direction_label(@selected_metric.direction)})</span>
            </p>
            <p class="text-xs text-neutral mt-2" data-role="metric-extension-note">
              This list is every metric the platform can compute. Parameterised metrics (outcome
              rates, durations) are set through the experiments MCP tools.
            </p>
          </div>

          <div>
            <label class="text-xs font-semibold text-base-content/70" for="create-stop-rule">
              Stop rule
            </label>
            <div class="flex items-center gap-2">
              <input
                id="create-stop-rule"
                name="min_subjects"
                type="number"
                min="1"
                step="1"
                required
                value={@create_form["min_subjects"]}
                data-role="create-stop-rule"
                class="input input-sm input-bordered w-24 tabular-nums"
              />
              <span class="text-sm text-neutral">subjects</span>
            </div>
            <p class="text-xs text-neutral mt-1">
              No figure is shown until this many subjects are measured. Required — without a stop
              rule the results layer fails closed and the experiment can never report.
            </p>
          </div>
        </div>

        <div class="flex flex-wrap justify-end gap-2">
          <button
            type="button"
            phx-click="hide_create"
            data-role="create-cancel"
            class="btn btn-sm btn-ghost"
          >
            Cancel
          </button>
          <button type="submit" data-role="create-submit" class="btn btn-sm btn-neutral">
            Create draft
          </button>
        </div>
      </form>
    </section>
    """
  end

  defp detail(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="space-y-2">
        <.link navigate={~p"/control/experiments"} class="text-xs link link-hover text-neutral">
          <span class="hero-arrow-left size-3" aria-hidden="true"></span> All experiments
        </.link>
        <div class="flex flex-wrap items-center gap-3">
          <h1 class="text-xl font-bold break-words">{@experiment.name}</h1>
          {status_badge(%{status: @experiment.status})}
          {approval_badge(%{experiment: @experiment})}
        </div>
        <p :if={@experiment.hypothesis} class="text-sm text-base-content max-w-2xl">
          {@experiment.hypothesis}
        </p>
        <p class="text-sm text-base-content/80 flex flex-wrap gap-x-4 gap-y-1">
          <span class="font-mono break-all" data-role="header-surface">
            {@experiment.surface_key || "dispatch.prompt"}
          </span>
          <span :if={window_days(@experiment)} data-role="observation-window">
            Window: {window_days(@experiment)} days
          </span>
        </p>
      </div>

      <%!-- Controls. Neutral, all of them: Promote, on an earned row, is the
            only primary action on this page. --%>
      <div :if={@root_admin?} class="flex flex-wrap gap-2" data-role="experiment-controls">
        <button
          :if={can_start?(@experiment)}
          type="button"
          phx-click="start"
          data-role="start-button"
          class="btn btn-sm btn-neutral"
        >
          Start
        </button>
        <button
          :if={@experiment.status == "running" and not @show_stop_form}
          type="button"
          phx-click="show_stop"
          data-role="stop-button"
          class="btn btn-sm btn-outline"
        >
          Stop
        </button>
        <button
          :if={@experiment.status == "running"}
          type="button"
          phx-click="conclude"
          data-role="conclude-button"
          data-confirm="Conclude this experiment? It stops assigning and its result stands."
          class="btn btn-sm btn-outline"
        >
          Conclude
        </button>
      </div>

      <form
        :if={@root_admin? and @show_stop_form and @experiment.status == "running"}
        phx-submit="stop"
        data-role="stop-form"
        class="bg-base-200 rounded-lg p-4 space-y-3 max-w-2xl"
      >
        <label class="text-sm font-semibold" for="stop-feedback">Why are you stopping it?</label>
        <textarea
          id="stop-feedback"
          name="feedback"
          rows="3"
          maxlength="4000"
          data-role="stop-feedback-input"
          class="textarea textarea-sm textarea-bordered w-full"
          placeholder="What you saw and what should happen next. The Scientist reads this."
        ></textarea>
        <p class="text-xs text-base-content/70">
          Stopping is not concluding: the question stays open, and subjects already assigned keep
          their arm.
        </p>
        <div class="flex flex-wrap justify-end gap-2">
          <button type="button" phx-click="hide_stop" class="btn btn-sm btn-ghost">Cancel</button>
          <button type="submit" data-role="stop-submit" class="btn btn-sm btn-neutral">
            Stop experiment
          </button>
        </div>
      </form>

      <section
        :if={@experiment.status == "stopped"}
        data-role="stop-record"
        class="bg-base-200 rounded-lg p-4 space-y-1 max-w-2xl"
      >
        <p class="text-sm">
          Stopped by
          <span class="font-medium" data-role="stopped-by">{@stopped_by || "an agent"}</span>
          on <span data-role="stopped-at">{format_dt(@experiment.stopped_at)}</span>
        </p>
        <%!-- A <pre> so the formatter cannot indent the text into the
              rendered feedback; the human's own line breaks are kept. --%>
        <pre
          :if={@experiment.stop_feedback}
          data-role="stop-feedback"
          class="font-sans text-sm whitespace-pre-wrap break-words"
        >{@experiment.stop_feedback}</pre>
        <p :if={is_nil(@experiment.stop_feedback)} class="text-sm text-base-content/70">
          No feedback was recorded.
        </p>
      </section>

      <section
        :if={@experiment.approval_state == "pending"}
        data-role="pending-approval"
        class="bg-base-200 rounded-lg p-4 space-y-2 max-w-2xl"
      >
        <p class="text-sm font-semibold">Awaiting human approval</p>
        <p class="text-sm">
          Proposed by <span class="font-medium" data-role="proposed-by">{@proposer_name}</span>.
          It assigns no subjects until an admin approves the launch. Approval still has to pass
          the live limit and the one-experiment-per-surface rule.
        </p>
        <button
          :if={@root_admin?}
          type="button"
          phx-click="approve_launch"
          phx-value-slug={@experiment.slug}
          data-role="approve-launch-button"
          class="btn btn-sm btn-neutral"
        >
          Approve launch
        </button>
      </section>

      <div role="tablist" class="tabs tabs-bordered overflow-x-auto">
        <button
          :for={{tab, label} <- tabs()}
          role="tab"
          type="button"
          phx-click="select_tab"
          phx-value-tab={tab}
          data-role="experiment-tab"
          data-tab={tab}
          class={["tab", @tab == tab && "tab-active font-semibold"]}
        >
          {label}
        </button>
      </div>

      <section :if={@tab == "results"} class="space-y-2">
        <%!-- One row per arm: the state on the left, the figure and its n
              fused in the middle, the only irreversible action pinned
              right. An unearned row gets the flat base-300 ground and NO bar
              element; an earned row draws the success bar. --%>
        <div
          :for={row <- @result_rows}
          id={"result-#{row.variant_slug}"}
          data-role="result-row"
          data-earned={to_string(row.earned?)}
          class={[
            "rounded-lg p-4 flex flex-col gap-3 sm:flex-row sm:items-center",
            if(row.earned?, do: "bg-base-200", else: "bg-base-300")
          ]}
        >
          <div class="flex items-center gap-2 sm:w-48 shrink-0 min-w-0">
            {status_badge(%{status: @experiment.status})}
            <span class="text-sm font-medium break-all">{row.variant_slug}</span>
          </div>
          <div class="flex-1 min-w-0 space-y-2">
            <div :if={row.earned?} class="h-2 rounded bg-base-300 overflow-hidden">
              <div
                data-role="evidence-bar"
                class="h-2 rounded bg-success"
                style={"width: #{Map.get(@bar_widths, row.variant_slug, 0.0)}%"}
              >
              </div>
            </div>
            {result_cell(%{
              row: row,
              experiment: @experiment,
              reasons: Map.get(@exclusions, row.variant_slug, [])
            })}
          </div>
          <div
            :if={row.earned? and @root_admin? and @experiment.status != "draft"}
            class="shrink-0 sm:ml-auto"
          >
            <button
              type="button"
              phx-click="promote"
              phx-value-variant={row.variant_slug}
              data-role="promote-button"
              data-confirm={"Promote #{row.variant_slug}? It becomes the default for this surface."}
              class="btn btn-sm btn-primary"
            >
              Promote
            </button>
          </div>
        </div>

        <p :if={@result_rows == []} data-role="no-variants" class="text-sm text-neutral">
          No variants yet. Starting this experiment creates the control arm.
        </p>
      </section>

      <section :if={@tab == "design"} class="space-y-4">
        <dl class="grid gap-3 sm:grid-cols-2 text-sm">
          <div>
            <dt class="text-xs text-base-content/70">Surface</dt>
            <dd data-role="design-surface" class="font-mono break-all">
              {@experiment.surface_key || "dispatch.prompt (not bound yet)"}
            </dd>
          </div>
          <div>
            <dt class="text-xs text-base-content/70">Target</dt>
            <dd data-role="design-target" class="font-mono break-all">
              {@experiment.surface_target || @experiment.target_template_slug || "not bound yet"}
            </dd>
          </div>
          <div>
            <dt class="text-xs text-base-content/70">Org</dt>
            <dd data-role="design-org">
              {if @experiment.org_id, do: @org_name || "an org", else: "Install-wide"}
            </dd>
          </div>
          <div>
            <dt class="text-xs text-base-content/70">Project</dt>
            <dd data-role="design-project">
              {if @experiment.project_id,
                do: @project_name || "a project",
                else: "Every project in scope"}
            </dd>
          </div>
          <div>
            <dt class="text-xs text-base-content/70">Metric</dt>
            <dd data-role="design-metric">{metric_words(@experiment, @metric_catalog)}</dd>
          </div>
          <div>
            <dt class="text-xs text-base-content/70">Stop rule</dt>
            <dd data-role="design-stop-rule">{ExperimentResults.stop_rule_label(@experiment)}</dd>
          </div>
          <div>
            <dt class="text-xs text-base-content/70">Observation window</dt>
            <dd data-role="design-window">
              {if window_days(@experiment),
                do: "#{window_days(@experiment)} days",
                else: "none; every subject counts once measured"}
            </dd>
          </div>
          <div>
            <dt class="text-xs text-base-content/70">Signal source</dt>
            <dd data-role="design-signal-source" class="break-words">
              {signal_words(@experiment.signal_source)}
            </dd>
          </div>
          <div class="sm:col-span-2">
            <dt class="text-xs text-base-content/70">Assignment policy</dt>
            <dd>
              <pre
                data-role="design-policy"
                class="text-xs whitespace-pre-wrap break-all font-mono"
              >{policy_words(@experiment.assignment_policy)}</pre>
            </dd>
          </div>
        </dl>

        <%!-- Activation is the consequential step for a prompt experiment,
              and the consequence is stated BEFORE the button. --%>
        <section
          :if={
            is_nil(@experiment.target_template_slug) and is_nil(@experiment.surface_target) and
              @experiment.status == "draft" and @root_admin?
          }
          data-role="activate-panel"
          class="border border-edge rounded-lg p-4 space-y-3 max-w-2xl"
        >
          <h2 class="text-sm font-semibold">Activate this experiment</h2>

          <form phx-submit="activate" data-role="activate-form" class="space-y-3">
            <div class="flex flex-wrap items-center gap-2">
              <label class="text-xs text-neutral w-20" for="activate-template">Template</label>
              <select
                id="activate-template"
                name="template_slug"
                required
                data-role="activate-template"
                class="select select-sm select-bordered flex-1 min-w-0 max-w-sm font-mono"
              >
                <option value="" disabled selected>Choose a template</option>
                <option :for={tmpl <- @templates} value={tmpl.slug} data-role="template-option">
                  {tmpl.slug}
                </option>
              </select>
            </div>

            <p class="text-sm text-base-content max-w-xl" data-role="activate-consequence">
              This experiment will compare against a copy of the template taken when it was
              activated, not against that row. Editing the template afterwards changes what future
              dispatches render; it changes nothing this experiment has measured or will measure.
            </p>

            <button type="submit" data-role="activate-button" class="btn btn-sm btn-neutral">
              Activate
            </button>
          </form>
        </section>

        <form
          :if={
            @root_admin? and @experiment.status == "draft" and
              @experiment.surface_key not in [nil, "dispatch.prompt"]
          }
          phx-submit="add_variant"
          data-role="add-variant-form"
          class="border border-edge rounded-lg p-4 space-y-3 max-w-2xl"
        >
          <h2 class="text-sm font-semibold">Add a variant</h2>
          <div class="grid gap-3 sm:grid-cols-3">
            <div class="sm:col-span-2">
              <label class="text-xs text-base-content/70" for="variant-slug">Slug</label>
              <input
                id="variant-slug"
                name="slug"
                required
                class="input input-sm input-bordered w-full font-mono"
              />
            </div>
            <div>
              <label class="text-xs text-base-content/70" for="variant-weight">Weight</label>
              <input
                id="variant-weight"
                name="weight"
                type="number"
                min="1"
                value="1"
                class="input input-sm input-bordered w-full font-mono"
              />
            </div>
          </div>
          <div>
            <label class="text-xs text-base-content/70" for="variant-payload">Payload (JSON)</label>
            <textarea
              id="variant-payload"
              name="payload"
              rows="3"
              required
              class="textarea textarea-sm textarea-bordered w-full font-mono"
            >{"{}"}</textarea>
            <p class="text-xs text-base-content/70">
              Validated by the surface; its errors are shown as written.
            </p>
          </div>
          <div class="flex justify-end">
            <button type="submit" data-role="add-variant-submit" class="btn btn-sm btn-neutral">
              Add variant
            </button>
          </div>
        </form>

        <%!-- Draft only, and hiding it is an affordance: the refusal is in
              `Experiments.delete_experiment/1` and reaches a by-name event
              too. An activated experiment's assignments are its record. --%>
        <div :if={@experiment.status == "draft" and @root_admin?} class="pt-2">
          <button
            type="button"
            phx-click="delete_experiment"
            phx-value-slug={@experiment.slug}
            data-confirm="Delete this draft? It has measured nothing."
            data-role="delete-draft-button"
            class="btn btn-sm btn-outline btn-error"
          >
            <span class="hero-trash size-4" aria-hidden="true"></span> Delete draft
          </button>
          <p class="text-xs text-neutral mt-1">
            Only a draft can be deleted. Once started, an experiment's assignments are evidence
            and stay on this page.
          </p>
        </div>

        <%!-- The prompt editor is NOT reimplemented here. One editor over one
              `prompt_templates` row; two would drift. --%>
        <p :if={@experiment.target_template_slug} class="text-sm">
          <.link
            navigate={~p"/admin/prompts/#{@experiment.target_template_slug}"}
            class="link link-hover"
            data-role="design-editor-link"
          >
            Edit this prompt and its variants
            <span class="hero-arrow-right size-3" aria-hidden="true"></span>
          </.link>
        </p>

        <div class="space-y-2">
          <h2 class="text-sm font-semibold">Variants</h2>
          <div
            :for={variant <- @variants}
            id={"variant-#{variant.slug}"}
            class="bg-base-200 rounded-lg p-3 space-y-1"
          >
            <div class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium break-all">{variant.slug}</span>
              <span class="text-xs text-neutral">weight {variant.weight}</span>
            </div>
            <pre class="text-xs whitespace-pre-wrap break-all text-base-content/80 max-h-40 overflow-y-auto">{variant_body(@experiment, variant)}</pre>
          </div>
        </div>
      </section>

      <section :if={@tab == "assignments"} class="space-y-3">
        <%!-- An excluded subject stays on this page with its reason. There
              is no filter and no "hide excluded" control. --%>
        <p class="text-sm text-base-content">
          {length(@assignments)} assigned, {excluded_count(@assignments)} excluded. Excluded
          subjects leave both sides of every ratio and stay listed here with the reason.
        </p>

        <section class="bg-base-200 rounded-lg overflow-x-auto shrink-0">
          <table class="table table-sm w-full min-w-[20rem]">
            <thead>
              <tr class="text-xs text-neutral">
                <th>Subject</th>
                <th>Variant</th>
                <th>Counted</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={assignment <- @assignments}
                id={"assignment-#{assignment.id}"}
                data-role="assignment-row"
                data-excluded={to_string(assignment.excluded_reason != nil)}
              >
                <td class="text-xs font-mono">
                  {assignment.subject_type}/{short(assignment.subject_id)}
                </td>
                <td class="text-xs">{assignment.variant_slug}</td>
                <td class="text-xs">
                  <span :if={assignment.excluded_reason} data-role="exclusion-reason">
                    excluded — {assignment.excluded_reason}
                  </span>
                  <span :if={is_nil(assignment.excluded_reason)}>counted</span>
                </td>
              </tr>
            </tbody>
          </table>
        </section>

        <p :if={@assignments == []} data-role="no-assignments" class="text-sm text-neutral">
          No subjects assigned yet.
        </p>
      </section>

      <section :if={@tab == "promotions"} class="space-y-3">
        <p class="text-sm text-base-content max-w-2xl">
          Promoting an arm makes it this surface's default. It is done from the Results tab, on
          an arm that has earned a figure, and never inferred from one: a figure that cleared its
          stop rule is evidence for a decision, not the decision. Concluding is separate and
          does not promote anything.
        </p>

        <p :if={not @root_admin?} data-role="admin-only-note" class="text-sm text-neutral">
          Only root-org admins can start, stop, conclude or promote an experiment.
        </p>
      </section>
    </div>
    """
  end

  @doc """
  THE result cell: the figure and its `n` as ONE string in one mono run, or
  the honest absence and the same `n`. See the moduledoc.

  `reasons` is `[{excluded_reason, count}]` for this arm; when the arm has
  exclusions the `(k excluded)` count is the summary of a `<details>` that
  opens onto them.
  """
  attr :row, :map, required: true
  attr :experiment, :map, required: true
  attr :reasons, :list, default: []

  def result_cell(assigns) do
    ~H"""
    <div
      data-role="result-cell"
      data-state={if @row.earned?, do: "measured", else: "insufficient"}
      class="space-y-1"
    >
      <div data-role="result-figure" class="font-mono text-[15px] leading-6 text-base-content">
        <span class="whitespace-nowrap" data-role="result-fused">{fused(@row)}</span>
        <details :if={@row.excluded > 0} data-role="result-exclusions" class="inline">
          <summary class="inline cursor-pointer whitespace-nowrap list-none [&::-webkit-details-marker]:hidden">
            ({@row.excluded} excluded)<span
              class="hero-chevron-down size-3 align-middle"
              aria-hidden="true"
            ></span>
          </summary>
          <ul class="font-sans text-sm mt-1 space-y-0.5">
            <li :for={{reason, count} <- @reasons} data-role="exclusion-reason">
              {reason} <span class="font-mono">({count})</span>
            </li>
          </ul>
        </details>
      </div>

      <div data-role="result-basis" class="text-xs text-base-content/70 space-y-0.5">
        <div>
          {@row.subjects} subjects assigned · {ExperimentResults.stop_rule_label(@experiment)}
        </div>
        <div :if={@row.pending > 0} data-role="result-pending">
          {@row.pending} pending, still inside the observation window; not counted as
          non-responses
        </div>
        <div :if={ExperimentResults.confound(@row) != ""} data-role="result-confound">
          {ExperimentResults.confound(@row)}
        </div>
      </div>
    </div>
    """
  end

  # The fused string. The earned branch is the only place on this page a
  # figure is printed, and it is never printed without its n.
  defp fused(%{earned?: true, n: n} = row), do: "#{ExperimentResults.figure(row)} · n=#{n}"
  defp fused(%{n: n}), do: "not enough data · n=#{n}"

  @doc """
  Lifecycle chip. States differ in HUE — Running success, Stopped warning,
  Concluded info — and read in sentence case.
  """
  attr :status, :string, required: true

  def status_badge(assigns) do
    ~H"""
    <span
      data-role="status-badge"
      data-status={@status}
      class={["badge badge-sm font-medium", badge_class(@status)]}
    >
      {status_label(@status)}
    </span>
    """
  end

  defp badge_class("draft"), do: "badge-ghost"
  defp badge_class("running"), do: "badge-success"
  defp badge_class("stopped"), do: "badge-warning"
  defp badge_class("concluded"), do: "badge-info"
  defp badge_class(_), do: "badge-ghost"

  defp status_label(status) when is_binary(status), do: String.capitalize(status)
  defp status_label(_), do: "Unknown"

  attr :experiment, :map, required: true

  defp approval_badge(assigns) do
    ~H"""
    <span
      :if={@experiment.approval_state == "pending"}
      data-role="approval-badge"
      class="badge badge-sm badge-outline font-medium"
    >
      Awaiting human approval
    </span>
    """
  end

  defp tabs do
    [
      {"results", "Results"},
      {"design", "Design"},
      {"assignments", "Assignments"},
      {"promotions", "Promotions"}
    ]
  end

  defp excluded_count(assignments), do: Enum.count(assignments, &(&1.excluded_reason != nil))

  # The TAIL of the id, not the head: UUIDv7 heads are millisecond-timestamp
  # bits, constant across a burst of assignments (task 019fb949).
  defp short(nil), do: "—"

  defp short(id) do
    id = to_string(id)
    if String.length(id) > 12, do: "…" <> String.slice(id, -12, 12), else: id
  end
end
