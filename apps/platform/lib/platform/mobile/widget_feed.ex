defmodule Platform.Mobile.WidgetFeed do
  @moduledoc """
  The one read behind `GET /api/app/widgets` (task 01a21e75 stage 1): the
  data for the iOS Waiting on you, Blocked for you, Recent and Shipped today
  widgets, in ONE response, so a widget refresh costs one request per install
  however many of those widgets are placed.

  Mirrors `Platform.Mobile.counts_for_user/1`: keyed off the caller's own
  user only, `as_of` read BEFORE every section.

  ## Sections

    * `waiting`: agent messages that tag the user and that the user has not
      answered. An inbox row of kind `chat_mention` (`source_type:
      "chat_message"`) in the user's reachable inbox LIST
      (`Platform.Inbox.reachable_unread_scope/3`: undismissed and
      grant-filtered; the list rather than the badge, so an opened but
      unanswered mention still counts), whose message is not deleted, is
      agent-authored (the `Inbox.mention_authors/1` test:
      `author_participant_type == "agent"` or an `author_agent_id`), was
      posted in the last 30 days, and has NO later message by the user in
      the same space (`Platform.Chat.user_posted_after_query/1`). `count`
      plus the newest 5 rows.
    * `blocked`: the blocked tasks the person can act on. A task with
      `status == "blocked"`, not soft-deleted, that the user sponsors
      (`sponsor_user_id`) or is the user assignee of (`assignee_type ==
      "user"`), in a project the user can see (`Platform.Tasks.
      list_projects_for_user/1`, the visibility the app's project picker
      uses). `count` plus the 3 most recently updated, each with the first
      line of `metadata["blocked_reason"]` (stamped by the orchestration
      layer) cut to 80 characters.
    * `recent`: the user's 4 Chat conversations (`Chat.chat_surface_kinds/0`,
      not archived, on the rail) with the newest non-deleted message, newest
      first, each with an `unread` flag from `Chat.unread_counts_for_user/1`.
    * `shipped`: tasks in visible projects, not soft-deleted, with a phase
      transition to `done` at or after the start of today in
      `Platform.Memory.Insights.Disseminator.timezone/0` (the briefing's
      zone). `count` and the newest one's title.

  ## Message text

  A mention row never carries the message body: `summary` is ONE line (the
  content with `@[...]` mention tokens reduced to their names, markdown
  markers stripped and all whitespace, newlines included, collapsed), cut to
  100 characters with an ellipsis. Nothing in this module logs.

  Options: `:now` (DateTime, default `DateTime.utc_now/0`).
  """

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.{Message, Participant, Space}
  alias Platform.Inbox
  alias Platform.Memory.Insights.Disseminator
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PhaseTransition, Task}

  @window_days 30
  @waiting_rows 5
  @blocked_rows 3
  @recent_rows 4
  @summary_max 100
  @reason_max 80
  @ellipsis "…"

  @type t :: %{
          as_of: DateTime.t(),
          waiting: %{count: non_neg_integer(), rows: [map()]},
          blocked: %{count: non_neg_integer(), rows: [map()]},
          recent: %{rows: [map()]},
          shipped: %{count: non_neg_integer(), newest_title: String.t() | nil}
        }

  @spec for_user(User.t(), keyword()) :: t()
  def for_user(%User{} = user, opts \\ []) do
    as_of = DateTime.utc_now()
    now = Keyword.get(opts, :now) || as_of
    project_ids = visible_project_ids(user)

    %{
      as_of: as_of,
      waiting: waiting(user, now),
      blocked: blocked(user, project_ids),
      recent: recent(user),
      shipped: shipped(project_ids, now)
    }
  end

  # ── waiting ────────────────────────────────────────────────────────────

  defp waiting(%User{id: user_id} = user, now) do
    since = DateTime.add(now, -@window_days * 86_400, :second)

    answered = Chat.user_posted_after_query(user_id)

    base =
      user_id
      |> Inbox.reachable_unread_scope(
        Platform.Tenancy.external_user?(user),
        Platform.Access.Scope.for_user(user)
      )
      |> where([i], i.kind == "chat_mention" and i.source_type == "chat_message")
      |> join(:inner, [i], m in Message, as: :message, on: m.id == i.source_id)
      |> where([message: m], is_nil(m.deleted_at))
      |> where(
        [message: m],
        m.author_participant_type == "agent" or not is_nil(m.author_agent_id)
      )
      |> where([message: m], m.inserted_at >= ^since)
      |> where([i], not exists(subquery(answered)))

    count = Repo.aggregate(base, :count)

    rows =
      base
      |> join(:inner, [message: m], s in Space, as: :space, on: s.id == m.space_id)
      |> order_by([message: m], desc: m.id)
      |> limit(@waiting_rows)
      |> select([i, message: m, space: s], %{
        item_id: i.id,
        space: %{id: s.id, org_id: s.org_id, slug: s.slug},
        asker: m.author_display_name,
        content: m.content,
        at: m.inserted_at
      })
      |> Repo.all()
      |> Enum.map(fn row ->
        %{
          item_id: row.item_id,
          space_path_segment: Chat.space_path_segment(row.space),
          asker: row.asker,
          summary: summary(row.content),
          at: row.at
        }
      end)

    %{count: count, rows: rows}
  end

  @doc """
  One line of `content`: `@[Name]` tokens reduced to `Name`, markdown links
  to their text, markdown markers stripped, whitespace (newlines included)
  collapsed to single spaces, cut to #{@summary_max} characters with an
  ellipsis. `nil` and blank content give `""`.
  """
  @spec summary(String.t() | nil) :: String.t()
  def summary(content), do: one_line(content, @summary_max)

  defp one_line(nil, _max), do: ""

  defp one_line(content, max) when is_binary(content) do
    content
    |> strip_markup()
    |> collapse_whitespace()
    |> cut(max)
  end

  defp strip_markup(text) do
    text
    |> then(&Regex.replace(~r/@\[([^\[\]]+)\]/u, &1, "\\1"))
    |> then(&Regex.replace(~r/!?\[([^\[\]]*)\]\([^)\s]*\)/u, &1, "\\1"))
    |> then(&Regex.replace(~r/^[ \t]*(?:\#{1,6}|>+|[-*+]|\d+[.)])[ \t]+/mu, &1, ""))
    |> then(&Regex.replace(~r/```[^\n]*|\*\*|__|~~|`|\*/u, &1, ""))
  end

  defp collapse_whitespace(text), do: text |> String.split() |> Enum.join(" ")

  defp cut(text, max) do
    if String.length(text) > max do
      String.trim_trailing(String.slice(text, 0, max)) <> @ellipsis
    else
      text
    end
  end

  # ── blocked ────────────────────────────────────────────────────────────

  defp blocked(%User{id: user_id}, project_ids) do
    base =
      from(t in Task,
        where: t.status == "blocked" and is_nil(t.deleted_at),
        where: t.project_id in ^project_ids,
        where:
          t.sponsor_user_id == ^user_id or
            (t.assignee_type == "user" and t.assignee_id == ^user_id)
      )

    count = Repo.aggregate(base, :count)

    rows =
      base
      |> order_by([t], desc: t.updated_at, desc: t.id)
      |> limit(@blocked_rows)
      |> select([t], %{id: t.id, title: t.title, metadata: t.metadata})
      |> Repo.all()
      |> Enum.map(fn t -> %{id: t.id, title: t.title, reason: reason(t.metadata)} end)

    %{count: count, rows: rows}
  end

  defp reason(%{"blocked_reason" => text}) when is_binary(text) do
    line =
      text
      |> String.split(["\r\n", "\n", "\r"], parts: 2)
      |> hd()
      |> String.trim()

    if line == "", do: nil, else: cut(line, @reason_max)
  end

  defp reason(_metadata), do: nil

  # ── recent ─────────────────────────────────────────────────────────────

  defp recent(%User{id: user_id}) do
    latest =
      from(m in Message,
        where: is_nil(m.deleted_at),
        group_by: m.space_id,
        select: %{space_id: m.space_id, at: max(m.inserted_at)}
      )

    spaces =
      from(p in Participant,
        join: s in Space,
        on: s.id == p.space_id,
        join: l in subquery(latest),
        on: l.space_id == s.id,
        where: p.participant_type == "user" and p.participant_id == ^user_id,
        where: is_nil(s.archived_at) and s.kind in ^Chat.chat_surface_kinds(),
        order_by: [desc: l.at, desc: s.id],
        select: s
      )
      |> Repo.all()
      |> Enum.filter(&Chat.rail_visible?/1)
      |> Enum.take(@recent_rows)

    space_ids = Enum.map(spaces, & &1.id)

    participants =
      from(p in Participant, where: p.space_id in ^space_ids)
      |> Repo.all()
      |> Enum.group_by(& &1.space_id)

    unread = Chat.unread_counts_for_user(user_id)

    rows =
      Enum.map(spaces, fn space ->
        members = Map.get(participants, space.id, [])

        %{
          space_id: space.id,
          path_segment: Chat.space_path_segment(space),
          kind: space.kind,
          name: Chat.display_name_for_space(space, members, user_id),
          counterpart: counterpart(space, members, user_id),
          unread: Map.get(unread, space.id, 0) > 0
        }
      end)

    %{rows: rows}
  end

  defp counterpart(%Space{kind: "dm"}, members, user_id) do
    case Enum.find(members, &(&1.participant_id != user_id)) do
      %Participant{participant_type: type, participant_id: id} -> %{type: type, id: id}
      nil -> nil
    end
  end

  defp counterpart(_space, _members, _user_id), do: nil

  # ── shipped ────────────────────────────────────────────────────────────

  defp shipped(project_ids, now) do
    start = start_of_today(now)

    done_today =
      from(pt in PhaseTransition,
        where: pt.to_status == "done" and pt.occurred_at >= ^start,
        group_by: pt.task_id,
        select: %{task_id: pt.task_id, at: max(pt.occurred_at)}
      )

    base =
      from(t in Task,
        join: d in subquery(done_today),
        on: d.task_id == t.id,
        where: is_nil(t.deleted_at) and t.project_id in ^project_ids
      )

    count = Repo.aggregate(base, :count)

    newest_title =
      base
      |> order_by([t, d], desc: d.at, desc: t.id)
      |> limit(1)
      |> select([t], t.title)
      |> Repo.one()

    %{count: count, newest_title: newest_title}
  end

  @doc """
  The first instant of `now`'s calendar date in
  `Disseminator.timezone/0`, in UTC.
  """
  @spec start_of_today(DateTime.t()) :: DateTime.t()
  def start_of_today(%DateTime{} = now) do
    date = Disseminator.local_date(now)

    case DateTime.new(date, ~T[00:00:00.000000], Disseminator.timezone()) do
      {:ok, local} -> DateTime.shift_zone!(local, "Etc/UTC")
      {:ambiguous, first, _second} -> DateTime.shift_zone!(first, "Etc/UTC")
      {:gap, _before, after_gap} -> DateTime.shift_zone!(after_gap, "Etc/UTC")
      {:error, _} -> DateTime.new!(date, ~T[00:00:00.000000], "Etc/UTC")
    end
  end

  # ── shared ─────────────────────────────────────────────────────────────

  defp visible_project_ids(user), do: user |> Tasks.list_projects_for_user() |> Enum.map(& &1.id)
end
