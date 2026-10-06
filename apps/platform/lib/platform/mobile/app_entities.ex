defmodule Platform.Mobile.AppEntities do
  @moduledoc """
  The queries and actions behind the native app's App Intents surface
  (task 01a10db6): Siri, Shortcuts, Spotlight, widgets and controls, served by
  `PlatformWeb.AppIntentsController` under `/api/app`.

  Every function takes the bearer's `%User{}` (`conn.assigns.current_user`
  from `PlatformWeb.Plugs.AppBearerAuth`) and keys everything off it: an
  install is its own database with its own bearer, so nothing here takes a
  user id from a parameter.

  ## Approvals

  `list_approvals/1` is built from `Platform.Inbox.reachable_unread_scope/1`
  with the same kind predicate `Platform.Mobile.counts_for_user/1` counts, so
  the list the app shows and the badge number cannot disagree.

  `approve/2` and `reject/3` resolve the inbox item by id AND owner (another
  user's item is `:not_found`, so ids are not probeable), then act through the
  same domain functions the web buttons call: `Tasks.approve_plan/3` /
  `Tasks.reject_plan/3` for a plan, `ReviewRequests.approve_item/2` /
  `reject_item/3` for every pending item of the task's open review requests.

  A second call on an already-settled subject answers
  `{:error, :already_handled, by}`. The state check and the act run under a
  per-task Postgres session advisory lock, so two concurrent taps serialise:
  the second one reads the settled state and is refused instead of acting
  twice.

  ## Logging

  Nothing here logs a title, plan text, feedback or message body.
  """

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.ExternalScope
  alias Platform.Chat.Participant
  alias Platform.Chat.Space
  alias Platform.Inbox
  alias Platform.Inbox.Item
  alias Platform.Meetings
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Roles.RoleAssignment
  alias Platform.Tasks
  alias Platform.Tasks.Plan
  alias Platform.Tasks.Project
  alias Platform.Tasks.ReviewItem
  alias Platform.Tasks.ReviewRequest
  alias Platform.Tasks.ReviewRequests
  alias Platform.Tasks.Task

  # Must stay equal to `Platform.Mobile`'s `@approval_kinds`: the list and the
  # badge count are the same predicate. `app_entities_test.exs` pins parity.
  @approval_kinds ~w(task_plan_review review_request_pending)
  @terminal_task_statuses ~w(done cancelled)

  @tasks_default_limit 25
  @tasks_max_limit 50
  @meetings_limit 20
  @messages_max_limit 20

  # Namespace for `pg_advisory_lock(int, int)`: the first key. Arbitrary but
  # fixed; the second key is a hash of the task id.
  @approval_lock_namespace 0x0A10DB6

  # ── approvals ────────────────────────────────────────────────────────

  @doc "The approval kinds the list and the badge count both read."
  def approval_kinds, do: @approval_kinds

  @doc """
  The user's reachable, unread approval inbox items, newest first.
  """
  @spec list_approvals(User.t()) :: [map()]
  def list_approvals(%User{id: user_id}) do
    items =
      user_id
      |> Inbox.reachable_unread_scope()
      |> where([i], i.kind in @approval_kinds)
      |> order_by([i], desc: i.inserted_at, desc: i.id)
      |> Repo.all()

    task_ids = items |> Enum.map(&item_task_id/1) |> Enum.filter(&is_binary/1) |> Enum.uniq()
    titles = task_titles(task_ids)

    Enum.map(items, fn item ->
      task_id = item_task_id(item)
      space = task_id && ExecutionSpace.find_by_task_id(task_id)

      %{
        id: item.id,
        kind: approval_kind(item.kind),
        title: Map.get(titles, task_id) || item.title,
        space_name: space && space.name,
        space_path_segment: space && Chat.space_path_segment(space),
        task_id: task_id,
        inserted_at: item.inserted_at,
        summary: if(item.kind == "task_plan_review", do: item.body)
      }
    end)
  end

  defp approval_kind("task_plan_review"), do: "plan"
  defp approval_kind("review_request_pending"), do: "review"

  defp task_titles([]), do: %{}

  defp task_titles(task_ids) do
    from(t in Task, where: t.id in ^task_ids, select: {t.id, t.title})
    |> Repo.all()
    |> Map.new()
  end

  # The task an approval row points at. Plan rows are `("task", task_id)`;
  # review rows are the per-task rollup `("task_review", task_id)` or the
  # legacy per-request `("review_request", request_id)`.
  defp item_task_id(%Item{source_type: st, source_id: sid}) when st in ["task", "task_review"],
    do: sid

  defp item_task_id(%Item{source_type: "review_request", source_id: sid}),
    do: ReviewRequests.task_id_for_request(sid)

  defp item_task_id(_), do: nil

  @doc """
  Approve the plan or review behind the user's approval inbox item `item_id`.

  Returns `{:ok, "approved"}`, `{:error, :not_found}`,
  `{:error, :already_handled, by_name_or_nil}` or `{:error, reason}`.
  """
  def approve(%User{} = user, item_id), do: act(user, item_id, :approve, nil)

  @doc """
  Reject the plan or review behind the user's approval inbox item `item_id`.

  A review reject needs non-blank `feedback` (`{:error, :feedback_required}`);
  a plan reject records it as the rejection reason when present.
  """
  def reject(%User{} = user, item_id, feedback), do: act(user, item_id, :reject, feedback)

  defp act(user, item_id, action, feedback) do
    feedback = normalize_feedback(feedback)

    with {:ok, item} <- fetch_own_approval(user, item_id),
         task_id when is_binary(task_id) <- item_task_id(item) do
      with_approval_lock(task_id, fn ->
        case item.kind do
          "task_plan_review" -> act_on_plan(user, task_id, action, feedback)
          "review_request_pending" -> act_on_review(user, task_id, action, feedback)
        end
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  defp normalize_feedback(feedback) when is_binary(feedback) do
    case String.trim(feedback) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_feedback(_), do: nil

  # Owner-scoped, read status irrelevant: a dismissed row still names the
  # subject, and the subject's own state decides whether it is settled.
  defp fetch_own_approval(%User{id: user_id}, item_id) do
    with true <- Platform.UUID.valid?(item_id),
         %Item{} = item <-
           Repo.one(
             from(i in Item,
               where: i.id == ^item_id and i.user_id == ^user_id and i.kind in @approval_kinds
             )
           ) do
      {:ok, item}
    else
      _ -> {:error, :not_found}
    end
  end

  defp act_on_plan(user, task_id, action, feedback) do
    case pending_plan(task_id) do
      nil ->
        {:error, :already_handled, settled_plan_by(task_id)}

      %Plan{} = plan ->
        result =
          case action do
            :approve -> Tasks.approve_plan(plan, user.id)
            :reject -> Tasks.reject_plan(plan, user.id, feedback)
          end

        case result do
          {:ok, _plan} -> {:ok, status_word(action)}
          {:error, :invalid_transition} -> {:error, :already_handled, settled_plan_by(task_id)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp pending_plan(task_id) do
    Repo.one(
      from(p in Plan,
        where: p.task_id == ^task_id and p.status == "pending_review",
        order_by: [desc: p.version, desc: p.inserted_at],
        limit: 1
      )
    )
  end

  # Who settled it, when that is recorded: `approved_by` on the newest
  # approved plan. A rejection records no actor, so it answers nil.
  defp settled_plan_by(task_id) do
    from(p in Plan,
      where: p.task_id == ^task_id and p.status in ["approved", "completed"],
      order_by: [desc: p.approved_at, desc: p.version],
      select: p.approved_by,
      limit: 1
    )
    |> Repo.one()
    |> actor_name()
  end

  defp act_on_review(_user, _task_id, :reject, nil), do: {:error, :feedback_required}

  defp act_on_review(user, task_id, action, feedback) do
    pending_items =
      from(ri in ReviewItem,
        join: rr in ReviewRequest,
        on: ri.review_request_id == rr.id,
        where: rr.task_id == ^task_id and rr.status == "pending" and ri.status == "pending",
        order_by: [asc: ri.inserted_at],
        select: ri.id
      )
      |> Repo.all()

    case pending_items do
      [] ->
        {:error, :already_handled, settled_review_by(task_id)}

      ids ->
        Enum.reduce_while(ids, {:ok, status_word(action)}, fn id, acc ->
          result =
            case action do
              :approve -> ReviewRequests.approve_item(id, user.id)
              :reject -> ReviewRequests.reject_item(id, user.id, feedback)
            end

          case result do
            {:ok, _item} -> {:cont, acc}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  defp settled_review_by(task_id) do
    from(ri in ReviewItem,
      join: rr in ReviewRequest,
      on: ri.review_request_id == rr.id,
      where: rr.task_id == ^task_id and not is_nil(ri.reviewed_at),
      order_by: [desc: ri.reviewed_at],
      select: ri.reviewed_by,
      limit: 1
    )
    |> Repo.one()
    |> actor_name()
  end

  defp status_word(:approve), do: "approved"
  defp status_word(:reject), do: "rejected"

  # `approved_by` / `reviewed_by` are generic actor strings: a user id, an
  # agent id, or a label such as `"system:auto"`. Only a resolvable person or
  # agent gets a name.
  defp actor_name(actor) when is_binary(actor) do
    if Platform.UUID.valid?(actor) do
      case Platform.Accounts.get_user(actor) do
        %User{name: name} when is_binary(name) and name != "" ->
          name

        _ ->
          case Repo.get(Agent, actor) do
            %Agent{name: name} -> name
            _ -> nil
          end
      end
    end
  end

  defp actor_name(_), do: nil

  # Session-level advisory lock on the checked-out connection, released in
  # `after`. Not a transaction: the domain functions broadcast and dispatch
  # after their own commits, and wrapping them in an outer transaction would
  # move those side effects ahead of the commit they describe.
  defp with_approval_lock(task_id, fun) do
    key = :erlang.phash2(task_id, 2_147_483_647)

    Repo.checkout(fn ->
      Repo.query!("SELECT pg_advisory_lock($1, $2)", [@approval_lock_namespace, key])

      try do
        fun.()
      after
        Repo.query!("SELECT pg_advisory_unlock($1, $2)", [@approval_lock_namespace, key])
      end
    end)
  end

  # ── tasks ────────────────────────────────────────────────────────────

  @doc """
  Open tasks assigned to the user (the `counts_for_user/1` tasks predicate),
  optionally narrowed by a case-insensitive title match.
  """
  @spec list_tasks(User.t(), keyword()) :: [map()]
  def list_tasks(%User{id: user_id}, opts \\ []) do
    limit = clamp_limit(Keyword.get(opts, :limit), @tasks_default_limit, @tasks_max_limit)

    from(t in Task,
      left_join: p in Project,
      on: p.id == t.project_id,
      where:
        t.assignee_type == "user" and t.assignee_id == ^user_id and
          t.status not in @terminal_task_statuses and is_nil(t.deleted_at),
      order_by: [desc: t.updated_at, desc: t.id],
      limit: ^limit,
      select: %{id: t.id, title: t.title, status: t.status, project_name: p.name}
    )
    |> filter_title(Keyword.get(opts, :q))
    |> Repo.all()
  end

  defp filter_title(query, q) when is_binary(q) do
    case String.trim(q) do
      "" ->
        query

      term ->
        pattern = "%" <> escape_like(term) <> "%"
        where(query, [t], ilike(t.title, ^pattern))
    end
  end

  defp filter_title(query, _), do: query

  defp escape_like(term), do: String.replace(term, ~r/([\\%_])/, "\\\\\\1")

  @doc false
  def clamp_limit(value, default, max) do
    case parse_int(value) do
      n when is_integer(n) and n > 0 -> min(n, max)
      _ -> default
    end
  end

  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  # ── meetings ─────────────────────────────────────────────────────────

  @doc "The newest #{@meetings_limit} meetings the user may see."
  @spec list_meetings(User.t()) :: [map()]
  def list_meetings(%User{} = user) do
    meetings = user |> Meetings.list_meetings_for_user() |> Enum.take(@meetings_limit)

    space_names =
      meetings
      |> Enum.map(& &1.chat_space_id)
      |> Enum.reject(&is_nil/1)
      |> then(fn
        [] ->
          %{}

        ids ->
          Repo.all(from(s in Space, where: s.id in ^ids, select: {s.id, s.name})) |> Map.new()
      end)

    Enum.map(meetings, fn m ->
      %{
        id: m.id,
        slug: m.slug,
        name: m.name,
        starts_at: m.scheduled_start_at || m.started_at,
        space_name: Map.get(space_names, m.chat_space_id)
      }
    end)
  end

  @doc """
  Start an unscheduled meeting now, the way MeetingLive's "Meet now" does
  (`Meetings.create_meeting/1` with a name and project, no intended time).

  A meeting belongs to a PROJECT and mints its own chat space, so it cannot
  be created "in" a space. `opts[:space_id]`, when given, is authorized with
  `authorize_space/2` and picks the project: the user's project in that
  space's org. Without it, `opts[:project_id]` if the user can see it, else
  the project of the user's most recent meeting, else their first project.
  """
  @spec start_meeting(User.t(), keyword()) ::
          {:ok, map()} | {:error, :forbidden | :no_project | term()}
  def start_meeting(%User{} = user, opts \\ []) do
    with {:ok, space} <- maybe_authorize_space(user, Keyword.get(opts, :space_id)),
         {:ok, project_id} <- meeting_project_id(user, space, Keyword.get(opts, :project_id)),
         {:ok, meeting} <-
           Meetings.create_meeting(%{
             project_id: project_id,
             name: meet_now_name(DateTime.utc_now()),
             scheduled_start_at: nil,
             scheduled_end_at: nil
           }) do
      {:ok, %{id: meeting.id, slug: meeting.slug, path: "/meetings/#{meeting.slug}"}}
    end
  end

  defp maybe_authorize_space(_user, space_id) when space_id in [nil, ""], do: {:ok, nil}

  defp maybe_authorize_space(user, space_id) do
    case authorize_space(user, space_id) do
      {:ok, space, _participant} -> {:ok, space}
      {:error, :forbidden} -> {:error, :forbidden}
    end
  end

  defp meeting_project_id(user, space, requested) do
    projects = Tasks.list_projects_for_user(user)
    ids = MapSet.new(projects, & &1.id)

    in_org =
      case space do
        %Space{org_id: org_id} when is_binary(org_id) ->
          Enum.find_value(projects, fn p -> if p.org_id == org_id, do: p.id end)

        _ ->
          nil
      end

    recent =
      user
      |> Meetings.list_meetings_for_user()
      |> Enum.find_value(fn m -> if MapSet.member?(ids, m.project_id), do: m.project_id end)

    chosen =
      cond do
        is_binary(requested) and MapSet.member?(ids, requested) -> requested
        in_org -> in_org
        recent -> recent
        true -> projects |> List.first() |> then(&(&1 && &1.id))
      end

    if chosen, do: {:ok, chosen}, else: {:error, :no_project}
  end

  defp meet_now_name(%DateTime{} = at),
    do: "Meeting · " <> Calendar.strftime(at, "%-d %b %Y, %-I:%M %p UTC")

  # ── spaces ───────────────────────────────────────────────────────────

  @doc """
  Authorize `user` on `space_id`: the space exists and is not archived,
  `ExternalScope.authorized_space?/2` admits the user, and the user holds a
  participant row in it. The same three checks `AppApiController`'s message
  post runs. Returns `{:ok, space, participant}` or `{:error, :forbidden}`.
  """
  @spec authorize_space(User.t(), term()) ::
          {:ok, Space.t(), Participant.t()} | {:error, :forbidden}
  def authorize_space(%User{} = user, space_id) do
    with true <- is_binary(space_id) and Platform.UUID.valid?(space_id),
         %Space{archived_at: nil} = space <- Chat.get_space(space_id),
         true <- ExternalScope.authorized_space?(user, space),
         %Participant{} = participant <- user_participant(space.id, user.id) do
      {:ok, space, participant}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp user_participant(space_id, user_id) do
    Repo.one(
      from(p in Participant,
        where:
          p.space_id == ^space_id and p.participant_type == "user" and
            p.participant_id == ^user_id,
        limit: 1
      )
    )
  end

  # ── agents ───────────────────────────────────────────────────────────

  @doc """
  Agents on the roster of any non-archived space the user participates in,
  deduped, with the same space predicate and external scoping as
  `AppApiController.spaces/2`.
  """
  @spec list_agents(User.t()) :: [map()]
  def list_agents(%User{} = user) do
    space_ids =
      from(s in Space,
        join: p in Participant,
        on: p.space_id == s.id,
        where:
          p.participant_type == "user" and p.participant_id == ^user.id and
            is_nil(s.archived_at) and s.kind != "execution",
        select: s.id
      )
      |> ExternalScope.scope_spaces(ExternalScope.for_user(user))

    agents =
      from(a in Agent,
        where:
          a.id in subquery(
            from(p in Participant,
              where: p.participant_type == "agent" and p.space_id in subquery(space_ids),
              select: p.participant_id
            )
          ),
        order_by: [asc: a.name, asc: a.id],
        select: %{id: a.id, name: a.name, slug: a.slug}
      )
      |> Repo.all()

    roles = roles_by_agent(Enum.map(agents, & &1.id))
    Enum.map(agents, &Map.put(&1, :role, Map.get(roles, &1.id)))
  end

  # First role key (alphabetical) an agent holds, or nil.
  defp roles_by_agent([]), do: %{}

  defp roles_by_agent(agent_ids) do
    from(ra in RoleAssignment,
      where: ra.agent_id in ^agent_ids,
      order_by: [asc: ra.role_key],
      select: {ra.agent_id, ra.role_key}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {agent_id, key}, acc -> Map.put_new(acc, agent_id, key) end)
  end

  @doc """
  Find or create the user's DM with an agent. Returns the space id and its
  `path_segment` (a DM has no slug, so this is its id).
  """
  @spec open_agent_dm(User.t(), term()) ::
          {:ok, map()} | {:error, :not_found | :dm_not_allowed | term()}
  def open_agent_dm(%User{id: user_id}, agent_id) do
    with true <- is_binary(agent_id) and Platform.UUID.valid?(agent_id),
         %Agent{} <- Repo.get(Agent, agent_id),
         {:ok, %Space{} = space} <- Chat.find_or_create_dm(user_id, "agent", agent_id) do
      {:ok, %{space_id: space.id, path_segment: Chat.space_path_segment(space)}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  # ── messages poll ────────────────────────────────────────────────────

  @doc """
  Messages in an authorized space after the `after` cursor, oldest first, at
  most #{@messages_max_limit}. `{:error, :forbidden}` for a space the user is
  not in; `{:error, :invalid_cursor}` for a malformed cursor.
  """
  @spec poll_messages(User.t(), term(), keyword()) ::
          {:ok, [map()]} | {:error, :forbidden | :invalid_cursor}
  def poll_messages(%User{} = user, space_id, opts \\ []) do
    after_id = Keyword.get(opts, :after)
    limit = clamp_limit(Keyword.get(opts, :limit), @messages_max_limit, @messages_max_limit)

    with {:ok, space, _participant} <- authorize_space(user, space_id),
         {:ok, after_id} <- cursor(after_id) do
      messages =
        Chat.list_messages(space.id,
          after_id: after_id,
          order: :asc,
          limit: limit,
          scope: ExternalScope.for_user(user)
        )

      {:ok,
       Enum.map(messages, fn m ->
         %{
           id: m.id,
           inserted_at: m.inserted_at,
           author_type: m.author_participant_type,
           author_id: m.author_user_id || m.author_agent_id,
           author_name: m.author_display_name,
           content: m.content,
           thread_id: m.thread_id
         }
       end)}
    end
  end

  defp cursor(nil), do: {:ok, nil}
  defp cursor(""), do: {:ok, nil}

  defp cursor(id) when is_binary(id) do
    if Platform.UUID.valid?(id), do: {:ok, id}, else: {:error, :invalid_cursor}
  end

  defp cursor(_), do: {:error, :invalid_cursor}
end
