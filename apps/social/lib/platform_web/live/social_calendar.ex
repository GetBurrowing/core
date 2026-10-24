defmodule PlatformWeb.SocialCalendar do
  @moduledoc """
  The Calendar's data and its item markup (Social authoring 8/11), for
  `PlatformWeb.SocialCalendarTab`'s two streams.

    * The week runs Monday to Sunday in a named zone
      (`PlatformWeb.SocialCalendarClock`): the profile's zone for one brand,
      the viewer's browser zone for All brands, UTC when neither is known.
    * On the calendar: `needs_approval` posts that have a `scheduled_at` (the
      suggested time), `approved`, `scheduled`, `published` and `failed`.
      A published post is placed by `published_at`, then `scheduled_at`, then
      `approved_at`; any other post by `scheduled_at`, then `approved_at`
      (`Platform.Social.list_posts/2`'s `:calendar_from`/`:calendar_to`).
    * Each item has a STATE, always shown as text plus a border pattern, never
      colour alone: `:waiting` (dashed, "Waiting on you"/"Waiting on
      <owner>"), `:scheduled` (solid), `:failed` and `:refused` (error border
      and badge, the reason on hover/focus), `:published` (solid, muted, plus
      a result chip once Clip Studio 9/9's `metrics` exist).
    * Posts of one idea on one day stack into one group with a platform
      glyph per post.
    * The desktop week is a grid of time rows (one per hour that has an item
      or a posting slot) by seven day columns; a slot shades its cell.
  """

  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [icon: 1]
  import PlatformWeb.SocialHelpers, only: [platform_icon: 1, platform_label: 1]

  alias Platform.Social
  alias PlatformWeb.SocialCalendarClock, as: Clock

  @statuses ~w(needs_approval approved scheduled published failed)

  # Eight brand fills, each a DaisyUI pair whose text clears AA on its fill
  # in both themes (error is reserved for failed posts; accent == primary
  # in this theme). Full literal class strings, so Tailwind sees them.
  @palette [
    "bg-primary text-primary-content border-primary",
    "bg-info text-info-content border-info",
    "bg-success text-success-content border-success",
    "bg-warning text-warning-content border-warning",
    "bg-secondary text-secondary-content border-secondary",
    "bg-base-content text-base-100 border-base-content",
    "bg-base-300 text-base-content border-base-content",
    "bg-base-100 text-base-content border-base-content"
  ]

  @doc "The statuses the calendar shows."
  def statuses, do: @statuses

  @doc "The brand palette (8 class strings)."
  def palette, do: @palette

  @doc "The Monday of the week containing `date`."
  @spec week_start(Date.t()) :: Date.t()
  def week_start(%Date{} = date), do: Date.beginning_of_week(date, :monday)

  @doc "The seven dates of the week starting `monday`."
  def days(%Date{} = monday), do: Enum.map(0..6, &Date.add(monday, &1))

  @doc """
  `[%{id, name, colour, index}]`: one stable colour per profile, keyed by
  the profiles' id order, from the fixed palette.
  """
  def brands(profiles) do
    profiles
    |> Enum.sort_by(& &1.id)
    |> Enum.with_index()
    |> Enum.map(fn {p, i} ->
      %{id: p.id, name: p.name, index: i, colour: Enum.at(@palette, rem(i, length(@palette)))}
    end)
    |> Enum.sort_by(&String.downcase(&1.name || ""))
  end

  @doc """
  The profile's calendar posts placed in the week starting `monday` drawn in
  `zone`, each an item map (`place/3`), in time order.
  """
  def items(profile, accounts, %Date{} = monday, zone, extra \\ %{}) do
    profile.org_id
    |> Social.list_posts([profile_id: profile.id] ++ week_filters(monday, zone))
    |> place(accounts, zone, extra)
  end

  @doc """
  `items/5` across every profile `user` may see (All brands), read through
  `Platform.Social.list_posts_for_profiles/3` (never widened by the caller).
  """
  def items_for_user(user, accounts, %Date{} = monday, zone, extra \\ %{}) do
    user
    |> Social.list_posts_for_profiles(:all, week_filters(monday, zone))
    |> place(accounts, zone, extra)
  end

  defp week_filters(monday, zone) do
    {from, to} = Clock.week_bounds(monday, zone)
    [statuses: @statuses, calendar_from: from, calendar_to: to]
  end

  @doc "When a post sits on the calendar (UTC), or nil."
  def placed_at(%{status: "published"} = post),
    do: post.published_at || post.scheduled_at || post.approved_at

  def placed_at(%{status: "needs_approval"} = post), do: post.scheduled_at
  def placed_at(post), do: post.scheduled_at || post.approved_at

  @doc """
  The item's state: `:waiting`, `:scheduled`, `:refused`, `:failed` or
  `:published`.
  """
  def state(%{status: "needs_approval"}), do: :waiting
  def state(%{status: "approved", refused_reason: r}) when is_binary(r) and r != "", do: :refused
  def state(%{status: s}) when s in ~w(approved scheduled), do: :scheduled
  def state(%{status: "failed"}), do: :failed
  def state(%{status: "published"}), do: :published
  def state(_post), do: :scheduled

  # `extra`: `%{waiting_on: %{account_id => label}, brands: %{profile_id => brand}}`.
  defp place(posts, accounts, zone, extra) do
    by_id = Map.new(accounts, &{&1.id, &1})
    waiting_on = Map.get(extra, :waiting_on, %{})
    brands = Map.get(extra, :brands, %{})

    posts
    |> Enum.flat_map(fn post ->
      with {:ok, account} <- Map.fetch(by_id, post.account_id),
           %DateTime{} = utc <- placed_at(post) do
        at = Clock.local(utc, zone)

        [
          %{
            post: post,
            account: account,
            at: at,
            date: DateTime.to_date(at),
            hour: at.hour,
            state: state(post),
            waiting_on: Map.get(waiting_on, account.id, "Waiting on approval"),
            brand: Map.get(brands, account.profile_id)
          }
        ]
      else
        _ -> []
      end
    end)
    |> Enum.sort_by(&{DateTime.to_unix(&1.at, :microsecond), &1.post.id})
  end

  @doc """
  Items of one idea on one day as one group; every other item is a group of
  one. Each `%{id, at, hour, date, items}`, in time order.
  """
  def groups(items) do
    items
    |> Enum.group_by(fn item ->
      case item.post.idea_id do
        nil -> {:post, item.post.id}
        idea_id -> {:idea, idea_id, item.date}
      end
    end)
    |> Enum.map(fn {_key, [first | _] = members} ->
      %{id: first.post.id, at: first.at, hour: first.hour, date: first.date, items: members}
    end)
    |> Enum.sort_by(&{DateTime.to_unix(&1.at, :microsecond), &1.id})
  end

  @doc """
  The desktop week: one row per hour that has an item group or a slot,
  each `%{id, hour, label, days: [%{date, groups, slots}]}`.
  """
  def rows(items, slots, %Date{} = monday) do
    groups = groups(items)
    days = days(monday)

    (Enum.map(groups, & &1.hour) ++ Enum.map(slots, & &1.hour))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn hour ->
      %{
        id: "h" <> pad(hour),
        hour: hour,
        label: pad(hour) <> ":00",
        days:
          Enum.map(days, fn d ->
            %{
              date: d,
              groups: Enum.filter(groups, &(&1.hour == hour and &1.date == d)),
              slots: Enum.filter(slots, &(&1.hour == hour and &1.date == d))
            }
          end)
      }
    end)
  end

  defp pad(hour), do: hour |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc "One block per day that has items, for the phone agenda."
  def agenda(items, %Date{} = monday) do
    for day <- days(monday),
        day_items = Enum.filter(items, &(&1.date == day)),
        day_items != [],
        do: %{id: Date.to_iso8601(day), date: day, items: day_items}
  end

  @doc "HH:MM of `at` in its own zone."
  def time(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M")

  @doc "Short day head, e.g. \"Mon\"."
  def day_name(%Date{} = d), do: Calendar.strftime(d, "%a")

  @doc "Day label for the agenda, e.g. \"Mon 13 Oct\"."
  def day_label(%Date{} = d), do: Calendar.strftime(d, "%a %-d %b")

  @doc """
  The views figure of a published post's result, or nil. Reads Clip Studio
  9/9's `metrics` (`views`) only when it is there: no metrics means no chip,
  never \"0\".
  """
  def result_views(post) do
    metrics = if is_map(post), do: Map.get(post, :metrics), else: nil

    case metrics && (Map.get(metrics, :views) || Map.get(metrics, "views")) do
      views when is_integer(views) and views >= 0 -> compact(views)
      _ -> nil
    end
  end

  @doc "12_400 -> \"12.4k\", 1_250_000 -> \"1.3M\", 950 -> \"950\"."
  def compact(n) when n >= 1_000_000, do: one_decimal(n / 1_000_000) <> "M"
  def compact(n) when n >= 1_000, do: one_decimal(n / 1_000) <> "k"
  def compact(n), do: Integer.to_string(n)

  defp one_decimal(x) do
    rounded = Float.round(x, 1)

    if rounded == trunc(rounded),
      do: Integer.to_string(trunc(rounded)),
      else: :erlang.float_to_binary(rounded, decimals: 1)
  end

  @doc "Why a failed or refused post did not go out."
  def reason(%{status: "failed", error: e}) when is_binary(e) and e != "", do: e
  def reason(%{status: "failed"}), do: "The publish failed."

  def reason(%{refused_reason: r}) when is_binary(r) and r != "",
    do: "Refused: " <> String.replace(r, "_", " ")

  def reason(_post), do: nil

  @doc "The state's text label for `item`."
  def state_label(%{state: :waiting, waiting_on: who}), do: who
  def state_label(%{state: :scheduled, post: %{status: "approved"}}), do: "approved"
  def state_label(%{state: s}), do: Atom.to_string(s)

  @doc "`{icon, badge classes}` for a state."
  def mark(:waiting), do: {"hero-hand-raised-micro", "badge-outline border-dashed"}
  def mark(:scheduled), do: {"hero-clock-micro", "badge-ghost"}
  def mark(:published), do: {"hero-check-micro", "badge-ghost"}
  def mark(:failed), do: {"hero-x-mark-micro", "badge-error"}
  def mark(:refused), do: {"hero-no-symbol-micro", "badge-error"}
  def mark(_), do: {"hero-minus-micro", "badge-ghost"}

  @doc "The item chip's border pattern and surface for a state."
  def surface(:waiting), do: "border border-dashed border-base-content/70 bg-base-100"
  def surface(:scheduled), do: "border border-solid border-base-content/40 bg-base-100"
  def surface(:published), do: "border border-solid border-base-content/20 bg-base-300"

  def surface(s) when s in [:failed, :refused],
    do: "border-2 border-solid border-error bg-base-100"

  def surface(_), do: "border border-solid border-base-content/40 bg-base-100"

  # ── Markup ───────────────────────────────────────────────────────────

  attr :state, :atom, required: true
  attr :label, :string, required: true

  @doc "A state's badge: icon plus text."
  def state_mark(assigns) do
    {icon, badge} = mark(assigns.state)
    assigns = assign(assigns, icon: icon, badge: badge)

    ~H"""
    <span
      class={["badge badge-sm shrink-0 gap-1 whitespace-nowrap", @badge]}
      data-role="social-calendar-state"
      data-state={@state}
    >
      <.icon name={@icon} class="size-3" />{@label}
    </span>
    """
  end

  attr :brand, :map, default: nil

  @doc "The brand chip (All brands): the brand's colour with its name."
  def brand_chip(assigns) do
    ~H"""
    <span
      :if={@brand}
      class={[
        "inline-flex max-w-[8rem] shrink-0 items-center truncate rounded border px-1.5 text-xs font-semibold",
        @brand.colour
      ]}
      data-role="social-calendar-brand"
      data-brand-id={@brand.id}
    >
      {@brand.name}
    </span>
    """
  end

  attr :post, :map, required: true

  @doc "A published post's result chip; renders nothing without metrics."
  def result_chip(assigns) do
    assigns = assign(assigns, :views, result_views(assigns.post))

    ~H"""
    <span
      :if={@views}
      class="badge badge-sm badge-outline shrink-0 gap-1 whitespace-nowrap"
      data-role="social-calendar-result"
    >
      <.icon name="hero-eye-micro" class="size-3" />{@views} views
    </span>
    """
  end

  attr :item, :map, required: true
  attr :show_brand?, :boolean, default: false
  attr :compact?, :boolean, default: false

  @doc """
  One post on the calendar: a button (opens the post detail) whose border
  pattern and badge say its state; a failed/refused post's reason is in a
  tooltip on hover and focus and in the button's accessible text.
  """
  def item_chip(assigns) do
    assigns = assign(assigns, :reason, reason(assigns.item.post))

    ~H"""
    <div
      class={["w-full", @reason && "tooltip tooltip-bottom"]}
      data-tip={@reason}
    >
      <button
        type="button"
        class={[
          "flex w-full min-w-0 flex-wrap items-center gap-1 rounded px-1.5 py-1 text-left text-base-content",
          surface(@item.state)
        ]}
        phx-click="open_post"
        phx-value-id={@item.post.id}
        data-role="social-calendar-item"
        data-post-id={@item.post.id}
        data-state={@item.state}
        title={@reason}
      >
        <.brand_chip :if={@show_brand?} brand={@item.brand} />
        <span class="shrink-0 whitespace-nowrap font-mono text-xs">{time(@item.at)}</span>
        <span class="inline-flex shrink-0 items-center" title={platform_label(@item.account.platform)}>
          <.platform_icon platform={@item.account.platform} class="size-3.5" />
          <span class="sr-only">{platform_label(@item.account.platform)}</span>
        </span>
        <span :if={!@compact?} class="min-w-0 flex-1 truncate text-sm text-base-content/80">
          {@item.account.handle}
        </span>
        <.state_mark state={@item.state} label={state_label(@item)} />
        <.result_chip :if={@item.state == :published} post={@item.post} />
        <span :if={@reason} class="sr-only" data-role="social-calendar-reason">{@reason}</span>
      </button>
    </div>
    """
  end

  attr :group, :map, required: true
  attr :show_brand?, :boolean, default: false

  @doc """
  A cell entry: a single post's chip, or one idea's posts on one day as one
  stacked chip (a platform glyph per post).
  """
  def group_chip(%{group: %{items: [_one]}} = assigns) do
    ~H"""
    <.item_chip item={hd(@group.items)} show_brand?={@show_brand?} compact? />
    """
  end

  def group_chip(assigns) do
    ~H"""
    <div
      class="space-y-px rounded border border-solid border-base-content/40 bg-base-100 p-0.5"
      data-role="social-calendar-group"
      data-count={length(@group.items)}
    >
      <p class="flex items-center gap-1 px-1 text-xs text-base-content/80">
        <.icon name="hero-square-3-stack-3d-micro" class="size-3" />
        <span>{length(@group.items)} posts, one idea</span>
      </p>
      <.item_chip :for={item <- @group.items} item={item} show_brand?={@show_brand?} compact? />
    </div>
    """
  end
end
