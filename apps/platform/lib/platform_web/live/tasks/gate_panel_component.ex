defmodule PlatformWeb.Tasks.GatePanelComponent do
  @moduledoc """
  The Reviews & Validation ("gate") concern of the Tasks surface, extracted
  from `PlatformWeb.TasksLive` by task 01a008f6 stage 6.

  ## Why `gate_*` and not `review_*`

  Named for the *gate* it operates, not for the noun on the screen. Three
  different things in this codebase are called a "review": the
  `manual_approval` validation gate, the `ReviewRequests` rows that satisfy
  it, and the stack-level review rollup (which belongs to
  `StacksComponent`, not here). `review_*` would have collided with all
  three; `gate_*` names exactly one. Stage 4 already renamed the canvas
  events on this reasoning (`open_review_canvas` / `canvas_open` →
  `gate_canvas_open`) — this module finishes the job for the module name
  and the rest of the event namespace.

  ## Why a form, and not `phx-value-feedback`

  The rejection reason is submitted as a real `<form>` field. It used to ride
  on a `phx-value-feedback` attribute that the server rendered from a
  `:gate_feedback_text` assign fed by `phx-keyup`, and that lost data on
  every rejection where the reviewer typed and clicked without pausing: the
  attribute only carries keystrokes whose round-trip had already been
  re-rendered into the DOM, so the last few characters — and any text the
  reviewer pasted, which fires no keyup at all — never reached the server.
  A production rejection stored 43 characters of a longer sentence, cut
  mid-phrase, with no error shown to anyone.

  A form field is serialized by the browser from the live DOM at click time,
  so the value is whole regardless of latency, paste, IME, or autofill.
  `:gate_feedback_text` survives only to repopulate the textarea across
  unrelated re-renders; it is never the source of the submitted value.

  ## Ownership

  Assigns owned here — the shell holds none of them:

    * `:gate_feedback_open` — MapSet of review-item ids whose feedback
      textarea is expanded.
    * `:gate_feedback_text` — map of review-item id → in-progress feedback.
    * `:gate_feedback_error` — map of review-item id → inline validation
      message. Rendered in the drawer rather than flashed: `put_flash/3` from
      a live component does not reach the shell's flash container, so a
      flashed refusal would be invisible — which is the failure mode this
      whole change exists to remove.
    * `:gate_superseded_expanded` — the "Earlier submissions" disclosure.
    * `:gate_canvas` — the review canvas currently open in the modal. Set
      either by `gate_canvas_open` here, or by the shell forwarding
      `{:steering_open_canvas, canvas}` as a `send_update`, because
      `SteeringComponent` resolves an *output* canvas that this modal is
      also the renderer for.

  Read-only attrs: `pending_reviews`, `superseded_reviews`,
  `review_canvases`. Those are loaded by the shell's `reload_selected_task/1`
  because the same lists feed `SteeringComponent`; duplicating the queries
  here would double the round-trips on every selection change for no
  ownership gain.

  Events owned here (7 distinct — the planner's count of 9 double-counted
  `submit_review_feedback` / `update_review_feedback_text` against their
  markup sites): `gate_approve_item`, `gate_submit_feedback`,
  `gate_toggle_feedback`, `gate_feedback_changed`, `gate_toggle_superseded`,
  `gate_canvas_open`, `gate_canvas_close`.

  Approving or rejecting an item mutates data the *board* renders, so both
  report up with `send(self(), {:gate_reviews_changed})` rather than
  reaching for `refresh_board/1`; every purely-visual toggle stays local.

  ## Render regions

  Two, and they are not adjacent:

    * The Pending-Review + Earlier-submissions block, which used to be
      inline in `TaskDetailComponent` (`task_detail_component.ex`
      1588-1701 at `74448b78`) and renders through `:panel` in the detail
      body.
    * The review-canvas modal, which used to be inline in the shell
      template (`tasks_live.html.heex` 1470-1502 at `74448b78`). It is
      `fixed inset-0 z-50` and no ancestor between here and `<body>`
      establishes a containing block (the detail aside is `fixed` with no
      transform), so nesting it under the panel is visually identical to
      the shell-root placement it came from.

  The planner's line references for this concern (3535-3574) were written
  against the pre-stage-2 6,027-line shell and point past the end of both
  files today; the ranges above are the re-located actuals.
  """
  use PlatformWeb, :live_component

  require Logger

  alias Platform.Chat.Canvas
  alias Platform.Tasks.ReviewRequests

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:gate_feedback_open, MapSet.new())
     |> assign(:gate_feedback_text, %{})
     |> assign(:gate_feedback_error, %{})
     |> assign(:gate_superseded_expanded, false)
     |> assign(:gate_canvas, nil)}
  end

  @impl true
  def update(%{steering_canvas: canvas}, socket) do
    # SteeringComponent resolved an OUTPUT canvas and the shell forwarded
    # it here. Same modal, different source list — deliberately NOT
    # re-resolved against `review_canvases`, which does not contain it.
    {:ok, assign(socket, :gate_canvas, canvas)}
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # Keep an already-open review canvas pointing at the freshest struct
    # when the review set is reloaded; drop it if the reload removed it.
    # This is the logic that used to live in the shell's
    # `reload_selected_task/1`.
    {:ok, assign(socket, :gate_canvas, refresh_open_canvas(socket))}
  end

  defp refresh_open_canvas(socket) do
    case socket.assigns[:gate_canvas] do
      %Canvas{id: id} = open -> Map.get(socket.assigns[:review_canvases] || %{}, id) || open
      other -> other
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="contents">
      <%!-- Pending Review --%>
      <div :if={@pending_reviews != []} class="space-y-2">
        <div class="flex items-center gap-2">
          <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
            Pending Review
          </h3>
          <span class="badge badge-warning badge-xs">{length(@pending_reviews)}</span>
        </div>

        <div
          :for={review <- @pending_reviews}
          class="rounded-box border border-warning bg-warning/5 p-3 space-y-3"
        >
          <div class="flex items-center justify-between text-xs text-base-content/50">
            <span :if={review.submitted_by}>
              Submitted by {review.submitted_by}
            </span>
            <span>{Calendar.strftime(review.inserted_at, "%b %d, %H:%M")}</span>
          </div>

          <div
            :for={item <- review.items}
            class="rounded-lg border border-edge bg-base-100 p-3 space-y-2"
          >
            <div class="flex items-center justify-between">
              <span class="text-sm font-medium">{item.label}</span>
              <%= cond do %>
                <% item.status == "approved" -> %>
                  <span class="badge badge-success badge-xs gap-1">
                    <span class="hero-check-circle size-3"></span> Approved
                  </span>
                <% item.status == "needs_revision" -> %>
                  <span class="badge badge-warning badge-xs">Needs revision</span>
                <% true -> %>
                  <span class="badge badge-ghost badge-xs">Pending</span>
              <% end %>
            </div>

            <p :if={item.content} class="text-xs text-base-content/70 whitespace-pre-wrap">
              {item.content}
            </p>

            <div :if={item.canvas_id} class="flex items-center gap-2 text-xs">
              <span class="badge badge-outline badge-xs gap-1">
                <span class="hero-squares-2x2 size-3"></span> Linked output
              </span>
              <button
                class="btn btn-ghost btn-xs"
                phx-click="gate_canvas_open"
                phx-target={@myself}
                phx-value-canvas-id={item.canvas_id}
              >
                View output
              </button>
            </div>

            <%!-- Feedback display for rejected items --%>
            <div
              :if={item.status == "needs_revision" && item.feedback}
              class="rounded bg-warning/10 p-2 text-xs text-warning-content"
            >
              <span class="font-medium">Feedback:</span> {item.feedback}
            </div>

            <%!-- Action buttons for pending items --%>
            <div :if={item.status == "pending"} class="flex items-center gap-2">
              <button
                class="btn btn-success btn-xs"
                phx-click="gate_approve_item"
                phx-target={@myself}
                phx-value-item-id={item.id}
              >
                <span class="hero-check size-3"></span> Approve
              </button>
              <button
                class="btn btn-ghost btn-xs"
                phx-click="gate_toggle_feedback"
                phx-target={@myself}
                phx-value-item-id={item.id}
              >
                <span class="hero-chat-bubble-left size-3"></span> Send feedback
              </button>
            </div>

            <%!-- Feedback textarea (toggled) --%>
            <div
              :if={item.status == "pending" && MapSet.member?(@gate_feedback_open, item.id)}
              class="space-y-2"
            >
              <%!--
                The reason travels as a real form field, NOT as a
                server-rendered `phx-value-feedback` echo of keystroke
                events. See the "Why a form" note in the @moduledoc: the
                echo lost whatever the reviewer typed in the last round-trip
                before they clicked, and lost pasted text entirely.
              --%>
              <form
                phx-submit="gate_submit_feedback"
                phx-change="gate_feedback_changed"
                phx-target={@myself}
              >
                <input type="hidden" name="item-id" value={item.id} />
                <textarea
                  name="feedback"
                  class="textarea textarea-bordered textarea-xs w-full"
                  aria-label="Review feedback"
                  placeholder="Describe what needs to change..."
                  phx-debounce="blur"
                >{Map.get(@gate_feedback_text, item.id, "")}</textarea>
                <p
                  :if={Map.has_key?(@gate_feedback_error, item.id)}
                  class="mt-1 text-xs text-error"
                  role="alert"
                >
                  {Map.fetch!(@gate_feedback_error, item.id)}
                </p>
                <button type="submit" class="btn btn-warning btn-xs mt-2">
                  Submit Feedback
                </button>
              </form>
            </div>
          </div>
        </div>
      </div>

      <%!-- Earlier submissions (task 019fed8d stage 3, defect 2). The markup
           and its two label helpers live in
           `PlatformWeb.Components.SupersededReviewSubmissions`; this component
           keeps only the assign and the toggle event. --%>
      <PlatformWeb.Components.SupersededReviewSubmissions.superseded_review_submissions
        :if={@superseded_reviews != []}
        reviews={@superseded_reviews}
        expanded={@gate_superseded_expanded}
        target={@myself}
      />

      <%!-- Review canvas modal. Was inline in the shell template; renders
           here now so the canvas assign has exactly one owner. --%>
      <div :if={@gate_canvas} class="fixed inset-0 z-50 flex items-center justify-center px-4 py-6">
        <div class="absolute inset-0 bg-black/50" phx-click="gate_canvas_close" phx-target={@myself} />
        <div class="relative z-10 flex max-h-[90vh] w-full max-w-6xl flex-col overflow-hidden rounded-2xl border border-edge bg-base-100 shadow-2xl">
          <div class="flex items-center justify-between border-b border-edge px-4 py-3">
            <div class="min-w-0">
              <div class="truncate text-sm font-semibold">
                {@gate_canvas.title || "Review canvas"}
              </div>
              <div class="text-xs text-base-content/60">
                {Platform.Chat.CanvasDocument.root_kind(@gate_canvas.document) || "canvas"}
              </div>
            </div>
            <button
              class="btn btn-ghost btn-sm btn-square"
              phx-click="gate_canvas_close"
              phx-target={@myself}
              aria-label="Close review canvas"
            >
              <span class="hero-x-mark size-4"></span>
            </button>
          </div>
          <div class="overflow-auto p-4">
            <PlatformWeb.Chat.CanvasRenderer.canvas_document
              canvas={@gate_canvas}
              show_header={false}
              dom_id_base="tasks-review-modal"
              event_target={@myself}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("gate_approve_item", %{"item-id" => item_id}, socket) do
    reviewed_by = socket.assigns[:current_user_id] || "unknown"

    case ReviewRequests.approve_item(item_id, reviewed_by) do
      {:ok, _} ->
        send(self(), {:gate_reviews_changed})
        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to approve review item.")}
    end
  end

  # `feedback` arrives as a form field serialized from the live DOM at submit
  # time, so it is whole by construction. Do NOT reintroduce a
  # `phx-value-feedback` attribute here: that reads a server-rendered echo of
  # earlier keystrokes and silently drops the tail (see @moduledoc).
  def handle_event(
        "gate_submit_feedback",
        %{"item-id" => item_id, "feedback" => feedback},
        socket
      ) do
    reviewed_by = socket.assigns[:current_user_id] || "unknown"

    if String.trim(feedback) == "" do
      {:noreply,
       socket
       |> assign(
         :gate_feedback_text,
         Map.put(socket.assigns.gate_feedback_text, item_id, feedback)
       )
       |> assign(
         :gate_feedback_error,
         Map.put(
           socket.assigns.gate_feedback_error,
           item_id,
           "Enter a reason before sending feedback."
         )
       )}
    else
      submit_feedback(socket, item_id, reviewed_by, feedback)
    end
  end

  def handle_event("gate_toggle_superseded", _params, socket) do
    {:noreply,
     assign(socket, :gate_superseded_expanded, !socket.assigns.gate_superseded_expanded)}
  end

  def handle_event("gate_toggle_feedback", %{"item-id" => item_id}, socket) do
    open = socket.assigns.gate_feedback_open

    updated =
      if MapSet.member?(open, item_id),
        do: MapSet.delete(open, item_id),
        else: MapSet.put(open, item_id)

    {:noreply, assign(socket, :gate_feedback_open, updated)}
  end

  def handle_event("gate_canvas_open", %{"canvas-id" => canvas_id}, socket) do
    canvas = Map.get(socket.assigns[:review_canvases] || %{}, canvas_id)
    {:noreply, assign(socket, :gate_canvas, canvas)}
  end

  def handle_event("gate_canvas_close", _params, socket) do
    {:noreply, assign(socket, :gate_canvas, nil)}
  end

  # Interactive nodes in the review-canvas modal (action_row buttons, forms)
  # are targeted here via `event_target={@myself}`. Untargeted they reached
  # TasksLive, which has no clause for either event: FunctionClauseError.
  # Read-only no-op, like CanvasLive's: acting on the click (ChatLive's
  # `CanvasServer.emit_event`) is an agent-visible signal that would need its
  # own authorization decision on this page. Two literal heads, not a guarded
  # clause, so TasksLiveEventWiringTest can see them.
  def handle_event("canvas_action_click", params, socket) do
    Logger.info(
      "[GatePanelComponent] canvas_action_click ignored (read-only) canvas_id=#{inspect(params["canvas-id"])} node_id=#{inspect(params["node-id"])} action=#{inspect(params["action"])}"
    )

    {:noreply, socket}
  end

  def handle_event("canvas_form_submit", params, socket) do
    Logger.info(
      "[GatePanelComponent] canvas_form_submit ignored (read-only) canvas_id=#{inspect(params["canvas-id"])} node_id=#{inspect(params["node-id"])}"
    )

    {:noreply, socket}
  end

  # Draft-preservation only. `phx-change` keeps the textarea populated across
  # unrelated re-renders; it is NOT the source of the submitted value.
  def handle_event("gate_feedback_changed", %{"item-id" => item_id, "feedback" => text}, socket) do
    {:noreply,
     socket
     |> assign(
       :gate_feedback_text,
       Map.put(socket.assigns.gate_feedback_text, item_id, text)
     )
     |> assign(
       :gate_feedback_error,
       Map.delete(socket.assigns.gate_feedback_error, item_id)
     )}
  end

  defp submit_feedback(socket, item_id, reviewed_by, feedback) do
    case ReviewRequests.reject_item(item_id, reviewed_by, feedback) do
      {:ok, _} ->
        send(self(), {:gate_reviews_changed})

        {:noreply,
         socket
         |> assign(:gate_feedback_text, Map.delete(socket.assigns.gate_feedback_text, item_id))
         |> assign(
           :gate_feedback_error,
           Map.delete(socket.assigns.gate_feedback_error, item_id)
         )
         |> assign(
           :gate_feedback_open,
           MapSet.delete(socket.assigns.gate_feedback_open, item_id)
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to submit feedback.")}
    end
  end
end
