defmodule PlatformWeb.Components.UxDecisionRow do
  @moduledoc """
  The UX role's question as an Inbox row (task 01a1af00 stage 3, design
  canvas `01a1b684-c1dd` node `layout`).

  One `Platform.Inbox.Item` of kind `ux_decision` per finding, addressed to
  the finding's recipient (`Platform.Ux.Decisions`). The row opens the
  question in the detail pane (`/inbox/ux/<finding_id>`).

  ## Anatomy

      [UX]  Make DMs a top-level tab on mobile?            2h
            Seen 6× this week across 3 channels · "can't find my DMs"

    * the `UX` chip: `bg-info text-info-content` (teal), never the primary
      fill, which belongs to the one recommended answer;
    * the question as the title: semibold body type in `text-base-content`.
      It NEVER truncates: it wraps (two lines in practice), the chip and the
      time are `shrink-0`, so neither takes space from it;
    * the time and the evidence line in the secondary-text token
      (`text-subtle`; see the deviation note below). The evidence line is
      the one part that truncates (`min-w-0 truncate`).

  No severity badge, ever: the count says why it matters.

  ## Deviation: `text-subtle`, not `text-neutral`

  The canvas palette names `--color-neutral` for the evidence and time.
  As TEXT, `--color-neutral` is a fill colour: in the dark theme it is
  `oklch(40%)` on a near-black base, far below 4.5:1. The secondary-text
  token is `--color-subtle`, which every Inbox row already uses.

  `assigns_for/3` is the pure part (item + finding -> slots); the function
  components only paint, like `PlatformWeb.Components.MeetingBriefingRow`.
  """

  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [icon: 1]

  alias Platform.Inbox.Item
  alias Platform.Ux.Decisions
  alias Platform.Ux.Finding
  alias PlatformWeb.Components.InboxItem

  @doc """
  Every slot of the row, as plain data. `finding` may be nil (a row whose
  finding is gone): the row then shows the item's own title and body.

  Options: `:selected` — whether this row's question is open in the pane.
  """
  @spec assigns_for(Item.t(), Finding.t() | nil, keyword()) :: map()
  def assigns_for(%Item{} = item, finding, opts \\ []) do
    evidence = (finding && finding.evidence) || %{}

    %{
      id: item.id,
      dom_id: "inbox-ux-#{item.id}",
      finding_id: item.source_id,
      question: (finding && finding.question) || item.title,
      evidence: if(finding, do: Decisions.evidence_line(evidence), else: item.body),
      quotes: Decisions.quotes(evidence),
      inserted_at: item.inserted_at,
      time: InboxItem.relative_time(item.inserted_at),
      url: item.url || Decisions.url(item.source_id),
      unread?: is_nil(item.read_at),
      selected?: Keyword.get(opts, :selected, false) == true
    }
  end

  @doc "The evidence line with its quotes, one string, for a truncating line."
  @spec evidence_text(map()) :: String.t()
  def evidence_text(%{evidence: evidence, quotes: quotes}) do
    [evidence | Enum.map(quotes, &("“" <> &1 <> "”"))]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" · ")
  end

  @doc "The teal `UX` source chip."
  attr :class, :any, default: nil

  def ux_chip(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex h-5 shrink-0 items-center rounded px-1.5 text-[11px] font-semibold leading-none tracking-wide bg-info text-info-content",
        @class
      ]}
      data-role="ux-chip"
    >
      UX
    </span>
    """
  end

  @doc "The desktop row: a stream child of the Inbox's decisions list."
  attr :id, :string, required: true
  attr :row, :map, required: true
  attr :patch, :string, required: true

  def ux_decision_row(assigns) do
    ~H"""
    <li
      id={@id}
      class={[
        "group relative flex items-stretch gap-1 rounded-2xl border border-edge transition-colors lg:hover:border-base-content/20",
        if(@row.selected?, do: "bg-base-100 lg:bg-base-300", else: "bg-base-100")
      ]}
      data-role="inbox-ux-row"
      data-item-id={@row.id}
      data-finding-id={@row.finding_id}
      data-selected={to_string(@row.selected?)}
    >
      <span
        :if={@row.selected?}
        class="absolute inset-y-0 left-0 hidden w-1 rounded-l-2xl bg-primary lg:block"
        aria-hidden="true"
      >
      </span>
      <.link
        patch={@patch}
        class="flex min-w-0 flex-1 flex-col gap-1 rounded-2xl py-3 pl-4 pr-2 text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring focus-visible:ring-offset-2 focus-visible:ring-offset-base-100"
        data-role="inbox-ux-open"
        aria-current={if(@row.selected?, do: "page")}
      >
        <span class="flex items-start gap-2">
          <.ux_chip class="mt-0.5" />
          <span
            class="min-w-0 flex-1 break-words text-sm font-semibold text-base-content"
            data-role="inbox-ux-question"
          >
            {@row.question}
          </span>
          <time
            datetime={@row.inserted_at && DateTime.to_iso8601(@row.inserted_at)}
            class="shrink-0 whitespace-nowrap pt-0.5 text-xs tabular-nums text-subtle"
            data-role="inbox-ux-time"
          >
            {@row.time}
          </time>
          <span
            :if={@row.unread?}
            class="mt-1.5 size-2 shrink-0 rounded-full bg-primary"
            data-role="inbox-ux-unread-dot"
            aria-hidden="true"
          >
          </span>
          <span :if={@row.unread?} class="sr-only">Unread</span>
        </span>
        <span class="flex min-w-0 pl-9">
          <span class="min-w-0 truncate text-sm text-subtle" data-role="inbox-ux-evidence">
            {evidence_text(@row)}
          </span>
        </span>
      </.link>

      <button
        type="button"
        phx-click="dismiss_ux"
        phx-value-id={@row.id}
        class="m-1 flex size-11 shrink-0 items-center justify-center self-center rounded-full text-subtle opacity-100 transition lg:m-2 lg:size-8 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-error focus-visible:ring-offset-2 focus-visible:ring-offset-base-100 lg:opacity-0 lg:hover:bg-error/10 lg:hover:text-error lg:group-hover:opacity-100 lg:group-focus-within:opacity-100"
        data-role="inbox-ux-dismiss"
        aria-label="Dismiss UX question"
        title="Dismiss"
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>
    </li>
    """
  end

  @doc """
  The phone list's row body (inside `PlatformWeb.Inbox.InboxList`'s row
  link): chip, question, time, then the truncating evidence line.
  """
  attr :row, :map, required: true

  def ux_phone_row_body(assigns) do
    ~H"""
    <span class="min-w-0 flex-1" data-role="inbox-row-ux">
      <span class="flex items-start gap-2">
        <.ux_chip class="mt-0.5" />
        <b
          data-role="inbox-row-author"
          class="min-w-0 flex-1 break-words text-[15px] font-semibold text-base-content"
        >
          {@row.question}
        </b>
        <time class="shrink-0 whitespace-nowrap pt-0.5 text-xs tabular-nums text-subtle">
          {@row.time}
        </time>
      </span>
      <span class="mt-0.5 flex min-w-0">
        <span data-role="inbox-row-body" class="min-w-0 truncate text-sm text-subtle">
          {evidence_text(@row)}
        </span>
      </span>
    </span>
    """
  end
end
