defmodule PlatformWeb.Components.InboxItem do
  @moduledoc """
  A single Inbox row — one `Platform.Inbox.Item` rendered as a stream child.

  Layout is up to THREE sibling controls under one `<li>`, deliberately NOT
  nested:

    * the **select** checkbox (`phx-click="toggle_select"`), leftmost, present
      only when `selectable`.
    * the **open** control (`phx-click="open"`) fills the row and carries the
      item's `id` + `url`; clicking it acknowledges the item
      (`Platform.Inbox.open_item/2`) and navigates to `item.url`.
    * the **dismiss** affordance (`phx-click="dismiss"`) is a right-aligned X.

  All three are SIBLINGS, never descendants of one another, so a click on the
  X fires only `dismiss` and a click on the checkbox fires only
  `toggle_select` — neither ever bubbles into `open`. This is the rule the
  whole row layout exists to protect: `open` acknowledges the item and navigates
  away, so any control that accidentally nests inside it becomes a trapdoor.

  The dismiss X is always tappable on mobile (the touch equivalent of the
  desktop swipe-left / hover-reveal), and hover-revealed on desktop
  (`md:opacity-0 md:group-hover:opacity-100`) so the resting row stays calm.

  ## Read state: one marker per row (task 01a11703 stage 2)

  The leftmost slot belongs to the select checkbox. The unread dot does NOT
  share it: the dot sits at the RIGHT end of the meta line (`ml-auto`), so the
  checkbox and the dot are never two small primary-toned marks stacked a few
  pixels apart. The dot keys on `is_nil(@item.read_at)` and nothing else.

  A row carries exactly one of three markers:

    * **Unread** (`read_at` nil, any kind): the `bg-primary` dot plus an
      `sr-only` "Unread", and a `font-semibold` title. The dot is a fill, not
      text, and cyan on base-100 is below 3:1, so the weight step and the
      screen-reader text carry the meaning; the dot is a redundant cue.
    * **Seen, awaiting your action** (`read_at` set and the kind is in
      `Platform.Inbox.action_kinds/0`): a `font-normal` title and an outlined
      "Needs your review" tag (`text-info` on `border-info/40`, transparent
      fill) inside the meta line, after the kind label. Opening an action row
      stamps `read_at` only, so the row stays listed until the review is acted
      on.
    * **Nothing**: a read row outside `action_kinds/0`. Opening such a row
      dismisses it, so on this surface it appears only after an Undo restores
      it; it renders at normal weight with no dot and no tag.

  The dot and the tag are mutually exclusive by construction: the dot needs
  `read_at` nil and the tag needs it set.

  At 375px the meta line's existing `flex-wrap` drops the tag under the kind
  label, and `ml-auto` keeps the dot on the first meta line.

  The dom id (`inbox-item-<id>`) is supplied by the caller so it matches the
  stream `dom_id` and `stream_delete_by_dom_id/3` target exactly.

  Styling reads only from semantic DaisyUI token slots per
  `docs/design-system/01-foundations.md`, no raw hex: `bg-primary` (unread
  dot), `text-info` + `border-info/40` (Needs-your-review tag), `base-100` +
  `border-edge` (row ground), `text-base-content` (body), and `error` (the
  dismiss X hover). The rail count stays `badge-error` in `IconRail`; this
  component does not render it. The kind badge and the per-item space label
  give each row its taxonomy at a glance.
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
    doc: "Render the leftmost select checkbox."

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
        <span class="min-w-0 flex-1">
          <span class="flex flex-wrap items-center gap-2">
            <span
              class="inline-flex items-center gap-1 text-[11px] font-medium uppercase tracking-wide text-subtle"
              data-role="inbox-item-kind"
            >
              <.icon name={kind_icon(@item.kind)} class="size-3.5" />
              {kind_label(@item.kind)}
            </span>
            <span
              :if={@space_label}
              class="inline-flex items-center rounded-full bg-base-200 px-2 py-0.5 text-xs font-medium text-subtle"
              data-role="inbox-item-space"
            >
              {@space_label}
            </span>
            <%!-- Seen, awaiting action: read action rows only (see moduledoc). --%>
            <span
              :if={needs_action?(@item)}
              data-role="inbox-item-needs-action"
              class="inline-flex items-center rounded-full border border-info/40 px-2 py-0.5 text-[11px] font-medium text-info"
            >
              Needs your review
            </span>
            <%!-- Unread: the dot sits at the right end of the meta line. --%>
            <span
              :if={unread?(@item)}
              class="ml-auto size-2 shrink-0 rounded-full bg-primary"
              data-role="inbox-item-unread-dot"
              aria-hidden="true"
            >
            </span>
            <span :if={unread?(@item)} class="sr-only">Unread</span>
          </span>

          <span
            class={[
              "mt-1 block truncate text-sm text-base-content",
              if(unread?(@item), do: "font-semibold", else: "font-normal")
            ]}
            data-role="inbox-item-title"
          >
            {@item.title}
          </span>

          <span
            :if={present?(@item.body)}
            class="mt-0.5 block line-clamp-2 text-sm text-base-content"
          >
            {@item.body}
          </span>

          <span
            class="mt-1 block text-xs text-subtle"
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
        class="m-2 flex size-8 shrink-0 items-center justify-center self-center rounded-full text-subtle opacity-100 transition hover:bg-error/10 hover:text-error focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-error focus-visible:ring-offset-2 focus-visible:ring-offset-base-100 md:opacity-0 md:group-hover:opacity-100 md:group-focus-within:opacity-100"
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

  # ONE table for every core kind's label, in both forms (redesign rung 14):
  #
  #   * `:long`, the desktop row's label (`kind_label/1`), unchanged;
  #   * `:short`, the phone Inbox's kind word on the meta line (Saru, Inbox
  #     canvas 01a15ec4 rev 2), read by `PlatformWeb.Inbox.InboxList`.
  #
  # "Meeting invite" is spelled out, not humanized: the humanizing fallback
  # would render "Meeting invited", a one-character difference that reads as
  # correct at a glance. An extension kind and an unknown kind share ONE
  # fallback for both forms (`kind_label/2`).
  @kind_labels %{
    "review_request_pending" => %{long: "Review requested", short: "Review"},
    "task_plan_review" => %{long: "Plan needs review", short: "Plan review"},
    "chat_mention" => %{long: "Mention", short: "Mention"},
    "meeting_starting" => %{long: "Meeting starting", short: "Starting now"},
    "meeting_invited" => %{long: "Meeting invite", short: "Meeting invite"},
    "task_sponsor_assigned" => %{long: "Task sponsor assigned", short: "Sponsor"},
    "lifecycle_step_failed" => %{long: "Lifecycle step failed", short: "Step failed"},
    # Main's daily briefing kind (task 01a15ee1). Main had no explicit label,
    # so its desktop form is the humanized key, kept as-is.
    "briefing" => %{long: "Briefing", short: "Briefing"},
    # Main's meeting briefing kind (task 01a1694a). The short form is the
    # word its own row renders (`MeetingBriefingCopy.kind_label/0`).
    "meeting_briefing" => %{long: "Meeting briefing", short: "Meeting"}
  }

  @doc "The core kinds `kind_label/2` has an explicit entry for."
  def labelled_kinds, do: Map.keys(@kind_labels)

  @doc false
  def kind_label(kind), do: kind_label(kind, :long)

  @doc """
  A kind's label in `form` `:long` (the desktop row) or `:short` (the phone
  Inbox's kind word). Core kinds read `@kind_labels`. Any other kind falls
  back, in both forms, to the registered extension's declared `label`, then to
  the humanized key; a non-string kind is "Notification".
  """
  def kind_label(kind, form) when is_binary(kind) and form in [:long, :short] do
    case Map.fetch(@kind_labels, kind) do
      {:ok, labels} -> Map.fetch!(labels, form)
      :error -> fallback_label(kind)
    end
  end

  def kind_label(_kind, form) when form in [:long, :short], do: "Notification"

  defp fallback_label(kind) do
    case Platform.Extensions.inbox_kind(kind) do
      %{label: label} -> label
      nil -> Phoenix.Naming.humanize(kind)
    end
  end

  @doc false
  def kind_icon("review_request_pending"), do: "hero-clipboard-document-check"
  def kind_icon("task_plan_review"), do: "hero-clipboard-document-list"
  def kind_icon("chat_mention"), do: "hero-at-symbol"
  def kind_icon("meeting_starting"), do: "hero-video-camera"
  # An envelope (a message you were sent), not a camera (a call in progress).
  # MUST sit above the `hero-bell` catch-all.
  def kind_icon("meeting_invited"), do: "hero-envelope"
  # The camera `MeetingBriefingRow` shows. Above the catch-all too.
  def kind_icon("meeting_briefing"), do: "hero-video-camera"

  def kind_icon(other) do
    case Platform.Extensions.inbox_kind(other) do
      %{icon: icon} -> icon
      nil -> "hero-bell"
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp unread?(%Item{read_at: nil}), do: true
  defp unread?(%Item{}), do: false

  defp needs_action?(%Item{read_at: nil}), do: false
  # A read `briefing` row stays listed (it is in `action_kinds/0`) but asks for
  # no review; the briefing has its own row renderer (task 01a15ee1 stage 4).
  defp needs_action?(%Item{kind: "briefing"}), do: false
  defp needs_action?(%Item{kind: "meeting_briefing"}), do: false
  defp needs_action?(%Item{kind: kind}), do: kind in Platform.Inbox.action_kinds()

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
