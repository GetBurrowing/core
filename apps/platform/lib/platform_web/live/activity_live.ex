defmodule PlatformWeb.ActivityLive do
  @moduledoc """
  Read-only audit log of AI agent actions across the viewer's accessible
  (non-archived) spaces.

  Each row carries a `:state` of `:active` or `:undone` derived at fetch
  time from the underlying resource's `deleted_at`. Active rows render
  unmarked; `:undone` rows render with a "Deleted" pill and strikethrough.
  State never mutates in the LiveView — there is no UI action to flip it.

  Sort is always `inserted_at desc` for cursor stability — pagination
  cannot skip or duplicate rows. Pill renders only on `:undone` rows;
  Active is the unmarked default.

  Pagination is **numbered pages** (10 per page). Total page count comes
  from `Chat.count_recent_agent_actions/1`. Each page navigation fetches
  only that page's slice (over-fetch + slice on the server side).

  Polling-only; no live streaming. See `Platform.Chat.list_recent_agent_actions/1`.
  """

  use PlatformWeb, :live_view

  alias Platform.Chat
  alias Platform.Chat.{Canvas, Message}

  @ranges ~w(24h 7d 30d all)
  @default_range "24h"
  @page_size 10

  @impl true
  def mount(_params, _session, socket) do
    {actions, page, total_pages} = load_page(@default_range, 1)

    {:ok,
     socket
     |> assign(:page_title, "Activity")
     |> assign(:current_path, "/activity")
     |> assign(:range, @default_range)
     |> assign(:ranges, @ranges)
     |> assign(:page, page)
     |> assign(:total_pages, total_pages)
     |> assign(:page_size, @page_size)
     |> assign(:actions, actions)}
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    range = if range in @ranges, do: range, else: @default_range
    {actions, page, total_pages} = load_page(range, 1)

    {:noreply,
     socket
     |> assign(:range, range)
     |> assign(:page, page)
     |> assign(:total_pages, total_pages)
     |> assign(:actions, actions)}
  end

  def handle_event("refresh", _params, socket) do
    {actions, page, total_pages} = load_page(socket.assigns.range, socket.assigns.page)

    {:noreply,
     socket
     |> assign(:page, page)
     |> assign(:total_pages, total_pages)
     |> assign(:actions, actions)
     |> put_flash(:info, "Refreshed")}
  end

  def handle_event("goto_page", %{"page" => page_str}, socket) do
    page = parse_page(page_str)
    {actions, page, total_pages} = load_page(socket.assigns.range, page)

    {:noreply,
     socket
     |> assign(:page, page)
     |> assign(:total_pages, total_pages)
     |> assign(:actions, actions)}
  end

  # ── Page loader ────────────────────────────────────────────────────────────

  defp load_page(range, page) do
    since = since_for_range(range)

    count_opts = [include_deleted: true]
    count_opts = put_since(count_opts, since)
    total = Chat.count_recent_agent_actions(count_opts)

    total_pages = max(1, ceil_div(total, @page_size))
    page = clamp(page, 1, total_pages)

    # Over-fetch up to (page * @page_size) items so we can slice the page's
    # window. The list call's dual-stream merge means we need at least
    # `page * @page_size` items in the merged-and-sorted result.
    list_opts = [limit: page * @page_size, include_deleted: true]
    list_opts = put_since(list_opts, since)

    all = Chat.list_recent_agent_actions(list_opts)
    actions = Enum.slice(all, (page - 1) * @page_size, @page_size)

    {actions, page, total_pages}
  end

  defp parse_page(page_str) do
    case Integer.parse(to_string(page_str)) do
      {n, _} when n >= 1 -> n
      _ -> 1
    end
  end

  defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)

  defp ceil_div(0, _denom), do: 0
  defp ceil_div(num, denom) when num > 0, do: div(num + denom - 1, denom)

  defp put_since(opts, nil), do: opts
  defp put_since(opts, %DateTime{} = since), do: Keyword.put(opts, :since, since)

  defp since_for_range("24h"), do: DateTime.add(DateTime.utc_now(), -86_400, :second)
  defp since_for_range("7d"), do: DateTime.add(DateTime.utc_now(), -604_800, :second)
  defp since_for_range("30d"), do: DateTime.add(DateTime.utc_now(), -2_592_000, :second)
  defp since_for_range("all"), do: nil
  defp since_for_range(_), do: DateTime.add(DateTime.utc_now(), -86_400, :second)

  # ── Template helpers ──────────────────────────────────────────────────────

  def range_label("24h"), do: "Last 24 hours"
  def range_label("7d"), do: "Last 7 days"
  def range_label("30d"), do: "Last 30 days"
  def range_label("all"), do: "All time"
  def range_label(other), do: other

  def avatar_initial(nil), do: "?"
  def avatar_initial(""), do: "?"

  def avatar_initial(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.first()
    |> Kernel.||("?")
    |> String.upcase()
  end

  def kind_label(:message), do: "Message"
  def kind_label(:canvas), do: "Canvas"
  def kind_label(other), do: to_string(other)

  def action_preview(%{kind: :message, item: %Message{content: content}})
      when is_binary(content) do
    String.slice(content, 0, 200)
  end

  def action_preview(%{kind: :canvas, item: %Canvas{title: title}}) do
    case title do
      t when is_binary(t) and t != "" -> t
      _ -> "(untitled canvas)"
    end
  end

  def action_preview(_), do: ""

  def time_ago(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3_600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3_600)}h ago"
      diff < 2_592_000 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(dt, "%b %-d")
    end
  end

  def time_ago(_), do: ""

  @doc """
  Groups a list of actions by their inserted_at date (UTC), returning
  `[{date, [action]}]` in reverse chronological order. Used by the
  Activity feed to render day-section headers above each group.

  UTC is intentional — `time_ago/1` already uses UTC for the relative
  label, so the date boundary here matches what the user sees on each
  item ("3h ago" rolls into the right day-bucket).
  """
  @spec group_actions_by_day([map()]) :: [{Date.t(), [map()]}]
  def group_actions_by_day(actions) when is_list(actions) do
    actions
    |> Enum.group_by(fn action -> DateTime.to_date(action.inserted_at) end)
    |> Enum.sort_by(fn {date, _actions} -> date end, {:desc, Date})
  end

  @doc """
  Renders the section header label for a given date relative to today.
  Today/yesterday use the relative phrase + explicit date; same-year
  dates use weekday + month/day; older dates include the year.
  """
  @spec day_header_label(Date.t()) :: String.t()
  def day_header_label(%Date{} = date) do
    today = Date.utc_today()
    diff = Date.diff(today, date)

    cond do
      diff == 0 -> "Today · " <> Calendar.strftime(date, "%b %-d")
      diff == 1 -> "Yesterday · " <> Calendar.strftime(date, "%b %-d")
      date.year == today.year -> Calendar.strftime(date, "%a, %b %-d")
      true -> Calendar.strftime(date, "%b %-d, %Y")
    end
  end

  @doc """
  Visible page numbers for a numbered-pagination nav. Returns a list of
  integers and `:ellipsis` markers. For ≤7 total pages, shows them all;
  otherwise shows 1, neighbors of current, and last with ellipses.
  """
  @spec visible_pages(integer(), integer()) :: [integer() | :ellipsis]
  def visible_pages(_current, total) when total <= 7, do: Enum.to_list(1..total)

  def visible_pages(current, total) when current <= 4 do
    Enum.to_list(1..5) ++ [:ellipsis, total]
  end

  def visible_pages(current, total) when current >= total - 3 do
    [1, :ellipsis] ++ Enum.to_list((total - 4)..total)
  end

  def visible_pages(current, total) do
    [1, :ellipsis, current - 1, current, current + 1, :ellipsis, total]
  end
end
