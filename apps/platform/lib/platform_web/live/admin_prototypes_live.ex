defmodule PlatformWeb.AdminPrototypesLive do
  @moduledoc """
  `/admin/prototypes` — this install's prototype publishing switch and caps
  (ADR 0057 Decision 5; task 01a1316b-4e46 stage 2). Edits the
  `Platform.Prototypes.Settings` singleton stage 1 added: enabled, who may
  publish, max bundle size, max files, retention days.

  Install-wide, not per org: an org is a client, and per-install config never
  goes on the orgs table (same reasoning as `/admin/branding`).

  ## Authorization, twice

  The route is in the `:admin` live_session (`LiveAuth :ensure_admin`), AND
  `Settings.update/2` re-checks `Tenancy.root_admin?/1` on the actor threaded
  in from `@current_user_record`. Neither check is load-bearing alone.

  ## Units

  The table stores bytes; the form edits whole MiB, because nobody types a
  byte count. Retention left blank means keep every version forever (the
  latest version is never removed either way).
  """

  use PlatformWeb, :live_view

  alias Platform.Prototypes.Settings

  @mib 1024 * 1024

  @impl true
  def mount(_params, _session, socket) do
    settings = Settings.get()

    {:ok,
     socket
     |> assign(:page_title, "Prototypes")
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
         |> put_flash(:info, "Prototype settings saved.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Only an install admin can change these settings.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(params, as: :settings))
         |> put_flash(:error, "Not saved: " <> error_summary(changeset))}
    end
  end

  @doc false
  def form_params(%Settings{} = s) do
    %{
      "enabled" => s.enabled,
      "who_may_publish" => s.who_may_publish,
      "max_bundle_mb" => div(s.max_bundle_bytes, @mib),
      "max_files" => s.max_files,
      "retention_days" => s.retention_days
    }
  end

  @doc false
  def to_attrs(params) do
    %{
      "enabled" => params["enabled"],
      "who_may_publish" => params["who_may_publish"],
      "max_bundle_bytes" => mib_to_bytes(params["max_bundle_mb"]),
      "max_files" => params["max_files"],
      "retention_days" => blank_to_nil(params["retention_days"])
    }
  end

  defp mib_to_bytes(value) do
    case Integer.parse(to_string(value || "")) do
      {mb, ""} -> mb * @mib
      _ -> value
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp error_summary(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  defp policy_options do
    [
      {"Org members and agents", "members"},
      {"Org admins (and agents they own)", "admins"},
      {"Agents only", "agents_only"}
    ]
    |> Enum.filter(fn {_, v} -> v in Settings.publish_policies() end)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :policy_options, policy_options())

    ~H"""
    <div class="flex h-full min-h-0 flex-col">
      <.breadcrumb segments={[
        %{label: "Admin", navigate: ~p"/admin"},
        %{label: "Prototypes", navigate: nil}
      ]} />
      <div class="flex items-center justify-between border-b border-edge px-4 py-3">
        <h1 class="text-sm font-semibold uppercase tracking-widest text-base-content/60">
          Admin · Prototypes
        </h1>
      </div>

      <div class="flex-1 min-h-0 overflow-y-auto p-4">
        <div class="mx-auto max-w-2xl space-y-4">
          <p class="text-sm text-base-content/60">
            Prototypes are clickable HTML bundles that agents and people publish with
            <code class="font-mono text-xs">prototype_publish</code>
            or the New canvas form, served sealed (no network, no Burrow access) to members of
            the prototype's org. These settings apply to every org on this install.
          </p>

          <.form
            for={@form}
            id="admin-prototypes-form"
            phx-change="validate"
            phx-submit="save"
            class="divide-y divide-edge rounded-xl border border-edge bg-base-100"
          >
            <div class="flex items-center justify-between gap-4 p-4">
              <div class="min-w-0">
                <p class="text-sm font-medium text-base-content">Publishing</p>
                <p class="text-xs text-base-content/60">
                  Off by default. While off, every publish is refused and the New canvas form
                  hides the Prototype choice. Published versions keep serving.
                </p>
              </div>
              <.input
                field={@form[:enabled]}
                type="checkbox"
                class="toggle toggle-sm"
                aria-label="Prototype publishing enabled"
                data-role="prototypes-enabled"
              />
            </div>

            <div class="grid gap-2 p-4 sm:grid-cols-[1fr_16rem] sm:items-center sm:gap-4">
              <div class="min-w-0">
                <p class="text-sm font-medium text-base-content">Who may publish</p>
                <p class="text-xs text-base-content/60">Also governs rollback.</p>
              </div>
              <.input
                field={@form[:who_may_publish]}
                type="select"
                options={@policy_options}
                aria-label="Who may publish"
                data-role="prototypes-who-may-publish"
              />
            </div>

            <div class="grid gap-2 p-4 sm:grid-cols-[1fr_16rem] sm:items-center sm:gap-4">
              <div class="min-w-0">
                <p class="text-sm font-medium text-base-content">Max bundle size (MB)</p>
                <p class="text-xs text-base-content/60">Uncompressed total of every file.</p>
              </div>
              <.input
                field={@form[:max_bundle_mb]}
                type="number"
                min="1"
                step="1"
                aria-label="Max bundle size in MB"
                data-role="prototypes-max-bundle-mb"
              />
            </div>

            <div class="grid gap-2 p-4 sm:grid-cols-[1fr_16rem] sm:items-center sm:gap-4">
              <div class="min-w-0">
                <p class="text-sm font-medium text-base-content">Max files</p>
                <p class="text-xs text-base-content/60">Files in one bundle.</p>
              </div>
              <.input
                field={@form[:max_files]}
                type="number"
                min="1"
                step="1"
                aria-label="Max files"
                data-role="prototypes-max-files"
              />
            </div>

            <div class="grid gap-2 p-4 sm:grid-cols-[1fr_16rem] sm:items-center sm:gap-4">
              <div class="min-w-0">
                <p class="text-sm font-medium text-base-content">Retention (days)</p>
                <p class="text-xs text-base-content/60">
                  Older versions are removed after this many days. Blank keeps every version.
                  The latest version is never removed.
                </p>
              </div>
              <.input
                field={@form[:retention_days]}
                type="number"
                min="1"
                step="1"
                placeholder="Keep forever"
                aria-label="Retention in days"
                data-role="prototypes-retention-days"
              />
            </div>

            <div class="flex justify-end p-4">
              <button type="submit" class="btn btn-neutral btn-sm" data-role="prototypes-save">
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
