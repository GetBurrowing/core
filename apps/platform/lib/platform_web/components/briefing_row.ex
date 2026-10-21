defmodule PlatformWeb.Components.BriefingRow do
  @moduledoc """
  The daily briefing's row in the Inbox list (task 01a15ee1 stage 4).

  One `Platform.Inbox.Item` of kind `briefing` per person per day
  (`source_id` is the `memory_briefings` id). The row opens the day's
  briefing at `/inbox/briefing/<digest_date>`; opening marks it read and
  it STAYS listed (`briefing` is in `Platform.Inbox.action_kinds/0`), so
  a read row loses its dot and keeps its live subtitle.

  ## Logic and markup are separate

  `assigns_for/2` is a pure function from the Inbox row plus the
  briefing's live counts (`Platform.Memory.Insights.Briefings.view/2`) to
  every slot the row shows: kind, title, receipt line, time, unread and
  selected. `briefing_row/1` only paints those slots. A later list
  renderer (the shared Inbox list row) can call `assigns_for/2` as it is
  and change only the markup.

  ## Copy (canvas 01a15ee2 rev 2 and prototype 01a15ec9 v1)

    * kind: "Briefing";
    * title: "Today's briefing" when `digest_date` is today in the
      viewer's zone, else "Briefing · Mon, Oct 20";
    * receipt line: "<N> items · <K> need your call" (the call count is a
      pill, "1 needs your call" when K is 1), "<N> items · FYI only" when
      K is 0, and "All done · nothing waiting" when nothing is open;
    * time: when the row was delivered, as "7:00" in the viewer's zone.

  ## Skin

  Main's Inbox row (`PlatformWeb.Components.InboxItem`): the
  `rounded-2xl border border-edge bg-base-100` card, the kind line, the
  unread dot at the right end of the kind line with an `sr-only` "Unread",
  and secondary text in `text-subtle`. Hover and the selected bar apply at
  `lg` and up only: below `lg` a tap navigates, so there is no selected
  state to show and no hover to rely on.
  """

  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [icon: 1]

  alias Platform.Inbox
  alias Platform.Inbox.Item

  @default_zone "America/Chicago"

  @doc "The kind word every briefing row carries."
  @spec kind_label() :: String.t()
  def kind_label, do: "Briefing"

  @doc """
  Every slot of the row, as plain data.

  `item` is the Inbox row. Options:

    * `:counts` — `%{total, open, calls}` from `Briefings.view/2`
      (default all zero);
    * `:digest_date` — the briefing's `Date` (default: parsed from the
      row's url);
    * `:today` — today's `Date` in the viewer's zone (default: computed
      from `:time_zone`);
    * `:time_zone` — the viewer's IANA zone (default America/Chicago,
      the zone `digest_date` is written in);
    * `:selected` — whether this row's briefing is open in the detail
      pane (default false).
  """
  @spec assigns_for(Item.t(), keyword()) :: map()
  def assigns_for(%Item{} = item, opts \\ []) do
    zone = Keyword.get(opts, :time_zone) || @default_zone
    counts = Map.merge(%{total: 0, open: 0, calls: 0}, Keyword.get(opts, :counts) || %{})
    date = Keyword.get(opts, :digest_date) || date_from_url(item.url)
    today = Keyword.get_lazy(opts, :today, fn -> today(zone) end)
    {lead, pill} = receipt_line(counts)

    %{
      id: item.id,
      dom_id: "inbox-briefing-#{item.id}",
      kind: kind_label(),
      title: title(date, today),
      date: date,
      url: date && Inbox.briefing_url(date),
      receipt_lead: lead,
      receipt_pill: pill,
      summary: summary(counts),
      time: time(item.inserted_at, zone),
      unread?: is_nil(item.read_at),
      selected?: Keyword.get(opts, :selected, false) == true,
      counts: counts
    }
  end

  @doc """
  The row's title: "Today's briefing" for today, else "Briefing · Mon, Oct 20".
  """
  @spec title(Date.t() | nil, Date.t()) :: String.t()
  def title(%Date{} = date, %Date{} = today) do
    if Date.compare(date, today) == :eq,
      do: Inbox.briefing_title(),
      else: "Briefing · " <> Calendar.strftime(date, "%a, %b %-d")
  end

  def title(_date, _today), do: Inbox.briefing_title()

  @doc """
  The receipt line as one string, e.g. "5 items · 3 need your call",
  "5 items · FYI only" or "All done · nothing waiting".
  """
  @spec summary(map()) :: String.t()
  def summary(%{open: 0}), do: "All done · nothing waiting"
  def summary(%{total: total, calls: calls}), do: Inbox.briefing_summary(total, calls)

  # `{lead, pill}`: the plain part of the line and the call-count pill
  # (nil when nothing needs a call). Joined, they read exactly `summary/1`.
  defp receipt_line(%{open: 0} = counts), do: {summary(counts), nil}
  defp receipt_line(%{calls: 0} = counts), do: {summary(counts), nil}

  defp receipt_line(%{total: total, calls: calls}) do
    items = if total == 1, do: "1 item", else: "#{total} items"
    pill = if calls == 1, do: "1 needs your call", else: "#{calls} need your call"
    {items <> " · ", pill}
  end

  @doc "Today's date in `zone` (falls back to America/Chicago)."
  @spec today(String.t() | nil) :: Date.t()
  def today(zone) do
    case DateTime.now(zone || @default_zone) do
      {:ok, now} -> DateTime.to_date(now)
      {:error, _} -> @default_zone |> DateTime.now!() |> DateTime.to_date()
    end
  end

  defp time(%DateTime{} = at, zone) do
    local =
      case DateTime.shift_zone(at, zone) do
        {:ok, shifted} -> shifted
        {:error, _} -> DateTime.shift_zone!(at, @default_zone)
      end

    Calendar.strftime(local, "%-H:%M")
  end

  defp time(_at, _zone), do: ""

  defp date_from_url("/inbox/briefing/" <> iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp date_from_url(_url), do: nil

  # ── Markup ─────────────────────────────────────────────────────────────

  attr :row, :map, required: true, doc: "The map `assigns_for/2` returns."
  attr :patch, :string, required: true, doc: "Where the row patches to (keeps the filter)."

  def briefing_row(assigns) do
    ~H"""
    <li
      id={@row.dom_id}
      class={[
        "group relative flex items-stretch gap-1 rounded-2xl border border-edge transition-colors lg:hover:border-base-content/20",
        if(@row.selected?, do: "bg-base-100 lg:bg-base-300", else: "bg-base-100")
      ]}
      data-role="inbox-briefing-row"
      data-item-id={@row.id}
      data-date={@row.date && Date.to_iso8601(@row.date)}
      data-selected={to_string(@row.selected?)}
    >
      <%!-- The selected bar: desktop two-pane only. Below lg a tap navigates,
           so there is no selected state to show. --%>
      <span
        :if={@row.selected?}
        class="absolute inset-y-0 left-0 hidden w-1 rounded-l-2xl bg-primary lg:block"
        aria-hidden="true"
      >
      </span>
      <.link
        patch={@patch}
        class="flex min-w-0 flex-1 items-start gap-3 rounded-2xl py-3 pl-4 pr-4 text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring focus-visible:ring-offset-2 focus-visible:ring-offset-base-100"
        data-role="inbox-briefing-open"
        aria-current={if(@row.selected?, do: "page")}
      >
        <span
          class="flex size-9 shrink-0 items-center justify-center rounded-xl bg-primary text-primary-content"
          data-role="inbox-briefing-icon"
          aria-hidden="true"
        >
          <.icon name="hero-sun" class="size-5" />
        </span>
        <span class="min-w-0 flex-1">
          <span class="flex flex-wrap items-center gap-2">
            <span
              class="text-[11px] font-medium uppercase tracking-wide text-subtle"
              data-role="inbox-briefing-kind"
            >
              {@row.kind}
            </span>
            <span
              :if={@row.unread?}
              class="ml-auto size-2 shrink-0 rounded-full bg-primary"
              data-role="inbox-briefing-unread-dot"
              aria-hidden="true"
            >
            </span>
            <span :if={@row.unread?} class="sr-only">Unread</span>
          </span>

          <span
            class={[
              "mt-1 block truncate text-sm text-base-content",
              if(@row.unread?, do: "font-semibold", else: "font-normal")
            ]}
            data-role="inbox-briefing-title"
          >
            {@row.title}
          </span>

          <span class="mt-0.5 block text-sm text-subtle" data-role="inbox-briefing-summary">
            {@row.receipt_lead}<span
              :if={@row.receipt_pill}
              class="inline-flex items-center rounded-full bg-warning-dim px-2 py-0.5 text-[11px] font-bold text-base-content"
              data-role="inbox-briefing-calls"
            >{@row.receipt_pill}</span>
          </span>

          <span class="mt-1 block text-xs text-subtle" data-role="inbox-briefing-time">
            {@row.time}
          </span>
        </span>
      </.link>

      <button
        type="button"
        phx-click="dismiss_briefing"
        phx-value-id={@row.id}
        class="m-2 flex size-8 shrink-0 items-center justify-center self-center rounded-full text-subtle opacity-100 transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-error focus-visible:ring-offset-2 focus-visible:ring-offset-base-100 lg:opacity-0 lg:hover:bg-error/10 lg:hover:text-error lg:group-hover:opacity-100 lg:group-focus-within:opacity-100"
        data-role="inbox-briefing-dismiss"
        aria-label="Dismiss briefing"
        title="Dismiss"
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>
    </li>
    """
  end
end
