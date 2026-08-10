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
  alias PlatformWeb.ExperimentResults

  @tabs ~w(results design assignments promotions)
  @default_tab "results"

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Experiments")}
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

  def handle_event("create_experiment", params, socket) do
    admin_only(socket, fn ->
      attrs = %{
        "slug" => params["slug"],
        "name" => params["name"],
        "hypothesis" => params["hypothesis"],
        "primary_metric" => params["primary_metric"]
      }

      case Experiments.create_experiment(attrs) do
        {:ok, _experiment} ->
          {:noreply, socket |> put_flash(:info, "Experiment created.") |> load_index()}

        {:error, changeset} ->
          {:noreply, put_flash(socket, :error, error_message(changeset))}
      end
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
      </div>

      <p class="text-sm text-base-content max-w-2xl">
        Every experiment ever run, including the ones that made things worse. A result appears
        only once its arm has measured enough to have earned one — until then the cell says so
        and states how far it has got.
      </p>

      <p :if={@rows == []} data-role="empty-list" class="text-sm text-neutral">
        No experiments yet.
      </p>

      <%!-- shrink-0: this is a scroll container inside a flex-col page, whose
            min-height resolves to `auto` and therefore to 0. Without it the
            whole list renders and parks off-panel at narrow viewports —
            present in the DOM, invisible on the screen. --%>
      <section :if={@rows != []} class="bg-base-200 rounded-lg overflow-x-auto shrink-0">
        <table class="table table-sm w-full min-w-[44rem]">
          <thead>
            <tr class="text-xs text-neutral uppercase">
              <th>Experiment</th>
              <th>Status</th>
              <th>Metric</th>
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
              <td class="align-top text-xs">
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

  defp short(nil), do: "—"
  defp short(id), do: String.slice(to_string(id), 0, 8)
end
