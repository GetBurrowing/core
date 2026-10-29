defmodule PlatformWeb.SocialClipsReviewActions do
  @moduledoc "Desktop and phone decision controls; authorization stays in the review component."
  use PlatformWeb, :html

  # [reviewHTML .pbar] the phone bottom bar: the same approve/reject events
  # and enabled rules as the desktop footer. Rendered only for an approver
  # with a clip selected; hidden above 760px.
  attr :clip, :any, required: true
  attr :note, :string, required: true
  attr :ticked, :list, required: true
  attr :myself, :any, required: true
  attr :render_id, :any, required: true
  attr :appearance_dirty, :boolean, default: false

  def pbar(assigns) do
    assigns = assign(assigns, :blank?, String.trim(assigns.note) == "")

    ~H"""
    <div
      class={
        [
          "fixed inset-x-0 bottom-0 z-30 hidden gap-2.5 border-t border-base-300 bg-base-100/80 backdrop-blur",
          "px-3 pt-2.5 pb-[calc(10px+env(safe-area-inset-bottom))] max-[760px]:flex",
          # Clears Burrow's own mobile tab bar (core's --bottom-nav-height,
          # 56px below lg, 0 elsewhere); the prototype has no host nav.
          "mb-[var(--bottom-nav-height,0px)]"
        ]
      }
      data-role="clips-pbar"
    >
      <button
        type="button"
        class="btn btn-outline h-[46px] w-[112px] flex-none rounded-full text-base"
        disabled={@blank?}
        title={if @blank?, do: "Add a note first"}
        phx-click="reject"
        phx-value-id={@clip.id}
        phx-target={@myself}
        data-role="clips-pbar-reject"
      >
        Reject
      </button>
      <button
        type="button"
        class="btn btn-primary btn-lg h-[46px] flex-1 rounded-full text-base"
        disabled={@ticked == [] or @appearance_dirty}
        phx-click="approve"
        phx-value-render_id={@render_id}
        phx-value-id={@clip.id}
        phx-target={@myself}
        data-role="clips-pbar-approve"
      >
        {if @ticked == [], do: "Pick a platform", else: "Approve and publish"}
      </button>
    </div>
    """
  end

  attr :clip, :any, required: true
  attr :note, :string, required: true
  attr :ticked, :list, required: true
  attr :myself, :any, required: true
  attr :render_id, :any, required: true
  attr :appearance_dirty, :boolean, default: false
  attr :why_line, :string, required: true

  def decision_bar(assigns) do
    ~H"""
    <div
      class="flex shrink-0 flex-col gap-2 border-t border-base-300 bg-base-100 p-4 max-[760px]:hidden"
      data-role="clips-decide"
    >
      <div class="flex gap-2">
        <button
          type="button"
          class="btn btn-outline rounded-full"
          disabled={String.trim(@note) == ""}
          title={
            if String.trim(@note) == "", do: "Add a note to reject", else: "Reject with your note"
          }
          phx-click="reject"
          phx-value-id={@clip.id}
          phx-target={@myself}
          data-role="clip-reject"
        >
          Reject
        </button>
        <button
          type="button"
          class="btn btn-primary flex-1 rounded-full"
          disabled={@ticked == [] or @appearance_dirty}
          phx-click="approve"
          phx-value-render_id={@render_id}
          phx-value-id={@clip.id}
          phx-target={@myself}
          data-role="clip-approve"
        >
          {if @ticked == [], do: "Pick a platform", else: "Approve and publish"}
        </button>
      </div>
      <p class="text-center text-xs text-subtle" data-role="clip-why">
        {@why_line}
      </p>
    </div>
    """
  end
end
