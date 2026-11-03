defmodule PlatformWeb.Components.Meetings.CancelMeeting do
  @moduledoc """
  The "Cancel meeting" control and the "Cancelled" chip (task 01a19e7f,
  design direction canvas `01a19e80-1c97-7000-aef5-16bf61ec837f` rev 1).
  Shared by the /meetings detail (list view and calendar view) and, from
  stage 4, by /calendar's details panel, so the control has one look and
  one set of events everywhere.

  ## States

    * `:idle` — a quiet text row in the error slot, at the BOTTOM of the
      surface below a border-edge rule, never on the action row beside
      Join or Open, where it would invite mis-taps.
    * `:confirming` — the row expands IN PLACE into an inset on base-200
      with the border token: "Cancel this meeting?", the audience sentence,
      and "Keep meeting" (ghost) / "Cancel meeting" (error fill). Focus
      lands on "Keep meeting" so Enter is the safe choice, and Esc
      collapses the inset only. No modal, and no second sheet on mobile.
    * `:working` — the confirm button shows a spinner and both buttons are
      disabled.
    * `:error` — "That didn't cancel. Try again." in the error slot inside
      the inset, which stays open.

  Done is not a state of this component: once the meeting is cancelled the
  caller stops rendering it (`can_cancel` false) and shows
  `cancelled_chip/1` in the header instead. There is no toast.

  ## Hidden, never disabled

  Someone who may not cancel gets NO element: `can_cancel` false renders
  nothing at all, so there is no disabled control and no tooltip. The
  server enforces the rule regardless
  (`Platform.Meetings.cancel_meeting_for_user/2`); this attr only decides
  whether the row is drawn.

  ## Events

  `cancel_meeting_open`, `cancel_meeting_keep` and `cancel_meeting_confirm`,
  all without a meeting id. The LiveView acts on its own SELECTION, so a
  forged payload cannot point the confirm at another meeting.

  ## DOM contract

  `data-role` values `meeting-cancel-row`, `meeting-cancel-confirm`,
  `meeting-cancel-keep`, `meeting-cancel-submit`, `meeting-cancel-error`
  and `meeting-cancelled-chip`. Tests key on these, never on classes.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @states [:idle, :confirming, :working, :error]

  @doc """
  The cancel row and its inline confirm.

  `id_prefix` is required: the calendar view renders the panel and the
  sheet in one document, so the two copies need distinct ids.
  """
  attr(:can_cancel, :boolean, required: true)
  attr(:state, :atom, default: :idle, values: @states)
  attr(:audience, :integer, default: 0)
  attr(:id_prefix, :string, required: true)
  attr(:class, :any, default: nil)

  def cancel_meeting(assigns) do
    ~H"""
    <div
      :if={@can_cancel}
      id={"#{@id_prefix}-meeting-cancel"}
      class={["border-t border-edge pt-3", @class]}
      data-cancel-state={@state}
    >
      <button
        :if={@state == :idle}
        type="button"
        class="flex min-h-11 w-full items-center text-left text-sm font-medium text-error hover:underline lg:min-h-8"
        phx-click="cancel_meeting_open"
        data-role="meeting-cancel-row"
      >
        Cancel meeting
      </button>

      <div
        :if={@state != :idle}
        id={"#{@id_prefix}-meeting-cancel-confirm"}
        class="flex flex-col gap-2 rounded border border-edge bg-base-200 p-3 text-base-content"
        role="group"
        aria-labelledby={"#{@id_prefix}-meeting-cancel-heading"}
        phx-window-keydown={@state in [:confirming, :error] && "cancel_meeting_keep"}
        phx-key="Escape"
        data-role="meeting-cancel-confirm"
      >
        <p id={"#{@id_prefix}-meeting-cancel-heading"} class="m-0 text-sm font-medium">
          Cancel this meeting?
        </p>
        <p class="m-0 text-sm" data-role="meeting-cancel-audience">
          {audience_sentence(@audience)}
        </p>
        <p
          :if={@state == :error}
          class="m-0 text-sm text-error"
          role="alert"
          data-role="meeting-cancel-error"
        >
          That didn't cancel. Try again.
        </p>
        <div class="flex flex-wrap gap-2">
          <button
            id={"#{@id_prefix}-meeting-cancel-keep"}
            type="button"
            class="inline-flex h-8 items-center whitespace-nowrap rounded-full border border-subtle px-3 text-xs font-medium text-base-content hover:bg-base-300 disabled:opacity-50 max-lg:!h-11"
            phx-click="cancel_meeting_keep"
            phx-mounted={JS.focus()}
            disabled={@state == :working}
            data-role="meeting-cancel-keep"
          >
            Keep meeting
          </button>
          <button
            type="button"
            class="inline-flex h-8 items-center gap-1.5 whitespace-nowrap rounded-full bg-error px-3 text-xs font-medium text-error-content hover:brightness-110 disabled:opacity-70 max-lg:!h-11"
            phx-click="cancel_meeting_confirm"
            disabled={@state == :working}
            aria-busy={@state == :working && "true"}
            data-role="meeting-cancel-submit"
          >
            <span
              :if={@state == :working}
              class="loading loading-spinner loading-xs"
              aria-hidden="true"
            >
            </span>
            Cancel meeting
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  The neutral "Cancelled" chip for a cancelled meeting's header or row.

  `text-neutral` is the direction's slot. In the dark theme that slot is a
  dark grey on a dark ground (measured about 1.5:1), so dark mode reads
  `neutral-content` instead.
  """
  attr(:class, :any, default: nil)

  def cancelled_chip(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex shrink-0 items-center rounded-full border border-edge px-2 text-xs font-medium leading-5 text-neutral dark:text-neutral-content",
        @class
      ]}
      data-role="meeting-cancelled-chip"
    >
      Cancelled
    </span>
    """
  end

  @doc """
  The confirm's audience sentence. `N` is
  `Platform.Meetings.cancellation_audience_count/1`, the notifier's own
  count, so the sentence and the notice cannot disagree.
  """
  @spec audience_sentence(non_neg_integer()) :: String.t()
  def audience_sentence(0), do: "Nobody else was invited."
  def audience_sentence(1), do: "1 person was invited. They'll be told it's cancelled."

  def audience_sentence(n) when is_integer(n) and n > 1,
    do: "#{n} people were invited. They'll be told it's cancelled."
end
