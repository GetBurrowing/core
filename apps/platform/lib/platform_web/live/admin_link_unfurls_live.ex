defmodule PlatformWeb.AdminLinkUnfurlsLive do
  @moduledoc """
  `/admin/link-unfurls`: whether this install fetches link previews for
  outside links in chat (task 01a1a944 stage 4). Edits the
  `Platform.Chat.LinkUnfurls.Settings` singleton stage 3 added. Mirrors
  `PlatformWeb.AdminInsightsLive`.

  There is no per-org settings column, so the switch is install-wide.
  Turning it off stops new fetches; previews already stored still render,
  and an author can still remove one message's preview.

  ## Authorization, twice

  The route is in the `:admin` live_session (`LiveAuth :ensure_admin`), AND
  `Settings.update/2` re-checks `Platform.Access.authorize_install/1` on the
  actor threaded in from `@current_user_record`.
  """

  use PlatformWeb, :live_view

  alias Platform.Chat.LinkUnfurls.Settings

  @impl true
  def mount(_params, _session, socket) do
    settings = Settings.get()

    {:ok,
     socket
     |> assign(:page_title, "Link previews")
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
         |> put_flash(:info, "Link preview settings saved.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Only an install admin can change these settings.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         socket
         |> assign(:form, to_form(params, as: :settings))
         |> put_flash(:error, "Link preview settings were not saved.")}
    end
  end

  @doc false
  def form_params(%Settings{} = s), do: %{"enabled" => s.enabled}

  # Only the one switch is read from params; anything else is dropped.
  @doc false
  def to_attrs(params), do: %{"enabled" => params["enabled"]}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full min-h-0 flex-col">
      <.breadcrumb segments={[
        %{label: "Admin", navigate: ~p"/admin"},
        %{label: "Link previews", navigate: nil}
      ]} />
      <div class="flex items-center justify-between border-b border-edge px-4 py-3">
        <h1 class="text-sm font-semibold uppercase tracking-widest text-base-content">
          Admin · Link previews
        </h1>
      </div>

      <div class="flex-1 min-h-0 overflow-y-auto p-4 clears-tab-bar">
        <div class="mx-auto max-w-2xl space-y-4">
          <p class="text-sm text-subtle">
            When a message links to an outside page, this install fetches the page's title,
            image and description and shows them in a card. This setting applies to every org on
            this install.
          </p>

          <.form
            for={@form}
            id="admin-link-unfurls-form"
            phx-change="validate"
            phx-submit="save"
            class="divide-y divide-edge rounded-xl border border-edge bg-base-100"
          >
            <div class="flex items-center justify-between gap-4 p-4">
              <div class="min-w-0">
                <p class="text-sm font-medium text-base-content">Show link previews</p>
                <p class="text-xs text-subtle" data-role="link-unfurls-note">
                  Turning this off stops new previews. Previews already shown stay, and the
                  person who posted a link can still remove its preview.
                </p>
              </div>
              <.input
                field={@form[:enabled]}
                type="checkbox"
                class="toggle toggle-sm"
                aria-label="Show link previews"
                data-role="link-unfurls-enabled"
              />
            </div>

            <div class="flex justify-end p-4">
              <button type="submit" class="btn btn-neutral btn-sm" data-role="link-unfurls-save">
                Save
              </button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  # A stray message (a shell broadcast, a late reply) must not crash an
  # admin page.
  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}
end
