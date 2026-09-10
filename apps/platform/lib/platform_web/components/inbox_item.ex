defmodule PlatformWeb.Components.InboxItem do
  @moduledoc """
  A single Inbox row — one `Platform.Inbox.Item` rendered as a stream child.

  Layout is up to THREE sibling controls under one `<li>`, deliberately NOT
  nested:

    * the **select** checkbox (`phx-click="toggle_select"`), leftmost, present
      only when `selectable`.
    * the **open** control (`phx-click="open"`) fills the row and carries the
      item's `id` + `url`; clicking it marks the item read and navigates to
      `item.url`.
    * the **dismiss** affordance (`phx-click="dismiss"`) is a right-aligned X.

  All three are SIBLINGS, never descendants of one another, so a click on the
  X fires only `dismiss` and a click on the checkbox fires only
  `toggle_select` — neither ever bubbles into `open`. This is the rule the
  whole row layout exists to protect: `open` marks the item read and navigates
  away, so any control that accidentally nests inside it becomes a trapdoor.

  The dismiss X is always tappable on mobile (the touch equivalent of the
  desktop swipe-left / hover-reveal), and hover-revealed on desktop
  (`md:opacity-0 md:group-hover:opacity-100`) so the resting row stays calm.

  ## The checkbox REPLACES the unread dot (task 01a00108 stage 2)

  The dot used to hold the leftmost slot, inside the open button. The checkbox
  cannot live there — see the sibling rule above — so it has to claim that slot
  from outside the button, and the two cannot share it without stacking two
  small primary-toned marks a few pixels apart.

  The dot loses. It renders unconditionally — it has never read `read_at` — so
  it is true of every row at once and discriminates nothing, while the checkbox
  in the same slot carries real per-row state and is actionable. The
  `bg-primary` signature survives as `checkbox-primary`. When `selectable` is
  false the dot still renders, so a non-selecting caller keeps today's row
  verbatim.

  ## The premise moved (task 01a00108 stage 4)

  The paragraph above originally justified the dot's removal by saying every
  rendered row was unread BY CONSTRUCTION, because `InboxLive` rendered only
  `Inbox.unread_scope/1` and that scope excluded read rows. Stage 4 retired
  read-as-cleared, so the surface now renders read and unread rows side by side
  and that premise is false.

  The decision survives it, because the dot never keyed on `read_at` in the
  first place — an unconditional mark discriminates nothing regardless of what
  is on the list. But note what is now true and was not: read vs. unread is a
  REAL distinction on this surface, and no affordance expresses it. Reviving
  the dot as a genuine `is_nil(@item.read_at)` indicator is a live design
  question, deliberately left to a later stage rather than smuggled into a
  semantics change.

  The dom id (`inbox-item-<id>`) is supplied by the caller so it matches the
  stream `dom_id` and `stream_delete_by_dom_id/3` target exactly.

  Styling reads only from semantic DaisyUI token slots (primary / base-* /
  error) per `docs/design-system/01-foundations.md` — no raw hex. The kind
  badge and the per-item space label give each row its taxonomy at a glance.
  """

  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [icon: 1]

  alias Platform.Inbox.Item

  attr :id, :string, required: true, doc: ~s(dom id, "inbox-item-<item.id>")
  attr :item, Item, required: true

  attr :space_label, :string,
    default: nil,
    doc: "Space label for chat_mention rows (grouping cue); nil for other kinds."

  attr :selectable, :boolean,
    default: false,
    doc: "Render the leftmost select checkbox in place of the unread dot."

  attr :selected, :boolean, default: false, doc: "Checked state of the select checkbox."

  def inbox_item(assigns) do
    ~H"""
    <li
      id={@id}
      class="group relative flex items-stretch gap-1 rounded-2xl border border-edge bg-base-100 transition-colors hover:border-base-content/20"
      data-role="inbox-item"
      data-item-id={@item.id}
      data-item-kind={@item.kind}
    >
      <%!-- Select checkbox — FIRST sibling, outside the open button. --%>
      <div :if={@selectable} class="flex shrink-0 items-center pl-4">
        <input
          type="checkbox"
          data-role="inbox-item-select"
          checked={@selected}
          phx-click="toggle_select"
          phx-value-id={@item.id}
          class="checkbox checkbox-primary checkbox-sm [--radius-selector:0.25rem] focus-visible-ring"
          aria-label={"Select #{@item.title}"}
        />
      </div>

      <button
        type="button"
        phx-click="open"
        phx-value-id={@item.id}
        phx-value-url={@item.url}
        class={[
          "flex min-w-0 flex-1 items-start gap-3 rounded-2xl py-3 pr-4 text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring focus-visible:ring-offset-2 focus-visible:ring-offset-base-100",
          if(@selectable, do: "pl-3", else: "pl-4")
        ]}
        data-role="inbox-item-open"
      >
        <%!-- Signature element: the unread dot. Yields the slot to the
             checkbox when the row is selectable (see moduledoc). --%>
        <span
          :if={not @selectable}
          class="mt-1.5 size-2 shrink-0 rounded-full bg-primary"
          data-role="inbox-item-unread-dot"
          aria-hidden="true"
        >
        </span>

        <span class="min-w-0 flex-1">
          <span class="flex flex-wrap items-center gap-2">
            <span
              class="inline-flex items-center gap-1 text-[11px] font-medium uppercase tracking-wide text-base-content/60"
              data-role="inbox-item-kind"
            >
              <.icon name={kind_icon(@item.kind)} class="size-3.5" />
              {kind_label(@item.kind)}
            </span>
            <span
              :if={@space_label}
              class="inline-flex items-center rounded-full bg-base-200 px-2 py-0.5 text-[11px] font-medium text-base-content/70"
              data-role="inbox-item-space"
            >
              {@space_label}
            </span>
          </span>

          <span class="mt-1 block truncate text-sm font-semibold text-base-content">
            {@item.title}
          </span>

          <span
            :if={present?(@item.body)}
            class="mt-0.5 block line-clamp-2 text-sm text-base-content/70"
          >
            {@item.body}
          </span>

          <span
            class="mt-1 block text-xs text-base-content/50"
            title={DateTime.to_string(@item.inserted_at)}
          >
            {relative_time(@item.inserted_at)}
          </span>
        </span>
      </button>

      <button
        type="button"
        phx-click="dismiss"
        phx-value-id={@item.id}
        class="m-2 flex size-8 shrink-0 items-center justify-center self-center rounded-full text-base-content/40 opacity-100 transition hover:bg-error/10 hover:text-error focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-error focus-visible:ring-offset-2 focus-visible:ring-offset-base-100 md:opacity-0 md:group-hover:opacity-100 md:group-focus-within:opacity-100"
        data-role="inbox-item-dismiss"
        aria-label="Dismiss notification"
        title="Dismiss"
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>
    </li>
    """
  end

  # ── Kind → label / icon ────────────────────────────────────────────────

  @doc false
  def kind_label("review_request_pending"), do: "Review requested"
  def kind_label("task_plan_review"), do: "Plan needs review"
  def kind_label("chat_mention"), do: "Mention"
  def kind_label("meeting_starting"), do: "Meeting starting"
  # MUST sit above the humanizing catch-all: it would render "Meeting invited"
  # — a one-character difference that reads as correct at a glance.
  def kind_label("meeting_invited"), do: "Meeting invite"
  def kind_label(other) when is_binary(other), do: Phoenix.Naming.humanize(other)
  def kind_label(_), do: "Notification"

  @doc false
  def kind_icon("review_request_pending"), do: "hero-clipboard-document-check"
  def kind_icon("task_plan_review"), do: "hero-clipboard-document-list"
  def kind_icon("chat_mention"), do: "hero-at-symbol"
  def kind_icon("meeting_starting"), do: "hero-video-camera"
  # An envelope (a message you were sent), not a camera (a call in progress).
  # MUST sit above the `hero-bell` catch-all.
  def kind_icon("meeting_invited"), do: "hero-envelope"
  def kind_icon(_), do: "hero-bell"

  # ── Helpers ────────────────────────────────────────────────────────────

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  @doc """
  A compact relative timestamp ("just now" / "5m ago" / "Jul 21"), matching
  the Activity feed's `time_ago/1` phrasing so the two feeds read alike.
  """
  def relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3_600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3_600)}h ago"
      diff < 2_592_000 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(dt, "%b %-d")
    end
  end

  def relative_time(_), do: ""
end
