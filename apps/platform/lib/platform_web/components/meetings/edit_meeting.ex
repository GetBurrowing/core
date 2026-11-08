defmodule PlatformWeb.Components.Meetings.EditMeeting do
  @moduledoc """
  The pieces of the retired "Edit meeting" form (task 01a1b281 stage 3) that
  Calendar's ONE event editor kept (task 01a1b8a5 stages 2 and 4; design
  direction canvas `01a1b282-37bc-7000-899c-692ba01d0293`):

    * `edit_button/1` — the text "Edit" action in the Calendar details
      footer for a call record. Renders NOTHING unless `can_edit` is true;
      callers compute that with `Platform.Meetings.can_edit_meeting?/2`.
    * `invitees/1` — the staged-people block (`InviteeStaging`).
    * `was/1` — a changed field's muted "was ..." marker.
    * `summary/1` — "When you save": `Platform.Meetings.preview_meeting_edit/2`'s
      recipients turned into sentences. Nothing here decides who is emailed.

  The form itself (`edit_meeting/1`) and its LiveView half
  (`PlatformWeb.MeetingLive.MeetingEdit`) are gone: the /meetings listing
  was its only caller, and a second invitee editor beside Calendar's is
  exactly what the consolidation removes. The server rule still holds
  regardless of what is drawn: Calendar's editor reloads the meeting
  through the viewer scope on every event.

  ## DOM contract

  `data-role` values `meeting-edit-open`, `meeting-edit-was`,
  `meeting-edit-removed`, `meeting-edit-last-invitee`,
  `meeting-edit-summary` and `meeting-edit-summary-*`.
  """
  use PlatformWeb, :html

  import PlatformWeb.Components.Meetings.InviteControl, only: [invite_control: 1]

  # ── the Edit action ─────────────────────────────────────────────────────

  attr(:can_edit, :boolean, required: true)
  attr(:variant, :atom, default: :pill, values: [:pill, :text])
  attr(:id, :string, required: true)
  attr(:class, :any, default: nil)

  @doc "The Edit action. Nothing at all unless `can_edit`."
  def edit_button(%{variant: :text} = assigns) do
    ~H"""
    <button
      :if={@can_edit}
      id={@id}
      type="button"
      class={[
        "inline-flex min-h-8 items-center px-2 text-sm font-medium text-base-content hover:underline max-lg:min-h-11",
        @class
      ]}
      phx-click="meeting_edit_open"
      data-role="meeting-edit-open"
    >
      Edit
    </button>
    """
  end

  def edit_button(assigns) do
    ~H"""
    <button
      :if={@can_edit}
      id={@id}
      type="button"
      class={[
        "inline-flex h-8 shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full border border-subtle px-3 text-xs font-medium text-base-content hover:bg-base-300 max-lg:!h-11",
        @class
      ]}
      phx-click="meeting_edit_open"
      data-role="meeting-edit-open"
    >
      <span class="hero-pencil-square size-4" aria-hidden="true"></span> Edit
    </button>
    """
  end

  # ── the form ────────────────────────────────────────────────────────────

  attr(:staging, :map, required: true, doc: "an `InviteeStaging` state")
  attr(:kept, :list, required: true)
  attr(:removed, :list, required: true)
  attr(:label, :string, default: "Invitees")
  attr(:label_class, :string, default: nil)
  attr(:placeholder, :string, default: "Name or email")
  attr(:always_open, :boolean, default: false, doc: "show the search box without Add people")
  attr(:id, :string, default: "meeting-edit-invite")
  attr(:rest, :global)

  @doc """
  The staged people block: kept rows, staged additions, removed rows with
  undo, the last-invitee refusal and the add-people search. Shared by the
  Edit meeting form and the Calendar event editor (task 01a1b8a5 stage 2);
  its events are `meeting_edit_remove`, `meeting_edit_undo`,
  `meeting_edit_unstage`, `meeting_edit_add_people` and InviteControl's
  `:edit` mode, in both.
  """
  def invitees(assigns) do
    ~H"""
    <div class="flex flex-col gap-1" data-role="meeting-edit-invitees" {@rest}>
      <span class={@label_class || label_class()}>{@label}</span>
      <div class="flex flex-col">
        <.invitee_row :for={row <- @kept} row={row} event="meeting_edit_remove" />
        <.invitee_row
          :for={entry <- @staging.added}
          row={entry}
          event="meeting_edit_unstage"
          added
        />
      </div>
      <p
        :for={row <- @removed}
        class="m-0 text-sm text-subtle"
        data-role="meeting-edit-removed"
        data-invite-id={row.id}
      >
        removed: {row.name} (<button
          type="button"
          class="text-base-content underline"
          phx-click="meeting_edit_undo"
          phx-value-id={row.id}
          data-role="meeting-edit-undo"
        >undo</button>)
      </p>
      <p
        :if={@staging.refused?}
        class="m-0 flex items-center gap-1.5 text-sm text-error"
        role="alert"
        data-role="meeting-edit-last-invitee"
      >
        <span class="hero-exclamation-circle size-4 shrink-0" aria-hidden="true"></span>
        Keep at least one invitee, or cancel the meeting.
      </p>
      <button
        :if={!@staging.adding? and !@always_open}
        type="button"
        class="mt-1 flex min-h-11 items-center gap-2 rounded-lg border border-dashed border-edge px-3 text-left text-sm font-medium text-base-content lg:min-h-9 lg:hover:border-primary"
        phx-click="meeting_edit_add_people"
        data-role="meeting-edit-add-people"
      >
        <span class="hero-plus size-4" aria-hidden="true"></span> Add people
      </button>
      <div
        :if={@staging.adding? or @always_open}
        class="mt-1"
        data-role="meeting-edit-invite-expansion"
      >
        <.invite_control
          mode={:edit}
          id={@id}
          query={@staging.query}
          candidates={@staging.candidates}
          email_option={@staging.email}
          dropdown={:inline}
          placeholder={@placeholder}
          aria_label={@label}
        />
      </div>
    </div>
    """
  end

  attr(:row, :map, required: true)
  attr(:event, :string, required: true)
  attr(:added, :boolean, default: false)

  defp invitee_row(assigns) do
    ~H"""
    <div
      class="flex min-h-11 items-center gap-2.5 border-b border-edge py-1.5 last:border-b-0"
      data-role="meeting-edit-invitee"
      data-added={@added && "true"}
      data-email-chip={@added && is_nil(@row.user_id) && "true"}
    >
      <span
        :if={is_nil(@row.user_id)}
        class="flex size-7 shrink-0 items-center justify-center rounded-full bg-base-200"
        aria-hidden="true"
      >
        <span class="hero-envelope size-4 text-subtle"></span>
      </span>
      <.human_avatar :if={@row.user_id} name={row_name(@row)} seed={@row.user_id} size="sm" />
      <span class="min-w-0 flex-1">
        <span class="block truncate text-sm font-medium">{row_name(@row)}</span>
        <span
          :if={@row[:subtitle] && @row[:subtitle] != row_name(@row)}
          class="block truncate text-xs text-subtle"
        >
          {@row.subtitle}
        </span>
      </span>
      <span :if={@added} class="text-xs text-subtle">new</span>
      <button
        type="button"
        class="btn btn-ghost btn-xs btn-square min-h-11 lg:min-h-8"
        phx-click={@event}
        phx-value-id={@row.id}
        aria-label={"Remove #{row_name(@row)}"}
        data-role="meeting-edit-invitee-remove"
      >
        <span class="hero-x-mark size-4"></span>
      </button>
    </div>
    """
  end

  defp row_name(%{name: name}) when is_binary(name), do: name
  defp row_name(%{display_name: name}) when is_binary(name), do: name
  defp row_name(%{email: email}), do: email

  attr(:text, :string, required: true)
  attr(:bare, :boolean, default: false)

  @doc "A muted 'was ...' marker beside a changed field's label."
  def was(assigns) do
    ~H"""
    <span
      class="ml-1 text-xs font-normal normal-case tracking-normal text-subtle"
      data-role="meeting-edit-was"
    >
      {if @bare, do: @text, else: "was " <> @text}
    </span>
    """
  end

  # ── the consequence summary ─────────────────────────────────────────────

  attr(:preview, :map, required: true)

  @doc """
  "When you save": `Platform.Meetings.preview_meeting_edit/2`'s answer as
  sentences.
  """
  def summary(assigns) do
    ~H"""
    <div
      class="flex gap-2 rounded-lg border border-edge bg-base-200 p-3 text-sm"
      data-role="meeting-edit-summary"
    >
      <span class="hero-information-circle size-5 shrink-0 text-info" aria-hidden="true"></span>
      <div class="flex min-w-0 flex-col gap-1">
        <h3 class="m-0 text-sm font-semibold">When you save</h3>
        <%= cond do %>
          <% @preview.changed == [] -> %>
            <p class="m-0" data-role="meeting-edit-summary-none">Nothing has changed yet.</p>
          <% @preview.changed == [:description] and not @preview.emails? -> %>
            <p class="m-0" data-role="meeting-edit-summary-notes-only">
              Invitees won’t be emailed; only the notes changed.
            </p>
          <% true -> %>
            <p
              :if={@preview.update_recipients != []}
              class="m-0"
              data-role="meeting-edit-summary-updated"
            >
              {sentence(@preview.update_recipients, "an updated invite (#{what(@preview.changed)})")}
            </p>
            <p
              :if={@preview.invite_recipients != []}
              class="m-0"
              data-role="meeting-edit-summary-invited"
            >
              {sentence(@preview.invite_recipients, "an invite")}
            </p>
            <p
              :if={@preview.cancel_recipients != []}
              class="m-0"
              data-role="meeting-edit-summary-cancelled"
            >
              {sentence(@preview.cancel_recipients, "a cancellation")}
            </p>
            <p :if={not @preview.emails?} class="m-0" data-role="meeting-edit-summary-no-mail">
              Nobody will be emailed.
            </p>
            <p class="m-0" data-role="meeting-edit-summary-link">
              The link stays the same:
              <span class="break-all font-mono text-xs">{link_text(@preview.link)}</span>
            </p>
        <% end %>
      </div>
    </div>
    """
  end

  @doc false
  def sentence([_one] = people, what), do: "#{names(people)} gets #{what}."
  def sentence(people, what), do: "#{names(people)} get #{what}."

  @doc "A recipient's name as the summary prints it."
  def recipient_name(%{name: name}) when is_binary(name) and name != "", do: name
  def recipient_name(%{email: email}), do: email

  defp names(people) do
    case Enum.map(people, &recipient_name/1) do
      [one] -> one
      list -> Enum.join(Enum.drop(list, -1), ", ") <> " and " <> List.last(list)
    end
  end

  # Matches the update mail's headline ("Time changed", "Title changed",
  # "Time and title changed"): only the two calendar-visible fields count.
  defp what(changed) do
    case {:time in changed, :name in changed} do
      {true, true} -> "new time and new title"
      {true, false} -> "new time"
      {false, true} -> "new title"
      {false, false} -> "guest list changed"
    end
  end

  defp link_text("/" <> _ = path), do: PlatformWeb.Endpoint.url() <> path
  defp link_text(link), do: link

  defp label_class, do: "text-xs font-semibold uppercase tracking-wider text-base-content"
end
