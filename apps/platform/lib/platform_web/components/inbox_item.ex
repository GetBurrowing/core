defmodule PlatformWeb.Components.InboxItem do
  @moduledoc """
  A single Inbox row — one `Platform.Inbox.Item` rendered as a stream child.

  Layout is two sibling controls under one `<li>`, deliberately NOT nested:

    * the **open** control (`phx-click="open"`) fills the row and carries the
      item's `id` + `url`; clicking it marks the item read and navigates to
      `item.url`.
    * the **dismiss** affordance (`phx-click="dismiss"`) is a right-aligned X.
      It is a SIBLING of the open control, never a descendant, so a click on
      the X fires only `dismiss` and never bubbles into `open`.

  The dismiss X is always tappable on mobile (the touch equivalent of the
  desktop swipe-left / hover-reveal), and hover-revealed on desktop
  (`md:opacity-0 md:group-hover:opacity-100`) so the resting row stays calm.

  The dom id (`inbox-item-<id>`) is supplied by the caller so it matches the
  stream `dom_id` and `stream_delete_by_dom_id/3` target exactly.

  Styling reads only from semantic DaisyUI token slots (primary / base-* /
  error) per `docs/design-system/01-foundations.md` — no raw hex. The unread
  dot is the row's signature element (`bg-primary`); the kind badge and the
  per-item space label give each row its taxonomy at a glance.
  """

  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [icon: 1]

  alias Platform.Inbox.Item

  attr :id, :string, required: true, doc: ~s(dom id, "inbox-item-<item.id>")
  attr :item, Item, required: true

  attr :space_label, :string,
    default: nil,
    doc: "Space label for chat_mention rows (grouping cue); nil for other kinds."

  def inbox_item(assigns) do
    ~H"""
    <li
      id={@id}
      class="group relative flex items-stretch gap-1 rounded-2xl border border-base-300 bg-base-100 transition-colors hover:border-base-content/20"
      data-role="inbox-item"
      data-item-id={@item.id}
      data-item-kind={@item.kind}
    >
      <button
        type="button"
        phx-click="open"
        phx-value-id={@item.id}
        phx-value-url={@item.url}
        class="flex min-w-0 flex-1 items-start gap-3 rounded-2xl px-4 py-3 text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2 focus-visible:ring-offset-base-100"
        data-role="inbox-item-open"
      >
        <%!-- Signature element: the unread dot. --%>
        <span
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
