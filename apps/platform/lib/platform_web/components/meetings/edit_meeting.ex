defmodule PlatformWeb.Components.Meetings.EditMeeting do
  @moduledoc """
  Edit a scheduled meeting in place (task 01a1b281 stage 3; design
  direction canvas `01a1b282-37bc-7000-899c-692ba01d0293`, mockup canvas
  `01a1b290-0b1c-7000-a236-56cff21d2a55`, prototype `01a1b28f-58ac` v1).

  Two pieces, shared by `PlatformWeb.MeetingLive` and
  `PlatformWeb.CalendarLive`:

    * `edit_button/1` — the secondary "Edit" beside Cancel meeting on the
      /meetings detail, or the text action in the calendar details footer.
    * `edit_meeting/1` — the form: a centred dialog from `sm` up, a
      full-height sheet below it. Name, Date, Start and Duration in the
      create sheet's order, prefilled, then Invitees and Notes, then the
      pinned "When you save" summary and Save changes.

  ## Hidden, never disabled

  `edit_button/1` renders NOTHING unless the caller passes `can_edit`
  true, and callers compute that with `Platform.Meetings.can_edit_meeting?/2`.
  The server rule holds regardless: every `meeting_edit_*` event reloads the
  meeting through the viewer scope (`PlatformWeb.MeetingLive.MeetingEdit`).

  ## The summary is rendered, never decided

  `summary/1` turns `Platform.Meetings.preview_meeting_edit/2`'s answer
  into sentences: its recipient lists name who gets an updated invite, an
  invite or a cancellation, its `changed` list says what moved, and its
  `link` is the link that stays. Nothing here decides who is emailed.

  ## Events

  `meeting_edit_open` (from the button), then `meeting_edit_change`,
  `meeting_edit_save`, `meeting_edit_close`, `meeting_edit_remove`,
  `meeting_edit_undo`, `meeting_edit_unstage`, `meeting_edit_add_people`
  and InviteControl's `:edit` mode events. None carries a meeting id.

  ## DOM contract

  `data-role` values `meeting-edit-open`, `meeting-edit`, `meeting-edit-*`
  for fields, `meeting-edit-was`, `meeting-edit-removed`,
  `meeting-edit-last-invitee`, `meeting-edit-summary`,
  `meeting-edit-summary-*` and `meeting-edit-save`.
  """
  use PlatformWeb, :html

  import PlatformWeb.Components.Meetings.InviteControl, only: [invite_control: 1]

  alias PlatformWeb.MeetingLive
  alias PlatformWeb.MeetingLive.MeetingEdit

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

  attr(:edit, :map, required: true, doc: "the `:meeting_edit` assign (never nil here)")

  attr(:escape, :boolean,
    default: true,
    doc:
      "bind Escape to `meeting_edit_close`. CalendarLive binds Escape page-wide and closes the form itself, so it passes false"
  )

  @doc "The Edit meeting dialog (desktop) / full-height sheet (phone)."
  def edit_meeting(assigns) do
    edit = assigns.edit

    assigns =
      assigns
      |> assign(:form, edit.form)
      |> assign(:changed, edit.changed)
      |> assign(:original, edit.original)
      |> assign(:kept, Enum.reject(edit.invitees, &(&1.id in edit.removed_ids)))
      |> assign(:removed, Enum.filter(edit.invitees, &(&1.id in edit.removed_ids)))
      |> assign(:durations, MeetingEdit.duration_options(edit))
      |> assign(:dirty?, edit.preview.changed != [])
      |> assign(:can_save?, edit.preview.changed != [] and is_nil(edit.error))

    ~H"""
    <div
      id="meeting-edit"
      class="fixed inset-0 z-50 flex items-stretch justify-center sm:items-center"
      role="dialog"
      aria-modal="true"
      aria-labelledby="meeting-edit-title"
      data-role="meeting-edit"
      phx-window-keydown={@escape && "meeting_edit_close"}
      phx-key={@escape && "Escape"}
    >
      <div
        class="absolute inset-0 bg-scrim"
        phx-click="meeting_edit_close"
        aria-hidden="true"
        data-role="meeting-edit-backdrop"
      >
      </div>

      <%!-- A capped flex COLUMN that clips, with ONE scrolling body, like
           the create sheet: a long invitee list scrolls under the pinned
           summary and Save instead of pushing them off the panel. Below
           `sm` it is the full height of the screen. --%>
      <div class="relative flex h-full w-full flex-col overflow-hidden bg-base-100 pb-[env(safe-area-inset-bottom)] shadow-2xl sm:h-auto sm:max-h-[85vh] sm:max-w-lg sm:rounded-2xl">
        <div class="flex flex-none items-center gap-2 border-b border-edge px-4 py-3">
          <span class="hero-pencil-square size-5 shrink-0 text-subtle" aria-hidden="true"></span>
          <h2 id="meeting-edit-title" class="flex-1 text-base font-semibold">Edit meeting</h2>
          <button
            type="button"
            phx-click="meeting_edit_close"
            class="btn btn-sm btn-ghost btn-square min-h-11 sm:min-h-8"
            aria-label="Close"
            data-role="meeting-edit-close"
          >
            <span class="hero-x-mark size-4"></span>
          </button>
        </div>

        <.form
          for={@form}
          id="meeting-edit-form"
          phx-change="meeting_edit_change"
          phx-submit="meeting_edit_save"
          novalidate
          class="flex min-h-0 flex-1 flex-col"
        >
          <div
            class="flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto px-4 py-4"
            data-role="meeting-edit-body"
          >
            <div
              :if={@edit.error}
              class="rounded-md border border-error/40 bg-error/10 px-3 py-2 text-xs text-base-content"
              role="alert"
              data-role="meeting-edit-error"
            >
              {@edit.error}
            </div>

            <div class="flex flex-col gap-1">
              <label for="meeting-edit-name" class={label_class()}>
                Name <span class="text-base-content">*</span>
                <.was :if={@changed.name} text={@original["name"]} />
              </label>
              <input
                id="meeting-edit-name"
                type="text"
                name={@form[:name].name}
                value={@form[:name].value}
                required
                autocomplete="off"
                class="input input-bordered min-h-11 w-full text-sm font-semibold"
                data-role="meeting-edit-name"
              />
            </div>

            <div class="grid grid-cols-2 gap-2 sm:grid-cols-[1.4fr_1fr_1fr]">
              <div class="col-span-2 flex flex-col gap-1 sm:col-span-1">
                <label for="meeting-edit-date" class={label_class()}>
                  Date <.was :if={@changed.date} text={date_label(@original["date"])} />
                </label>
                <input
                  id="meeting-edit-date"
                  type="date"
                  name={@form[:date].name}
                  value={@form[:date].value}
                  phx-hook="DateEntryGuard"
                  data-incomplete-flag="meeting-edit-date-incomplete"
                  class="input input-bordered min-h-11 w-full text-sm"
                  data-role="meeting-edit-date"
                />
                <input
                  id="meeting-edit-date-incomplete"
                  type="hidden"
                  name={@form[:date_incomplete].name}
                  value=""
                  phx-update="ignore"
                />
              </div>

              <div class="flex flex-col gap-1">
                <label for="meeting-edit-start-time" class={label_class()}>
                  Start <.was :if={@changed.start_time} text={@original["start_time"]} />
                </label>
                <input
                  id="meeting-edit-start-time"
                  type="text"
                  inputmode="text"
                  autocomplete="off"
                  placeholder="1:00 PM"
                  name={@form[:start_time].name}
                  value={@form[:start_time].value}
                  class="input input-bordered min-h-11 w-full text-sm"
                  data-role="meeting-edit-start-time"
                />
              </div>

              <div class="flex flex-col gap-1">
                <label for="meeting-edit-duration" class={label_class()}>
                  Duration
                  <.was
                    :if={@changed.duration_minutes}
                    text={duration_text(@original["duration_minutes"])}
                  />
                </label>
                <select
                  id="meeting-edit-duration"
                  name={@form[:duration_minutes].name}
                  class="select select-bordered min-h-11 w-full text-sm"
                  data-role="meeting-edit-duration"
                >
                  <option
                    :for={minutes <- @durations}
                    value={minutes}
                    selected={to_string(@form[:duration_minutes].value) == to_string(minutes)}
                  >
                    {MeetingLive.duration_label(minutes)}
                  </option>
                </select>
              </div>
            </div>

            <div class="flex flex-col gap-1" data-role="meeting-edit-invitees">
              <span class={label_class()}>Invitees</span>
              <div class="flex flex-col">
                <.invitee_row :for={row <- @kept} row={row} event="meeting_edit_remove" />
                <.invitee_row
                  :for={entry <- @edit.added}
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
                :if={@edit.refused?}
                class="m-0 flex items-center gap-1.5 text-sm text-error"
                role="alert"
                data-role="meeting-edit-last-invitee"
              >
                <span class="hero-exclamation-circle size-4 shrink-0" aria-hidden="true"></span>
                Keep at least one invitee, or cancel the meeting.
              </p>
              <button
                :if={!@edit.adding?}
                type="button"
                class="mt-1 flex min-h-11 items-center gap-2 rounded-lg border border-dashed border-edge px-3 text-left text-sm font-medium text-base-content lg:min-h-9 lg:hover:border-primary"
                phx-click="meeting_edit_add_people"
                data-role="meeting-edit-add-people"
              >
                <span class="hero-plus size-4" aria-hidden="true"></span> Add people
              </button>
              <div :if={@edit.adding?} class="mt-1" data-role="meeting-edit-invite-expansion">
                <.invite_control
                  mode={:edit}
                  id="meeting-edit-invite"
                  query={@edit.query}
                  candidates={@edit.candidates}
                  email_option={@edit.email}
                  dropdown={:inline}
                />
              </div>
            </div>

            <div class="flex flex-col gap-1">
              <label for="meeting-edit-notes" class={label_class()}>
                Notes <.was :if={@changed.description} text="edited" bare />
              </label>
              <textarea
                id="meeting-edit-notes"
                name={@form[:description].name}
                rows="3"
                class="textarea textarea-bordered w-full text-sm"
                data-role="meeting-edit-notes"
              >{Phoenix.HTML.Form.normalize_value("textarea", @form[:description].value)}</textarea>
            </div>
          </div>

          <div class="flex-none border-t border-edge px-4 pt-3">
            <.summary preview={@edit.preview} />
          </div>

          <div
            class="flex flex-none items-center justify-end gap-2 px-4 py-3"
            data-role="meeting-edit-footer"
          >
            <button
              type="button"
              phx-click="meeting_edit_close"
              class="btn btn-ghost btn-sm hidden min-h-11 sm:inline-flex"
              data-role="meeting-edit-cancel"
            >
              Close
            </button>
            <button
              type="submit"
              class="btn btn-primary btn-sm min-h-11 max-sm:w-full"
              disabled={!@can_save?}
              data-role="meeting-edit-save"
            >
              Save changes
            </button>
          </div>
        </.form>
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
        <span :if={@row[:subtitle]} class="block truncate text-xs text-subtle">
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

  defp was(assigns) do
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

  defp date_label(""), do: "no date"

  defp date_label(iso) do
    case Date.from_iso8601(iso || "") do
      {:ok, date} -> Calendar.strftime(date, "%a %b %-d")
      _ -> iso
    end
  end

  defp duration_text(raw) do
    case Integer.parse(raw || "") do
      {minutes, ""} -> MeetingLive.duration_label(minutes)
      _ -> raw
    end
  end
end
