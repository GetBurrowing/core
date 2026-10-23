defmodule PlatformWeb.SocialCardComponent do
  @moduledoc """
  The interactive approval card (task 01a140a9-31b0, Social 3/7), rendered
  by the `social_post_card` kind (`Platform.Social.CanvasKinds.SocialPostCard`)
  inside any LiveView that renders canvases (ChatLive, CanvasLive, ...).

  ## Clicks run in the clicker's own session

  A LiveComponent runs in its parent LiveView's process, so Approve, Edit
  and Reject execute in the clicking human's own session. Each click:

    * re-reads the user from the database (`Platform.Accounts.get_user/1`)
      from the renderer's `viewer`, never a cached struct;
    * names the card by the CLICKED canvas id (`phx-value-canvas-id`, from
      the renderer's `canvas_id` assign, never from document props), so a
      lookalike canvas holding a real `card_id` decides nothing;
    * carries the content `fingerprint` the card rendered, so an edit the
      human did not see is refused (`:post_changed`);
    * goes through `Platform.Social.Approvals.decide_*`, where every rule
      is enforced. This module only reflects refusals as plain flash copy.

  The open/closed state of the inline editor and the reject box, and the
  reject text (which keeps "Reject post" disabled until it has text), are
  socket-local to this card.

  ## Who sees what

  `Approvals.card_view/2` decides. A non-approver (an agent, a human not on
  the list) gets the status line only: no buttons at all (not disabled
  ones), no preview text, no media. On an owned account (task 01a14ce1,
  stage 3) the owner sees a "Posts as you" meta line, and a profile
  approver sees the post read-only with a "Waiting for <owner>" info pill
  in place of the action row: no buttons, not disabled ones.

  ## Events

  `social_card_approve`, `social_card_edit_open`, `social_card_edit_save`,
  `social_card_edit_cancel`, `social_card_reject_open`,
  `social_card_reject_change`, `social_card_reject_submit`,
  `social_card_reject_cancel`, `social_card_retry_publish` (task
  01a165f1), all targeted at this component
  (`phx-target={@myself}`), so no other hook sees them. A refusal is shown
  as a notice ON the card (`data-role="social-card-notice"`, `role="alert"`)
  rather than the page flash: a LiveComponent's flash does not reach the
  parent page without a redirect. There is no `social_card_tab` event: no
  stack member groups one post across platforms (one post per account), so
  a card has exactly one platform tab.

  ## Refused publish (task 01a165f1)

  An approved post refused before the vendor shows "Not published" (or
  "Waiting to retry" when rate limited) in place of "Approved", the reason
  in plain words, when it was refused, and, for an approver only, the one
  action that fixes it (`card_view/2`'s `refusal.action`). Retry publish and
  Publish now call `Platform.Social.Publishing.retry_publish/3` as the
  freshly re-read clicker. A second refusal updates the reason line in
  place: no notice, no stacked history.
  """
  use Phoenix.LiveComponent

  import PlatformWeb.CoreComponents, only: [icon: 1]

  alias Platform.Social.{Approvals, Publishing}

  @refusals %{
    already_decided: "Someone already decided this post.",
    card_changed: "This card changed since it was posted; reload.",
    not_a_social_card: "This card is not a real approval card.",
    not_an_approver: "You are not an approver for this account.",
    not_the_owner: "Only the person this account posts as can decide this post.",
    not_a_human: "You are not an approver for this account.",
    approver_no_access: "Your access to this account was removed.",
    approver_archived: "Your access to this account was removed.",
    draft_only: "This account is draft-only; copy the text and post it by hand.",
    post_changed: "The post changed since you opened it; read the new text and decide again.",
    reason_required: "Say what should change before rejecting.",
    not_refused: "This post isn't waiting to publish any more.",
    not_found: "This post is no longer available."
  }

  # A retry refused for the same reason again (task 01a165f1): the reason
  # line updates in place, so no notice is stacked on top of it.
  @refused_again [:rate_limited, :account_archived, :publisher_not_configured]

  @doc false
  def refusal_copy(reason, view \\ %{})

  # Task 01a14ce1 stage 3: the canvas copy names the owner.
  def refusal_copy(:not_the_owner, %{owner_name: name}) when is_binary(name),
    do: "Only #{name} can approve posts to their account."

  def refusal_copy({:wait_until, %DateTime{} = at}, _view),
    do: "This post goes out at #{Calendar.strftime(at, "%H:%M")}."

  def refusal_copy(reason, _view),
    do: Map.get(@refusals, reason, "That did not work: #{inspect(reason)}")

  @impl true
  def mount(socket) do
    {:ok, assign(socket, mode: nil, reject_text: "", edit_text: nil, notice: nil)}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(Map.take(assigns, [:id, :card_id, :rev, :canvas_id, :viewer]))
      |> refresh()

    {:ok, socket}
  end

  defp refresh(socket) do
    view = Approvals.card_view(socket.assigns.card_id, socket.assigns.viewer)

    # A decided card, or one this viewer may no longer act on, closes the forms.
    mode = if Map.get(view, :actions, []) == [], do: nil, else: socket.assigns.mode
    assign(socket, view: view, mode: mode)
  end

  # ── Events ────────────────────────────────────────────────────────────

  @impl true
  def handle_event("social_card_approve", params, socket) do
    with_clicker(socket, fn user ->
      Approvals.decide_approve(params["canvas-id"], user, params["fingerprint"])
    end)
  end

  def handle_event("social_card_edit_open", _params, socket) do
    if :edit in Map.get(socket.assigns.view, :actions, []) do
      {:noreply, assign(socket, mode: :edit, edit_text: socket.assigns.view.body)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("social_card_edit_cancel", _params, socket),
    do: {:noreply, assign(socket, mode: nil, edit_text: nil)}

  def handle_event("social_card_edit_save", params, socket) do
    with_clicker(socket, fn user ->
      Approvals.decide_edit(
        params["canvas-id"],
        user,
        %{body: params["body"] || ""},
        params["fingerprint"]
      )
    end)
  end

  def handle_event("social_card_reject_open", _params, socket) do
    if :reject in Map.get(socket.assigns.view, :actions, []),
      do: {:noreply, assign(socket, mode: :reject, reject_text: "")},
      else: {:noreply, socket}
  end

  def handle_event("social_card_reject_change", params, socket),
    do: {:noreply, assign(socket, reject_text: params["reason"] || "")}

  def handle_event("social_card_reject_cancel", _params, socket),
    do: {:noreply, assign(socket, mode: nil, reject_text: "")}

  def handle_event("social_card_reject_submit", params, socket) do
    with_clicker(socket, fn user ->
      Approvals.decide_reject(params["canvas-id"], user, params["reason"], params["fingerprint"])
    end)
  end

  # Task 01a165f1: Retry publish / Publish now on a refused approved post,
  # as the clicker re-read from the database now. retry_publish/3 re-checks
  # the approver rule and the rate limit; the button is only a hint.
  def handle_event("social_card_retry_publish", _params, socket) do
    user =
      case socket.assigns.viewer do
        {:user, id} -> Platform.Accounts.get_user(id)
        _ -> nil
      end

    refusal = socket.assigns.view[:refusal]

    result =
      cond do
        is_nil(user) -> {:error, :not_an_approver}
        is_nil(refusal) -> {:error, :not_refused}
        true -> Publishing.retry_publish(refusal.org_id, refusal.post_id, user.id)
      end

    notice =
      case result do
        {:ok, _post} -> nil
        {:error, {:media_rejected, _}} -> nil
        {:error, {:publish_failed, _}} -> nil
        {:error, reason} when reason in @refused_again -> nil
        {:error, reason} -> refusal_copy(reason, socket.assigns.view)
      end

    {:noreply, socket |> assign(notice: notice) |> refresh()}
  end

  # The user is re-read from the database at click time.
  defp with_clicker(socket, decide) do
    user =
      case socket.assigns.viewer do
        {:user, id} -> Platform.Accounts.get_user(id)
        _ -> nil
      end

    result = if user, do: decide.(user), else: {:error, :not_an_approver}

    socket =
      case result do
        {:ok, _} -> assign(socket, mode: nil, reject_text: "", edit_text: nil, notice: nil)
        {:error, reason} -> assign(socket, notice: refusal_copy(reason, socket.assigns.view))
      end

    {:noreply, refresh(socket)}
  end

  # ── Render ────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      data-role="social-card"
      data-card-role={@view.role}
      data-card-state={@view[:state]}
      class="w-full max-w-xl space-y-3 rounded-xl border border-edge bg-base-100 p-3 text-sm text-base-content sm:p-4"
    >
      <.status_header view={@view} />

      <p
        :if={@view[:posts_as]}
        data-role="social-card-posts-as"
        class="-mt-2 text-sm text-subtle"
      >
        {@view.posts_as}
      </p>

      <.refusal :if={@view[:refusal]} refusal={@view.refusal} myself={@myself} />

      <p
        :if={@notice}
        role="alert"
        data-role="social-card-notice"
        class="rounded-lg border border-error/40 px-3 py-2 text-sm text-error"
      >
        {@notice}
      </p>

      <%= if @view.role in [:approver, :waiting] do %>
        <.preview
          view={@view}
          myself={@myself}
          mode={if @view.role == :approver, do: @mode}
          edit_text={@edit_text}
          canvas_id={@canvas_id}
        />

        <p
          :if={@view.provenance}
          data-role="social-card-provenance"
          class="text-sm text-subtle"
        >
          {@view.provenance}
        </p>
        <p :if={@view.edited_by} data-role="social-card-edited" class="text-sm text-subtle">
          Edited by {@view.edited_by}
        </p>
        <p
          :if={@view.draft_only? and @view.actions != []}
          data-role="social-card-by-hand"
          class="text-sm text-subtle"
        >
          Post this by hand on {@view.platform_label}
        </p>

        <.reject_box
          :if={@mode == :reject}
          myself={@myself}
          canvas_id={@canvas_id}
          view={@view}
          reject_text={@reject_text}
        />

        <.actions
          :if={@view.actions != [] and @mode == nil and is_binary(@canvas_id)}
          view={@view}
          myself={@myself}
          canvas_id={@canvas_id}
          id={@id}
        />

        <div
          :if={@view.role == :waiting and @view[:waiting?]}
          data-role="social-card-waiting"
          class="flex items-center"
        >
          <span class="badge badge-info badge-sm font-medium">Waiting for {@view.owner_name}</span>
        </div>
      <% end %>
    </div>
    """
  end

  attr :view, :map, required: true

  defp status_header(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
      <%= if @view.status[:dot] do %>
        <%!-- Task 01a165f1: a refused publish. The colour is on the dot only;
           the label stays base-content. --%>
        <span
          data-role="social-card-status"
          data-dot={@view.status.dot}
          class="inline-flex items-center gap-1.5 text-sm font-medium text-base-content"
        >
          <span
            aria-hidden="true"
            class={[
              "inline-block size-2 shrink-0 rounded-full",
              if(@view.status.dot == :warning, do: "bg-warning", else: "bg-error")
            ]}
          >
          </span>
          {@view.status.text}
        </span>
      <% else %>
        <%= if @view.status.tone == :warning do %>
          <span data-role="social-card-status" class="badge badge-warning badge-sm font-medium">
            {@view.status.text}
          </span>
        <% else %>
          <span
            data-role="social-card-status"
            class={["text-sm font-medium", tone_class(@view.status.tone)]}
          >
            {@view.status.text}
          </span>
        <% end %>
      <% end %>
      <span :if={@view[:profile_name]} class="text-sm font-semibold">{@view.profile_name}</span>
      <span :if={@view[:handle]} class="text-sm text-subtle">{@view.handle}</span>
      <span
        :if={@view[:found]}
        data-role="social-card-time"
        class="ml-auto font-mono text-xs text-subtle"
      >
        {schedule(@view)}
      </span>
      <a
        :if={@view.status[:external_url]}
        href={@view.status.external_url}
        target="_blank"
        rel="noopener noreferrer"
        data-role="social-card-view-post"
        class="link text-sm text-success"
      >
        View post
      </a>
    </div>
    """
  end

  attr :refusal, :map, required: true
  attr :myself, :any, required: true

  # Task 01a165f1, canvas 01a165f1-f2a4 node m2: the reason line, when it
  # was refused, and at most one action. Viewers get no action at all.
  defp refusal(assigns) do
    ~H"""
    <div
      data-role="social-card-refusal"
      data-refusal={@refusal.kind}
      class="space-y-1.5"
    >
      <p
        data-role="social-card-refusal-reason"
        class="flex items-start gap-2 text-[15px] leading-snug text-base-content"
      >
        <.icon
          :if={@refusal.kind != :rate_limited}
          name="hero-exclamation-triangle-mini"
          class="mt-0.5 size-4 shrink-0 text-error"
        />
        <span :if={@refusal.clock}>
          {String.replace_suffix(@refusal.reason, @refusal.clock <> ".", "")}<span
            data-role="social-card-retry-clock"
            class="font-mono tabular-nums"
          >{@refusal.clock}</span>.
        </span>
        <span :if={!@refusal.clock}>{@refusal.reason}</span>
      </p>
      <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
        <span data-role="social-card-refused-at" class="text-[13px] text-base-content">
          Refused {hhmm(@refusal.refused_at)}
        </span>
        <%= case @refusal.action do %>
          <% %{href: href} = action when is_binary(href) -> %>
            <.link
              navigate={href}
              data-role="social-card-refusal-action"
              data-action={action.kind}
              class="btn btn-outline btn-sm"
            >
              {action.label}
            </.link>
          <% %{} = action -> %>
            <button
              type="button"
              phx-click="social_card_retry_publish"
              phx-target={@myself}
              phx-disable-with="Publishing"
              disabled={action.disabled?}
              data-role="social-card-refusal-action"
              data-action={action.kind}
              class="peer btn btn-outline btn-sm"
            >
              {action.label}
            </button>
            <span
              aria-hidden="true"
              data-role="social-card-retry-spinner"
              class="hidden text-base-content peer-[.phx-click-loading]:inline-flex"
            >
              <.icon name="hero-arrow-path-mini" class="size-4 animate-spin" />
            </span>
          <% nil -> %>
        <% end %>
      </div>
    </div>
    """
  end

  defp hhmm(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M")
  defp hhmm(_), do: ""

  attr :view, :map, required: true
  attr :myself, :any, required: true
  attr :mode, :atom, default: nil
  attr :edit_text, :string, default: nil
  attr :canvas_id, :string, default: nil

  defp preview(assigns) do
    ~H"""
    <div class="space-y-2">
      <div role="tablist" class="flex gap-1" data-role="social-card-tabs">
        <span
          role="tab"
          aria-selected="true"
          data-role="social-card-tab"
          data-over-limit={to_string(@view.over_limit?)}
          class={[
            "rounded border px-2 py-0.5 font-mono text-xs uppercase tracking-wide",
            if(@view.over_limit?,
              do: "border-warning text-warning",
              else: "border-edge font-medium text-base-content"
            )
          ]}
        >
          {String.upcase(@view.platform_label)}{if @view.over_limit?, do: " !"}
        </span>
      </div>

      <div
        data-role="social-card-preview"
        class="w-full space-y-2 rounded-lg border border-edge bg-base-100 p-3"
      >
        <div :for={m <- @view.media} data-role="social-card-media" class="w-full">
          <video
            :if={String.starts_with?(m.content_type || "", "video/")}
            src={m.src}
            controls
            playsinline
            preload="metadata"
            class="mx-auto block max-h-80 w-auto max-w-full rounded"
            style={aspect(m)}
          >
          </video>
          <img
            :if={!String.starts_with?(m.content_type || "", "video/")}
            src={m.src}
            alt="Post media"
            class="mx-auto block max-h-80 w-auto max-w-full rounded object-contain"
            style={aspect(m)}
          />
        </div>

        <%= if @mode == :edit do %>
          <form
            id={"social-card-edit-#{@canvas_id}"}
            phx-submit="social_card_edit_save"
            phx-target={@myself}
            data-role="social-card-editor"
            class="space-y-2"
          >
            <input type="hidden" name="canvas-id" value={@canvas_id} />
            <input type="hidden" name="fingerprint" value={@view.fingerprint} />
            <textarea
              name="body"
              rows="6"
              class="textarea textarea-bordered w-full text-base"
              aria-label="Post text"
            >{@edit_text}</textarea>
            <div class="flex items-center gap-2">
              <button
                type="button"
                phx-click="social_card_edit_cancel"
                phx-target={@myself}
                class="btn btn-ghost btn-sm"
              >
                Cancel
              </button>
              <button type="submit" class="btn btn-outline btn-sm ml-auto">Save text</button>
            </div>
          </form>
        <% else %>
          <p
            phx-no-format
            data-role="social-card-body"
            class="whitespace-pre-wrap break-words text-base"
          >{@view.body}</p>
        <% end %>

        <p
          :if={@view.hashtags != []}
          data-role="social-card-hashtags"
          class="text-sm text-subtle"
        >
          {Enum.join(@view.hashtags, " ")}
        </p>
        <p :if={@view.link_url} data-role="social-card-link" class="break-all text-sm">
          link:
          <a href={@view.link_url} target="_blank" rel="noopener noreferrer" class="link">
            {@view.link_url}
          </a>
        </p>
        <p
          data-role="social-card-count"
          data-over-limit={to_string(@view.over_limit?)}
          class={[
            "text-right font-mono text-xs",
            if(@view.over_limit?, do: "text-warning", else: "text-base-content")
          ]}
        >
          {@view.char_count} / {@view.char_limit}
        </p>
      </div>
    </div>
    """
  end

  attr :view, :map, required: true
  attr :myself, :any, required: true
  attr :canvas_id, :string, required: true
  attr :id, :string, required: true

  defp actions(assigns) do
    ~H"""
    <div data-role="social-card-actions" class="flex items-center gap-2">
      <button
        :if={:reject in @view.actions}
        type="button"
        phx-click="social_card_reject_open"
        phx-target={@myself}
        data-role="social-card-reject"
        class="btn btn-outline btn-sm"
      >
        Reject
      </button>
      <button
        :if={:edit in @view.actions}
        type="button"
        phx-click="social_card_edit_open"
        phx-target={@myself}
        data-role="social-card-edit"
        class="btn btn-ghost btn-sm"
      >
        Edit
      </button>
      <button
        :if={:approve in @view.actions}
        type="button"
        phx-click="social_card_approve"
        phx-value-canvas-id={@canvas_id}
        phx-value-fingerprint={@view.fingerprint}
        phx-target={@myself}
        data-role="social-card-approve"
        class="btn btn-primary btn-sm ml-auto"
      >
        Approve
      </button>
      <button
        :if={:copy in @view.actions}
        type="button"
        id={"#{@id}-copy"}
        phx-hook="CopyToClipboard"
        data-clipboard-text={@view.body}
        data-role="social-card-copy"
        class="btn btn-primary btn-sm ml-auto"
      >
        Copy text
      </button>
    </div>
    """
  end

  attr :view, :map, required: true
  attr :myself, :any, required: true
  attr :canvas_id, :string, required: true
  attr :reject_text, :string, default: ""

  defp reject_box(assigns) do
    ~H"""
    <form
      id={"social-card-reject-#{@canvas_id}"}
      phx-change="social_card_reject_change"
      phx-submit="social_card_reject_submit"
      phx-target={@myself}
      data-role="social-card-reject-box"
      class="space-y-2"
    >
      <input type="hidden" name="canvas-id" value={@canvas_id} />
      <input type="hidden" name="fingerprint" value={@view.fingerprint} />
      <label class="block text-sm font-medium" for={"social-card-reason-#{@canvas_id}"}>
        What should change?
      </label>
      <textarea
        id={"social-card-reason-#{@canvas_id}"}
        name="reason"
        rows="3"
        required
        maxlength="2000"
        phx-debounce="100"
        class="textarea textarea-bordered w-full text-base"
      >{@reject_text}</textarea>
      <div class="flex items-center gap-2">
        <button
          type="button"
          phx-click="social_card_reject_cancel"
          phx-target={@myself}
          data-role="social-card-reject-cancel"
          class="btn btn-ghost btn-sm"
        >
          Cancel
        </button>
        <button
          type="submit"
          disabled={String.trim(@reject_text) == ""}
          data-role="social-card-reject-submit"
          class="btn btn-error btn-sm ml-auto"
        >
          Reject post
        </button>
      </div>
    </form>
    """
  end

  defp tone_class(:success), do: "text-success"
  defp tone_class(:error), do: "text-error"
  defp tone_class(_), do: "text-subtle"

  defp schedule(%{scheduled_at: %DateTime{} = at}), do: Approvals.when_text(at)
  defp schedule(_), do: "not scheduled"

  defp aspect(%{width: w, height: h}) when is_number(w) and is_number(h) and w > 0 and h > 0,
    do: "aspect-ratio: #{w} / #{h};"

  defp aspect(_), do: nil
end
