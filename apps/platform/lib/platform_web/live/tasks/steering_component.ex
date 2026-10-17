defmodule PlatformWeb.Tasks.SteeringComponent do
  @moduledoc """
  The Execution & Steering concern of the Tasks surface, extracted from
  `PlatformWeb.TasksLive` by task 01a008f6 stage 5.

  Owns the execution log, the steering composer (including its
  `allow_upload/3` plumbing, which lives on this LiveComponent's
  `mount/1` — see "Uploads" below) and the Outputs list. Rendered through
  `TaskDetailComponent`'s `:steering` slot, which stage 4 introduced
  precisely so this region could be swapped out here without fighting the
  detail panel's DOM.

  ## Ownership

    * Assigns owned here: `:execution_space_id`, `:execution_log`,
      `:execution_log_collapsed`, `:execution_participant`,
      `:steering_compose_form`, `:steering_feedback`,
      `:steering_upload_previews`, `:steering_attachment_intended`,
      `:output_canvases`, `:review_output_ids`, plus the mention pair
      `:mention_suggestions` / `:mention_source`.
    * Attrs in from the shell (read-only): `selected_task`,
      `current_user_id`, `pending_reviews`, `detail_epoch`.
    * The shell owns the PubSub *subscription* (it is the process that
      receives the messages), so this component reports its space id up
      with `send(self(), {:steering_space_changed, space_id})` and the
      shell subscribes/unsubscribes. Inbound `{:new_message, _}` comes
      back down as `send_update(.., reload: token)`.
    * Opening an output canvas is *requested*, never written:
      `send(self(), {:steering_open_canvas, canvas})`. The review-canvas
      modal is shell-owned.

  ## Uploads

  `Phoenix.LiveView.allow_upload/3` is called from this component's
  `mount/1` (LiveView supports uploads in stateful LiveComponents), so
  `:steering_attachments` is bound to the component rather than to the
  shell. The lifecycle mirrors `PlatformWeb.ChatLive.UploadHooks`:
  auto-upload with a `progress` callback that mirrors entries into
  `:steering_upload_previews`, an explicit cancel event, and
  `consume_uploaded_entries/3` at send time.

  The shell's OTHER upload (`:task_attachments`, the new-task sheet) is
  NOT steering's and stays on the shell — the stage brief's mention of
  `cancel_task_upload` was a mis-attribution; that event belongs to task
  creation (stage 6).

  ## @-mentions (defect fixed here)

  `TasksLive` carried `mention_query` / `mention_clear` as no-op stubs
  with a comment claiming "TasksLive has no mention UI". That comment was
  false: the steering composer carries `phx-hook="ComposeInput"` and
  `compose_input.js` pushes both events. The client was wired; the server
  discarded. Implemented here against the EXISTING pipeline —
  `PlatformWeb.ChatLive.MentionsHooks.build_suggestions/3` and the
  ADR-0037 `@[Name]` wire format — over a participants map built for the
  execution space with `PresenceHooks.build_participant_identity_map/3`.
  No second mention protocol.

  Renamed to `steering_mention_query` / `steering_mention_clear`, and
  `compose_input.js` pushes them with `pushEventTo` — a hook's
  `pushEvent` ignores `phx-target` (it passes a nil target context), so an
  untargeted push from markup inside a LiveComponent silently lands on the
  parent LiveView. The steering textarea therefore carries
  `data-mention-target` / `data-mention-query-event` /
  `data-mention-clear-event`; ChatLive sets none of them and keeps
  today's untargeted `mention_query` / `mention_clear`.
  """
  use PlatformWeb, :live_component

  require Logger

  alias Platform.Accounts
  alias Platform.Chat
  alias Platform.Chat.AttachmentStorage
  alias Platform.Orchestration.ExecutionSpace
  alias PlatformWeb.ChatLive.MentionsHooks
  alias PlatformWeb.ChatLive.PresenceHooks

  @max_upload_entries 5
  @max_upload_size 15_000_000

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:execution_space_id, nil)
     |> assign(:execution_log, [])
     |> assign(:execution_log_collapsed, false)
     |> assign(:execution_participant, nil)
     |> assign(:steering_compose_form, to_form(%{"text" => ""}, as: :steering))
     |> assign(:steering_feedback, nil)
     |> assign(:steering_upload_previews, [])
     |> assign(:steering_attachment_intended, false)
     |> assign(:output_canvases, [])
     |> assign(:review_output_ids, MapSet.new())
     |> assign(:mention_suggestions, [])
     |> assign(:mention_source, "steering-compose-form")
     |> assign(:loaded_epoch, nil)
     |> allow_upload(:steering_attachments,
       accept: :any,
       auto_upload: true,
       max_entries: @max_upload_entries,
       max_file_size: @max_upload_size,
       progress: &handle_steering_attachment_progress/3
     )}
  end

  @impl true
  def update(%{reload: _token}, socket) do
    {:ok, reload_log_and_outputs(socket)}
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)
    epoch = assigns[:detail_epoch]

    if epoch != socket.assigns.loaded_epoch do
      {:ok, socket |> assign(:loaded_epoch, epoch) |> load_for_task()}
    else
      {:ok,
       assign(socket, :review_output_ids, review_canvas_ids(socket.assigns[:pending_reviews]))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="contents">
      <%!-- Execution Log --%>
      <div
        :if={!@execution_space_id and @steering_feedback}
        id="steering-feedback-empty"
        class={[
          "flex items-start gap-2 rounded-lg border px-3 py-2 text-xs",
          @steering_feedback.kind == :success && "border-success/30 bg-success/10 text-success",
          @steering_feedback.kind == :error && "border-error/30 bg-error/10 text-error"
        ]}
      >
        <span class={[
          "mt-0.5 size-4 shrink-0",
          @steering_feedback.kind == :success && "hero-check-circle",
          @steering_feedback.kind == :error && "hero-exclamation-circle"
        ]}>
        </span>
        <span>{@steering_feedback.message}</span>
      </div>

      <div :if={@execution_space_id} class="space-y-2">
        <div class="flex items-center justify-between">
          <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
            Execution Log
          </h3>
          <button
            phx-click="toggle_execution_log"
            phx-target={@myself}
            class="btn btn-ghost btn-xs btn-square"
            title={if @execution_log_collapsed, do: "Expand log", else: "Collapse log"}
          >
            <span class={"size-4 transition-transform #{if @execution_log_collapsed, do: "hero-chevron-down", else: "hero-chevron-up"}"}>
            </span>
          </button>
        </div>

        <div :if={!@execution_log_collapsed}>
          <div
            :if={@execution_log == []}
            class="text-xs text-base-content/30 italic py-2"
          >
            No messages yet
          </div>

          <div
            :if={@execution_log != []}
            id="execution-log-scroll"
            phx-hook="ExecutionLogScroll"
            phx-drop-target={@uploads.steering_attachments.ref}
            class="max-h-72 overflow-y-auto rounded-box border border-edge bg-base-200/30 p-2 space-y-1"
          >
            <div
              :for={msg <- @execution_log}
              class={"flex flex-col gap-0.5 text-xs #{if msg.log_only, do: "opacity-50", else: ""} #{if msg.content_type == "system", do: "border-l-2 border-edge pl-2", else: ""} #{if msg.sender_type == "user", do: "border-l-2 border-primary pl-2", else: ""}"}
            >
              <div class="flex items-start gap-2">
                <span class="text-base-content/40 whitespace-nowrap shrink-0">
                  {format_log_timestamp(msg.inserted_at)}
                </span>
                <span class={"font-medium shrink-0 #{log_sender_color(msg.sender_type, msg.content_type)}"}>
                  {msg.sender_name}
                </span>
                <span class="flex-1 whitespace-pre-wrap break-words">{msg.content}</span>
              </div>

              <%!-- Inline attachments --%>
              <div
                :if={Map.get(msg, :attachments, []) != []}
                class="flex flex-wrap gap-1.5 ml-[4.5rem]"
              >
                <%= for att <- Map.get(msg, :attachments, []) do %>
                  <%= if String.starts_with?(att.content_type || "", "image/") do %>
                    <a
                      href={~p"/chat/attachments/#{att.id}"}
                      target="_blank"
                      class="block"
                    >
                      <img
                        src={~p"/chat/attachments/#{att.id}"}
                        alt={att.filename}
                        class="max-h-40 rounded border border-edge hover:border-primary transition-colors"
                        loading="lazy"
                      />
                    </a>
                  <% else %>
                    <a
                      href={~p"/chat/attachments/#{att.id}"}
                      target="_blank"
                      class="inline-flex items-center gap-1 rounded-lg border border-edge bg-base-200 px-2 py-1 text-xs hover:border-primary transition-colors"
                    >
                      <span class="hero-document size-3.5 text-base-content/50"></span>
                      <span class="truncate max-w-[120px]">{att.filename}</span>
                    </a>
                  <% end %>
                <% end %>
              </div>
            </div>
          </div>

          <%!-- Steering compose input --%>
          <.form
            for={@steering_compose_form}
            id="steering-compose-form"
            phx-hook="ButtonLoading"
            phx-target={@myself}
            phx-submit="send_steering_message"
            phx-change="steering_changed"
            class="mt-2 border-t border-edge pt-2"
          >
            <%!-- Upload previews --%>
            <div
              :if={@uploads.steering_attachments.entries != [] or @steering_upload_previews != []}
              class="flex flex-wrap gap-2 mb-2"
            >
              <div
                :for={entry <- @uploads.steering_attachments.entries}
                :if={@uploads.steering_attachments.entries != []}
                class="relative group"
              >
                <%= if String.starts_with?(entry.client_type, "image/") do %>
                  <.live_img_preview
                    entry={entry}
                    class="w-16 h-16 object-cover rounded-lg border border-edge"
                  />
                <% else %>
                  <div class="w-16 h-16 rounded-lg border border-edge bg-base-200 flex flex-col items-center justify-center gap-0.5 px-1">
                    <span class="hero-document size-5 text-base-content/40"></span>
                    <span class="text-[8px] text-base-content/60 truncate w-full text-center">
                      {entry.client_name}
                    </span>
                  </div>
                <% end %>

                <button
                  type="button"
                  phx-click="cancel_steering_upload"
                  phx-target={@myself}
                  phx-value-ref={entry.ref}
                  class="absolute -top-1.5 -right-1.5 w-5 h-5 rounded-full bg-error text-error-content flex items-center justify-center opacity-0 group-hover:opacity-100 transition-opacity shadow-sm"
                  title="Remove"
                >
                  <span class="hero-x-mark size-3"></span>
                </button>

                <div
                  :if={entry.progress > 0 and entry.progress < 100}
                  class="absolute bottom-0.5 left-0.5 right-0.5"
                >
                  <div class="h-1 rounded-full bg-base-300 overflow-hidden">
                    <div
                      class="h-full bg-primary transition-all duration-300"
                      style={"width: #{entry.progress}%"}
                    >
                    </div>
                  </div>
                </div>
              </div>

              <div
                :for={entry <- @steering_upload_previews}
                :if={@uploads.steering_attachments.entries == []}
                class="relative group"
              >
                <div class="w-16 h-16 rounded-lg border border-edge bg-base-200 flex flex-col items-center justify-center gap-0.5 px-1">
                  <span class={[
                    "size-5 text-base-content/40",
                    String.starts_with?(entry.client_type, "image/") && "hero-photo",
                    !String.starts_with?(entry.client_type, "image/") && "hero-document"
                  ]}>
                  </span>
                  <span class="text-[8px] text-base-content/60 truncate w-full text-center">
                    {entry.client_name}
                  </span>
                </div>

                <button
                  type="button"
                  phx-click="cancel_steering_upload"
                  phx-target={@myself}
                  phx-value-ref={entry.ref}
                  class="absolute -top-1.5 -right-1.5 w-5 h-5 rounded-full bg-error text-error-content flex items-center justify-center opacity-0 group-hover:opacity-100 transition-opacity shadow-sm"
                  title="Remove"
                >
                  <span class="hero-x-mark size-3"></span>
                </button>
              </div>
            </div>

            <%!-- Upload errors --%>
            <p
              :for={error <- upload_errors(@uploads.steering_attachments)}
              class="text-xs text-error mb-1"
            >
              {upload_error_to_string(error)}
            </p>

            <div :for={entry <- @uploads.steering_attachments.entries}>
              <p
                :for={error <- upload_errors(@uploads.steering_attachments, entry)}
                class="text-xs text-error mb-1"
              >
                {entry.client_name}: {upload_error_to_string(error)}
              </p>
            </div>

            <%!-- @mention autocomplete. Same markup contract as ChatLive's
                   dropdown (ADR 0037): the button dispatches `chat:insert-mention`
                   at the textarea, which rewrites the in-progress `@query` into
                   `@[Name] `. --%>
            <div :if={@mention_suggestions != []} class="relative">
              <div class="absolute bottom-0 left-0 z-50 w-64 rounded-2xl border border-base-content/10 bg-base-100 shadow-lg overflow-hidden">
                <div class="py-1">
                  <button
                    :for={{suggestion, idx} <- Enum.with_index(@mention_suggestions)}
                    type="button"
                    data-mention-suggestion={if idx == 0, do: "first"}
                    phx-click={
                      JS.dispatch("chat:insert-mention",
                        to: "##{@steering_compose_form[:text].id}",
                        detail: %{name: suggestion.name}
                      )
                    }
                    class="flex w-full items-center gap-2 px-3 py-2 text-sm hover:bg-base-200 text-left transition-colors"
                  >
                    <%= cond do %>
                      <% suggestion.participant_type == "broadcast" -> %>
                        <div class="w-6 h-6 rounded-full bg-warning/15 text-warning flex items-center justify-center flex-shrink-0">
                          <span class="hero-megaphone size-4"></span>
                        </div>
                      <% suggestion.participant_type == "agent" -> %>
                        <.agent_avatar
                          name={suggestion.name}
                          avatar_url={suggestion.avatar_url}
                          size="sm"
                          class="flex-shrink-0"
                        />
                      <% true -> %>
                        <.human_avatar
                          name={suggestion.name}
                          avatar_url={suggestion.avatar_url}
                          seed={suggestion.avatar_seed}
                          size="sm"
                          class="flex-shrink-0"
                        />
                    <% end %>
                    <span class="flex-1 min-w-0 truncate font-medium">{suggestion.name}</span>
                    <span class={[
                      "rounded-full px-1.5 py-0.5 text-[10px] uppercase tracking-wider",
                      suggestion.participant_type == "broadcast" && "bg-warning/10 text-warning",
                      suggestion.participant_type == "agent" && "bg-primary/10 text-primary",
                      suggestion.participant_type == "user" && "bg-base-300 text-base-content/50"
                    ]}>
                      {suggestion.participant_type}
                    </span>
                  </button>
                </div>
              </div>
            </div>

            <%!-- Compose row: [+] [input stretches] [send] --%>
            <div class="flex items-center gap-2">
              <button
                type="button"
                onclick="this.closest('form').querySelector('input[type=file]').click()"
                class="flex-shrink-0 cursor-pointer rounded-full w-9 h-9 flex items-center justify-center text-base-content/50 hover:bg-base-300 transition-colors"
                title="Attach files"
                disabled={is_nil(@execution_space_id)}
              >
                <span class="hero-plus size-5"></span>
              </button>

              <.live_file_input upload={@uploads.steering_attachments} class="hidden" />

              <textarea
                name="steering[text]"
                id={@steering_compose_form[:text].id}
                placeholder="Steer the agent..."
                autocomplete="off"
                rows="1"
                class="min-w-0 flex-1 rounded-xl text-sm resize-none bg-base-100 border border-edge focus:border-primary focus:outline-none transition-colors"
                style="line-height:1.5;padding:6px 12px;min-height:33px;max-height:200px;overflow-y:auto;field-sizing:content"
                phx-hook="ComposeInput"
                data-mention-target={"##{@id}"}
                data-mention-query-event="steering_mention_query"
                data-mention-clear-event="steering_mention_clear"
                disabled={is_nil(@execution_space_id)}
              >{Phoenix.HTML.Form.normalize_value("text", @steering_compose_form[:text].value)}</textarea>

              <button
                type="submit"
                class="flex-shrink-0 w-9 h-9 rounded-full btn btn-primary btn-sm flex items-center justify-center p-0"
                disabled={is_nil(@execution_space_id)}
                title="Send steering message"
              >
                <span class="hero-paper-airplane size-4 -rotate-45"></span>
              </button>
            </div>

            <div
              :if={@steering_feedback}
              id="steering-feedback"
              class={[
                "mt-2 flex items-start gap-2 rounded-lg border px-3 py-2 text-xs",
                @steering_feedback.kind == :success &&
                  "border-success/30 bg-success/10 text-success",
                @steering_feedback.kind == :error && "border-error/30 bg-error/10 text-error"
              ]}
            >
              <span class={[
                "mt-0.5 size-4 shrink-0",
                @steering_feedback.kind == :success && "hero-check-circle",
                @steering_feedback.kind == :error && "hero-exclamation-circle"
              ]}>
              </span>
              <span>{@steering_feedback.message}</span>
            </div>
          </.form>
        </div>
      </div>

      <%!-- Outputs --%>
      <div :if={@execution_space_id} class="space-y-2">
        <div class="flex items-center gap-2">
          <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
            Outputs
          </h3>
          <span :if={@output_canvases != []} class="badge badge-ghost badge-xs">
            {length(@output_canvases)}
          </span>
        </div>

        <div :if={@output_canvases == []} class="text-xs text-base-content/30 italic py-1">
          No outputs yet
        </div>

        <div :if={@output_canvases != []} class="space-y-3">
          <div
            :for={canvas <- Enum.reverse(@output_canvases)}
            class="rounded-box border border-edge bg-base-100 p-3 space-y-2"
          >
            <div class="flex items-center justify-between gap-3">
              <div class="min-w-0">
                <div class="truncate text-sm font-medium">{canvas.title || "Output"}</div>
                <div class="text-xs text-base-content/50">
                  {Platform.Chat.CanvasDocument.root_kind(canvas.document) || "canvas"} • {Calendar.strftime(
                    canvas.inserted_at,
                    "%b %-d, %-I:%M %p"
                  )}
                </div>
              </div>
              <div class="flex items-center gap-2">
                <span
                  :if={MapSet.member?(@review_output_ids, canvas.id)}
                  class="badge badge-warning badge-xs"
                >
                  Review item
                </span>
                <button
                  class="btn btn-ghost btn-xs"
                  phx-click="gate_canvas_open"
                  phx-target={@myself}
                  phx-value-canvas-id={canvas.id}
                >
                  Open
                </button>
              </div>
            </div>

            <div class="overflow-hidden rounded-box border border-base-200 bg-base-200/30">
              <PlatformWeb.Chat.CanvasRenderer.canvas_document
                canvas={canvas}
                inline={true}
                show_header={false}
                dom_id_base="tasks-output-inline"
                open_target={@myself}
                event_target={@myself}
              />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Events ─────────────────────────────────────────────────────────────

  @impl true
  def handle_event("toggle_execution_log", _params, socket) do
    {:noreply, assign(socket, :execution_log_collapsed, !socket.assigns.execution_log_collapsed)}
  end

  def handle_event("steering_changed", %{"steering" => params}, socket) do
    {:noreply,
     socket
     |> assign(:steering_compose_form, to_form(params, as: :steering))
     |> assign(:steering_feedback, nil)}
  end

  def handle_event("cancel_steering_upload", %{"ref" => ref}, socket) do
    socket =
      if Enum.any?(active_steering_upload_entries(socket), &(&1.ref == ref)) do
        cancel_upload(socket, :steering_attachments, ref)
      else
        socket
      end

    {:noreply,
     socket
     |> assign(
       :steering_upload_previews,
       Enum.reject(socket.assigns.steering_upload_previews, fn preview -> preview.ref == ref end)
     )
     |> sync_steering_attachment_intent()
     |> assign(:steering_feedback, nil)}
  end

  # The @-mention autocomplete for the steering composer. Candidates are
  # the EXECUTION SPACE's participants — the same space the composed
  # message is posted to — so an inserted `@[Name]` resolves under
  # ADR 0037 exactly as it does in chat.
  def handle_event("steering_mention_query", %{"query" => query} = params, socket) do
    source = Map.get(params, "source", "steering-compose-form")

    suggestions =
      MentionsHooks.build_suggestions(query, steering_participants_map(socket))

    {:noreply,
     socket
     |> assign(:mention_suggestions, suggestions)
     |> assign(:mention_source, source)}
  end

  def handle_event("steering_mention_query", _params, socket) do
    {:noreply, assign(socket, :mention_suggestions, [])}
  end

  def handle_event("steering_mention_clear", _params, socket) do
    {:noreply,
     socket
     |> assign(:mention_suggestions, [])
     |> assign(:mention_source, "steering-compose-form")}
  end

  def handle_event("gate_canvas_open", %{"canvas-id" => canvas_id}, socket) do
    open_output_canvas(socket, canvas_id)
  end

  # The inline canvas wrapper's own click (CanvasRenderer), targeted here via
  # `open_target={@myself}`. Opens the same modal as the Open button.
  def handle_event("canvas_open", %{"canvas-id" => canvas_id}, socket) do
    open_output_canvas(socket, canvas_id)
  end

  # Interactive nodes in an inline output canvas (action_row buttons, forms)
  # are targeted here via `event_target={@myself}`. Untargeted they reached
  # TasksLive, which has no clause for either event: FunctionClauseError.
  # Read-only no-op, like CanvasLive's: acting on the click (ChatLive's
  # `CanvasServer.emit_event`) is an agent-visible signal that would need its
  # own authorization decision on this page. Two literal heads, not a guarded
  # clause, so TasksLiveEventWiringTest can see them.
  def handle_event("canvas_action_click", params, socket) do
    Logger.info(
      "[SteeringComponent] canvas_action_click ignored (read-only) canvas_id=#{inspect(params["canvas-id"])} node_id=#{inspect(params["node-id"])} action=#{inspect(params["action"])}"
    )

    {:noreply, socket}
  end

  def handle_event("canvas_form_submit", params, socket) do
    Logger.info(
      "[SteeringComponent] canvas_form_submit ignored (read-only) canvas_id=#{inspect(params["canvas-id"])} node_id=#{inspect(params["node-id"])}"
    )

    {:noreply, socket}
  end

  def handle_event("send_steering_message", %{"steering" => %{"text" => content}}, socket) do
    content = String.trim(content || "")
    attachment_intended? = steering_attachment_intended?(socket)

    cond do
      content == "" and not attachment_intended? ->
        {:noreply,
         put_steering_feedback(socket, :error, "Enter a message or attach a file before sending.")}

      # The selected task, re-asked on every send (task 01a1472d stage 1):
      # a viewer who may no longer `tasks.write` it posts nothing.
      is_nil(PlatformWeb.Tasks.Selection.writable_selected_task(socket)) ->
        {:noreply, put_steering_feedback(socket, :error, "Task not found.")}

      is_nil(socket.assigns.execution_space_id) ->
        {:noreply,
         put_steering_feedback(
           socket,
           :error,
           "This task does not have an execution log yet, so there is nowhere to send steering."
         )}

      true ->
        post_steering(socket, content, attachment_intended?)
    end
  end

  defp open_output_canvas(socket, canvas_id) do
    canvas = Enum.find(socket.assigns.output_canvases, &(&1.id == canvas_id))
    if canvas, do: send(self(), {:steering_open_canvas, canvas})
    {:noreply, socket}
  end

  defp post_steering(socket, content, attachment_intended?) do
    space_id = socket.assigns.execution_space_id

    participant =
      socket.assigns.execution_participant ||
        resolve_execution_participant(space_id, socket.assigns.current_user_id)

    if participant do
      attrs = steering_message_attrs(space_id, participant.id, content)

      result =
        if attachment_intended? do
          case persist_steering_attachments(socket) do
            {:ok, pending_attachments} ->
              Chat.post_message_with_attachments(attrs, pending_attachments)

            {:error, :storage_failed} ->
              {:error, :storage_failed}
          end
        else
          case Chat.post_message(attrs) do
            {:ok, msg} -> {:ok, msg, []}
            error -> error
          end
        end

      handle_post_result(result, socket, participant)
    else
      {:noreply,
       put_steering_feedback(
         socket,
         :error,
         "Could not join the execution log as the current user. Refresh and try again."
       )}
    end
  end

  defp handle_post_result({:ok, _msg, _attachments}, socket, participant),
    do: {:noreply, sent_ok(socket, participant)}

  defp handle_post_result({:error, :uploads_in_progress}, socket, _participant) do
    {:noreply,
     put_steering_feedback(
       socket,
       :error,
       "Wait for attachments to finish uploading before sending steering."
     )}
  end

  defp handle_post_result({:error, :storage_failed}, socket, _participant) do
    {:noreply,
     socket
     |> assign(:steering_upload_previews, [])
     |> assign(:steering_attachment_intended, false)
     |> put_steering_feedback(
       :error,
       "The attachment upload could not be stored in the execution log. Please try again."
     )}
  end

  defp handle_post_result({:error, _reason}, socket, _participant) do
    {:noreply,
     put_steering_feedback(
       socket,
       :error,
       "The steering message was not posted to the execution log. Please try again."
     )}
  end

  defp sent_ok(socket, participant) do
    socket
    |> assign(:execution_participant, participant)
    |> assign(:steering_compose_form, to_form(%{"text" => ""}, as: :steering))
    |> assign(:steering_upload_previews, [])
    |> assign(:steering_attachment_intended, false)
    |> assign(:mention_suggestions, [])
    |> put_steering_feedback(:success, "Steering sent to the execution log.")
    |> push_event("compose_reset", %{})
  end

  # ── Loading ────────────────────────────────────────────────────────────

  defp load_for_task(socket) do
    task = socket.assigns[:selected_task]

    {space_id, log} =
      if task, do: load_execution_log(task.id), else: {nil, []}

    send(self(), {:steering_space_changed, space_id})

    participant =
      if space_id,
        do: resolve_execution_participant(space_id, socket.assigns[:current_user_id]),
        else: nil

    socket
    |> assign(:execution_space_id, space_id)
    |> assign(:execution_log, log)
    |> assign(:execution_participant, participant)
    |> assign(:steering_compose_form, to_form(%{"text" => ""}, as: :steering))
    |> assign(:steering_feedback, nil)
    |> assign(:steering_upload_previews, [])
    |> assign(:steering_attachment_intended, false)
    |> assign(:mention_suggestions, [])
    |> assign(:output_canvases, load_output_canvases(space_id))
    |> assign(:review_output_ids, review_canvas_ids(socket.assigns[:pending_reviews]))
    |> assign(:participants_map, nil)
  end

  defp reload_log_and_outputs(socket) do
    case socket.assigns[:execution_space_id] do
      nil ->
        socket

      space_id ->
        socket
        |> assign(:execution_log, ExecutionSpace.list_messages_with_participants(space_id))
        |> assign(:output_canvases, load_output_canvases(space_id))
    end
  end

  defp load_execution_log(task_id) do
    case ExecutionSpace.find_by_task_id(task_id) do
      %{id: space_id} -> {space_id, ExecutionSpace.list_messages_with_participants(space_id)}
      nil -> {nil, []}
    end
  end

  defp load_output_canvases(nil), do: []
  defp load_output_canvases(space_id), do: Chat.list_canvases(space_id)

  defp review_canvas_ids(pending_reviews) when is_list(pending_reviews) do
    pending_reviews
    |> Enum.flat_map(&(&1.items || []))
    |> Enum.map(& &1.canvas_id)
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  defp review_canvas_ids(_), do: MapSet.new()

  # Identity map for the execution space, in the SAME shape ChatLive's
  # `:participants_map` carries, so `MentionsHooks.build_suggestions/3`
  # (archived-drop, `@here` sentinel, truncation) applies unchanged.
  # Built lazily on first mention query and memoised per selected task.
  defp steering_participants_map(socket) do
    case socket.assigns[:participants_map] do
      %{} = map -> map
      _ -> build_participants_map(socket.assigns[:execution_space_id])
    end
  end

  defp build_participants_map(nil), do: %{}

  defp build_participants_map(space_id) do
    participants = Chat.list_participants(space_id)

    users_by_id =
      participants
      |> Enum.filter(&(&1.participant_type == "user"))
      |> Enum.map(& &1.participant_id)
      |> Accounts.get_users_map(include_archived: true)

    PresenceHooks.build_participant_identity_map(
      participants,
      users_by_id,
      Chat.agent_avatar_map_for_participants(participants)
    )
  end

  # ── Steering upload helpers (mirrors ChatLive.UploadHooks) ─────────────

  defp handle_steering_attachment_progress(:steering_attachments, entry, socket) do
    preview = %{
      ref: entry.ref,
      client_name: entry.client_name,
      client_type: entry.client_type,
      progress: entry.progress
    }

    {:noreply,
     assign(
       socket,
       :steering_upload_previews,
       [preview | Enum.reject(socket.assigns.steering_upload_previews, &(&1.ref == preview.ref))]
     )
     |> assign(:steering_attachment_intended, true)}
  end

  defp has_steering_upload_entries?(socket) do
    active_steering_upload_entries(socket) != [] or socket.assigns.steering_upload_previews != []
  end

  defp steering_attachment_intended?(socket) do
    socket.assigns.steering_attachment_intended or has_steering_upload_entries?(socket)
  end

  defp active_steering_upload_entries(socket) do
    case get_in(socket.assigns, [:uploads, :steering_attachments]) do
      %{entries: entries} when is_list(entries) -> entries
      _ -> []
    end
  end

  defp persist_steering_attachments(socket) do
    case uploaded_entries(socket, :steering_attachments) do
      {[], [_ | _]} ->
        {:error, :uploads_in_progress}

      {[], []} ->
        if steering_attachment_intended?(socket) do
          {:error, :storage_failed}
        else
          {:ok, []}
        end

      _ ->
        consume_and_persist(socket)
    end
  end

  defp consume_and_persist(socket) do
    results =
      consume_uploaded_entries(socket, :steering_attachments, fn %{path: path}, entry ->
        result =
          case AttachmentStorage.persist_upload(path, entry.client_name, entry.client_type) do
            {:ok, attrs} -> {:ok, attrs}
            {:error, _reason} -> {:error, :storage_failed}
          end

        {:ok, result}
      end)

    {ok_results, error_results} = Enum.split_with(results, &match?({:ok, _}, &1))
    attachments = Enum.map(ok_results, fn {:ok, attrs} -> attrs end)

    if error_results == [] do
      {:ok, attachments}
    else
      AttachmentStorage.delete_many(attachments)
      {:error, :storage_failed}
    end
  end

  defp sync_steering_attachment_intent(socket) do
    assign(socket, :steering_attachment_intended, has_steering_upload_entries?(socket))
  end

  defp steering_message_attrs(space_id, participant_id, content) do
    %{
      space_id: space_id,
      participant_id: participant_id,
      content_type: "text",
      content: content,
      log_only: false,
      metadata: %{
        "kind" => "steering",
        "source" => "tasks_live",
        "delivery" => "engagement"
      }
    }
  end

  defp put_steering_feedback(socket, kind, message) do
    assign(socket, :steering_feedback, %{kind: kind, message: message})
  end

  defp resolve_execution_participant(space_id, user_id)
       when is_binary(space_id) and is_binary(user_id) do
    existing =
      space_id
      |> Chat.list_participants(include_left: true)
      |> Enum.find(fn p -> p.participant_id == user_id end)

    case existing do
      nil -> join_execution_space(space_id, user_id)
      %{left_at: nil} = p -> p
      p -> rejoin_execution_space(p)
    end
  end

  defp resolve_execution_participant(_space_id, _user_id), do: nil

  defp join_execution_space(space_id, user_id) do
    display_name =
      case Accounts.get_user(user_id) do
        %{name: name} when is_binary(name) and name != "" -> name
        %{email: email} when is_binary(email) -> email
        _ -> "User"
      end

    case Chat.add_participant(space_id, %{
           participant_type: "user",
           participant_id: user_id,
           display_name: display_name,
           joined_at: DateTime.utc_now()
         }) do
      {:ok, p} -> p
      {:error, _} -> nil
    end
  end

  defp rejoin_execution_space(p) do
    case Chat.update_participant(p, %{left_at: nil, joined_at: DateTime.utc_now()}) do
      {:ok, rejoined} -> rejoined
      {:error, _} -> p
    end
  end

  # ── Render helpers (moved with their markup) ───────────────────────────

  defp format_log_timestamp(nil), do: ""

  defp format_log_timestamp(%DateTime{} = dt) do
    now = DateTime.utc_now()

    if Date.compare(DateTime.to_date(dt), DateTime.to_date(now)) == :eq do
      # Today — just HH:MM
      Calendar.strftime(dt, "%H:%M")
    else
      # Older — Mon DD HH:MM
      Calendar.strftime(dt, "%b %d %H:%M")
    end
  end

  defp log_sender_color("agent", "system"), do: "text-warning"
  defp log_sender_color("agent", _content_type), do: "text-info"
  defp log_sender_color("user", _content_type), do: "text-primary"
  defp log_sender_color(_sender_type, _content_type), do: "text-base-content/60"

  defp upload_error_to_string(:too_large), do: "File is too large"
  defp upload_error_to_string(:too_many_files), do: "Too many files selected"
  defp upload_error_to_string(:not_accepted), do: "File type is not accepted"
  defp upload_error_to_string(error), do: inspect(error)
end
