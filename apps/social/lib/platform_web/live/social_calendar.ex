defmodule PlatformWeb.SocialCalendar do
  @moduledoc """
  The Social tab's week (Social 7/7 stage 3), as plain data for
  `PlatformWeb.SocialLive`'s two calendar streams.

    * The week runs Monday to Sunday in UTC: core exposes no timezone on the
      user, so the page says "UTC" next to the week.
    * A post is placed by `scheduled_at`, or `approved_at` when it was
      published (or failed) at approval with no schedule; the schema has no
      published-at column (`Platform.Social.list_posts/2`'s `:placed_from`).
    * Only `scheduled`, `published` and `failed` posts are on the calendar.
  """

  alias Platform.Social

  @statuses ~w(scheduled published failed)

  @doc "The statuses the calendar shows."
  def statuses, do: @statuses

  @doc "The Monday of the week containing `date`."
  @spec week_start(Date.t()) :: Date.t()
  def week_start(%Date{} = date), do: Date.beginning_of_week(date, :monday)

  @doc "The seven dates of the week starting `monday`."
  def days(%Date{} = monday), do: Enum.map(0..6, &Date.add(monday, &1))

  @doc """
  The profile's calendar posts placed in the week starting `monday`, each
  `%{post:, account:, at: DateTime, date: Date}`, in time order.
  """
  def items(profile, accounts, %Date{} = monday) do
    from = DateTime.new!(monday, ~T[00:00:00], "Etc/UTC")
    to = DateTime.new!(Date.add(monday, 7), ~T[00:00:00], "Etc/UTC")
    by_id = Map.new(accounts, &{&1.id, &1})

    profile.org_id
    |> Social.list_posts(
      profile_id: profile.id,
      statuses: @statuses,
      placed_from: from,
      placed_to: to
    )
    |> Enum.flat_map(fn post ->
      case Map.fetch(by_id, post.account_id) do
        {:ok, account} ->
          at = post.scheduled_at || post.approved_at
          [%{post: post, account: account, at: at, date: DateTime.to_date(at)}]

        :error ->
          []
      end
    end)
    |> Enum.sort_by(& &1.at, DateTime)
  end

  @doc "One row per account, each with its items bucketed by the week's days."
  def rows(accounts, items, %Date{} = monday) do
    days = days(monday)

    Enum.map(accounts, fn account ->
      mine = Enum.filter(items, &(&1.account.id == account.id))

      %{
        id: account.id,
        account: account,
        days: Enum.map(days, fn d -> {d, Enum.filter(mine, &(&1.date == d))} end)
      }
    end)
  end

  @doc "One block per day that has items, for the mobile agenda."
  def agenda(items, %Date{} = monday) do
    for day <- days(monday),
        day_items = Enum.filter(items, &(&1.date == day)),
        day_items != [],
        do: %{id: Date.to_iso8601(day), date: day, items: day_items}
  end

  @doc "HH:MM in UTC."
  def time(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M")

  @doc "Short day head, e.g. \"Mon\"."
  def day_name(%Date{} = d), do: Calendar.strftime(d, "%a")

  @doc "Day label for the agenda, e.g. \"Mon 13 Oct\"."
  def day_label(%Date{} = d), do: Calendar.strftime(d, "%a %-d %b")

  @doc "Status mark: `{icon, badge class}`."
  def mark("scheduled"), do: {"hero-clock-micro", "badge-neutral"}
  def mark("published"), do: {"hero-check-micro", "badge-success"}
  def mark("failed"), do: {"hero-x-mark-micro", "badge-error"}
  def mark(_), do: {"hero-minus-micro", "badge-neutral"}
end
