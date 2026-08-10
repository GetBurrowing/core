defmodule PlatformWeb.ExperimentsLive do
  @moduledoc """
  `/control/experiments` — what we tried, what it cost, and what we are still
  not entitled to claim. Task 019fe6ba, ADR-0048.

  One LiveView serves both the list (`:index`) and the detail (`:show`) with
  its four tabs; the tab is socket state, not a route, so switching tabs
  cannot lose the loaded experiment.

  ## The result cell is the only thing on this page that may print a figure

  `result_cell/1` renders a figure TOGETHER WITH its basis — subjects,
  measured count, stop rule, exclusions — from one template with one branch.
  There is no second path to a number: no bare `{row.value}` anywhere in this
  module, no tooltip carrying the basis, no footnote. Both branches of that
  one `if` emit the basis block; only one of them emits a figure.

  That is the whole design. A footnote can be dropped by someone tidying a
  cramped column and the number survives it, which is how the honesty rule
  quietly stops holding while every test still passes. Here the number cannot
  outlive its basis, because they are the same markup.

  `PlatformWeb.ExperimentResults` refuses to carry `value` at all on a row
  that has not cleared its stop rule, so the rule is enforced twice — once
  where the data is built and once where it is drawn — and neither layer
  trusts the other.

  ## What this page will not draw

  No lift against control, no projection, no "+8.9% projected". ADR-0048
  names that shape specifically: it is how noise reads as measurement. Each
  arm's figure stands alone with its own `n`.

  Results are drawn in body ink whatever they say. A regression is not
  coloured as a failure and a win is not coloured as a success — an outcome
  palette teaches the reader the verdict before they have read the sample
  size, and the regression is usually the most instructive row here.

  ## Lifecycle colour survives greyscale

  Status is carried by WEIGHT as well as hue — draft outline, running filled,
  stopped outline, concluded filled — so the four states stay distinguishable
  where hue does not reach. `stopped` and `concluded` are different terminal
  states and both persist in the list; nothing here filters either out.

  ## Reads are member-visible, writes are admin-only, checked server-side

  These routes sit in `live_session :authenticated`, so any member can read
  the page — that is deliberate, an experiment nobody can see is not evidence
  anyone can act on. Every write handler re-checks `@fabrikam_admin?` ITSELF
  before touching the context. Hiding a button is an affordance; a forged
  event from a non-admin client is refused by the handler, not by the
  template. Mirrors the pattern in `PlatformWeb.ChatLive`'s admin sidebar
  mode.
  """

  use PlatformWeb, :live_view

  alias Platform.Experiments
  alias Platform.Experiments.Assignments
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Metrics
  alias Platform.Orchestration.PromptTemplates
  alias PlatformWeb.ExperimentResults

  @tabs ~w(results design assignments promotions)
  @default_tab "results"

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
    "min_subjects" => to_string(@default_min_subjects)
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Experiments")
     |> assign(:show_create, false)
     |> assign(:create_form, @empty_create_form)
     |> assign(:metric_catalog, Metrics.catalog())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:experiment, nil)
    |> load_index()
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

    assign(socket, :rows, Enum.map(experiments, &{&1, ExperimentResults.headline_row(&1)}))
  end

  defp load_experiment(socket, experiment) do
    socket
    |> assign(:experiment, experiment)
    |> assign(:page_title, experiment.name)
    |> assign(:result_rows, ExperimentResults.rows(experiment))
    |> assign(:variants, Experiments.list_variants(experiment))
    |> assign(:assignments, Assignments.list_assignments(experiment))
    |> assign(:templates, PromptTemplates.list_templates())
  end

  @impl true
  def handle_event("select_tab", %{"tab" => tab}, socket) when tab in @tabs do
    {:noreply, assign(socket, :tab, tab)}
  end

  def handle_event("select_tab", _params, socket), do: {:noreply, socket}

  # ── WRITES. Every one re-checks `@fabrikam_admin?` server-side ──────────────
  #
  # The buttons below are hidden from non-admins, and that is an affordance
  # only. A member who fires `activate` by name over the socket — which
  # costs nothing and needs no button — reaches this code, so this code is
  # where the refusal has to live. Each handler returns an error flash and
  # touches no context function on the way out.

  def handle_event("show_create", _params, socket) do
    admin_only(socket, fn ->
      {:noreply, socket |> assign(:show_create, true) |> assign(:create_form, @empty_create_form)}
    end)
  end

  def handle_event("hide_create", _params, socket) do
    {:noreply, assign(socket, :show_create, false)}
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

  def handle_event("create_experiment", params, socket) do
    admin_only(socket, fn ->
      # `stop_rule` was DROPPED here before this stage: the field could be
      # rendered, submitted and silently vanish. The shape is exactly what
      # `ExperimentResults.min_subjects/1` reads — a string key over an
      # INTEGER value; the string "40" fails that guard and reads as no rule.
      case parse_min_subjects(params["min_subjects"]) do
        :error ->
          {:noreply,
           socket
           |> assign(:create_form, merge_create_form(socket, params))
           |> put_flash(:error, "Stop rule must be a whole number of subjects, greater than 0.")}

        {:ok, min_subjects} ->
          attrs = %{
            "slug" => params["slug"],
            "name" => params["name"],
            "hypothesis" => params["hypothesis"],
            "primary_metric" => params["primary_metric"],
            "stop_rule" => %{"min_subjects" => min_subjects}
          }

          case Experiments.create_experiment(attrs) do
            {:ok, _experiment} ->
              {:noreply,
               socket
               |> put_flash(:info, "Experiment created.")
               |> assign(:show_create, false)
               |> assign(:create_form, @empty_create_form)
               |> load_index()}

            {:error, changeset} ->
              {:noreply,
               socket
               |> assign(:create_form, merge_create_form(socket, params))
               |> put_flash(:error, error_message(changeset))}
          end
      end
    end)
  end

  # Drafts only. The refusal is the context's (`{:error, :not_draft}`); this
  # handler renders it. Once an experiment has been activated its
  # assignments ARE the evidence trail.
  def handle_event("delete_experiment", %{"slug" => slug}, socket) do
    admin_only(socket, fn ->
      case Experiments.get_experiment_by_slug(slug) do
        nil ->
          {:noreply, put_flash(socket, :error, "No experiment #{slug}.")}

        experiment ->
          case Experiments.delete_experiment(experiment) do
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

            {:error, changeset} ->
              {:noreply, put_flash(socket, :error, error_message(changeset))}
          end
      end
    end)
  end

  def handle_event("delete_experiment", _params, socket) do
    admin_only(socket, fn ->
      {:noreply, put_flash(socket, :error, "Name the experiment to delete.")}
    end)
  end

  def handle_event("activate", %{"template_slug" => template_slug}, socket) do
    admin_only(socket, fn ->
      case Experiments.activate(socket.assigns.experiment, template_slug) do
        {:ok, experiment} ->
          {:noreply,
           socket |> put_flash(:info, "Experiment running.") |> load_experiment(experiment)}

        {:error, changeset} ->
          {:noreply, put_flash(socket, :error, error_message(changeset))}
      end
    end)
  end

  def handle_event("activate", _params, socket) do
    admin_only(socket, fn ->
      {:noreply,
       put_flash(socket, :error, "Name the prompt template to snapshot as the control.")}
    end)
  end

  def handle_event("stop", _params, socket) do
    admin_only(socket, fn ->
      case Experiments.stop(socket.assigns.experiment) do
        {:ok, experiment} ->
          {:noreply,
           socket |> put_flash(:info, "Experiment stopped.") |> load_experiment(experiment)}

        {:error, changeset} ->
          {:noreply, put_flash(socket, :error, error_message(changeset))}
      end
    end)
  end

  # "Promote" concludes the experiment. It is a separate event name from
  # `stop` because the two write DIFFERENT terminal statuses and both stay on
  # the page — collapsing them onto one handler is the first step towards
  # collapsing them onto one status.
  def handle_event("promote", _params, socket) do
    admin_only(socket, fn ->
      case Experiments.conclude(socket.assigns.experiment) do
        {:ok, experiment} ->
          {:noreply,
           socket |> put_flash(:info, "Experiment concluded.") |> load_experiment(experiment)}

        {:error, changeset} ->
          {:noreply, put_flash(socket, :error, error_message(changeset))}
      end
    end)
  end

  # The gate. `fun` is not evaluated at all unless the acting user is a Fabrikam
  # admin, so a refused write cannot have run a context function first.
  defp admin_only(socket, fun) do
    if socket.assigns[:fabrikam_admin?] do
      fun.()
    else
      {:noreply, put_flash(socket, :error, "Only Fabrikam admins can change experiments.")}
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
      _ -> :error
    end
  end

  defp parse_min_subjects(n) when is_integer(n) and n > 0, do: {:ok, n}
  defp parse_min_subjects(_), do: :error

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

  defp error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

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
          :if={@fabrikam_admin? and not @show_create}
          type="button"
          phx-click="show_create"
          data-role="new-experiment-button"
          class="btn btn-sm btn-primary"
        >
          <span class="hero-plus size-4" aria-hidden="true"></span> New experiment
        </button>
      </div>

      <p class="text-sm text-base-content max-w-2xl">
        Every experiment ever run, including the ones that made things worse. A result appears
        only once its arm has measured enough to have earned one — until then the cell says so
        and states how far it has got.
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
          An experiment runs one variant of a prompt against production traffic and reports
          whether it helped — or says it does not know yet.
        </p>
        <button
          :if={@fabrikam_admin?}
          type="button"
          phx-click="show_create"
          data-role="empty-create-cta"
          class="btn btn-sm btn-outline btn-primary"
        >
          Create the first one
        </button>
      </section>

      <%!-- shrink-0: this is a scroll container inside a flex-col page, whose
            min-height resolves to `auto` and therefore to 0. Without it the
            whole list renders and parks off-panel at narrow viewports —
            present in the DOM, invisible on the screen. --%>
      <%!-- The METRIC column drops below `sm`, and only that one. At 390px all
            four columns need ~44rem, which pushes RESULT — the entire point of
            this page — off the right edge behind a horizontal scroll. The
            metric name is the least load-bearing of the four and is repeated
            on the detail page's Design tab; the result cell is the signature
            element and may not be the column you cannot see. --%>
      <section :if={@rows != []} class="bg-base-200 rounded-lg overflow-x-auto shrink-0">
        <table class="table table-sm w-full min-w-[22rem]">
          <thead>
            <tr class="text-xs text-neutral uppercase">
              <th>Experiment</th>
              <th>Status</th>
              <th class="hidden sm:table-cell">Metric</th>
              <th>Result</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{experiment, row} <- @rows} id={"experiment-row-#{experiment.slug}"}>
              <td class="align-top">
                <.link
                  navigate={~p"/control/experiments/#{experiment.slug}"}
                  class="link link-hover font-medium"
                >
                  {experiment.name}
                </.link>
                <div class="text-xs text-neutral">{experiment.slug}</div>
              </td>
              <td class="align-top">{status_badge(%{status: experiment.status})}</td>
              <td class="align-top text-xs hidden sm:table-cell">
                {experiment.primary_metric || "—"}
              </td>
              <td class="align-top">
                {result_cell(%{row: row, experiment: experiment})}
              </td>
            </tr>
          </tbody>
        </table>
      </section>
    </div>
    """
  end

  # The create form. Submitting it makes a DRAFT and nothing else — no
  # assignments, no snapshot, no traffic — because `create_experiment/1`
  # forces the status. Activation stays a separate, deliberate act.
  defp create_panel(assigns) do
    assigns =
      assign(
        assigns,
        :selected_metric,
        selected_metric(assigns.metric_catalog, assigns.create_form["primary_metric"])
      )

    ~H"""
    <section
      :if={@show_create and @fabrikam_admin?}
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
          <label class="text-xs font-semibold uppercase text-neutral" for="create-name">Name</label>
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
          <label class="text-xs font-semibold uppercase text-neutral" for="create-slug">Slug</label>
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
          <label class="text-xs font-semibold uppercase text-neutral" for="create-hypothesis">
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

        <div class="grid gap-4 sm:grid-cols-2">
          <div>
            <label class="text-xs font-semibold uppercase text-neutral" for="create-metric">
              Primary metric
            </label>
            <%!-- A PICKER, not free text. An unrecognised string resolves to
                  `:no_metric`, so a free-text box is a second way to create a
                  silently inert experiment. Options come from the context
                  registry, so a metric that exists here can be computed.

                  The option carries LABEL + SHORT DIRECTION only. The
                  description used to live here too, and a native `<option>`
                  neither wraps nor truncates: the text measured 708px inside a
                  302px control, and the popup sized itself to the content and
                  spilled outside the panel. The description is not dropped —
                  it moves below the control, where it is ordinary text that
                  wraps. --%>
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
              This list is every metric the platform can compute. To measure something else, add a
              metric module under the experiments metrics directory and register it.
            </p>
          </div>

          <div>
            <label class="text-xs font-semibold uppercase text-neutral" for="create-stop-rule">
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
          <button type="submit" data-role="create-submit" class="btn btn-sm btn-primary">
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
          ← All experiments
        </.link>
        <div class="flex flex-wrap items-center gap-3">
          <h1 class="text-xl font-bold">{@experiment.name}</h1>
          {status_badge(%{status: @experiment.status})}
        </div>
        <p :if={@experiment.hypothesis} class="text-sm text-base-content max-w-2xl">
          {@experiment.hypothesis}
        </p>
      </div>

      <div role="tablist" class="tabs tabs-bordered">
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

      <section :if={@tab == "results"} class="space-y-4">
        <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <div
            :for={row <- @result_rows}
            id={"result-#{row.variant_slug}"}
            class="bg-base-200 rounded-lg p-4 space-y-2"
          >
            <h2 class="text-sm font-semibold">{row.variant_slug}</h2>
            {result_cell(%{row: row, experiment: @experiment})}
          </div>
        </div>

        <p :if={@result_rows == []} data-role="no-variants" class="text-sm text-neutral">
          No variants yet. Activating this experiment snapshots the current prompt as the control.
        </p>
      </section>

      <section :if={@tab == "design"} class="space-y-4">
        <dl class="grid gap-3 sm:grid-cols-2 text-sm">
          <div>
            <dt class="text-xs text-neutral uppercase">Primary metric</dt>
            <dd data-role="design-metric">{@experiment.primary_metric || "none set"}</dd>
          </div>
          <div>
            <dt class="text-xs text-neutral uppercase">Stop rule</dt>
            <dd data-role="design-stop-rule">{ExperimentResults.stop_rule_label(@experiment)}</dd>
          </div>
          <div>
            <dt class="text-xs text-neutral uppercase">Target template</dt>
            <dd data-role="design-target">{@experiment.target_template_slug || "not bound yet"}</dd>
          </div>
        </dl>

        <%!-- Activation is the consequential step, and the consequence is
              stated BEFORE the button in the same words the other side of
              the snapshot already uses on `/admin/prompts/:slug`. --%>
        <section
          :if={
            is_nil(@experiment.target_template_slug) and @experiment.status == "draft" and
              @fabrikam_admin?
          }
          data-role="activate-panel"
          class="border border-primary/60 rounded-lg p-4 space-y-3 max-w-2xl"
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
                class="select select-sm select-bordered flex-1 max-w-sm font-mono"
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

            <button type="submit" data-role="activate-button" class="btn btn-sm btn-primary">
              Activate
            </button>
          </form>
        </section>

        <%!-- Draft only, and hiding it is an affordance: the refusal is in
              `Experiments.delete_experiment/1` and reaches a by-name event
              too. An activated experiment's assignments are its record. --%>
        <div :if={@experiment.status == "draft" and @fabrikam_admin?} class="pt-2">
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
            Only a draft can be deleted. Once activated, an experiment's assignments are evidence
            and stay on this page.
          </p>
        </div>

        <%!-- The editor is NOT reimplemented here. One editor over one
              `prompt_templates` row; two would drift, and the drift surfaces
              as "the experiment ran the wrong text". --%>
        <p :if={@experiment.target_template_slug} class="text-sm">
          <.link
            navigate={~p"/admin/prompts/#{@experiment.target_template_slug}"}
            class="link link-hover"
            data-role="design-editor-link"
          >
            Edit this prompt and its variants →
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
              <span class="text-sm font-medium">{variant.slug}</span>
              <span class="text-xs text-neutral">weight {variant.weight}</span>
            </div>
            <pre class="text-xs whitespace-pre-wrap text-base-content/80 max-h-40 overflow-y-auto">{variant.content}</pre>
          </div>
        </div>
      </section>

      <section :if={@tab == "assignments"} class="space-y-3">
        <%!-- Rule 4: an excluded subject stays on this page with its reason.
              There is no filter here and no "hide excluded" control — the
              exclusion is part of the record, and a denominator that shrank
              for reasons nobody can see is how a result quietly becomes
              wrong. --%>
        <p class="text-sm text-base-content">
          {length(@assignments)} assigned, {excluded_count(@assignments)} excluded. Excluded
          subjects leave both sides of every ratio and stay listed here with the reason.
        </p>

        <section class="bg-base-200 rounded-lg overflow-x-auto shrink-0">
          <table class="table table-sm w-full min-w-[36rem]">
            <thead>
              <tr class="text-xs text-neutral uppercase">
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
          Promoting an experiment concludes it. Nothing is promoted automatically and no
          promotion is inferred from a result — a figure that cleared its stop rule is evidence
          for a decision, not the decision.
        </p>

        <div :if={@fabrikam_admin?} class="flex flex-wrap gap-2">
          <button
            type="button"
            phx-click="stop"
            data-role="stop-button"
            class="btn btn-sm btn-outline btn-warning"
          >
            Stop
          </button>
          <button
            type="button"
            phx-click="promote"
            data-role="promote-button"
            class="btn btn-sm btn-primary"
          >
            Conclude
          </button>
        </div>

        <p :if={not @fabrikam_admin?} data-role="admin-only-note" class="text-sm text-neutral">
          Only Fabrikam admins can stop or conclude an experiment.
        </p>
      </section>
    </div>
    """
  end

  @doc """
  THE result cell. A figure and its basis, or the honest absence and the same
  basis — one component, one branch, no other path to a number on this page.

  The two branches are deliberately symmetrical in size and weight:
  `text-2xl font-semibold` either way, neutral rather than dimmed for the
  unearned state. If "no effect yet" rendered smaller and greyer than a real
  number, the page would reward the experiments that produced figures, and
  that bias is the thing this design exists to fight.

  Tabular numerals on the figure so digits line up between rows; the basis is
  body face, because it is prose.
  """
  attr :row, :map, required: true
  attr :experiment, :map, required: true

  def result_cell(assigns) do
    ~H"""
    <div
      data-role="result-cell"
      data-state={if @row.earned?, do: "measured", else: "insufficient"}
      class="space-y-1"
    >
      <%= if @row.earned? do %>
        <div data-role="result-figure" class="text-2xl font-semibold tabular-nums text-base-content">
          {ExperimentResults.figure(@row)}
        </div>
      <% else %>
        <div data-role="result-figure" class="text-2xl font-semibold text-neutral">
          no effect yet
        </div>
      <% end %>

      <%!-- The basis. Outside the branch above, so it renders in BOTH states
            and cannot be separated from the figure by any edit that keeps
            this component intact. --%>
      <div data-role="result-basis" class="text-xs text-neutral space-y-0.5">
        <div>
          {@row.subjects} subjects, {@row.n} measured; {ExperimentResults.stop_rule_label(@experiment)}
        </div>
        <div :if={@row.excluded > 0} data-role="result-exclusions">
          {@row.excluded} excluded, counted in neither side
        </div>
        <div :if={ExperimentResults.confound(@row) != ""} data-role="result-confound">
          {ExperimentResults.confound(@row)}
        </div>
        <div :if={@row.earned?} data-role="result-unit">
          {ExperimentResults.unit_label(@row.unit)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Lifecycle badge. Weight carries the state as much as hue does — outline
  versus filled — so the four statuses stay apart in greyscale, and
  `stopped` never reads as a dimmer `concluded`.
  """
  attr :status, :string, required: true

  def status_badge(assigns) do
    ~H"""
    <span
      data-role="status-badge"
      data-status={@status}
      class={["badge badge-sm", badge_class(@status)]}
    >
      {@status}
    </span>
    """
  end

  defp badge_class("draft"), do: "badge-outline"
  defp badge_class("running"), do: "badge-info"
  defp badge_class("stopped"), do: "badge-outline badge-warning font-semibold"
  defp badge_class("concluded"), do: "badge-neutral"
  defp badge_class(_), do: "badge-outline"

  defp tabs do
    [
      {"results", "Results"},
      {"design", "Design"},
      {"assignments", "Assignments"},
      {"promotions", "Promotions"}
    ]
  end

  defp excluded_count(assignments), do: Enum.count(assignments, &(&1.excluded_reason != nil))

  # The TAIL of the id, not the head.
  #
  # Subject ids are UUIDv7 and their leading hex digits are the high bits of a
  # millisecond timestamp — constant across a ~65-second bucket. Subjects are
  # assigned to an experiment in bursts, so a head-truncated id renders every
  # row in an arm as the same string, and the assignments table stops
  # distinguishing the subjects it exists to list. This repo has already been
  # bitten by exactly that truncation once, in the `task_slug` prompt sample
  # (task 019fb949); the tail is the random part.
  defp short(nil), do: "—"

  defp short(id) do
    id = to_string(id)
    if String.length(id) > 12, do: "…" <> String.slice(id, -12, 12), else: id
  end
end
