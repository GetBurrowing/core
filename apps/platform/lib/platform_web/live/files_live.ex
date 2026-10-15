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

  ## Delete + undo (task 019f7cb0 stage 5)

  The detail-pane Delete button soft-deletes via
  `Platform.Files.delete_file/2` — optimistic removal with NO confirm
  dialog (ratified: undo over consent). The context broadcasts
  `{:file_deleted, file_id}` itself, so this LV never re-broadcasts; the
  click handler still drops the row in-place for same-tab snappiness
  (the broadcast converges other tabs). An ~8s undo toast
  (`PlatformWeb.Components.FileDeleteUI`) offers
  `Platform.Files.restore_file/2`; `{:file_restored, file_id}` from any
  session re-inserts the row via the same single-row refresh the ingest
  events use. `restore_file/2` has no window check — a row purged
  mid-undo (30-day sweeper) surfaces as a graceful "couldn't restore"
  flash, never a crash.

  ## Failed-ingest summary (task 01a0008b stage 4)

  One sentence above the table, rendered ONLY when
  `Platform.Files.count_failed_ingests/1` is greater than zero, carrying
  the project-wide count and the retry-all action.

  Two things were missing before it, and neither was visibility: the red
  "Failed" badge already rendered per row. What was missing was an
  AGGREGATE (noticing cost opening a project and scanning every row, so
  nobody did) and an ACTION (the badge was a dead end —
  `Platform.Files.request_ingest/2` existed and nothing in the UI called
  it).

  The zero case renders NOTHING — no empty state, no green all-clear, no
  persistent widget. That absence is the design decision, not an
  omission: a status surface that renders when everything is fine trains
  people to stop reading it, and then it fails on the one day it
  matters. Its mere presence is the signal, before anyone reads the
  number.

  The count comes from the DB aggregate, never from `@files` — that list
  is capped at 200 (`list_files/1`), so a list-derived count starts
  under-reporting exactly when a project is big enough for the summary to
  matter, and a wrong number on a surface whose only job is trust is
  worse than no number. It is recomputed on every event that can move it
  (see `assign_failed_summary/1`), not just on mount and project switch.

  Repeated failure does NOT escalate. At
  `Platform.Files.repeat_failure_threshold/0` consecutive failures a file
  is withheld from the BULK sweep and the sentence re-diagnoses it as
  likely needing a re-export; nothing pages, alerts, or changes colour.
  The per-file Retry stays available at any count — that bound rate-limits
  one fan-out button, it does not lock anybody out of their own file.

  ## Out of scope

  Chat-attachment → Files promotion is a separate stack — this surface
  is the standalone document store only.
  """

  use PlatformWeb, :live_view

  alias Platform.Accounts
  alias Platform.Chat.ContentRenderer
  alias Platform.Files
  alias Platform.Files.Storage
  alias Platform.Files.Supersession
  alias Platform.Memory
  alias Platform.Projects
  alias Platform.Tasks
  alias Platform.Tenancy

  @max_upload_size 50_000_000
  @max_upload_entries 10

  # Undo window for the delete toast (design direction: ~8 seconds).
  # Soft delete keeps the row recoverable server-side for 30 days after
  # the toast dies — the toast is the fast path, not the only path.
  @undo_toast_ms 8_000

  # ── Mount / handle_params ────────────────────────────────────────────────

  @impl true
  def mount(_params, session, socket) do
    projects = Tasks.list_projects_for_user(socket.assigns[:current_user_record], preload: :org)
    current_user_id = session["current_user_id"]

    {:ok,
     socket
     |> assign(:page_title, "Files")
     |> assign(:current_path, "/files")
     |> assign(:current_user_id, current_user_id)
     |> assign(:projects, projects)
     # Navigation source: every active org THE VIEWER BELONGS TO keeps a section
     # (and count) even at zero projects, so archiving an org's last project
     # can't erase its header. Foreign orgs get no header at all — an empty
     # header naming an org the viewer isn't in is still an existence leak
     # — matches the Tasks sidebar and Chat. Files has no <select> consuming
     # this grouping, so there's no project-derived variant to keep alongside.
     |> assign(
       :project_sections,
       Projects.group_by_active_org(
         projects,
         Tenancy.list_active_tenants_for_user(socket.assigns[:current_user_record])
       )
     )
     |> assign(:selected_project_id, nil)
     |> assign(:selected_project, nil)
     |> assign(:files, [])
     # file_id => Files.Supersession.claim(). Absent for every file
     # whose card records no claim, which is nearly all of them.
     |> assign(:supersession_claims, %{})
     |> assign(:selected_file, nil)
     |> assign(:selected_file_text, nil)
     # nil means "render no summary line at all", which is also what a
     # project with zero failed ingests resolves to. There is no
     # zero-state variant of this assign on purpose.
     |> assign(:failed_summary, nil)
     # Ephemeral full-screen preview overlay. Socket state only — no
     # ClientState, no hook — and guarded on `@selected_file` at render so
     # it cannot outlive the row it is showing.
     |> assign(:preview_fullscreen, false)
     |> assign(:filter, "")
     |> assign(:sort, "date_desc")
     |> assign(:semantic_query, "")
     |> assign(:semantic_results, [])
     |> assign(:semantic_search_state, :idle)
     |> assign(:show_upload_sheet, false)
     |> assign(:undo_toast, nil)
     |> assign(:subscribed_project_id, nil)
     |> assign(:upload_batch, empty_upload_batch())
     # Default CHECKED: most uploads are working material an agent should
     # be able to read. Checked does not force "attempt" — it just means
     # "no opinion", leaving the content-type default to decide, so a
     # video does not get queued for extraction it cannot survive.
     |> assign(:upload_include_for_agents, true)
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
     |> assign(:supersession_claims, %{})
     |> assign(:selected_file, nil)
     |> assign(:selected_file_text, nil)
     |> assign(:failed_summary, nil)
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
         |> assign(:selected_file_text, load_text_excerpt(file))
         |> assign(:preview_fullscreen, false)}
    end
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_file, nil)
     |> assign(:selected_file_text, nil)
     |> assign(:preview_fullscreen, false)}
  end

  def handle_event("open_preview_fullscreen", _params, socket) do
    {:noreply, assign(socket, :preview_fullscreen, true)}
  end

  def handle_event("close_preview_fullscreen", _params, socket) do
    {:noreply, assign(socket, :preview_fullscreen, false)}
  end

  # Optimistic delete — no confirm dialog (ratified design: undo over
  # consent). The disabled button still emits clicks (aria-disabled is
  # advisory), so the actor check here is the real rail.
  def handle_event("delete_file", %{"id" => file_id}, socket) do
    case {delete_actor(socket), find_known_file(socket, file_id)} do
      {nil, _file} ->
        {:noreply, put_flash(socket, :error, "Sign in to delete files.")}

      {_actor, nil} ->
        {:noreply, socket}

      {actor, file} ->
        do_delete_file(socket, actor, file)
    end
  end

  def handle_event("undo_delete", _params, socket) do
    case socket.assigns.undo_toast do
      nil ->
        {:noreply, socket}

      %{file: file, timer: timer} ->
        Process.cancel_timer(timer)

        socket
        |> assign(:undo_toast, nil)
        |> restore_deleted_file(delete_actor(socket), file)
    end
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
    case readable_file(socket, file_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "File no longer exists.")}

      file ->
        snippet = Enum.find_value(socket.assigns.semantic_results, &snippet_for(&1, file_id))

        {:noreply,
         socket
         |> assign(:selected_file, file)
         |> assign(:selected_file_text, load_text_excerpt(file))
         |> assign(:highlight_snippet, snippet)
         |> assign(:preview_fullscreen, false)
         # A semantic hit can select a row outside @files, so the claim
         # map has to be widened to cover the selection.
         |> put_claims()}
    end
  end

  # A fresh file selection (phx-change fires when the user picks or drops
  # files) begins a new upload session — reset the running batch counter so
  # the success flash reflects THIS selection, not the cumulative tally
  # across sessions in the same mounted LV.
  def handle_event("validate_upload", params, socket) do
    {:noreply,
     socket
     |> assign(:upload_batch, empty_upload_batch())
     |> assign(:upload_include_for_agents, params["include_for_agents"] != "false")}
  end

  # Flip an existing file between the two audiences, in either direction,
  # WITHOUT a re-upload — the whole reason the schema carries intent
  # separately from status.
  #
  # Two explicit branches, no catch-all: an intent outside the vocabulary
  # is a data bug, and guessing a direction for it would either destroy
  # extracted text nobody asked to lose or silently re-expose a withdrawn
  # file. Crashing is the honest outcome.
  def handle_event("toggle_agent_context", %{"id" => file_id}, socket) do
    case readable_file(socket, file_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "File no longer exists.")}

      file ->
        result =
          case file.ingest_intent do
            "attempt" -> Files.withdraw_from_agent_context(file)
            "human_only" -> Files.restore_to_agent_context(file)
          end

        case result do
          {:ok, updated} ->
            {:noreply, put_file_row(socket, updated)}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not change this file's audience.")}
        end
    end
  end

  # Interactive-code gate (task 01a06a20 stage 3) — the segmented
  # control beside Download in the detail pane, not a toggle. Two
  # explicit events rather than one "toggle_interactive" that infers
  # direction from current state: the segmented control's two buttons
  # each name the consequence they cause, and collapsing that into one
  # event would put the direction-inference back on the server, which is
  # exactly the implicit branching a named-consequence control is meant
  # to avoid. Reuses `delete_actor/1` (actor-map construction is not
  # delete-specific) and `find_known_file/2` (a semantic-search hit can
  # select a row outside `@files`, same as the delete path).
  def handle_event("mark_interactive", %{"id" => file_id}, socket) do
    case {delete_actor(socket), find_known_file(socket, file_id)} do
      {nil, _file} ->
        {:noreply, put_flash(socket, :error, "Sign in to run a file as a prototype.")}

      {_actor, nil} ->
        {:noreply, socket}

      {actor, file} ->
        case Files.mark_interactive(actor, file) do
          {:ok, updated} ->
            {:noreply, put_file_row(socket, updated)}

          {:error, :already_interactive} ->
            # Another session (or a replayed click) beat us to it —
            # converge silently, same as the delete path's
            # :already_deleted branch.
            {:noreply, socket}

          {:error, :project_archived} ->
            {:noreply,
             put_flash(socket, :error, "This project is archived — files can't be changed.")}

          {:error, _reason} ->
            {:noreply,
             put_flash(socket, :error, "Couldn't turn on scripts for #{display_name(file)}.")}
        end
    end
  end

  def handle_event("unmark_interactive", %{"id" => file_id}, socket) do
    case {delete_actor(socket), find_known_file(socket, file_id)} do
      {nil, _file} ->
        {:noreply, put_flash(socket, :error, "Sign in to change this file's script setting.")}

      {_actor, nil} ->
        {:noreply, socket}

      {actor, file} ->
        case Files.unmark_interactive(actor, file) do
          {:ok, updated} ->
            {:noreply, put_file_row(socket, updated)}

          {:error, :not_interactive} ->
            {:noreply, socket}

          {:error, :project_archived} ->
            {:noreply,
             put_flash(socket, :error, "This project is archived — files can't be changed.")}

          {:error, _reason} ->
            {:noreply,
             put_flash(socket, :error, "Couldn't turn off scripts for #{display_name(file)}.")}
        end
    end
  end

  # Rule on the supersession claim made ABOUT this file. The verbs sit
  # on the superseded document (design direction: the ruling belongs on
  # the document, not in a queue), so `file_id` here is the SUPERSEDED
  # file and the write lands on the claimant's card — see
  # `Supersession.rule_claim/3`.
  #
  # This is the ONLY mutation the ghost state has: nothing here
  # publishes, unpublishes, hides or unhides a card. The claim was
  # already visible metadata before anybody clicked, and stays visible
  # metadata afterwards. Confirm upgrades it to authoritative; Not true
  # denies it.
  def handle_event("rule_supersession", %{"id" => file_id, "ruling" => ruling}, socket)
      when is_binary(file_id) do
    cond do
      ruling not in Supersession.rulings() ->
        {:noreply, socket}

      not can_rule_supersession?(socket.assigns.current_user_id) ->
        {:noreply, put_flash(socket, :error, "Sign in to rule on supersession claims.")}

      true ->
        case Map.get(socket.assigns.supersession_claims, file_id) do
          nil ->
            {:noreply, socket}

          claim ->
            do_rule_supersession(socket, claim, ruling)
        end
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :files, ref)}
  end

  # Retry every failed ingest in the project that is still worth
  # retrying. Lives in the summary line rather than on each row: eight
  # failures would otherwise be eight clicks, which is how a repair gets
  # abandoned halfway through.
  #
  # No flash on success. The line disappearing IS the feedback, and a
  # toast confirming a repair the page already shows would be the second
  # place to look this design exists to avoid.
  def handle_event("retry_failed_ingests", _params, socket) do
    case socket.assigns.selected_project_id do
      nil ->
        {:noreply, socket}

      project_id ->
        {:ok, _summary} = Files.retry_failed_ingests(project_id)

        # Re-list rather than patch rows: the sweep is project-wide and
        # uncapped, so it can touch rows this page never loaded.
        {:noreply,
         socket
         |> assign(:files, list_files(project_id))
         |> assign_failed_summary()}
    end
  end

  # Per-file retry from the detail panel. `request_ingest/2` is the
  # single retry entry point (it flips intent + status in one write and
  # enqueues); the default `mode: :async` is correct here because a
  # LiveView's BEAM outlives the spawned task.
  #
  # The eligibility check is repeated server-side because a click is an
  # arbitrary client message, not proof a control was rendered. It no
  # longer guards a failure count — the manual retry is unbounded — but
  # it still guards STATUS: a replayed or forged click must not be able
  # to re-enqueue a `"not_attempted"` (human_only) row and overturn a
  # human's decision, nor kick a row that is already pending.
  def handle_event("retry_file", %{"id" => file_id}, socket) do
    case find_known_file(socket, file_id) do
      nil ->
        {:noreply, socket}

      file ->
        if can_retry_file?(file), do: do_retry_file(socket, file), else: {:noreply, socket}
    end
  end

  # ── PubSub ──────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:file_ingested, file_id}, socket) do
    {:noreply, refresh_file(socket, file_id)}
  end

  def handle_info({:file_ingest_failed, file_id, _reason}, socket) do
    {:noreply, refresh_file(socket, file_id)}
  end

  # Another session withdrew this file from agent context. The broadcast
  # lands on the project topic we already subscribe to; re-fetch the row
  # so its badge and toggle reflect the new intent without a refresh.
  def handle_info({:file_withdrawn_from_agent_context, file_id}, socket) do
    {:noreply, refresh_file(socket, file_id)}
  end

  def handle_info({:file_deleted, file_id}, socket) do
    {:noreply, drop_file_row(socket, file_id)}
  end

  # Another session (or our own undo — idempotent) restored a
  # soft-deleted file: re-fetch and re-insert via the same single-row
  # refresh the ingest events use. A toast still offering undo for this
  # file is stale — the file is already back — so clear it.
  def handle_info({:file_restored, file_id}, socket) do
    socket =
      case socket.assigns.undo_toast do
        %{file: %Files.File{id: ^file_id}, timer: timer} ->
          Process.cancel_timer(timer)
          assign(socket, :undo_toast, nil)

        _ ->
          socket
      end

    {:noreply, refresh_file(socket, file_id)}
  end

  # Undo window elapsed. Guard on the file id so a late-arriving timer
  # message from a replaced toast (consecutive deletes race
  # Process.cancel_timer) can't clear the newer toast.
  def handle_info({:clear_undo_toast, file_id}, socket) do
    case socket.assigns.undo_toast do
      %{file: %Files.File{id: ^file_id}} ->
        {:noreply, assign(socket, :undo_toast, nil)}

      _ ->
        {:noreply, socket}
    end
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
          {:ok,
           handle_one_consumed(
             path,
             entry,
             project_id,
             org_id,
             uploaded_by,
             socket.assigns.upload_include_for_agents
           )}
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
  defp handle_one_consumed(path, entry, project_id, org_id, uploaded_by, include_for_agents?) do
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
          case Files.create_file(put_upload_intent(create_attrs, include_for_agents?)) do
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

  # The upload checkbox is a one-way override. Unchecked means "hold this
  # back", which is an explicit intent the context honours over the
  # content-type default. Checked supplies NOTHING — forcing "attempt"
  # would queue extraction for formats the extractor cannot read.
  defp put_upload_intent(attrs, true), do: attrs
  defp put_upload_intent(attrs, false), do: Map.put(attrs, :ingest_intent, "human_only")

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
        |> File.stream!(64 * 1024)
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
    |> put_claims()
  end

  defp empty_upload_batch, do: %{created: [], dedup: [], errors: []}

  # ── Internals ───────────────────────────────────────────────────────────

  defp load_project(socket, project_id) do
    # An archived project is treated exactly like a missing one (task
    # 019f4eaa): it's gone from the sidebar, so it must not stay reachable as
    # a live file list via a restored selection or a deep link.
    project = Tasks.get_project(project_id)

    # RBAC v2 (task 01a1386e-45a5 stage 1): a project the viewer's
    # `files.read` deny covers behaves exactly like a missing one.
    if is_nil(project) or Platform.Projects.archived?(project) or
         not project_readable?(socket, project.id) do
      socket
      |> put_flash(:error, "Project not found.")
      |> push_patch(to: ~p"/files")
    else
      # Preload :org so the breadcrumb can render the scope label/color.
      # `Tasks.get_project/1` doesn't preload by default — the sidebar
      # already calls `list_projects_for_user(user, preload: :org)` for the same reason.
      project = Platform.Repo.preload(project, :org)

      socket
      |> maybe_unsubscribe()
      |> subscribe(project_id)
      |> assign(:selected_project_id, project_id)
      |> assign(:selected_project, project)
      |> assign(:files, list_files(project_id))
      |> assign(:selected_file, nil)
      |> assign(:selected_file_text, nil)
      |> assign_failed_summary()
      |> assign(:semantic_results, [])
      |> assign(:semantic_search_state, :idle)
      |> assign(:filter, "")
      |> put_claims()
    end
  end

  # RBAC v2 (task 01a1386e-45a5 stage 1): `files.read` on the project through
  # `Platform.Access.check/3`, in conjunction with whatever already admitted
  # the request. With no grants on `@access_scope` it is always true.
  defp project_readable?(socket, project_id),
    do:
      Platform.Access.check(socket.assigns[:access_scope], "files.read", {:project, project_id}) ==
        :ok

  # `Files.get_file/1` for a file the viewer may read: a file in a project a
  # deny covers is `nil`, exactly like a missing one.
  defp readable_file(socket, file_id) do
    case Files.get_file(file_id) do
      %Files.File{project_id: project_id} = file ->
        if project_readable?(socket, project_id), do: file, else: nil

      other ->
        other
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

  # Write a file we already hold into both places the page renders it —
  # the list row and the detail pane — without a re-fetch. Used by the
  # agent-context toggle, whose context call already returned the updated
  # struct; going back to the DB for it would just add a race.
  defp put_file_row(socket, %Files.File{} = file) do
    files =
      Enum.map(socket.assigns.files, fn f -> if f.id == file.id, do: file, else: f end)

    selected =
      case socket.assigns.selected_file do
        %Files.File{id: id} when id == file.id -> file
        other -> other
      end

    socket
    |> assign(files: files, selected_file: selected)
    |> assign_failed_summary()
  end

  defp refresh_file(%{assigns: %{selected_project_id: nil}} = socket, _file_id), do: socket

  defp refresh_file(socket, file_id) do
    case readable_file(socket, file_id) do
      nil ->
        # Row vanished — drop it from the list.
        socket
        |> assign(:files, Enum.reject(socket.assigns.files, &(&1.id == file_id)))
        |> assign_failed_summary()

      file ->
        files = Enum.map(socket.assigns.files, fn f -> if f.id == file_id, do: file, else: f end)

        files =
          if Enum.any?(files, &(&1.id == file_id)), do: files, else: [file | files]

        selected =
          case socket.assigns.selected_file do
            %{id: ^file_id} -> file
            other -> other
          end

        # The ingest that just resolved is what triggers cataloging, so
        # this is the event on which a claim first becomes renderable.
        socket
        |> assign(files: files, selected_file: selected)
        |> assign_failed_summary()
        |> put_claims()
    end
  end

  # ── Failed-ingest summary (task 01a0008b stage 4) ───────────────────────

  # Recompute the summary from the DATABASE. Called from every seam that
  # can move the count — the single-row refresh behind
  # `{:file_ingested, _}` / `{:file_ingest_failed, _}` / `{:file_restored, _}`,
  # the drop behind `{:file_deleted, _}`, the in-place write behind the
  # agent-context toggle (an intent flip moves a row in or out of the
  # sweep), and both retry actions.
  #
  # Recomputing here rather than only on mount / project switch is the
  # point: those clauses refresh ONE row, so a count left alone goes
  # stale the instant a retry succeeds, and a summary line still claiming
  # "3 files" over three green rows is worse than no line.
  defp assign_failed_summary(%{assigns: %{selected_project_id: nil}} = socket),
    do: assign(socket, :failed_summary, nil)

  defp assign_failed_summary(%{assigns: %{selected_project_id: project_id}} = socket),
    do: assign(socket, :failed_summary, build_failed_summary(project_id))

  # nil — not a zero-count struct — when there is nothing to say, so the
  # template's `:if` drops the element from the DOM entirely.
  defp build_failed_summary(project_id) do
    case Files.count_failed_ingests(project_id) do
      0 ->
        nil

      count ->
        rows = Files.list_failed_ingests(project_id)
        threshold = Files.repeat_failure_threshold()
        {retryable, withheld} = Enum.split_with(rows, &(failure_count(&1) < threshold))

        %{
          # The DB aggregate, deliberately not `length(rows)` and never
          # `@files` — see the moduledoc.
          count: count,
          retryable: length(retryable),
          withheld: length(withheld),
          threshold: threshold,
          last_attempt_at: last_attempt_at(rows)
        }
    end
  end

  # No column records "when did we last try this": `update_ingest_status/2`
  # writes the failure, so the row's own `updated_at` is that moment. The
  # newest one across the swept rows is what "last tried" means for the
  # group.
  defp last_attempt_at([]), do: nil

  defp last_attempt_at(rows) do
    rows
    |> Enum.map(& &1.updated_at)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      stamps -> Enum.max(stamps, DateTime)
    end
  end

  defp failure_count(%Files.File{ingest_failure_count: n}) when is_integer(n), do: n
  defp failure_count(_file), do: 0

  defp do_retry_file(socket, file) do
    case Files.request_ingest(file) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_file_row(updated)
         |> assign_failed_summary()}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, "Couldn't retry #{display_name(file)}. Please try again.")}
    end
  end

  # ── Delete + undo internals (task 019f7cb0 stage 5) ────────────────────

  # Actor map for the session's current user — shared by every
  # Platform.Files mutator that follows the actor-first convention
  # (delete_file/2, restore_file/2, and, as of task 01a06a20 stage 3,
  # mark_interactive/2 / unmark_interactive/2). An untyped map audits as
  # "user", which is correct here; nil (no session user) fails the
  # context's presence gate. Named for its original caller; nothing
  # about its shape is delete-specific.
  defp delete_actor(%{assigns: %{current_user_id: user_id}}) when is_binary(user_id),
    do: %{id: user_id}

  defp delete_actor(_socket), do: nil

  # The Delete button acts on the detail pane's file, which normally sits
  # in @files too — but a semantic-search hit can select a row outside
  # the loaded list, so check the selection first.
  defp find_known_file(socket, file_id) do
    case socket.assigns.selected_file do
      %Files.File{id: ^file_id} = file -> file
      _ -> Enum.find(socket.assigns.files, &(&1.id == file_id))
    end
  end

  defp do_delete_file(socket, actor, file) do
    case Files.delete_file(actor, file) do
      {:ok, deleted} ->
        # The context already broadcast {:file_deleted, id} for other
        # sessions; drop the row here too so this tab doesn't wait on
        # its own PubSub round-trip (drop_file_row is idempotent).
        {:noreply,
         socket
         |> drop_file_row(deleted.id)
         |> show_undo_toast(deleted)}

      {:error, :already_deleted} ->
        # Another session (or the MCP tool) beat us to it — converge
        # silently; their broadcast may not have reached us yet.
        {:noreply, drop_file_row(socket, file.id)}

      {:error, :project_archived} ->
        {:noreply,
         put_flash(socket, :error, "This project is archived — its files can't be deleted.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Sign in to delete files.")}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, "Couldn't delete #{display_name(file)}. Please try again.")}
    end
  end

  # Remove a row from local state and clear the detail pane if it was
  # showing that file. Shared by the {:file_deleted, _} broadcast and the
  # optimistic click path — both may fire for the same delete, so this
  # must stay idempotent.
  defp drop_file_row(socket, file_id) do
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

    socket
    |> assign(:files, files)
    |> assign_failed_summary()
  end

  # One toast at a time: a consecutive delete replaces the toast and its
  # timer (cancel-or-race is handled by the id guard in handle_info).
  defp show_undo_toast(socket, %Files.File{} = deleted) do
    cancel_undo_timer(socket)
    timer = Process.send_after(self(), {:clear_undo_toast, deleted.id}, @undo_toast_ms)

    assign(socket, :undo_toast, %{
      file: deleted,
      name: display_name(deleted),
      timer: timer
    })
  end

  defp cancel_undo_timer(%{assigns: %{undo_toast: %{timer: timer}}}),
    do: Process.cancel_timer(timer)

  defp cancel_undo_timer(_socket), do: :ok

  defp restore_deleted_file(socket, nil, _file) do
    {:noreply, put_flash(socket, :error, "Sign in to restore files.")}
  end

  defp restore_deleted_file(socket, actor, file) do
    case safe_restore(actor, file) do
      {:ok, restored} ->
        # Reinsert directly from the re-fetched row the context returns;
        # the {:file_restored, _} broadcast also lands here and converges
        # idempotently via refresh_file/2.
        {:noreply, insert_file_row(socket, restored)}

      {:error, :not_deleted} ->
        # Already restored elsewhere (double-undo race) — just make sure
        # the row is showing.
        {:noreply, refresh_file(socket, file.id)}

      {:error, :not_found} ->
        # The 30-day sweeper purged the row mid-undo. restore_file/2 has
        # no window check, so this surfaces as a stale update — tell the
        # user plainly instead of crashing.
        {:noreply,
         put_flash(
           socket,
           :error,
           "Couldn't restore #{display_name(file)} — it has been permanently removed."
         )}

      {:error, :project_archived} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "This project is archived — #{display_name(file)} can't be restored."
         )}

      {:error, _other} ->
        {:noreply, put_flash(socket, :error, "Couldn't restore #{display_name(file)}.")}
    end
  end

  # A purged row makes Repo.update raise Ecto.StaleEntryError inside
  # restore_file/2 — normalize it to the :not_found the caller handles.
  defp safe_restore(actor, file) do
    Files.restore_file(actor, file)
  rescue
    Ecto.StaleEntryError -> {:error, :not_found}
  end

  # Insert-or-replace a single row in local state; sort order is applied
  # at render time by filtered_and_sorted/3, so list position is
  # irrelevant. Ignores rows for projects other than the selected one
  # (an undo can fire after the user navigated away).
  defp insert_file_row(socket, %Files.File{} = file) do
    if file.project_id == socket.assigns.selected_project_id do
      files = socket.assigns.files

      files =
        if Enum.any?(files, &(&1.id == file.id)) do
          Enum.map(files, fn f -> if f.id == file.id, do: file, else: f end)
        else
          [file | files]
        end

      socket
      |> assign(:files, files)
      |> assign_failed_summary()
      |> put_claims()
    else
      socket
    end
  end

  # ── Supersession rulings (task 01a0008c stage 5) ───────────────────────

  # Recompute the claim map from whatever this LV is currently showing.
  # Keyed by the SUPERSEDED file's id — that is the row a claim renders
  # on. The selection is folded in because a semantic-search hit can be
  # selected without ever being in @files, and its card may be the one
  # making a claim.
  defp put_claims(socket) do
    files =
      case socket.assigns[:selected_file] do
        %Files.File{id: id} = selected ->
          if Enum.any?(socket.assigns.files, &(&1.id == id)),
            do: socket.assigns.files,
            else: [selected | socket.assigns.files]

        _ ->
          socket.assigns.files
      end

    assign(socket, :supersession_claims, Supersession.claims_for_files(files))
  end

  defp do_rule_supersession(socket, claim, ruling) do
    case Supersession.rule_claim(claim, ruling, actor_id: socket.assigns.current_user_id) do
      {:ok, _claim} ->
        {:noreply, put_claims(socket)}

      {:error, reason} when reason in [:no_card, :card_missing, :no_claim] ->
        # The card was regenerated, purged, or never carried a claim —
        # the panel the user clicked is stale. Re-read rather than
        # insisting on the state we rendered.
        {:noreply,
         socket
         |> put_claims()
         |> put_flash(:error, "That supersession claim is no longer on this document's card.")}

      {:error, _other} ->
        {:noreply, put_flash(socket, :error, "Couldn't record that ruling. Please try again.")}
    end
  end

  defp display_name(%Files.File{} = file), do: file.name || file.original_filename || "file"

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

  @doc """
  Whether the current viewer may delete (and restore) files. Mirrors the
  page's only mutation gate — actor presence (`current_user_id` in the
  session; the context adds no role check, per the ratified stage-2
  scope). The route sits behind RequireAuth, so this is a defensive rail
  for the disabled-button render path rather than a reachable state.
  """
  def can_delete?(current_user_id), do: is_binary(current_user_id)

  @doc """
  Whether the current viewer may rule on a supersession claim.

  Same gate as `can_delete?/1` — actor presence — because a ruling is
  the same class of act as the page's other mutations and the route
  already sits behind RequireAuth. The buttons render disabled rather
  than hidden (persistent controls over reveal, the locked direction on
  this surface), and `handle_event/3` re-checks: a disabled button
  still emits clicks.
  """
  def can_rule_supersession?(current_user_id), do: is_binary(current_user_id)

  @doc false
  def status_badge_class("ingested"), do: "badge badge-success badge-sm"
  def status_badge_class("failed"), do: "badge badge-error badge-sm"
  # A human_only file is never enqueued, so "not_attempted" is a terminal
  # resting state, not a step on the way to "ingested". Without this head
  # it fell through to the warning pill and read as perpetually ingesting.
  # whitespace-nowrap because this is the only two-word status label: at a
  # 375px viewport the words wrapped inside a badge whose pill did not grow
  # with them, so the text rendered outside its own lozenge (measured).
  def status_badge_class("not_attempted"), do: "badge badge-ghost badge-sm whitespace-nowrap"
  def status_badge_class(_), do: "badge badge-warning badge-sm"

  @doc false
  def status_label("ingested"), do: "Ready"
  def status_label("failed"), do: "Failed"
  def status_label("not_attempted"), do: "People only"
  def status_label(_), do: "Ingesting…"

  @doc """
  Whether the detail panel offers a retry for this file (task 01a0008b
  stage 4).

  ONE condition: the file's extraction actually broke. There is NO
  failure-count bound here, deliberately (task 01a0166d). A person
  clicking Retry on a row has looked at that row, spends one request,
  and is the only party who can know something changed outside the
  system — the backend recovered, the file was re-exported. Refusing
  them makes the product argue with someone about their own file.

  `Platform.Files.repeat_failure_threshold/0` still bounds the bulk
  sweep, and that bound is only defensible because THIS function never
  withholds. Re-introducing a count comparison here turns the sweep's
  rate limit into a lockout with no escape hatch; the comment on
  `@repeat_failure_threshold` in `Platform.Files` says the same thing
  from the other side. Read the threshold for copy, never to gate.

  A `"not_attempted"` file is still not offered a retry: it was withheld
  on purpose by a human, and the audience toggle beside this button is
  the control that means "actually, do read this one". That withhold is
  a decision, not a bound.
  """
  def can_retry_file?(%Files.File{ingest_status: "failed"}), do: true

  def can_retry_file?(_file), do: false

  # What a failed row says when the reason column is NULL — the nine rows
  # that failed before the column existed, and any future writer that
  # records a stage without a detail. Rendered in the same mono as a real
  # reason because it is a statement about the record, not a reason.
  #
  # A blank strip is not an option: a failed row that says nothing is the
  # exact defect task 01a0166d exists to remove, so leaving the element
  # empty would re-create it one layer down.
  @missing_reason "Reason not recorded"

  @doc """
  The human half of the failure strip: which of the three ingest stages
  broke, in words (task 01a0166d stage 4).

  The prefix is the whole point of the column pair. When eight of nine
  rows read `Embedding: connect timed out`, the ninth reading
  `Extraction: unsupported encoding` is the entire value of the strip,
  and it is invisible without this half. The machine tail is never
  rendered alone.

  TOTAL over any string, deliberately. `:ingest_failure_stage` is a plain
  text column read back from the database, and a `case` without a
  catch-all over one is a crash waiting for a value the writer did not
  anticipate — a future stage, a hand-edited row, a migration. An
  unrecognised stage degrades to the generic noun rather than taking the
  Files page down.
  """
  def failure_stage_label("extract"), do: "Extraction"
  def failure_stage_label("embed"), do: "Embedding"
  def failure_stage_label("storage"), do: "Storage"
  def failure_stage_label(_other), do: "Ingest"

  @doc """
  The machine half of the failure strip, verbatim.

  Rendered in mono, which is doing real work: it tells the reader the
  string came from the machine and was not written for them, which is
  exactly the expectation you want before they paste it to an engineer.

  A NULL or blank detail becomes `#{@missing_reason}` rather than an
  empty element — see the note on `@missing_reason`.
  """
  def failure_detail_text(detail) when is_binary(detail) do
    case String.trim(detail) do
      "" -> @missing_reason
      trimmed -> trimmed
    end
  end

  def failure_detail_text(_detail), do: @missing_reason

  @doc """
  Whether the AUTOMATIC bulk sweep will decline to re-enqueue this row
  (task 01a0166d stage 4).

  Derived, not stored: `"failed"` plus a count that has reached
  `Platform.Files.repeat_failure_threshold/0`. No new column, and no
  second literal for the threshold.

  This is a READ of the sweep's bound so the row can explain itself, NOT
  a gate. Nothing in the manual retry path consults it — `can_retry_file?/1`
  above stays status-only. A row this returns `true` for still offers the
  detail pane's Retry, which is the only reason the sweep is allowed to
  keep a bound at all.

  Without this state a row the sweep skipped is pixel-identical to one
  the sweep tried and failed on: it shows its old reason, and stale
  silence reads as "tried and failed" when nothing was tried. That is
  this task's own defect, reappearing one layer up.
  """
  def sweep_skipped?(%Files.File{ingest_status: "failed"} = file),
    do: failure_count(file) >= Files.repeat_failure_threshold()

  def sweep_skipped?(_file), do: false

  @doc """
  The clause appended to the reason when the sweep skipped the row.

  The copy is the sharp part and it is not a preference: the sentence
  must name the AUTOMATIC path. The manual retry is unbounded, so a bare
  "not retried" reads as "you cannot retry" — the precise inversion of
  the instruction this task exists to carry out. The strip must never
  contradict the control it sits beside.

  The number comes from `Platform.Files.repeat_failure_threshold/0`; a
  second literal here is the drift that function exists to prevent.
  """
  def sweep_skipped_clause,
    do: "not retried automatically after #{Files.repeat_failure_threshold()} attempts"

  @doc """
  The words following the count in the summary line.

  The count itself is rendered separately so it alone can carry the error
  colour, so this deliberately starts mid-sentence at the noun.

  When nothing is left to retry the sentence CHANGES rather than the
  styling: same colour, same size, different diagnosis. Getting louder on
  the third failure would be escalation, and escalation on a condition
  the reader cannot fix from the notification is the noise this task
  exists to remove, relocated.
  """
  def failed_summary_sentence(%{count: count, retryable: 0, threshold: threshold}) do
    "#{file_noun(count)} #{has_have(count)} failed #{threshold} times and " <>
      "likely #{needs_need(count)} re-exporting."
  end

  def failed_summary_sentence(%{count: count}) do
    "#{file_noun(count)} can't be read by agents."
  end

  @doc """
  The quieter clause after the sentence: when these files were last
  tried, plus — when both populations are present — how many of them the
  retry will not touch.

  Returns `nil` when there is nothing quiet to add, so the template can
  omit the element rather than render an empty one.
  """
  def failed_summary_note(%{} = summary) do
    [last_tried_clause(summary), withheld_clause(summary)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " ")
    end
  end

  defp last_tried_clause(%{last_attempt_at: nil}), do: nil

  defp last_tried_clause(%{last_attempt_at: at}),
    do: "Last tried #{Calendar.strftime(at, "%Y-%m-%d %H:%M")}."

  # Only when BOTH populations exist. If every file is withheld the main
  # sentence already says so, and if none are there is nothing to
  # withhold — in both cases this clause would just repeat or mislead.
  #
  # The copy carries the same rule as `sweep_skipped_clause/0` one level
  # up, and for the same reason: name the AUTOMATIC path, then point at
  # the action that IS open. "needs re-exporting instead" framed the
  # export as the alternative TO retrying, which reads as "you cannot
  # retry these" — the exact inversion this task exists to remove, and
  # false besides, since the detail pane's unbounded Retry is right
  # there. Re-exporting is a suggestion; the retry is available; the
  # sentence must not close the second to offer the first.
  #
  # It points at the file, not at the row: the per-row button was
  # removed deliberately (see the row strip comment in the template), so
  # copy telling the reader to look for one on the row would send them
  # hunting for a control that does not exist. Opening the file is what
  # actually reaches `files-detail-retry`.
  #
  # The number comes from the summary's `threshold`, which is
  # `Files.repeat_failure_threshold/0` — never a second literal.
  defp withheld_clause(%{retryable: retryable, withheld: withheld, threshold: threshold})
       when retryable > 0 and withheld > 0 do
    "#{withheld} of them #{has_have(withheld)} failed #{threshold} times, so the sweep " <>
      "no longer retries #{it_them(withheld)} automatically — open #{that_file(withheld)} " <>
      "to try again, or re-export."
  end

  defp withheld_clause(_summary), do: nil

  defp file_noun(1), do: "file"
  defp file_noun(_count), do: "files"

  defp has_have(1), do: "has"
  defp has_have(_count), do: "have"

  defp needs_need(1), do: "needs"
  defp needs_need(_count), do: "need"

  defp it_them(1), do: "it"
  defp it_them(_count), do: "them"

  defp that_file(1), do: "that file"
  defp that_file(_count), do: "each of those files"

  @doc false
  def agent_toggle_label("attempt"), do: "Included for agents"
  def agent_toggle_label("human_only"), do: "People only"

  @doc false
  def agent_toggle_icon("attempt"), do: "hero-sparkles"
  def agent_toggle_icon("human_only"), do: "hero-user"

  @doc """
  Confirmation copy for the agent-context toggle, or `nil` when the flip
  needs none.

  Only the attempt → human_only direction destroys derived data (the
  cached extracted text and the index entry), so only that direction
  confirms. Prompting on the way back would train the user to click
  through the prompt that matters.
  """
  def agent_toggle_confirm("attempt"),
    do: "Removes this file's extracted text from agent search."

  def agent_toggle_confirm("human_only"), do: nil

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

  @doc """
  Frame source for the sandboxed HTML preview. `?preview=1` is what makes
  the blob route answer markup inline at all — without it the same URL
  downloads, which is the point of the disposition rule. The response is
  still `Content-Security-Policy: sandbox`, so nothing in the document
  runs regardless of which frame asks for it.
  """
  def file_preview_frame_url(%Files.File{id: id}), do: "/files/blob/#{id}?preview=1"

  @doc """
  Design width, in CSS pixels, the HTML preview frame is given.

  Deliberately NOT `100%`. A frame sized to the pane hands a desktop
  mockup a narrow viewport, its own media queries fire, and the reviewer
  studies the mobile layout believing it is the desktop one. The pane
  scrolls horizontally instead; shrink-to-fit was rejected because 5px
  type defeats the entire use case (read the mockup).
  """
  def html_preview_width, do: 1280

  @doc """
  Design height, in CSS pixels, of the auto-scaled INTERACTIVE prototype
  frame (task 01a06a20 stage 3).

  Paired with `html_preview_width/0` by the client-side `FilePreviewScale`
  hook, which reuses the canvas embed's scale-to-fit approach: both
  numbers go out as `data-declared-*` attributes so the hook can compute
  `containerWidth / declared_width` and collapse the wrapper to
  `declared_height * scale`, rather than leaving blank space below a
  shrunk frame. Not used by the unflagged path, which keeps its `70vh`
  height and horizontal scroll (`html_preview_width/0`'s own doc still
  applies there).
  """
  def html_preview_height, do: 800

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
    * `:html`     — render the markup in a SANDBOXED `<iframe>`
                    (text/html), scripts refused — unless the file is
                    flagged interactive (`interactive_at` set, task
                    01a06a20 stage 3), in which case scripts run and an
                    attribution bar renders above the frame. See
                    `PlatformWeb.Components.FilePreview`'s moduledoc.
    * `:markdown` — render extracted text through the chat markdown
                    pipeline (text/markdown).
    * `:text`     — render extracted text in a `<pre>` block
                    (text/plain, text/csv, application/json, etc.).
    * `:document` — extracted text in a prose-styled `<div>` for
                    DOCX / GDoc / anything else with extracted text but
                    no native browser preview.
    * `:unknown`  — fall back to "cannot preview" + download link.
  """
  @spec preview_mode(Files.File.t()) ::
          :image | :pdf | :html | :markdown | :text | :document | :unknown
  def preview_mode(%Files.File{content_type: ct}) when is_binary(ct) do
    cond do
      String.starts_with?(ct, "image/") -> :image
      ct == "application/pdf" -> :pdf
      ct == "text/html" -> :html
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

  @doc """
  The attribution line for a flagged HTML preview's bar (task 01a06a20
  stage 3, fix stage 4): `"Made interactive by <name> · <when>"`.

  This is the anti-phishing mitigation for the whole feature — its job is
  to say who made this thing run, not who uploaded it. Those are
  frequently different people, so the copy names the flagging action
  (`interactive_by_user_id` / `interactive_at`) explicitly rather than
  reading as upload provenance.

  Reads `interactive_by_user_id` fresh via `Platform.Accounts.get_user/2`
  rather than expecting a preloaded association — the detail pane shows
  one file at a time, so the extra lookup is a single primary-key read,
  not a query fan-out. `interactive_by_user_id` nilifies on user delete
  (stage 1's migration), so a flagged file can outlive the account that
  flagged it; that case degrades to `"Made interactive <when>"` rather
  than showing a stale or blank name.

  `<when>` is recency-framed via `interactive_recency_text/1`: seconds
  read as "just now", minutes/hours as "N minute(s)/hour(s) ago", one
  full day as "yesterday", and anything older falls back to the absolute
  `%-d %b` date — the question this bar answers is who made this run and
  how recently, not just who.
  """
  def interactive_attribution_text(%Files.File{interactive_at: %DateTime{} = at} = file) do
    when_text = interactive_recency_text(at)

    case interactive_uploader_name(file) do
      nil -> "Made interactive #{when_text}"
      name -> "Made interactive by #{name} · #{when_text}"
    end
  end

  def interactive_attribution_text(_file), do: nil

  @doc false
  def interactive_uploader_name(%Files.File{interactive_by_user_id: nil}), do: nil

  def interactive_uploader_name(%Files.File{interactive_by_user_id: user_id}) do
    case Accounts.get_user(user_id) do
      nil -> nil
      user -> user.name || user.email
    end
  end

  # Recency framing for `interactive_attribution_text/1`'s "<when>" — see
  # that function's doc for the boundaries. Compared against `now` at call
  # time rather than a stored/precomputed value: the bar re-renders on
  # every mount, so "5 minutes ago" is expected to march forward on
  # refresh, not freeze at flag time.
  defp interactive_recency_text(%DateTime{} = at) do
    diff_seconds = DateTime.diff(DateTime.utc_now(), at, :second)

    cond do
      diff_seconds < 60 -> "just now"
      diff_seconds < 3600 -> ago(div(diff_seconds, 60), "minute")
      diff_seconds < 86_400 -> ago(div(diff_seconds, 3600), "hour")
      diff_seconds < 172_800 -> "yesterday"
      true -> Calendar.strftime(at, "%-d %b")
    end
  end

  defp ago(count, unit), do: "#{count} #{pluralize_unit(unit, count)} ago"

  defp pluralize_unit(word, 1), do: word
  defp pluralize_unit(word, _count), do: word <> "s"

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
