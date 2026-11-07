defmodule Platform.Secretary.Inputs do
  @moduledoc """
  Everything the triage agent may read for one person, as
  `[%Platform.Secretary.Input{}]` (task 01a1b721 stage 1). Deterministic: no
  model call, no write.

  ## Readability is Platform.Access, decided for the viewer

  Every source is filtered by the VIEWER's own Scope
  (`Platform.Access.Scope.for_user/1`); nothing here re-implements a rule.

    * `:inbox` — the person's inbox rows ONLY through
      `Platform.Inbox.reachable_unread_scope/3`, which narrows by the
      viewer's current grants.
    * `:chat` — messages since `since` ONLY in spaces passing
      `Platform.Access.Query.where_readable/5` for `chat.read` AND whose kind
      is `channel`, `dm` or `group`. Access admits execution and system
      spaces org-wide; they are excluded here on purpose, because they are
      agents' working rooms, not the person's conversations. An open channel
      the person is not in arrives with `member?: false`. Capped per space
      and per batch (`max_batch_items`).
    * `:meetings` — unfiled action items from the after-action briefings
      the person attended, each checked with `Platform.Access.can?/3`
      `chat.read` on the meeting's chat space (resolved through
      `Platform.Inbox.resource_for("meeting", id)`).
    * `:calendar` — `Platform.Calendar.list_events/4` for the next 36 hours.
    * `:todos` — the person's own open list.
    * `:mail` — declared, returns `[]`. Inbound mail is agent-scoped
      (`Platform.Mail.InboundAccess`), and reading it for a person is child
      task 01a1b754-6207-7000-bbcd-c043a1c025a6. It is NOT read here.

  An external user (`Platform.Tenancy.external_user?/1`) gets `[]`.
  """

  import Ecto.Query

  alias Platform.Access
  alias Platform.Access.Scope
  alias Platform.Accounts.User
  alias Platform.Chat.{Message, MessageAttention, Participant, Space}
  alias Platform.Inbox
  alias Platform.Inbox.Item
  alias Platform.Meetings.MeetingBriefing
  alias Platform.Repo
  alias Platform.Secretary.{Input, Todos}
  alias Platform.Tenancy

  @sources [:inbox, :chat, :meetings, :calendar, :todos, :mail]
  @space_kinds ~w(channel dm group)
  @default_max_batch_items 60
  @default_per_space 20
  @calendar_horizon_hours 36

  @doc "The declared sources, in gather order."
  @spec sources() :: [atom()]
  def sources, do: @sources

  @doc "The space kinds chat messages are read from."
  @spec space_kinds() :: [String.t()]
  def space_kinds, do: @space_kinds

  @doc """
  Gathers the readable inputs for `user` since `since`.

  Options: `:now` (default `DateTime.utc_now/0`), `:max_batch_items`
  (default #{@default_max_batch_items}, the surface payload's value),
  `:per_space` (default #{@default_per_space}), `:sources` (default all).
  """
  @spec gather(User.t(), DateTime.t(), keyword()) :: [Input.t()]
  def gather(user, since, opts \\ [])

  def gather(%User{id: user_id} = user, %DateTime{} = since, opts) when is_binary(user_id) do
    if Tenancy.external_user?(user) do
      []
    else
      scope = Scope.for_user(user)
      ctx = %{user: user, scope: scope, since: since, opts: opts}

      opts
      |> Keyword.get(:sources, @sources)
      |> Enum.flat_map(&gather_source(&1, ctx))
    end
  end

  def gather(_user, _since, _opts), do: []

  defp gather_source(:inbox, ctx), do: inbox(ctx)
  defp gather_source(:chat, ctx), do: chat(ctx)
  defp gather_source(:meetings, ctx), do: meetings(ctx)
  defp gather_source(:calendar, ctx), do: calendar(ctx)
  defp gather_source(:todos, ctx), do: todos(ctx)
  # Child task 01a1b754-6207-7000-bbcd-c043a1c025a6 owns reading mail for a
  # person. Platform.Mail.Inbound is agent-scoped (mail/inbound_access.ex), so
  # nothing here may read it.
  defp gather_source(:mail, _ctx), do: []
  defp gather_source(_other, _ctx), do: []

  # ── (a) inbox ───────────────────────────────────────────────────────────

  defp inbox(%{user: user, scope: scope, since: since} = ctx) do
    user.id
    |> Inbox.reachable_unread_scope(false, scope)
    |> where([i], i.inserted_at >= ^since or is_nil(i.read_at))
    |> order_by([i], desc: i.inserted_at, desc: i.id)
    |> limit(^max_items(ctx))
    |> Repo.all()
    |> Enum.map(fn %Item{} = item ->
      %Input{
        ref_type: "inbox_item",
        ref_id: item.id,
        kind: "inbox:" <> item.kind,
        title: item.title,
        text: item.body,
        member?: true,
        mentioned?: item.kind == "chat_mention",
        at: item.inserted_at
      }
    end)
  end

  # ── (b) chat ────────────────────────────────────────────────────────────

  defp chat(%{user: user, scope: scope, since: since} = ctx) do
    readable =
      Space
      |> Access.Query.where_readable(scope, "chat.read", :space, %{id: :id})
      |> where([s], s.kind in ^@space_kinds and is_nil(s.archived_at))
      |> select([s], s.id)

    per_space = Keyword.get(ctx.opts, :per_space, @default_per_space)

    ranked =
      from(m in Message,
        where:
          m.space_id in subquery(readable) and m.inserted_at > ^since and is_nil(m.deleted_at) and
            m.log_only == false and is_nil(m.thread_id) and
            (is_nil(m.author_user_id) or m.author_user_id != ^user.id),
        select: %{
          id: m.id,
          rn: over(row_number(), partition_by: m.space_id, order_by: [desc: m.inserted_at])
        }
      )

    rows =
      from(m in Message,
        join: r in subquery(ranked),
        on: r.id == m.id,
        join: s in Space,
        on: s.id == m.space_id,
        where: r.rn <= ^per_space,
        order_by: [desc: m.inserted_at, desc: m.id],
        limit: ^max_items(ctx),
        select: {m, s.kind, s.name}
      )
      |> Repo.all()

    member_spaces = member_space_ids(user.id, Enum.map(rows, fn {m, _, _} -> m.space_id end))
    attention = attention_message_ids(user.id, Enum.map(rows, fn {m, _, _} -> m.id end))
    token = mention_token(user)

    Enum.map(rows, fn {%Message{} = m, kind, name} ->
      %Input{
        ref_type: "chat_message",
        ref_id: m.id,
        kind: "chat:" <> kind,
        title: name,
        text: m.content,
        space_id: m.space_id,
        space_kind: kind,
        member?: MapSet.member?(member_spaces, m.space_id),
        mentioned?: MapSet.member?(attention, m.id) or mentions?(m.content, token),
        author_id: m.author_user_id || m.author_agent_id,
        author_label: m.author_display_name,
        at: m.inserted_at
      }
    end)
  end

  defp member_space_ids(_user_id, []), do: MapSet.new()

  defp member_space_ids(user_id, space_ids) do
    from(p in Participant,
      where:
        p.participant_type == "user" and p.participant_id == ^user_id and
          p.space_id in ^Enum.uniq(space_ids),
      select: p.space_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp attention_message_ids(_user_id, []), do: MapSet.new()

  defp attention_message_ids(user_id, message_ids) do
    from(a in MessageAttention,
      join: p in Participant,
      on: p.id == a.participant_id,
      where:
        a.message_id in ^message_ids and p.participant_type == "user" and
          p.participant_id == ^user_id,
      select: a.message_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp mention_token(%User{name: name}) when is_binary(name) and name != "",
    do: "@[" <> String.downcase(name) <> "]"

  defp mention_token(_user), do: nil

  defp mentions?(content, token) when is_binary(content) and is_binary(token),
    do: String.contains?(String.downcase(content), token)

  defp mentions?(_content, _token), do: false

  # ── (c) meeting action items ────────────────────────────────────────────

  defp meetings(%{user: user, scope: scope, since: since}) do
    from(b in MeetingBriefing,
      where:
        fragment("?::uuid = ANY(?)", type(^user.id, :binary_id), b.attendee_user_ids) and
          b.updated_at >= ^since,
      order_by: [desc: b.updated_at]
    )
    |> Repo.all()
    |> Enum.filter(&meeting_readable?(&1, scope))
    |> Enum.flat_map(fn %MeetingBriefing{} = briefing ->
      items = get_in(briefing.items || %{}, ["_content", "unfiled_action_items"]) || []

      for %{"id" => id} = item <- items, Platform.UUID.valid?(id) do
        %Input{
          ref_type: "meeting_action_item",
          ref_id: id,
          kind: "meeting:action_item",
          title: nil,
          text: item["text"],
          member?: true,
          mentioned?: false,
          at: briefing.updated_at
        }
      end
    end)
  end

  defp meeting_readable?(%MeetingBriefing{meeting_id: meeting_id}, scope) do
    case Inbox.resource_for("meeting", meeting_id) do
      {:space, space_id} when is_binary(space_id) ->
        Access.can?(scope, "chat.read", {:space, space_id})

      _ ->
        false
    end
  end

  # ── (d) calendar ────────────────────────────────────────────────────────

  defp calendar(%{scope: scope, opts: opts}) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    to = DateTime.add(now, @calendar_horizon_hours * 3600, :second)

    scope
    |> Platform.Calendar.list_events(now, to)
    |> Enum.map(fn event ->
      %Input{
        ref_type: "calendar_event",
        ref_id: event.id,
        kind: "calendar:event",
        title: event.title,
        text: event.description,
        member?: true,
        at: event.starts_at,
        deadline_at: event.starts_at
      }
    end)
  end

  # ── (e) the person's own list ───────────────────────────────────────────

  defp todos(%{user: user}) do
    user.id
    |> Todos.list()
    |> Enum.map(fn todo ->
      %Input{
        ref_type: "todo",
        ref_id: todo.id,
        kind: "todo:" <> todo.status,
        title: todo.title,
        text: todo.source_quote,
        space_id: todo.source_space_id,
        member?: true,
        at: todo.inserted_at,
        deadline_at: due_at(todo.due_on)
      }
    end)
  end

  defp due_at(nil), do: nil
  defp due_at(%Date{} = date), do: DateTime.new!(date, ~T[23:59:59], "Etc/UTC")

  defp max_items(ctx), do: Keyword.get(ctx.opts, :max_batch_items, @default_max_batch_items)
end
