defmodule PlatformWeb.FilesLive do
  @moduledoc """
  Files surface — the user-facing UI for the project-scoped document
  store introduced by ADR 0042.

  ## Layout

    * LEFT — org-grouped project picker (sidebar; hidden on mobile).
      Reuses `Platform.Projects.group_by_active_org/2` so the Files and
      Tasks sidebars stay in lock-step: every active org keeps its header
      even at zero projects (archiving an org's last project can't erase
      it). Header order, scope colours, and "Unassigned" bucket all share
      the Tasks-sidebar treatment.
    * CENTER — file list for the selected project. Sortable columns
      (date / name / size / type), client-side substring filter, and a
      semantic-search box that hits `Platform.Memory.search/2` with
      `memory_type: "document"` + `project_id`.
    * RIGHT — file-detail pane (desktop) / full-screen drawer (mobile).
      Renders images inline (`<img>`), PDFs in an `<iframe>`, markdown
      through the chat content renderer, plain/CSV/JSON in a `<pre>`,
      DOCX-class documents in a prose `<div>` rendered from the
      cached extracted text, and any unsupported type as a download
      link. Every mode always exposes a "Download" button + a
      "Copy link" action at the top of the pane.

  ## Drag-drop + mobile FAB

  The CENTER region carries the namespaced `data-role="file-dropzone"`
  marker so end-to-end tests and any future drag-drop hook can find it
  without colliding with the chat-attachment dropzone. The mobile FAB
  (`data-role="file-upload-fab"`) sits at the canonical position used
  by the Tasks "+" button — same `bottom-[calc(...)]` math so it clears
  the safe-area inset and the bottom-nav height on every device.

  ## PubSub

  `mount/3` subscribes to `Platform.Files.project_topic/1` for the
  selected project. `Platform.Files.Ingester` broadcasts
  `{:file_ingested, file_id}` (and `{:file_ingest_failed, …}`) when a
  run resolves; the LV re-fetches the row and updates the stream so
  the "Ingesting…" pill flips to "Ready" without a refresh. The
  `file_delete` MCP tool (ADR-0042 Stage 4) emits
  `{:file_deleted, file_id}` on the same topic; the LV drops the row
  from local state and clears the detail pane if it was selected.

  ## Out of scope

  Chat-attachment → Files promotion is a separate stack — this surface
  is the standalone document store only.
  """

  use PlatformWeb, :live_view

  alias Platform.Chat.ContentRenderer
  alias Platform.Files
  alias Platform.Files.Storage
  alias Platform.Memory
  alias Platform.Projects
  alias Platform.Tasks
  alias Platform.Tenancy

  @max_upload_size 50_000_000
  @max_upload_entries 10

  # ── Mount / handle_params ────────────────────────────────────────────────

  @impl true
  def mount(_params, session, socket) do
    projects = Tasks.list_projects(preload: :org)
    current_user_id = session["current_user_id"]

    {:ok,
     socket
     |> assign(:page_title, "Files")
     |> assign(:current_path, "/files")
     |> assign(:current_user_id, current_user_id)
     |> assign(:projects, projects)
     # Navigation source: every active org keeps a section (and count) even at
     # zero projects, so archiving an org's last project can't erase its header
     # — matches the Tasks sidebar and Chat. Files has no <select> consuming
     # this grouping, so there's no project-derived variant to keep alongside.
     |> assign(
       :project_sections,
       Projects.group_by_active_org(projects, Tenancy.list_active_tenants())
     )
     |> assign(:selected_project_id, nil)
     |> assign(:selected_project, nil)
     |> assign(:files, [])
     |> assign(:selected_file, nil)
     |> assign(:selected_file_text, nil)
     |> assign(:filter, "")
     |> assign(:sort, "date_desc")
     |> assign(:semantic_query, "")
     |> assign(:semantic_results, [])
     |> assign(:semantic_search_state, :idle)
     |> assign(:show_upload_sheet, false)
     |> assign(:subscribed_project_id, nil)
     |> assign(:upload_batch, empty_upload_batch())
     |> allow_upload(:files,
       accept: :any,
       auto_upload: true,
       max_entries: @max_upload_entries,
       max_file_size: @max_upload_size,
       progress: &handle_file_upload_progress/3
     )}
  end

  @impl true
  def handle_params(%{"project_id" => project_id}, _url, socket) do
    {:noreply, load_project(socket, project_id)}
  end

  def handle_params(_params, _url, socket) do
    # Index view — no selection. Drop any prior subscription so we don't
    # keep getting PubSub events for a project the user moved away from.
    {:noreply,
     socket
     |> maybe_unsubscribe()
     |> assign(:selected_project_id, nil)
     |> assign(:selected_project, nil)
     |> assign(:files, [])
     |> assign(:selected_file, nil)
     |> assign(:selected_file_text, nil)
     |> assign(:semantic_results, [])
     |> assign(:semantic_search_state, :idle)
     |> assign(:filter, "")}
  end

  # ── Events ──────────────────────────────────────────────────────────────

  @impl true
  def handle_event("select_project", %{"id" => project_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/files/#{project_id}")}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/files")}
  end

  def handle_event("filter", %{"value" => value}, socket) do
    {:noreply, assign(socket, :filter, value)}
  end

  def handle_event("filter", %{"filter" => value}, socket) do
    {:noreply, assign(socket, :filter, value)}
  end

  def handle_event("sort", %{"sort" => sort}, socket) when is_binary(sort) do
    {:noreply, assign(socket, :sort, sort)}
  end

  def handle_event("select_file", %{"id" => file_id}, socket) do
    case Enum.find(socket.assigns.files, &(&1.id == file_id)) do
      nil ->
        {:noreply, socket}

      file ->
        {:noreply,
         socket
         |> assign(:selected_file, file)
         |> assign(:selected_file_text, load_text_excerpt(file))}
    end
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_file, nil)
     |> assign(:selected_file_text, nil)}
  end

  def handle_event("toggle_upload_sheet", _params, socket) do
    {:noreply, assign(socket, :show_upload_sheet, !socket.assigns.show_upload_sheet)}
  end

  def handle_event("close_upload_sheet", _params, socket) do
    {:noreply, assign(socket, :show_upload_sheet, false)}
  end

  def handle_event("semantic_search", %{"query" => query}, socket) do
    trimmed = String.trim(query || "")

    cond do
      trimmed == "" ->
        {:noreply,
         socket
         |> assign(:semantic_query, "")
         |> assign(:semantic_results, [])
         |> assign(:semantic_search_state, :idle)}

      socket.assigns.selected_project_id == nil ->
        {:noreply,
         socket
         |> assign(:semantic_query, trimmed)
         |> put_flash(:error, "Pick a project before running semantic search.")}

      true ->
        {:noreply, run_semantic_search(socket, trimmed)}
    end
  end

  def handle_event("clear_semantic", _params, socket) do
    {:noreply,
     socket
     |> assign(:semantic_query, "")
     |> assign(:semantic_results, [])
     |> assign(:semantic_search_state, :idle)}
  end

  def handle_event("select_semantic_hit", %{"id" => file_id}, socket) do
    case Files.get_file(file_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "File no longer exists.")}

      file ->
        snippet = Enum.find_value(socket.assigns.semantic_results, &snippet_for(&1, file_id))

        {:noreply,
         socket
         |> assign(:selected_file, file)
         |> assign(:selected_file_text, load_text_excerpt(file))
         |> assign(:highlight_snippet, snippet)}
    end
  end

  # A fresh file selection (phx-change fires when the user picks or drops
  # files) begins a new upload session — reset the running batch counter so
  # the success flash reflects THIS selection, not the cumulative tally
  # across sessions in the same mounted LV.
  def handle_event("validate_upload", _params, socket) do
    {:noreply, assign(socket, :upload_batch, empty_upload_batch())}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :files, ref)}
  end

  # ── PubSub ──────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:file_ingested, file_id}, socket) do
    {:noreply, refresh_file(socket, file_id)}
  end

  def handle_info({:file_ingest_failed, file_id, _reason}, socket) do
    {:noreply, refresh_file(socket, file_id)}
  end

  def handle_info({:file_deleted, file_id}, socket) do
    files = Enum.reject(socket.assigns.files, &(&1.id == file_id))

    selected_drop? =
      case socket.assigns.selected_file do
        %Files.File{id: ^file_id} -> true
        _ -> false
      end

    socket =
      if selected_drop? do
        socket
        |> assign(:selected_file, nil)
        |> assign(:selected_file_text, nil)
        |> assign(:highlight_snippet, nil)
      else
        socket
      end

    {:noreply, assign(socket, :files, files)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # ── Upload progress ─────────────────────────────────────────────────────

  # The LiveView upload pipeline streams chunks into a temp file before
  # `:done?` flips true. We consume each entry exactly once — copying it
  # to the platform_files object store, inserting the row, and kicking
  # off the async ingest. If the same bytes were already ingested in
  # this project we fast-path to the existing row instead of creating a
  # duplicate (the content_hash + project_id unique index would reject
  # it anyway; resolving here gives a friendlier UX).
  defp handle_file_upload_progress(:files, entry, socket) do
    if entry.done? do
      {:noreply, consume_one_upload(socket, entry)}
    else
      {:noreply, socket}
    end
  end

  # The progress callback fires per-entry as each upload flips
  # `done?`, so we drain that specific entry with
  # `consume_uploaded_entry/3` (singular). The plural
  # `consume_uploaded_entries/3` raises if ANY entry in the batch is
  # still in progress, which breaks per-entry drain — see
  # Phoenix.LiveView.Upload.consume_uploaded_entries/3 upstream. The
  # singular form takes the specific entry explicitly, so closing over
  # `entry` here is the correct per-file scope (not the metadata-bleed
  # bug Stage 1 called out — that bug only exists if you use the
  # plural form + ignore the callback's inner entry arg).
  defp consume_one_upload(socket, entry) do
    project_id = socket.assigns.selected_project_id

    if is_nil(project_id) do
      put_flash(socket, :error, "Pick a project before uploading.")
    else
      org_id =
        case socket.assigns.selected_project do
          %{org_id: oid} -> oid
          _ -> nil
        end

      uploaded_by = socket.assigns[:current_user_id]

      # `consume_uploaded_entry/3` unwraps the callback's `{:ok, term}`
      # and returns just `term`. We keep the outer `{:ok, _}` wrapper
      # so the callback conforms to the LV contract, then pattern-
      # match on the inner tuple shape below.
      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, handle_one_consumed(path, entry, project_id, org_id, uploaded_by)}
        end)

      # Successful results are `{:created, file}` (freshly written) or
      # `{:dedup, file}` (identical bytes already ingested in this
      # project). Only `{:error, _}` counts as a failure. Anything else
      # is treated as an error too, defensively. We accumulate results
      # across the callbacks that fire for this batch so the flash + list
      # refresh reflect the CUMULATIVE outcome ("3 files uploaded" after
      # the third callback in a bulk selection) instead of a per-file
      # ping-pong. The batch resets whenever `validate_upload` fires
      # (new selection).
      socket = accumulate_upload_result(socket, result)
      batch = socket.assigns.upload_batch
      successes = batch.created ++ batch.dedup

      socket
      |> maybe_flash_success(batch)
      |> maybe_flash_errors_from_batch(batch)
      |> maybe_refresh_after_upload(successes, project_id)
    end
  end

  # Returns a bare tuple — `{:created, file}` / `{:dedup, file}` /
  # `{:error, reason}` — that the caller wraps in the LV-mandated
  # `{:ok, term}` envelope. See `consume_one_upload/1` for the wrap +
  # subsequent split_with contract.
  defp handle_one_consumed(path, entry, project_id, org_id, uploaded_by) do
    filename = entry.client_name || "upload"
    content_type = entry.client_type || "application/octet-stream"

    with {:ok, sibling} <- maybe_find_sibling(path, project_id),
         {:resolved, attrs} <-
           resolve_create_attrs(
             sibling,
             path,
             filename,
             content_type,
             project_id,
             org_id,
             uploaded_by
           ) do
      case attrs do
        {:dedup, file} ->
          # Already ingested in this project — return the existing row.
          {:dedup, file}

        {:new, create_attrs} ->
          case Files.create_file(create_attrs) do
            {:ok, file} ->
              Files.Ingester.ingest_async(file)
              {:created, file}

            {:error, changeset} ->
              {:error, changeset}
          end
      end
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  # Compute the sha256 first so we can short-circuit dedup before we
  # round-trip bytes through the storage adapter (cheaper on every
  # repeat upload). Caller passes the LV's temp path.
  defp maybe_find_sibling(path, project_id) do
    case hash_path(path) do
      {:ok, hash} ->
        {:ok, Files.find_ingested_sibling(project_id, hash)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_create_attrs(nil, path, filename, content_type, project_id, org_id, uploaded_by) do
    case Storage.put({:path, path}, project_id, filename: filename) do
      {:ok, %{storage_key: key, content_hash: hash, byte_size: size}} ->
        {:resolved,
         {:new,
          %{
            project_id: project_id,
            org_id: org_id,
            uploaded_by_user_id: uploaded_by,
            name: filename,
            original_filename: filename,
            content_type: content_type,
            byte_size: size,
            storage_key: key,
            content_hash: hash
          }}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_create_attrs(%Files.File{} = sibling, _path, _f, _ct, _pid, _oid, _uid) do
    {:resolved, {:dedup, sibling}}
  end

  defp hash_path(path) do
    try do
      hash =
        path
        |> File.stream!([], 64 * 1024)
        |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)

      {:ok, hash}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  # Per-callback accumulator. Because the LV upload pipeline drives one
  # progress callback per completed entry, we stash results in a running
  # bucket on the socket so downstream flash + list-refresh code can see
  # the WHOLE batch's outcome, not just this file. `validate_upload`
  # clears the bucket at the start of every new selection.
  defp accumulate_upload_result(socket, result) do
    batch = socket.assigns[:upload_batch] || empty_upload_batch()

    updated =
      case result do
        {:created, file} -> %{batch | created: [file | batch.created]}
        {:dedup, file} -> %{batch | dedup: [file | batch.dedup]}
        {:error, reason} -> %{batch | errors: [reason | batch.errors]}
        other -> %{batch | errors: [other | batch.errors]}
      end

    assign(socket, :upload_batch, updated)
  end

  defp maybe_flash_success(socket, %{created: [], dedup: []}), do: socket

  defp maybe_flash_success(socket, batch) do
    put_flash(socket, :info, success_message(batch))
  end

  defp maybe_flash_errors_from_batch(socket, %{errors: []}), do: socket

  defp maybe_flash_errors_from_batch(socket, %{errors: errors}) do
    msg = "#{length(errors)} file(s) failed to upload. See logs for details."
    put_flash(socket, :error, msg)
  end

  # Positive-feedback copy: says "N files uploaded" plainly when everything
  # is a fresh write, and calls out dedups parenthetically when identical
  # bytes already existed in the project (Stage 1 pinned dedup as a
  # first-class success outcome). All-dedup batches get their own phrasing
  # so users understand nothing new landed but nothing failed either.
  defp success_message(%{created: created, dedup: dedup}) do
    new_count = length(created)
    dup_count = length(dedup)
    total = new_count + dup_count

    base =
      case total do
        1 -> "1 file uploaded"
        n -> "#{n} files uploaded"
      end

    cond do
      new_count == 0 and dup_count == 1 -> "1 file already ingested"
      new_count == 0 and dup_count > 1 -> "#{dup_count} files already ingested"
      dup_count > 0 -> "#{base} (#{dup_count} already ingested)"
      true -> base
    end
  end

  defp maybe_refresh_after_upload(socket, [], _project_id), do: socket

  defp maybe_refresh_after_upload(socket, _oks, project_id) do
    socket
    |> assign(:files, list_files(project_id))
    |> assign(:show_upload_sheet, false)
  end

  defp empty_upload_batch, do: %{created: [], dedup: [], errors: []}

  # ── Internals ───────────────────────────────────────────────────────────

  defp load_project(socket, project_id) do
    # An archived project is treated exactly like a missing one (task
    # 019f4eaa): it's gone from the sidebar, so it must not stay reachable as
    # a live file list via a restored selection or a deep link.
    project = Tasks.get_project(project_id)

    if is_nil(project) or Platform.Projects.archived?(project) do
      socket
      |> put_flash(:error, "Project not found.")
      |> push_patch(to: ~p"/files")
    else
      # Preload :org so the breadcrumb can render the scope label/color.
      # `Tasks.get_project/1` doesn't preload by default — the sidebar
      # already calls `list_projects(preload: :org)` for the same reason.
      project = Platform.Repo.preload(project, :org)

      socket
      |> maybe_unsubscribe()
      |> subscribe(project_id)
      |> assign(:selected_project_id, project_id)
      |> assign(:selected_project, project)
      |> assign(:files, list_files(project_id))
      |> assign(:selected_file, nil)
      |> assign(:selected_file_text, nil)
      |> assign(:semantic_results, [])
      |> assign(:semantic_search_state, :idle)
      |> assign(:filter, "")
    end
  end

  defp subscribe(socket, project_id) do
    if connected?(socket) do
      :ok = Files.subscribe_project(project_id)
    end

    assign(socket, :subscribed_project_id, project_id)
  end

  defp maybe_unsubscribe(%{assigns: %{subscribed_project_id: nil}} = socket), do: socket

  defp maybe_unsubscribe(%{assigns: %{subscribed_project_id: project_id}} = socket) do
    Phoenix.PubSub.unsubscribe(Platform.PubSub, Files.project_topic(project_id))
    assign(socket, :subscribed_project_id, nil)
  end

  defp list_files(project_id), do: Files.list_files_for_project(project_id, limit: 200)

  defp refresh_file(%{assigns: %{selected_project_id: nil}} = socket, _file_id), do: socket

  defp refresh_file(socket, file_id) do
    case Files.get_file(file_id) do
      nil ->
        # Row vanished — drop it from the list.
        assign(socket, :files, Enum.reject(socket.assigns.files, &(&1.id == file_id)))

      file ->
        files = Enum.map(socket.assigns.files, fn f -> if f.id == file_id, do: file, else: f end)

        files =
          if Enum.any?(files, &(&1.id == file_id)), do: files, else: [file | files]

        selected =
          case socket.assigns.selected_file do
            %{id: ^file_id} -> file
            other -> other
          end

        assign(socket, files: files, selected_file: selected)
    end
  end

  defp run_semantic_search(socket, query) do
    project_id = socket.assigns.selected_project_id

    opts = [project_id: project_id, memory_type: "document", limit: 10]

    case Memory.search(query, opts) do
      {:ok, results} ->
        socket
        |> assign(:semantic_query, query)
        |> assign(:semantic_results, results)
        |> assign(:semantic_search_state, if(results == [], do: :empty, else: :ok))

      {:error, reason} ->
        socket
        |> assign(:semantic_query, query)
        |> assign(:semantic_results, [])
        |> assign(:semantic_search_state, :error)
        |> put_flash(:error, "Semantic search failed: #{inspect(reason)}")
    end
  end

  defp snippet_for(%{id: id} = result, file_id) when id == file_id,
    do: Map.get(result, :content) || Map.get(result, "content")

  defp snippet_for(%{entry_id: id} = result, file_id) when id == file_id,
    do: Map.get(result, :content) || Map.get(result, "content")

  defp snippet_for(_result, _file_id), do: nil

  # Detail-pane text loader — returns the FULL extracted text so the
  # viewer can render the document in-app (Rowan's stage-5 revision
  # feedback: "we need a way to view the file in app as well"). For
  # very large extractions we still cap at a generous ceiling so the
  # LV diff doesn't blow past the websocket frame size; in practice
  # 200 KB is plenty for any DOCX / extracted-PDF body Suite ingests.
  defp load_text_excerpt(%Files.File{} = file) do
    case Files.fetch_extracted_text(file.id) do
      nil -> nil
      %{text: text} -> cap_text(text, 200_000)
    end
  end

  defp cap_text(text, max) when is_binary(text) do
    if String.length(text) <= max do
      text
    else
      String.slice(text, 0, max) <> "\n\n…(truncated — download the file for the full content)"
    end
  end

  # ── Template helpers exposed via assigns ───────────────────────────────

  @doc false
  def filtered_and_sorted(files, filter, sort) do
    files
    |> apply_filter(filter)
    |> apply_sort(sort)
  end

  defp apply_filter(files, nil), do: files
  defp apply_filter(files, ""), do: files

  defp apply_filter(files, query) when is_binary(query) do
    needle = String.downcase(query)

    Enum.filter(files, fn file ->
      String.contains?(String.downcase(file.name || ""), needle) or
        String.contains?(String.downcase(file.original_filename || ""), needle) or
        String.contains?(String.downcase(file.content_type || ""), needle)
    end)
  end

  defp apply_sort(files, "date_desc"),
    do: Enum.sort_by(files, & &1.inserted_at, {:desc, DateTime})

  defp apply_sort(files, "date_asc"),
    do: Enum.sort_by(files, & &1.inserted_at, {:asc, DateTime})

  defp apply_sort(files, "name_asc"),
    do: Enum.sort_by(files, &String.downcase(&1.name || &1.original_filename || ""))

  defp apply_sort(files, "name_desc"),
    do: Enum.sort_by(files, &String.downcase(&1.name || &1.original_filename || ""), :desc)

  defp apply_sort(files, "size_desc"), do: Enum.sort_by(files, & &1.byte_size, :desc)
  defp apply_sort(files, "size_asc"), do: Enum.sort_by(files, & &1.byte_size, :asc)
  defp apply_sort(files, "type_asc"), do: Enum.sort_by(files, & &1.content_type)
  defp apply_sort(files, _), do: apply_sort(files, "date_desc")

  @doc false
  def status_badge_class("ingested"), do: "badge badge-success badge-sm"
  def status_badge_class("failed"), do: "badge badge-error badge-sm"
  def status_badge_class(_), do: "badge badge-warning badge-sm"

  @doc false
  def status_label("ingested"), do: "Ready"
  def status_label("failed"), do: "Failed"
  def status_label(_), do: "Ingesting…"

  @doc false
  def humanize_bytes(nil), do: "—"
  def humanize_bytes(0), do: "0 B"

  def humanize_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_000_000_000 -> format_unit(bytes / 1_000_000_000, "GB")
      bytes >= 1_000_000 -> format_unit(bytes / 1_000_000, "MB")
      bytes >= 1_000 -> format_unit(bytes / 1_000, "KB")
      true -> "#{bytes} B"
    end
  end

  defp format_unit(value, unit), do: :erlang.float_to_binary(value, decimals: 1) <> " " <> unit

  @doc false
  def file_attachment_url(%Files.File{id: id}), do: "/files/blob/#{id}"

  @doc """
  URL that forces a `Content-Disposition: attachment` (browser download)
  instead of inline preview. Wired to the FileBlobController's
  `?download=1` query param.
  """
  def file_download_url(%Files.File{id: id}), do: "/files/blob/#{id}?download=1"

  @doc false
  def is_image?(%Files.File{content_type: ct}) when is_binary(ct),
    do: String.starts_with?(ct, "image/")

  def is_image?(_), do: false

  @doc false
  def is_pdf?(%Files.File{content_type: "application/pdf"}), do: true
  def is_pdf?(_), do: false

  @doc """
  Classifies a file into one of the detail-pane render modes:

    * `:image`    — render an inline `<img>` (image/*).
    * `:pdf`      — embed in an `<iframe>` (application/pdf).
    * `:markdown` — render extracted text through the chat markdown
                    pipeline (text/markdown).
    * `:text`     — render extracted text in a `<pre>` block
                    (text/plain, text/csv, application/json, etc.).
    * `:document` — extracted text in a prose-styled `<div>` for
                    DOCX / GDoc / anything else with extracted text but
                    no native browser preview.
    * `:unknown`  — fall back to "cannot preview" + download link.
  """
  @spec preview_mode(Files.File.t()) :: :image | :pdf | :markdown | :text | :document | :unknown
  def preview_mode(%Files.File{content_type: ct}) when is_binary(ct) do
    cond do
      String.starts_with?(ct, "image/") -> :image
      ct == "application/pdf" -> :pdf
      ct == "text/markdown" -> :markdown
      ct == "text/plain" -> :text
      ct == "text/csv" -> :text
      ct == "application/json" -> :text
      String.starts_with?(ct, "text/") -> :text
      document_content_type?(ct) -> :document
      true -> :unknown
    end
  end

  def preview_mode(_), do: :unknown

  defp document_content_type?(ct) do
    ct in [
      "application/msword",
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      "application/vnd.google-apps.document",
      "application/vnd.oasis.opendocument.text",
      "application/rtf"
    ]
  end

  @doc """
  Returns true when the detail pane should fall back to extracted text
  (text / markdown / document modes) even though no `platform_file_texts`
  row exists yet (still ingesting, failed, or non-text-bearing).
  """
  def text_mode?(mode), do: mode in [:text, :markdown, :document]

  @doc """
  Renders extracted markdown text through the chat content renderer so
  the viewer gets the same sanitized HTML pipeline as messages. Returns
  a `Phoenix.HTML.safe()` tuple suitable for direct `{}` interpolation.
  """
  def render_markdown_text(nil), do: Phoenix.HTML.raw("")
  def render_markdown_text(text) when is_binary(text), do: ContentRenderer.render_message(text)

  @doc false
  def org_label_for(%{org: %Tenancy.Org{slug: slug}}), do: Tenancy.scope_label(slug)
  def org_label_for(_), do: ""

  @doc false
  def org_color_for(%{org: %Tenancy.Org{slug: slug}}), do: Tenancy.scope_color(slug)
  def org_color_for(_), do: "text-muted"

  # ── Semantic-result accessors (tolerate both atom + string keys) ───────

  @doc false
  def result_file_id(result) do
    Map.get(result, :id) || Map.get(result, "id") ||
      Map.get(result, :entry_id) || Map.get(result, "entry_id") ||
      get_in_metadata(result, "file_id")
  end

  @doc false
  def result_label(result) do
    get_in_metadata(result, "original_filename") || result_file_id(result) || "(file)"
  end

  @doc false
  def result_score(result) do
    Map.get(result, :score) || Map.get(result, "score") || 0.0
  end

  @doc false
  def result_snippet(result) do
    Map.get(result, :content) || Map.get(result, "content") || ""
  end

  @doc false
  def format_score(score) when is_number(score),
    do: :erlang.float_to_binary(score * 1.0, decimals: 2)

  def format_score(_), do: "—"

  defp get_in_metadata(result, key) do
    meta = Map.get(result, :metadata) || Map.get(result, "metadata") || %{}
    Map.get(meta, key) || Map.get(meta, String.to_atom(key))
  end
end
