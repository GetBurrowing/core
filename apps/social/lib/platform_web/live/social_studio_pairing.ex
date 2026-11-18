defmodule PlatformWeb.SocialStudioPairing do
  @moduledoc "Preview and explicitly import clip exports for one Studio profile."
  use PlatformWeb, :live_component

  alias Platform.Social.{Intake, Pairing}

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> reset()
     |> allow_upload(:studio_export, accept: ~w(.json), max_entries: 1, max_file_size: 1_000_000)}
  end

  @impl true
  def update(assigns, socket) do
    changed? = socket.assigns[:profile] && socket.assigns.profile.id != assigns.profile.id
    socket = if changed?, do: reset(socket), else: socket
    {:ok, assign(socket, Map.take(assigns, [:id, :profile, :user]))}
  end

  defp reset(socket) do
    socket
    |> assign(:export_text, "")
    |> assign(:export, nil)
    |> assign(:entries, [])
    |> assign(:results, [])
    |> assign(:issues, [])
    |> assign(:choices, %{})
    |> assign(:error, nil)
  end

  @impl true
  def handle_event("preview", %{"export_json" => text}, socket) when is_binary(text) do
    preview(socket, text)
  end

  def handle_event("validate_file", _params, socket), do: {:noreply, socket}

  def handle_event("preview_file", _params, socket) do
    case consume_uploaded_entries(socket, :studio_export, fn %{path: path}, _entry ->
           File.read(path)
         end) do
      [text] -> preview(socket, text)
      _ -> {:noreply, assign(socket, :error, "Choose a JSON export to preview.")}
    end
  end

  def handle_event("import", params, socket) do
    %{profile: profile, user: user, export: export} = socket.assigns

    choices =
      Map.get(params, "choices", %{}) |> Enum.reject(fn {_ref, id} -> id == "" end) |> Map.new()

    socket = assign(socket, :choices, choices)

    with %{} <- export,
         {:ok, built} <-
           Pairing.build_manifest(profile.org_id, profile.id, export, choices, user.id) do
      issues =
        Enum.map(built.unresolved, &"#{&1}: choose a matching video") ++
          Enum.map(built.invalid, fn {index, _} -> "Entry #{index + 1}: invalid reference" end) ++
          Enum.map(built.rejected, fn {ref, _} -> "#{ref}: selection is no longer available" end)

      socket = assign(socket, :issues, issues)

      case built.manifest["clips"] do
        [] ->
          {:noreply, assign(socket, :error, "Choose at least one matching video to import.")}

        _ ->
          case Intake.import_manifest(profile.org_id, profile.id, built.manifest, user.id) do
            {:ok, %{clips: results}} ->
              send(self(), :studio_clips_imported)
              {:noreply, socket |> assign(:results, results) |> assign(:error, nil)}

            _ ->
              send(self(), :studio_scope_recheck)

              {:noreply,
               socket
               |> reset()
               |> assign(:error, "No clips were imported. Check your selections and access.")}
          end
      end
    else
      {:error, :duplicate_external_ref} ->
        {:noreply,
         socket
         |> assign(:export, nil)
         |> assign(:entries, [])
         |> assign(:error, "The export has a repeated reference. Correct it before importing.")}

      _ ->
        send(self(), :studio_scope_recheck)

        {:noreply,
         socket
         |> reset()
         |> assign(:error, "No clips were imported. Check your selections and access.")}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp preview(socket, text) do
    socket = socket |> assign(:export_text, text) |> assign(:results, []) |> assign(:choices, %{})
    socket = assign(socket, :issues, [])
    %{profile: profile, user: user} = socket.assigns

    with true <- byte_size(text) <= 1_000_000,
         {:ok, export} <- Jason.decode(text),
         {:ok, %{entries: entries}} <-
           Pairing.propose(profile.org_id, profile.id, export, user.id) do
      {:noreply,
       socket |> assign(:export, export) |> assign(:entries, entries) |> assign(:error, nil)}
    else
      {:error, :duplicate_external_ref} ->
        {:noreply,
         socket
         |> assign(:export, nil)
         |> assign(:entries, [])
         |> assign(:error, "The export has a repeated reference. Correct it before importing.")}

      _ ->
        {:noreply,
         socket
         |> assign(:export, nil)
         |> assign(:entries, [])
         |> assign(:error, "The export could not be previewed. Check the file and your access.")}
    end
  end

  defp files({:one, file}), do: [file]
  defp files({:many, files}), do: files
  defp files(_), do: []

  defp label(:none), do: "No matching uploaded file"
  defp label({:invalid, _}), do: "Invalid entry"
  defp label({:many, _}), do: "Choose a video"
  defp label({:one, _}), do: "Select the matching video"

  defp result_label(:created), do: "Imported"
  defp result_label(:exists), do: "Already imported"
  defp result_label({:error, :file_changed}), do: "File changed; preview the export again"

  defp result_label({:error, :file_not_in_project}),
    do: "File is no longer available in this project"

  defp result_label({:error, :invalid_media_claim}), do: "Invalid media information in the export"

  defp result_label({:error, :external_ref_conflict}),
    do: "This reference was already imported with different details"

  defp result_label({:error, _}), do: "Could not import"

  @impl true
  def render(assigns) do
    ~H"""
    <section
      class="space-y-3 rounded-box border border-base-content/25 bg-base-100 p-4"
      data-role="studio-pairing"
    >
      <h2 class="text-lg font-semibold">Import clips</h2>
      <form
        id="studio-pair-file-form"
        phx-change="validate_file"
        phx-submit="preview_file"
        phx-target={@myself}
        class="space-y-2"
      >
        <label for={@uploads.studio_export.ref}>Choose an export file</label>
        <.live_file_input upload={@uploads.studio_export} class="file-input w-full" />
        <span :for={entry <- @uploads.studio_export.entries}>
          {entry.client_name} · {entry.progress}%
        </span>
        <button type="submit" class="btn btn-outline">Preview file</button>
      </form>
      <form id="studio-pair-preview" phx-submit="preview" phx-target={@myself} class="space-y-2">
        <label for="studio-pair-export">Export JSON</label>
        <textarea id="studio-pair-export" name="export_json" class="textarea w-full">{@export_text}</textarea>
        <button type="submit" class="btn btn-outline">Preview matches</button>
      </form>
      <form
        :if={@export}
        id="studio-pair-import"
        phx-submit="import"
        phx-target={@myself}
        class="space-y-2"
      >
        <div :for={entry <- @entries} data-role="studio-pair-entry">
          <p>{entry.external_ref || "Entry without a reference"} · {label(entry.match)}</p>
          <p :if={entry.shared_with != []}>Shared with {Enum.join(entry.shared_with, ", ")}</p>
          <select
            :if={files(entry.match) != []}
            name={"choices[#{entry.external_ref}]"}
            class="select"
          >
            <option value="">Choose a video</option>
            <option
              :for={file <- files(entry.match)}
              value={file.id}
              selected={@choices[entry.external_ref] == file.id}
            >
              {file.name} · {file.byte_size} bytes
            </option>
          </select>
        </div>
        <button type="submit" class="btn btn-primary">Import selected clips</button>
      </form>
      <p :for={result <- @results} data-role="studio-pair-result">
        {result.external_ref} · {result_label(result.status)}
      </p>
      <p :for={issue <- @issues} data-role="studio-pair-issue">{issue}</p>
      <p :if={@error} role="alert">{@error}</p>
    </section>
    """
  end
end
