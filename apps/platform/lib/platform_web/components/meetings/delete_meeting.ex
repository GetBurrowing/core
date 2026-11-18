defmodule PlatformWeb.Components.Meetings.DeleteMeeting do
  @moduledoc """
  The "Delete meeting" control and its inline confirm (task 01a1b281 stage
  4, design canvas `01a1b282-37bc-7000-899c-692ba01d0293`). Shared by the
  /meetings detail (list view, calendar view panel and sheet) and /calendar's
  details, so the control has one look and one set of events everywhere.

  It is drawn only for a meeting `Platform.Meetings.can_delete_meeting?/2`
  allows: cancelled, ended, or scheduled with its time already past. A live
  meeting, or a scheduled one still ahead, never shows it (cancel first);
  Edit is hidden wherever Delete is shown, because the two predicates are
  disjoint by construction.

  ## States

    * `:idle` — a quiet text row in the error slot, below the cancel row.
    * `:confirming` — the row expands IN PLACE into an inset on base-200:
      "Delete this meeting? It disappears from everyone's lists. Its
      transcript and recording are kept." and "Keep it" (ghost) / "Delete"
      (error fill). Focus lands on "Keep it" so Enter is the safe choice,
      and Esc collapses the inset only. No modal, and no second sheet.
    * `:working` — the confirm button shows a spinner, both disabled.
    * `:error` — "That didn't delete. Try again." inside the open inset.

  Done is not a state of this component: once the meeting is deleted the
  row leaves every list and the caller has nothing to render it against.

  ## Hidden, never disabled

  `can_delete` false renders nothing at all. The server enforces the rule
  regardless (`Platform.Meetings.delete_meeting_for_user/2` reloads the
  meeting through the viewer scope and re-checks it); this attr only decides
  whether the row is drawn.

  ## Events

  `delete_meeting_open`, `delete_meeting_keep` and `delete_meeting_confirm`,
  all without a meeting id. The LiveView acts on its own SELECTION, so a
  forged payload cannot point the confirm at another meeting.

  ## DOM contract

  `data-role` values `meeting-delete-row`, `meeting-delete-confirm`,
  `meeting-delete-keep`, `meeting-delete-submit` and `meeting-delete-error`.
  Tests key on these, never on classes.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @states [:idle, :confirming, :working, :error]

  @copy "Delete this meeting? It disappears from everyone's lists. Its transcript and recording are kept."

  @doc "The confirm's question, verbatim from the approved mockup."
  @spec confirm_copy() :: String.t()
  def confirm_copy, do: @copy

  @doc """
  The delete row and its inline confirm.

  `id_prefix` is required: the calendar view renders the panel and the
  sheet in one document, so the two copies need distinct ids.
  """
  attr(:can_delete, :boolean, required: true)
  attr(:state, :atom, default: :idle, values: @states)
  attr(:id_prefix, :string, required: true)
  attr(:class, :any, default: nil)

  attr(:escape, :boolean,
    default: true,
    doc:
      "bind Escape to `delete_meeting_keep` here. A page that already binds Escape (CalendarLive's `escape`) passes false and collapses the inset itself"
  )

  def delete_meeting(assigns) do
    assigns = assign(assigns, :copy, @copy)

    ~H"""
    <div
      :if={@can_delete}
      id={"#{@id_prefix}-meeting-delete"}
      class={["border-t border-edge pt-3", @class]}
      data-delete-state={@state}
    >
      <button
        :if={@state == :idle}
        type="button"
        class="flex min-h-11 w-full items-center text-left text-sm font-medium text-error hover:underline lg:min-h-8"
        phx-click="delete_meeting_open"
        data-role="meeting-delete-row"
      >
        Delete meeting
      </button>

      <div
        :if={@state != :idle}
        id={"#{@id_prefix}-meeting-delete-confirm"}
        class="flex flex-col gap-2 rounded border border-edge bg-base-200 p-3 text-base-content"
        role="group"
        aria-labelledby={"#{@id_prefix}-meeting-delete-heading"}
        phx-window-keydown={(@escape and @state in [:confirming, :error]) && "delete_meeting_keep"}
        phx-key={@escape && "Escape"}
        data-role="meeting-delete-confirm"
      >
        <p id={"#{@id_prefix}-meeting-delete-heading"} class="m-0 text-sm font-medium">
          {@copy}
        </p>
        <p
          :if={@state == :error}
          class="m-0 text-sm text-error"
          role="alert"
          data-role="meeting-delete-error"
        >
          That didn't delete. Try again.
        </p>
        <div class="flex flex-wrap gap-2">
          <button
            id={"#{@id_prefix}-meeting-delete-keep"}
            type="button"
            class="inline-flex h-8 items-center whitespace-nowrap rounded-full border border-subtle px-3 text-xs font-medium text-base-content hover:bg-base-300 disabled:opacity-50 max-lg:!h-11"
            phx-click="delete_meeting_keep"
            phx-mounted={JS.focus()}
            disabled={@state == :working}
            data-role="meeting-delete-keep"
          >
            Keep it
          </button>
          <button
            type="button"
            class="inline-flex h-8 items-center gap-1.5 whitespace-nowrap rounded-full bg-error px-3 text-xs font-medium text-error-content hover:brightness-110 disabled:opacity-70 max-lg:!h-11"
            phx-click="delete_meeting_confirm"
            disabled={@state == :working}
            aria-busy={@state == :working && "true"}
            data-role="meeting-delete-submit"
          >
            <span
              :if={@state == :working}
              class="loading loading-spinner loading-xs"
              aria-hidden="true"
            >
            </span>
            Delete
          </button>
        </div>
      </div>
    </div>
    """
  end
end
