defmodule PlatformWeb.AdminGamesLive do
  use PlatformWeb, :live_view
  alias Platform.Games.Publishing
  @impl true
  def mount(_params, _session, socket) do
    if Platform.Tenancy.root_admin?(socket.assigns.current_user_record) do
      {:ok, socket |> assign(:page_title, "Games") |> assign(:publications, Publishing.list(socket.assigns.current_user_record)) |> assign(:form, to_form(%{"slug" => "voltron", "title" => "Voltron", "published" => "true"}, as: :game))}
    else
      {:ok, socket |> put_flash(:error, "Root admin access required") |> redirect(to: "/")}
    end
  end
  @impl true
  def handle_event("publish", %{"game" => attrs}, socket) do
    case Publishing.publish_release(socket.assigns.current_user_record, attrs) do
      {:ok, publication} ->
        {:noreply, socket |> assign(:publications, Publishing.list(socket.assigns.current_user_record)) |> assign(:form, to_form(attrs, as: :game)) |> put_flash(:info, "Saved. Game page: /games/#{publication.slug}")}
      {:error, _} ->
        {:noreply, socket |> assign(:form, to_form(attrs, as: :game)) |> put_flash(:error, "Could not publish. Check the org, ready ZIP attachment and version. Existing versions cannot change bytes.")}
    end
  end
  def handle_event("edit", %{"slug" => slug}, socket) do
    case Enum.find(Publishing.list(socket.assigns.current_user_record), &(&1.slug == slug)) do
      nil -> {:noreply, socket}
      publication ->
        manifest = publication.manifest
        release = Platform.Games.current_release(manifest)
        attrs = Map.merge(manifest, %{"version" => release["version"], "attachment_id" => release["attachment_id"], "published" => to_string(manifest["published"])})
        {:noreply, assign(socket, :form, to_form(attrs, as: :game))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="max-w-3xl mx-auto p-6 space-y-6">
        <h1 class="text-3xl font-bold">Publish a game</h1>
        <p>Upload the Windows ZIP in Burrow chat, then publish it here. The page, downloads, updates and a separate player chat become available together. No host configuration or restart.</p>
        <.form for={@form} id="game-publication-form" phx-submit="publish" class="space-y-4">
          <.input field={@form[:slug]} label="Game URL name" required />
          <.input field={@form[:title]} label="Title" required />
          <.input field={@form[:summary]} label="About the game" />
          <.input field={@form[:multiplayer_note]} label="Multiplayer instructions / current server status" />
          <.input field={@form[:org_id]} label="Game organisation ID" required />
          <.input field={@form[:version]} label="Release version" required />
          <.input field={@form[:attachment_id]} label="Uploaded Windows ZIP attachment ID" required />
          <.input field={@form[:published]} type="select" label="Visibility" options={[{"Published", "true"}, {"Unpublished", "false"}]} />
          <button id="publish-game" class="btn btn-primary" phx-disable-with="Saving…">Save release</button>
        </.form>
        <p class="text-sm">Publish a new version to update players. Reuse an older version and its original attachment to roll back. Downloads use the uploaded ZIP’s verified size and checksum. The ZIP must contain Play Voltron.bat at its root for this prototype.</p>
        <div id="published-games" class="space-y-3">
          <div :for={publication <- @publications} id={"publication-#{publication.slug}"} class="card bg-base-200 p-4">
            <.link href={"/games/#{publication.slug}"}>{publication.manifest["title"]}</.link>
            <button class="btn btn-sm" phx-click="edit" phx-value-slug={publication.slug}>Edit / release update</button>
            <p>{publication.manifest["current_version"]} · {if publication.manifest["published"], do: "Published", else: "Unpublished"}</p>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
