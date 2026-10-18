defmodule PlatformWeb.AdminInsightsLive do
  @moduledoc """
  `/admin/insights` — whether this install sends dreaming insights beyond
  the Org Memory Insights tab, and which kinds (task
  `01a13867-3213-7001-a128-6b4c6b34283f` stage 5). Edits the
  `Platform.Memory.Insights.Settings` singleton stage 3 added. Mirrors
  `PlatformWeb.AdminPrototypesLive`.

  The direction canvas (`01a14a73-9058-7000-8695-d0753117c384`) places
  this under "Settings > Org memory > Dissemination". Install settings live
  in the admin panel, the pattern
  `0057-prototypes-on-suite.md § 5. Standard-feature requirements` sets for
  `/admin/prototypes`, so it is here, and the Insights tab's off notice links
  here for an admin.

  ## The hard limits are stated in the settings

  The copy says, before the switch is flipped, that only high-confidence
  insights are sent and that mail outside the org, deletes and permission
  changes always wait for a person. "Apply page edits automatically" and
  "File backlog tasks" render disabled with "Not available yet": the
  changeset and a DB CHECK refuse them anyway.

  ## Authorization, twice

  The route is in the `:admin` live_session (`LiveAuth :ensure_admin`), AND
  `Settings.update/2` re-checks `Platform.Access.authorize_install/1` on the
  actor threaded in from `@current_user_record`.
  """

  use PlatformWeb, :live_view

  alias Platform.Memory.Insights.Settings

  @limits "Only high-confidence insights are sent. Mail outside the org, deletes and permission changes always wait for a person."

  @doc "The hard-limits sentence, verbatim."
  def limits, do: @limits

  @impl true
  def mount(_params, _session, socket) do
    settings = Settings.get()

    {:ok,
     socket
     |> assign(:page_title, "Insights")
     |> assign(:settings, settings)
     |> assign(:form, to_form(form_params(settings), as: :settings))}
  end

  @impl true
  def handle_event("validate", %{"settings" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :settings))}
  end

  def handle_event("save", %{"settings" => params}, socket) do
    case Settings.update(socket.assigns[:current_user_record], to_attrs(params)) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> assign(:settings, settings)
         |> assign(:form, to_form(form_params(settings), as: :settings))
         |> put_flash(:info, "Insight settings saved.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Only an install admin can change these settings.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         socket
         |> assign(:form, to_form(params, as: :settings))
         |> put_flash(
           :error,
           "Not saved: automatic page edits and backlog tasks are not available yet."
         )}
    end
  end

  @doc false
  def form_params(%Settings{} = s) do
    %{
      "dissemination_enabled" => s.dissemination_enabled,
      "deliver_briefings" => s.deliver_briefings,
      "deliver_questions" => s.deliver_questions
    }
  end

  # Only the three live switches are ever sent. The two deferred ones are
  # disabled inputs (a browser does not submit them) and are never read
  # from params, so a forged value cannot reach the changeset from here.
  @doc false
  def to_attrs(params) do
    %{
      "dissemination_enabled" => params["dissemination_enabled"],
      "deliver_briefings" => params["deliver_briefings"],
      "deliver_questions" => params["deliver_questions"]
    }
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :limits, @limits)

    ~H"""
    <div class="flex h-full min-h-0 flex-col">
      <.breadcrumb segments={[
        %{label: "Admin", navigate: ~p"/admin"},
        %{label: "Insights", navigate: nil}
      ]} />
      <div class="flex items-center justify-between border-b border-edge px-4 py-3">
        <h1 class="text-sm font-semibold uppercase tracking-widest text-base-content/60">
          Admin · Insights
        </h1>
      </div>

      <div class="flex-1 min-h-0 overflow-y-auto p-4">
        <div class="mx-auto max-w-2xl space-y-4">
          <p class="text-sm text-base-content/60">
            Dreaming writes insights to the Org Memory
            <.link navigate={~p"/memory/insights"} class="link link-hover">Insights tab</.link>
            every night. While sending is off they stay on that tab. These settings apply to
            every org on this install.
          </p>

          <.form
            for={@form}
            id="admin-insights-form"
            phx-change="validate"
            phx-submit="save"
            class="divide-y divide-edge rounded-xl border border-edge bg-base-100"
          >
            <div class="flex items-center justify-between gap-4 p-4">
              <div class="min-w-0">
                <p class="text-sm font-medium text-base-content">Send insights beyond this tab</p>
                <p class="text-xs text-base-content/60" data-role="insights-limits">{@limits}</p>
              </div>
              <.input
                field={@form[:dissemination_enabled]}
                type="checkbox"
                class="toggle toggle-sm"
                aria-label="Send insights beyond this tab"
                data-role="insights-dissemination-enabled"
              />
            </div>

            <div class="flex items-center justify-between gap-4 p-4 pl-8">
              <p class="text-sm text-base-content">Briefings to people</p>
              <.input
                field={@form[:deliver_briefings]}
                type="checkbox"
                class="checkbox checkbox-sm"
                aria-label="Briefings to people"
                data-role="insights-deliver-briefings"
              />
            </div>

            <div class="flex items-center justify-between gap-4 p-4 pl-8">
              <p class="text-sm text-base-content">Questions to addressees</p>
              <.input
                field={@form[:deliver_questions]}
                type="checkbox"
                class="checkbox checkbox-sm"
                aria-label="Questions to addressees"
                data-role="insights-deliver-questions"
              />
            </div>

            <div
              :for={
                {label, role} <- [
                  {"Apply page edits automatically", "insights-apply-page-edits"},
                  {"File backlog tasks", "insights-file-tasks"}
                ]
              }
              class="flex items-center justify-between gap-4 p-4 pl-8"
            >
              <div class="min-w-0">
                <p class="text-sm text-base-content/50">{label}</p>
                <p class="text-xs text-base-content/50">Not available yet</p>
              </div>
              <input
                type="checkbox"
                class="checkbox checkbox-sm"
                disabled
                aria-label={label}
                data-role={role}
              />
            </div>

            <div class="flex justify-end p-4">
              <button type="submit" class="btn btn-neutral btn-sm" data-role="insights-save">
                Save
              </button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end
end
