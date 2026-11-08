defmodule Platform.Secretary.View do
  @moduledoc """
  The read model behind `PlatformWeb.SecretaryLive` (task 01a1b721 stage 4):
  one person's evaluations joined with the things they were about, grouped
  the way the screen shows them. Deterministic: nothing here calls a model.

  ## Where the rows come from

  An evaluation (`Platform.Secretary.Evaluation`) names a `{ref_type,
  ref_id}`; the thing itself is re-read through the same readable surfaces
  the evaluator used (`Platform.Secretary.Inputs.gather/3`), so a row the
  person may no longer read, or that has been dismissed, falls out of the
  view by construction. An inbox item that was read or dismissed in the
  last few minutes shows once more as *resolved elsewhere* (struck, with the
  reason) and then leaves.

  ## Modes

    * `:ok` — a model verdict stands: the brief, goal groups and the quiet
      band;
    * `:no_ai` — the last batch found no subscription AI login
      (`Platform.Secretary.Model.Host`): the fallback groups by kind;
    * `:budget` — the last batch was refused by a token ceiling
      (`Platform.Secretary.Budget`): the fallback groups by kind;
    * `:fallback` — the last batch failed, timed out or was rejected: the
      fallback groups by kind with no explanation line.

  `catching_up` is the number of refs in a batch still in flight, or 0.

  Every read takes the viewer's own `%User{}`; nothing lists another
  person's rows.
  """

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Access.Scope
  alias Platform.Chat.Space
  alias Platform.Inbox.Item
  alias Platform.Repo
  alias Platform.Roles

  alias Platform.Secretary.{
    Context,
    Evaluation,
    Fallback,
    Input,
    Inputs,
    Settings,
    Store,
    Todo,
    Todos
  }

  alias Platform.Secretary.Model.Host
  alias Platform.Tenancy

  @lookback_seconds 24 * 3600
  # A first evaluation this recent carries the `new` mark; a dismissed inbox
  # item this recent still shows struck through, as resolved elsewhere.
  @recent_seconds 10 * 60
  @tag_order %{
    "decide" => 0,
    "waiting" => 1,
    "not_in_space" => 2,
    "todo" => 3,
    "suggested" => 4,
    "fyi" => 5,
    "quiet" => 6
  }
  @tag_labels %{
    "decide" => "Decide",
    "waiting" => "Waiting on you",
    "fyi" => "FYI",
    "not_in_space" => "You’re not in this space",
    "todo" => "To-do",
    "suggested" => "To-do",
    "quiet" => "Quiet"
  }
  @brief_tag_labels %{
    "may_not_know" => "You may not know",
    "risk" => "Risk",
    "nobody_flagged" => "Nobody flagged this",
    "family" => "Family"
  }
  @none_group_label "Not tied to a goal"

  @type row :: map()
  @type group :: %{
          id: String.t(),
          label: String.t(),
          sub: String.t() | nil,
          status: String.t() | nil,
          at_risk?: boolean(),
          new_count: non_neg_integer(),
          count: non_neg_integer(),
          rows: [row()]
        }
  @type t :: %{
          mode: :ok | :no_ai | :budget | :fallback,
          agent: map() | nil,
          agent_name: String.t(),
          brief: [map()],
          groups: [group()],
          quiet: [row()],
          catching_up: non_neg_integer(),
          held_fyis: non_neg_integer(),
          fyi_count: non_neg_integer(),
          needs_count: non_neg_integer(),
          all_clear?: boolean()
        }

  @doc "The human label of a row tag."
  @spec tag_label(String.t() | nil) :: String.t() | nil
  def tag_label(tag), do: Map.get(@tag_labels, tag)

  @doc "The human label of a brief-line tag."
  @spec brief_tag_label(String.t() | nil) :: String.t() | nil
  def brief_tag_label(tag), do: Map.get(@brief_tag_labels, tag)

  @doc "The label of the group for rows outside every goal."
  @spec none_group_label() :: String.t()
  def none_group_label, do: @none_group_label

  @doc """
  The agent whose login reads for the person (`Platform.Roles.assignee_for/1`
  on `Platform.Secretary.Model.Host.responsibility/0`), or nil.
  """
  @spec agent() :: struct() | nil
  def agent do
    case Roles.assignee_for(Host.responsibility()) do
      %{id: _} = agent -> agent
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc "The agent's display name, or the product name when there is none."
  @spec agent_name(struct() | nil) :: String.t()
  def agent_name(%{name: name}) when is_binary(name) and name != "", do: name
  def agent_name(_), do: Platform.Secretary.name()

  @doc "Builds the view for `user`. Options: `:now`."
  @spec for_user(User.t(), keyword()) :: t()
  def for_user(%User{id: user_id} = user, opts \\ []) when is_binary(user_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    agent = Keyword.get_lazy(opts, :agent, &agent/0)
    settings = Settings.get(user)
    batches = Store.list_batches(user_id, limit: 5)
    mode = mode(batches)
    catching_up = catching_up(batches)

    evaluations = Store.list_evaluations(user_id)
    inputs = inputs(user, now)
    items = inbox_items(user_id, evaluations)

    todos =
      Map.new(Todos.list(user_id, statuses: ~w(suggested kept done dismissed)), &{&1.id, &1})

    goals = Context.for_user(user).goals
    spaces = spaces(inputs, goals)

    rows =
      evaluations
      |> Enum.map(&row(&1, inputs, items, todos, spaces, now))
      |> Enum.reject(&is_nil/1)
      |> Kernel.++(unevaluated_todos(evaluations, inputs, todos, spaces, now))

    live = Enum.reject(rows, & &1.leaving?)
    quiet = live |> Enum.filter(&(&1.tag == "quiet")) |> sort_rows()
    visible = Enum.reject(rows, &(&1.tag == "quiet"))

    brief =
      evaluations
      |> Enum.filter(&(is_integer(&1.brief_rank) and is_binary(&1.brief_line)))
      |> Enum.sort_by(& &1.brief_rank)
      |> Enum.map(&brief_line(&1, Enum.find(rows, fn r -> r.evaluation.id == &1.id end), now))

    brief = if mode == :ok, do: brief, else: []
    fyi_count = Enum.count(live, &(&1.tag == "fyi"))
    needs_count = Enum.count(live, &(&1.tag in ~w(decide waiting not_in_space)))

    groups =
      case mode do
        :ok -> goal_groups(visible, goals, spaces)
        _ -> fallback_groups(visible)
      end

    %{
      mode: mode,
      agent: agent,
      agent_name: agent_name(agent),
      settings: settings,
      brief: brief,
      groups: groups,
      quiet: quiet,
      catching_up: catching_up,
      held_fyis: fyi_count,
      fyi_count: fyi_count,
      needs_count: needs_count,
      all_clear?: mode == :ok and brief == [] and needs_count == 0
    }
  end

  @doc """
  The raw items the person's secretary read, newest first: the reachable
  unread inbox rows (`Platform.Inbox.reachable_unread_scope/3`).
  """
  @spec everything(User.t()) :: [Item.t()]
  def everything(%User{id: user_id} = user) do
    external? = Tenancy.external_user?(user)

    user_id
    |> Platform.Inbox.reachable_unread_scope(external?, Scope.for_user(user))
    |> order_by([i], desc: i.inserted_at, desc: i.id)
    |> limit(200)
    |> Repo.all()
  end

  @doc """
  Row 18's `Join #channel`: puts `user` into `space_id` when it is an open
  channel they may read (`Platform.Access` chat.read), the same participant
  row the chat UI writes. Anything else is `{:error, :not_joinable}`.
  """
  @spec join_open_channel(User.t(), term()) :: {:ok, Space.t()} | {:error, :not_joinable}
  def join_open_channel(%User{} = user, space_id) do
    scope = Scope.for_user(user)

    with true <- is_binary(space_id) and Platform.UUID.valid?(space_id),
         %Space{kind: "channel", archived_at: nil} = space <-
           Repo.one(from(s in Space, where: s.id == ^space_id)),
         true <- Platform.Access.can?(scope, "chat.read", {:space, space.id}),
         {:ok, _} <- ensure_participant(space.id, user) do
      {:ok, space}
    else
      _ -> {:error, :not_joinable}
    end
  end

  defp ensure_participant(space_id, %User{} = user) do
    existing =
      space_id
      |> Platform.Chat.list_participants()
      |> Enum.find(&(&1.participant_type == "user" and &1.participant_id == user.id))

    case existing do
      nil ->
        Platform.Chat.add_participant(space_id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: user.name || user.email,
          joined_at: DateTime.utc_now()
        })

      participant ->
        {:ok, participant}
    end
  end

  # ── mode ────────────────────────────────────────────────────────────────

  defp mode(batches) do
    case Enum.find(batches, &(&1.status != "dispatched")) do
      nil -> :ok
      %{status: "no_ai"} -> :no_ai
      %{status: "budget_exhausted"} -> :budget
      %{status: status} when status in ~w(failed expired rejected) -> :fallback
      _ -> :ok
    end
  end

  defp catching_up(batches) do
    case Enum.find(batches, &(&1.status == "dispatched")) do
      nil -> 0
      %{item_refs: refs} -> length(refs)
    end
  end

  # ── sources ─────────────────────────────────────────────────────────────

  defp inputs(user, now) do
    user
    |> Inputs.gather(DateTime.add(now, -@lookback_seconds, :second), now: now)
    |> Map.new(&{{&1.ref_type, &1.ref_id}, &1})
  end

  # The evaluated inbox rows, read or not, so a just-handled one can show
  # as resolved elsewhere. Owner-scoped: `i.user_id == ^user_id`.
  defp inbox_items(user_id, evaluations) do
    ids =
      for %Evaluation{ref_type: "inbox_item", ref_id: id} <- evaluations,
          Platform.UUID.valid?(id),
          do: id

    if ids == [] do
      %{}
    else
      from(i in Item, where: i.user_id == ^user_id and i.id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})
    end
  end

  defp spaces(inputs, goals) do
    ids =
      inputs
      |> Map.values()
      |> Enum.map(& &1.space_id)
      |> Kernel.++(Enum.map(goals, & &1.space_id))
      |> Enum.filter(&(is_binary(&1) and Platform.UUID.valid?(&1)))
      |> Enum.uniq()

    if ids == [] do
      %{}
    else
      from(s in Space, where: s.id in ^ids, select: {s.id, s})
      |> Repo.all()
      |> Map.new()
    end
  end

  # ── rows ────────────────────────────────────────────────────────────────

  defp row(%Evaluation{} = e, inputs, items, todos, spaces, now) do
    key = {e.ref_type, e.ref_id}

    case {Map.get(inputs, key), e.ref_type} do
      {%Input{} = input, _} ->
        build_row(e, input, items, todos, spaces, now, false)

      {nil, "inbox_item"} ->
        # Gone from the readable unread list. Just handled -> resolved
        # elsewhere for a moment; otherwise it has left the view.
        case Map.get(items, e.ref_id) do
          %Item{} = item ->
            handled_at = item.dismissed_at || item.read_at

            if handled_at && DateTime.diff(now, handled_at, :second) <= @recent_seconds do
              build_row(e, item_input(item), items, todos, spaces, now, true)
            end

          nil ->
            nil
        end

      {nil, "todo"} ->
        # A to-do just marked done leaves the open list; it stays a moment
        # with its done-because note, then goes.
        case Map.get(todos, e.ref_id) do
          %Todo{status: status, updated_at: at} = todo
          when status in ["done", "dismissed"] and not is_nil(at) ->
            if DateTime.diff(now, at, :second) <= @recent_seconds,
              do: build_row(e, todo_input(todo), items, todos, spaces, now, false)

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  # The person's own list is deterministic data, so an entry the evaluator
  # has not reached yet (just added, just heard) still shows, under its goal
  # or outside every goal, as a to-do or a suggestion. Nothing is persisted.
  defp unevaluated_todos(evaluations, inputs, todos, spaces, now) do
    evaluated = MapSet.new(evaluations, &{&1.ref_type, &1.ref_id})

    for {{"todo", id} = key, %Input{} = input} <- inputs,
        not MapSet.member?(evaluated, key),
        %Todo{} = todo <- [Map.get(todos, id)] do
      pending = %Evaluation{
        id: "pending-" <> id,
        user_id: todo.user_id,
        ref_type: "todo",
        ref_id: id,
        tag: if(todo.status == "suggested", do: "suggested", else: "todo"),
        group_key: todo.goal_key || "none",
        rank: nil,
        inserted_at: now,
        evaluated_at: now,
        model_version: "fallback"
      }

      build_row(pending, input, %{}, todos, spaces, now, false)
    end
  end

  defp todo_input(%Todo{} = todo) do
    %Input{
      ref_type: "todo",
      ref_id: todo.id,
      kind: "todo:" <> todo.status,
      title: todo.title,
      text: todo.source_quote,
      space_id: todo.source_space_id,
      member?: true,
      at: todo.inserted_at
    }
  end

  defp item_input(%Item{} = item) do
    %Input{
      ref_type: "inbox_item",
      ref_id: item.id,
      kind: "inbox:" <> item.kind,
      title: item.title,
      text: item.body,
      member?: true,
      at: item.inserted_at
    }
  end

  defp build_row(%Evaluation{} = e, %Input{} = input, items, todos, spaces, now, leaving?) do
    space = input.space_id && Map.get(spaces, input.space_id)
    todo = if input.ref_type == "todo", do: Map.get(todos, input.ref_id)
    item = if input.ref_type == "inbox_item", do: Map.get(items, input.ref_id)

    kind =
      cond do
        todo && todo.origin == "heard" && todo.status in ["suggested", "dismissed"] -> :suggested
        todo -> :todo
        e.tag == "not_in_space" -> :not_in_space
        true -> :item
      end

    recent? = DateTime.diff(now, e.inserted_at || now, :second) <= @recent_seconds

    %{
      id: "row-#{e.ref_type}-#{e.ref_id}",
      evaluation: e,
      ref_type: e.ref_type,
      ref_id: e.ref_id,
      tag: e.tag,
      tag_label: tag_label(e.tag),
      kind: kind,
      input_kind: input.kind,
      mentioned?: input.mentioned?,
      title: title(input, item, todo, space),
      reason: e.reason,
      kind_label: kind_label(input),
      source: source(input, space, todo),
      at: input.at,
      time_label: time_label(input.at),
      space_id: input.space_id,
      space_name: space && space.name,
      space_label: space && space_label(space),
      member?: input.member?,
      family?: e.family,
      agent_author?: agent_author?(input),
      author_label: input.author_label,
      quote: input.ref_type == "todo" && todo && todo.source_quote,
      todo: todo,
      item: item,
      url: url(input, item, space),
      deadline_at: e.deadline_at,
      due_label: todo && due_label(todo.due_on, now),
      due_soon?: todo && due_soon?(todo.due_on, now),
      new?: recent? and is_nil(e.previous_tag) and not leaving?,
      moved?: moved?(e),
      previous_tag_label: tag_label(e.previous_tag),
      leaving?: leaving?,
      rank: e.rank
    }
  end

  defp title(%Input{} = input, item, todo, space) do
    cond do
      todo -> todo.title
      item -> item.title
      is_binary(input.title) and input.ref_type == "inbox_item" -> input.title
      input.ref_type == "chat_message" -> chat_title(input, space)
      is_binary(input.title) and input.title != "" -> input.title
      is_binary(input.text) -> truncate(input.text, 120)
      true -> kind_label(input)
    end
  end

  defp chat_title(%Input{} = input, space) do
    cond do
      input.member? == false and space -> "Activity in #{space_label(space)}"
      is_binary(input.text) and input.text != "" -> truncate(input.text, 120)
      space -> "A message in #{space_label(space)}"
      true -> "A message"
    end
  end

  defp kind_label(%Input{kind: "inbox:" <> kind}),
    do: PlatformWeb.Components.InboxItem.kind_label(kind, :long)

  defp kind_label(%Input{kind: "chat:dm"}), do: "DM"
  defp kind_label(%Input{kind: "chat:" <> _}), do: "Message"
  defp kind_label(%Input{kind: "calendar:event"}), do: "Calendar"
  defp kind_label(%Input{kind: "meeting:action_item"}), do: "Action item"
  defp kind_label(%Input{kind: "todo:" <> _}), do: "To-do"
  defp kind_label(_), do: "Notification"

  defp source(%Input{ref_type: "todo"}, _space, %Todo{origin: "self"}), do: "you added this"

  defp source(%Input{ref_type: "todo"}, space, %Todo{} = todo) do
    where = if space, do: " in #{space_label(space)}", else: ""

    quote_bit =
      if is_binary(todo.source_quote), do: " · #{truncate(todo.source_quote, 80)}", else: ""

    "heard#{where}#{quote_bit}"
  end

  defp source(%Input{} = input, space, _todo) do
    case {kind_label(input), space} do
      {label, %Space{} = s} -> "#{label} in #{space_label(s)}"
      {label, _} -> label
    end
  end

  defp space_label(%Space{kind: "channel", slug: slug}) when is_binary(slug) and slug != "",
    do: "#" <> slug

  defp space_label(%Space{kind: "channel", name: name}) when is_binary(name), do: "#" <> name
  defp space_label(%Space{kind: "dm"}), do: "a DM"
  defp space_label(%Space{name: name}) when is_binary(name) and name != "", do: name
  defp space_label(_), do: "a space"

  defp agent_author?(%Input{kind: "chat:" <> _, author_id: id}) when is_binary(id) do
    case agent() do
      %{id: ^id} -> true
      _ -> false
    end
  end

  defp agent_author?(_), do: false

  defp url(%Input{ref_type: "inbox_item"}, %Item{url: url}, _space) when is_binary(url), do: url

  defp url(%Input{ref_type: "chat_message", ref_id: id}, _item, %Space{} = space),
    do: "/chat/#{Platform.Chat.space_path_segment(space)}?message=#{id}"

  defp url(%Input{ref_type: "calendar_event"}, _item, _space), do: "/calendar"
  defp url(_input, _item, _space), do: nil

  defp moved?(%Evaluation{previous_tag: prev, tag: tag}) when is_binary(prev) and is_binary(tag),
    do: Map.get(@tag_order, tag, 9) < Map.get(@tag_order, prev, 9)

  defp moved?(_e), do: false

  defp time_label(%DateTime{} = at), do: PlatformWeb.Components.InboxItem.relative_time(at)
  defp time_label(_), do: ""

  defp due_label(nil, _now), do: nil

  defp due_label(%Date{} = due, now) do
    today = DateTime.to_date(now)

    case Date.diff(due, today) do
      d when d < 0 -> "Overdue"
      0 -> "Today"
      1 -> "Tomorrow"
      d when d < 7 -> Calendar.strftime(due, "%a")
      _ -> Calendar.strftime(due, "%b %-d")
    end
  end

  defp due_soon?(%Date{} = due, now), do: Date.diff(due, DateTime.to_date(now)) <= 1
  defp due_soon?(_due, _now), do: false

  defp truncate(text, max) when is_binary(text) do
    text = text |> String.replace(~r/\s+/u, " ") |> String.trim()
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  defp sort_rows(rows) do
    Enum.sort_by(rows, fn r ->
      {Map.get(@tag_order, r.tag, 9), r.rank || 1_000_000, r.id}
    end)
  end

  # ── brief ───────────────────────────────────────────────────────────────

  defp brief_line(%Evaluation{} = e, row, now) do
    %{
      id: "brief-#{e.id}",
      evaluation_id: e.id,
      ref_type: e.ref_type,
      ref_id: e.ref_id,
      line: e.brief_line,
      action_label: e.brief_action_label || "Open",
      tag: e.brief_tag,
      tag_label: brief_tag_label(e.brief_tag),
      needs_you_now?: e.needs_you_now,
      new?: DateTime.diff(now, e.inserted_at || now, :second) <= @recent_seconds,
      url: row && row.url,
      item?: e.ref_type == "inbox_item"
    }
  end

  # ── groups ──────────────────────────────────────────────────────────────

  defp goal_groups(rows, goals, spaces) do
    by_key = Enum.group_by(rows, & &1.evaluation.group_key)
    goal_keys = MapSet.new(goals, & &1.key)

    goal_sections =
      for goal <- goals, rows = Map.get(by_key, goal.key, []), rows != [] do
        %{
          id: "goal-" <> String.replace(goal.key, ":", "-"),
          key: goal.key,
          label: goal.text,
          sub: "#{goal_space_label(Map.get(spaces, goal.space_id), goal)} goal",
          status: nil,
          at_risk?: false,
          new_count: Enum.count(rows, & &1.new?),
          count: length(rows),
          rows: sort_rows(rows)
        }
      end

    rest =
      by_key
      |> Enum.reject(fn {key, _} -> MapSet.member?(goal_keys, key) end)
      |> Enum.flat_map(fn {_, rows} -> rows end)

    none_section =
      if rest == [] do
        []
      else
        [
          %{
            id: "goal-none",
            key: "none",
            label: @none_group_label,
            sub: nil,
            status: nil,
            at_risk?: false,
            new_count: Enum.count(rest, & &1.new?),
            count: length(rest),
            rows: sort_rows(rest)
          }
        ]
      end

    goal_sections ++ none_section
  end

  defp goal_space_label(%Space{} = space, _goal), do: space_label(space)
  defp goal_space_label(nil, %{space_name: name}) when is_binary(name), do: "#" <> name
  defp goal_space_label(nil, _goal), do: "#space"

  # A row still carrying a goal key from an earlier model verdict (the
  # fallback has not rewritten it yet) is placed by its kind, the same
  # routing `Platform.Secretary.Fallback.classify/2` writes.
  defp fallback_groups(rows) do
    by_key =
      Enum.group_by(rows, fn row ->
        case row.evaluation.group_key do
          "fallback:" <> _ = key ->
            key

          _ ->
            case Fallback.classify(row.input_kind || "", row.mentioned? == true) do
              {nil, _} -> "none"
              {group, _} -> Fallback.group_key(group)
            end
        end
      end)

    for {key, label} <- Fallback.groups(),
        rows = Map.get(by_key, Fallback.group_key(key), []),
        rows != [] do
      %{
        id: "fallback-" <> key,
        key: Fallback.group_key(key),
        label: label,
        sub: nil,
        status: nil,
        at_risk?: false,
        new_count: 0,
        count: length(rows),
        rows: sort_rows(rows)
      }
    end
  end
end
