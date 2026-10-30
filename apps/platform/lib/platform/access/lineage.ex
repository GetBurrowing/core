defmodule Platform.Access.Lineage do
  @moduledoc """
  The inheritance edges between resources (task 01a1386d-e528 stage 2,
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Levels and inheritance`).
  This module answers "what is above this resource" and "what is below these
  resources". It compares no effect and makes no decision: precedence lives
  only in `Platform.Access` and `Platform.Access.Query`.

  ## Edges, downward only

    * project P → its tasks (`tasks.project_id`);
    * project P → those tasks' execution spaces (`chat_spaces.kind =
      'execution'`, `metadata->>'task_id'` compared as text, never cast);
    * project P → the canvases in those spaces, and the canvases attached to
      P's tasks (`task_canvas_attachments`);
    * project P → stacks with `task_stacks.project_id = P`;
    * space S → canvases whose `space_id` is S. The stage plan lists canvas
      edges only below a project; the ADR additionally requires this direct
      edge, and the ADR wins;
    * memory node N → every node and page under N's current path, through
      `Platform.Org.Wiki.Nodes.resolve/2`;
    * project P → its meetings' chat spaces (`meetings.project_id = P` →
      `meetings.chat_space_id`), and the canvases in them (task 01a18d38
      stage 2), so a project deny covers a meeting created later;
    * org O → its projects (`projects.org_id`), and through them their
      tasks, stacks, execution and meeting spaces and canvases; and its
      spaces (`chat_spaces.org_id`) and their canvases (task 01a18d38 stage
      2). Memory has no org edge.

  Nothing flows upward: `ancestors/1` of an org is the org alone, and
  `descendant_ids/2` never returns a project for a space or canvas target.

  ## Coverage is computed when the check runs

  No edge is materialised: a space, meeting or project created after an org
  or project deny is covered the moment its `org_id` / `project_id` is set,
  whichever path created it.

  ## A nil org is no org (fail closed, not open)

  A resource whose `org_id` is NULL (an org-less space, a project without an
  org) gets no `{:org, _}` ancestor, so it inherits no org deny; it keeps its
  own denies and its project's. A NULL org is never read as "covered by every
  org", which would turn one org's deny into an install-wide one.

  ## Resource forms

  A typed resource is one of `{:org, id}`, `{:project, id}`, `{:task, id}`,
  `{:stack, id}`, `{:space, id}`, `{:canvas, id}`, `{:memory, path}`,
  `{:memory, path, at}` or `{:memory_node, id}`. `typed/1` also infers the
  type from an `%Org{}`, `%Project{}`, `%Task{}`, `%Stack{}`, `%Space{}` or
  `%Canvas{}` struct. `:org` is a grant TARGET only: `id_types/0` (the types
  a listing asks about) does not include it.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Chat.{Canvas, Space}
  alias Platform.Meetings.Meeting
  alias Platform.Org.Wiki.{NodePath, Nodes}
  alias Platform.Repo
  alias Platform.Tasks.{CanvasAttachment, Project, Stack, Task}
  alias Platform.Tenancy.Org

  @type typed ::
          {:org | :project | :task | :stack | :space | :canvas | :memory_node, binary()}
          | {:memory, String.t()}
          | {:memory, String.t(), DateTime.t() | nil}

  @id_types [:org, :project, :task, :stack, :space, :canvas, :memory_node]

  @doc "The resource types `descendant_ids/2` and `base_ids/4` accept."
  @spec id_types() :: [atom()]
  def id_types, do: [:project, :task, :stack, :space, :canvas]

  @doc """
  The typed form of `resource`, or `:untyped` (a bare id, an untyped map, or
  `nil`). Structs are inferred; tuples pass through.
  """
  @spec typed(term()) :: typed() | :untyped
  # A tuple's id can arrive from a boundary (a LiveView param, an MCP
  # argument): a malformed one is untyped, never a query that raises.
  def typed({type, id} = r) when type in @id_types and is_binary(id),
    do: if(Platform.UUID.valid?(id), do: r, else: :untyped)

  def typed({:memory, path}) when is_binary(path), do: {:memory, path, nil}
  def typed({:memory, path, _at} = r) when is_binary(path), do: r
  def typed(%Org{id: id}) when is_binary(id), do: {:org, id}
  def typed(%Project{id: id}) when is_binary(id), do: {:project, id}
  def typed(%Task{id: id}) when is_binary(id), do: {:task, id}
  def typed(%Stack{id: id}) when is_binary(id), do: {:stack, id}
  def typed(%Space{id: id}) when is_binary(id), do: {:space, id}
  def typed(%Canvas{id: id}) when is_binary(id), do: {:canvas, id}
  def typed(_), do: :untyped

  # ── upward: what covers one resource ─────────────────────────────────

  @doc """
  The resource itself plus every resource above it on a downward edge, as
  `{type, id}` pairs. Memory resolves to the covering node ids
  (`{:memory_node, id}`), read through the interval history at `at`.
  """
  @spec ancestors(typed()) :: [{atom(), binary()}]
  def ancestors({:org, id}), do: [{:org, id}]

  def ancestors({:project, id}) do
    org = Repo.one(from(p in Project, where: p.id == ^id, select: p.org_id))
    [{:project, id} | org_pairs([org])]
  end

  def ancestors({:task, id}) do
    rows =
      Repo.all(
        from(t in Task,
          left_join: p in Project,
          on: p.id == t.project_id,
          where: t.id == ^id,
          select: {t.project_id, p.org_id}
        )
      )

    [{:task, id} | project_and_org_pairs(rows)]
  end

  def ancestors({:stack, id}) do
    rows =
      Repo.all(
        from(s in Stack,
          left_join: p in Project,
          on: p.id == s.project_id,
          where: s.id == ^id,
          select: {s.project_id, p.org_id}
        )
      )

    [{:stack, id} | project_and_org_pairs(rows)]
  end

  # The space's own org, the project of an execution space, and the project
  # of a meeting whose chat space it is, each with that project's org.
  def ancestors({:space, id}) do
    space_org = Repo.one(from(s in Space, where: s.id == ^id, select: s.org_id))

    Enum.uniq(
      [{:space, id}] ++
        project_and_org_pairs(execution_space_project(id) ++ meeting_space_projects(id)) ++
        org_pairs([space_org])
    )
  end

  def ancestors({:canvas, id}) do
    space_id = Repo.one(from(c in Canvas, where: c.id == ^id, select: c.space_id))

    attached_projects =
      Repo.all(
        from(a in CanvasAttachment,
          join: t in Task,
          on: t.id == a.task_id,
          left_join: p in Project,
          on: p.id == t.project_id,
          where: a.canvas_id == ^id,
          select: {t.project_id, p.org_id}
        )
      )

    above_space = if space_id, do: ancestors({:space, space_id}), else: []

    Enum.uniq([{:canvas, id}] ++ above_space ++ project_and_org_pairs(attached_projects))
  end

  def ancestors({:memory, path, at}) do
    path
    |> Nodes.resolve(at: at)
    |> Enum.map(&{:memory_node, &1.id})
  end

  def ancestors({:memory_node, id}) do
    current =
      Repo.one(
        from(p in NodePath, where: p.node_id == ^id and is_nil(p.valid_to), select: p.path)
      )

    case current do
      nil -> [{:memory_node, id}]
      path -> Enum.uniq([{:memory_node, id} | ancestors({:memory, path, nil})])
    end
  end

  defp project_pairs(ids), do: for(id <- ids, is_binary(id), do: {:project, id})

  # A NULL org contributes nothing (moduledoc, "A nil org is no org").
  defp org_pairs(ids), do: for(id <- ids, is_binary(id), do: {:org, id})

  defp project_and_org_pairs(rows) do
    Enum.uniq(
      project_pairs(Enum.map(rows, &elem(&1, 0))) ++ org_pairs(Enum.map(rows, &elem(&1, 1)))
    )
  end

  defp execution_space_project(space_id) do
    Repo.all(
      from(s in Space,
        join: t in Task,
        on: fragment("?->>'task_id' = ?::text", s.metadata, t.id),
        left_join: p in Project,
        on: p.id == t.project_id,
        where: s.id == ^space_id and s.kind == "execution",
        select: {t.project_id, p.org_id}
      )
    )
  end

  # The project → meeting chat space edge, read upward.
  defp meeting_space_projects(space_id) do
    Repo.all(
      from(m in Meeting,
        left_join: p in Project,
        on: p.id == m.project_id,
        where: m.chat_space_id == ^space_id,
        select: {m.project_id, p.org_id}
      )
    )
  end

  # ── downward: everything a set of targets covers ─────────────────────

  @doc """
  The ids of every `type` resource that `targets` (grant targets, as
  `{type, id}` pairs) cover through the downward edges, the targets of that
  type themselves included.
  """
  @spec descendant_ids(atom(), [{atom(), binary()}]) :: [binary()]
  def descendant_ids(_type, []), do: []

  def descendant_ids(type, targets) do
    orgs = ids_of(targets, :org)
    projects = ids_of(targets, :project)
    spaces = ids_of(targets, :space)
    canvases = ids_of(targets, :canvas)

    # Every project the targets cover: the named ones plus every project of a
    # named org, as ONE subquery (never a query per project or per org).
    covered_projects = projects_of(projects, orgs)

    case type do
      :project when orgs == [] ->
        projects

      :project ->
        Repo.all(covered_projects)

      :task ->
        Repo.all(from(t in Task, where: t.project_id in subquery(covered_projects), select: t.id))

      :stack ->
        Repo.all(
          from(s in Stack, where: s.project_id in subquery(covered_projects), select: s.id)
        )

      :space ->
        Repo.all(
          from(s in Space,
            where:
              s.id in ^spaces or s.org_id in ^orgs or
                s.id in subquery(execution_spaces_of(covered_projects)) or
                s.id in subquery(meeting_spaces_of(covered_projects)),
            select: s.id
          )
        )

      :canvas ->
        Repo.all(
          from(c in Canvas,
            left_join: s in Space,
            on: s.id == c.space_id,
            where:
              c.id in ^canvases or c.space_id in ^spaces or s.org_id in ^orgs or
                c.space_id in subquery(execution_spaces_of(covered_projects)) or
                c.space_id in subquery(meeting_spaces_of(covered_projects)) or
                c.id in subquery(attached_canvases_of(covered_projects)),
            select: c.id
          )
        )
    end
    |> Enum.uniq()
  end

  defp ids_of(targets, type), do: for({^type, id} <- targets, do: id)

  defp projects_of(projects, orgs) do
    from(p in Project, where: p.id in ^projects or p.org_id in ^orgs, select: p.id)
  end

  defp execution_spaces_of(projects) do
    from(s in Space,
      join: t in Task,
      on: fragment("?->>'task_id' = ?::text", s.metadata, t.id),
      where: s.kind == "execution" and t.project_id in subquery(projects),
      select: s.id
    )
  end

  defp meeting_spaces_of(projects) do
    from(m in Meeting, where: m.project_id in subquery(projects), select: m.chat_space_id)
  end

  defp attached_canvases_of(projects) do
    from(a in CanvasAttachment,
      join: t in Task,
      on: t.id == a.task_id,
      where: t.project_id in subquery(projects),
      select: a.canvas_id
    )
  end

  # ── the ids a role rule names ─────────────────────────────────────────

  @doc """
  The resource ids a role rule's id list could name for `typed`: the
  resource's own id plus the ids of its context that member 2's rules name
  (the org for `membership_org`, the space for a canvas's
  `participant_spaces`). A space is returned as `%{id, kind}` so the
  `implicit_or_participant` kind admission can answer it.
  """
  @spec base_candidates(typed()) :: [term()]
  def base_candidates({:project, id}) do
    [id | List.wrap(Repo.one(from(p in Project, where: p.id == ^id, select: p.org_id)))]
  end

  def base_candidates({:task, id}) do
    org =
      Repo.one(
        from(t in Task,
          join: p in Project,
          on: p.id == t.project_id,
          where: t.id == ^id,
          select: p.org_id
        )
      )

    [id | List.wrap(org)]
  end

  def base_candidates({:stack, id}) do
    org =
      Repo.one(
        from(s in Stack,
          join: p in Project,
          on: p.id == s.project_id,
          where: s.id == ^id,
          select: p.org_id
        )
      )

    [id | List.wrap(org)]
  end

  def base_candidates({:space, id}) do
    case Repo.one(from(s in Space, where: s.id == ^id, select: {s.kind, s.org_id})) do
      {kind, org_id} -> [%{id: id, kind: kind} | List.wrap(org_id)]
      nil -> [id]
    end
  end

  def base_candidates({:canvas, id}) do
    row =
      Repo.one(
        from(c in Canvas,
          left_join: s in Space,
          on: s.id == c.space_id,
          where: c.id == ^id,
          select: {c.space_id, s.org_id}
        )
      )

    case row do
      {space_id, org_id} -> [id | Enum.reject([space_id, org_id], &is_nil/1)]
      nil -> [id]
    end
  end

  def base_candidates({:org, id}), do: [id]

  def base_candidates(_memory), do: []

  @doc """
  The set form of `base_candidates/1`: every `type` resource id one of `ids`
  names through the same context, plus, for a space, every space whose kind
  is in `kinds` (the `implicit_or_participant` admission).
  """
  @spec base_ids(atom(), [binary()], [String.t()]) :: [binary()]
  def base_ids(:project, ids, _kinds),
    do: Repo.all(from(p in Project, where: p.id in ^ids or p.org_id in ^ids, select: p.id))

  def base_ids(:task, ids, _kinds) do
    Repo.all(
      from(t in Task,
        left_join: p in Project,
        on: p.id == t.project_id,
        where: t.id in ^ids or p.org_id in ^ids,
        select: t.id
      )
    )
  end

  def base_ids(:stack, ids, _kinds) do
    Repo.all(
      from(s in Stack,
        left_join: p in Project,
        on: p.id == s.project_id,
        where: s.id in ^ids or p.org_id in ^ids,
        select: s.id
      )
    )
  end

  def base_ids(:space, ids, kinds) do
    Repo.all(
      from(s in Space,
        where: s.id in ^ids or s.org_id in ^ids or s.kind in ^kinds,
        select: s.id
      )
    )
  end

  def base_ids(:canvas, ids, _kinds) do
    Repo.all(
      from(c in Canvas,
        left_join: s in Space,
        on: s.id == c.space_id,
        where: c.id in ^ids or c.space_id in ^ids or s.org_id in ^ids,
        select: c.id
      )
    )
  end
end
