defmodule Platform.Social.CalendarDayEntries do
  @moduledoc """
  Page-only legacy Queue review items that the current human can act on.

  Studio posts are excluded: Studio's normal review writers do not assign a
  scheduled time to a post awaiting approval, and planned posts are not actionable here.
  Refused and failed posts are deferred: the exact Queue destination is read-only.
  """

  alias Platform.{Accounts, Social}
  alias Platform.Social.{Approvals, PostPresentation, QueueFeed, Studio}

  def list(user_id, from, to, zone) do
    with true <- Platform.UUID.valid?(user_id),
         %{archived_at: nil} = user <- Accounts.get_user(user_id) do
      user
      |> Social.list_profiles_for_user()
      |> Enum.filter(&(Studio.require_social_use(user.id, &1) == :ok))
      |> Enum.flat_map(&entries_for_profile(&1, user, from, to, zone))
      |> Enum.group_by(& &1.day)
      |> Enum.map(fn {day, items} ->
        count = length(items)

        %{
          key: "social",
          label: "Social",
          day: day,
          heading: "Social posts that need you",
          aria:
            "#{count} Social #{if count == 1, do: "post needs", else: "posts need"} you on #{Calendar.strftime(day, "%A %-d %B")}",
          items: Enum.sort_by(items, &DateTime.to_unix(&1.at))
        }
      end)
    else
      _ -> []
    end
  end

  defp entries_for_profile(profile, user, from, to, zone) do
    groups = QueueFeed.needs_you(user, {:profile, profile})
    posts = Enum.flat_map(groups, & &1.posts)
    accounts = QueueFeed.accounts(posts)
    context = PostPresentation.authorize({:user, user.id}, [profile.id])

    posts
    |> Enum.uniq_by(& &1.id)
    |> Enum.flat_map(fn post ->
      account = accounts[post.account_id]

      with %DateTime{} = at <- post.scheduled_at,
           true <- DateTime.compare(at, from) != :lt and DateTime.compare(at, to) == :lt,
           %{} <- account,
           true <- actionable?(post, user),
           %{post_url: href} <- PostPresentation.describe(post, account, context),
           {:ok, local} <- DateTime.shift_zone(at, zone) do
        label =
          Enum.reject(
            [profile.name, Approvals.platform_label(account.platform), account.handle],
            &(is_nil(&1) or &1 == "")
          )
          |> Enum.join(" · ")

        [
          %{
            day: DateTime.to_date(local),
            at: at,
            text:
              label <> " · " <> state(post, account) <> " · " <> Calendar.strftime(local, "%H:%M"),
            href: href,
            link_label: "Open in Queue"
          }
        ]
      else
        _ -> []
      end
    end)
  end

  defp actionable?(%{status: "needs_approval"} = post, user) do
    case Approvals.live_card(post.id) do
      %{id: id} -> Map.get(Approvals.card_view(id, {:user, user.id}), :actions, []) != []
      _ -> false
    end
  end

  defp actionable?(_, _), do: false

  defp state(post, account) do
    case Approvals.latest_card(post.id) do
      nil -> post.error || "did not publish."
      card -> Approvals.status_line(card, post, account).text
    end
  end
end
