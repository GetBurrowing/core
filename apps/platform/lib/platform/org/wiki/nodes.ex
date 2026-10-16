defmodule Platform.Org.Wiki.Nodes do
  @moduledoc """
  Stable identity for org-memory locations (task 01a1386d-e528 stage 1).

  The decision lives in
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Memory grants`: a grant
  anchors to a memory NODE, not to a path. This module owns that identity and
  decides no permission; precedence lives only in `Platform.Access`.

  ## The model

    * A node (`Platform.Org.Wiki.Node`) is a location identity: a page path
      such as `org/page/eng/plan.md`, or a directory prefix ending in `/` such
      as `org/page/eng/`, which has no page row of its own.
    * Its path history is a set of intervals (`Platform.Org.Wiki.NodePath`),
      `[valid_from, valid_to)`. At most one node is CURRENT at a location.
    * **Page rows are untouched.** `Wiki.rename_page/3` still upserts the new
      key and deletes the source row; page ids, versions, indexing and the
      overwrite behaviour do not change. Nodes are a separate identity beside
      them.

  ## Rules

    * **Nodes are created on demand** by `ensure/2` (grant creation, stack
      member 3 stage 2), never on page write. That is why no page writer needs
      a hook.
    * **Page namespaces only:** `org/page/`, `project/<uuid>/page/` and
      `space/<uuid>/page/`, classified with `Platform.Org.Wiki.Routing.classify/1`.
      Journal, private and unknown paths are `{:error, :not_a_node_path}`;
      `burrow/…` is `{:error, :product_owned}`. The bare namespace root
      (`org/page/`) does not classify as a page and is not a node.
    * **A rename moves the node.** `move/3` runs inside the rename's
      transaction, after the page upsert and delete succeeded: it closes the
      old interval and opens the new one, for the node at `old` and, when
      `old` is a prefix, for every node under it.
    * **An overwrite merges.** When a single-page rename overwrites a location
      that has its own node, the displaced node's interval is closed and its
      grants are re-pointed to the moved node through
      `Platform.Access.Grants.merge_memory_nodes/2`, which keeps a deny over an
      allow on the same tuple.
    * **Deleting a page keeps its node.** The node is the location: a page
      recreated at the path inherits it, and a recently-deleted feedback row
      still resolves.
    * **`resolve/2` reads through the interval table.** It returns the nodes
      that covered the path itself and each ancestor prefix at `:at` (default
      now), so a row recorded before a rename still reaches the node it was
      about.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Access.Grants
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.{Node, NodePath, Routing}
  alias Platform.Org.WikiPage
  alias Platform.Repo

  @current_index "org_memory_node_paths_current_location_index"

  @typedoc "Options: `:workspace_id` (default nil), `:org_id`, `:at`."
  @type opts :: keyword()

  # ── Validation ────────────────────────────────────────────────────────

  @doc """
  `:ok` when `path` can name a node (a page path or a page-namespace prefix
  ending in `/`), else `{:error, :product_owned | :not_a_node_path}`.
  """
  @spec validate_path(String.t()) :: :ok | {:error, :product_owned | :not_a_node_path}
  def validate_path(path) when is_binary(path) do
    cond do
      Wiki.product_owned_key?(path) ->
        {:error, :product_owned}

      String.contains?(path, "//") ->
        {:error, :not_a_node_path}

      true ->
        case Routing.classify(path) do
          %{kind: :page, write_role: :historian} -> :ok
          %{kind: :page, write_role: :product} -> {:error, :product_owned}
          _ -> {:error, :not_a_node_path}
        end
    end
  end

  def validate_path(_), do: {:error, :not_a_node_path}

  @doc "True when `path` is a directory prefix (ends in `/`)."
  @spec prefix?(String.t()) :: boolean()
  def prefix?(path) when is_binary(path), do: String.ends_with?(path, "/")

  # ── ensure ────────────────────────────────────────────────────────────

  @doc """
  Returns the current node at `path`, creating it when none exists.

  ## Options
    * `:workspace_id` (default nil)
    * `:org_id` — the node's org. Defaults to the org of the page at `path`,
      then the org of the `project/<uuid>/` or `space/<uuid>/` namespace,
      then the install's root org.
  """
  @spec ensure(String.t(), opts()) ::
          {:ok, Node.t()} | {:error, :product_owned | :not_a_node_path | term()}
  def ensure(path, opts \\ []) do
    with :ok <- validate_path(path) do
      workspace_id = Keyword.get(opts, :workspace_id)

      case current(path, workspace_id: workspace_id) do
        %Node{} = node -> {:ok, node}
        nil -> create(path, workspace_id, opts)
      end
    end
  end

  defp create(path, workspace_id, opts) do
    result =
      Repo.transaction(fn ->
        with {:ok, org_id} <- org_id_for(path, workspace_id, opts),
             {:ok, node} <-
               Repo.insert(%Node{workspace_id: workspace_id, org_id: org_id}),
             {:ok, _} <- open_interval(node.id, workspace_id, path, DateTime.utc_now()) do
          %{node | path: path}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, node} ->
        {:ok, node}

      # Lost a race to a concurrent ensure: the winner's node is the answer.
      {:error, %Ecto.Changeset{} = cs} ->
        if current_index_conflict?(cs) do
          case current(path, workspace_id: workspace_id) do
            %Node{} = node -> {:ok, node}
            nil -> {:error, cs}
          end
        else
          {:error, cs}
        end

      {:error, _} = err ->
        err
    end
  end

  defp current_index_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, meta}} ->
      Keyword.get(meta, :constraint) == :unique and
        Keyword.get(meta, :constraint_name) == @current_index
    end)
  end

  defp org_id_for(path, workspace_id, opts) do
    org_id =
      Keyword.get(opts, :org_id) ||
        page_org_id(path, workspace_id) ||
        namespace_org_id(path) ||
        root_org_id()

    if org_id, do: {:ok, org_id}, else: {:error, :no_org}
  end

  defp page_org_id(path, workspace_id) do
    if prefix?(path) do
      nil
    else
      case Wiki.get_page(path, workspace_id: workspace_id) do
        %WikiPage{file_key: ^path, org_id: org_id} -> org_id
        _ -> nil
      end
    end
  end

  defp namespace_org_id(path) do
    case String.split(path, "/", parts: 3) do
      ["project", id, _] -> org_of(Platform.Tasks.Project, id)
      ["space", id, _] -> org_of(Platform.Chat.Space, id)
      _ -> nil
    end
  end

  defp org_of(schema, id) do
    if Platform.UUID.valid?(id) do
      Repo.one(from(r in schema, where: r.id == ^id, select: r.org_id))
    end
  end

  defp root_org_id do
    case Platform.Tenancy.get_root_org() do
      %{id: id} -> id
      nil -> nil
    end
  end

  # ── reads ─────────────────────────────────────────────────────────────

  @doc """
  The node whose CURRENT location is exactly `path`, or nil. Never creates.
  """
  @spec current(String.t(), opts()) :: Node.t() | nil
  def current(path, opts \\ []) when is_binary(path) do
    workspace_id = Keyword.get(opts, :workspace_id)

    from(p in NodePath,
      join: n in assoc(p, :node),
      where: p.path == ^path and is_nil(p.valid_to),
      select: %{n | path: p.path}
    )
    |> filter_workspace(workspace_id)
    |> Repo.one()
  end

  @doc """
  The nodes that covered `path` at `:at` (default now): the node at `path`
  itself and the node at each ancestor prefix, most specific first. A path
  is read through the interval history, never by string equality on a
  node's current location, so `resolve(old_path, at: before_rename)` returns
  the node that has since moved and `resolve(old_path)` after the rename
  returns nothing for it.

  A node's FIRST interval is open backward (task 01a1386d-e528 stage 4).
  Nodes are created on demand, when a grant is first made, so the location
  existed before its node did: a feedback row recorded at `path` before the
  grant was made still resolves to the node (and its deny). Only the first
  interval extends; a later interval (after a move) starts where it starts.

  ## Options
    * `:workspace_id` (default nil)
    * `:at` — a `DateTime` (default `DateTime.utc_now/0`)
  """
  @spec resolve(String.t(), opts()) :: [Node.t()]
  def resolve(path, opts \\ []) when is_binary(path) do
    workspace_id = Keyword.get(opts, :workspace_id)
    at = Keyword.get(opts, :at) || DateTime.utc_now()
    candidates = covering_paths(path)

    from(p in NodePath,
      as: :np,
      join: n in assoc(p, :node),
      where: p.path in ^candidates,
      where:
        p.valid_from <= ^at or
          not exists(
            from(p0 in NodePath,
              where:
                p0.node_id == parent_as(:np).node_id and
                  p0.valid_from < parent_as(:np).valid_from
            )
          ),
      where: is_nil(p.valid_to) or p.valid_to > ^at,
      select: %{n | path: p.path}
    )
    |> filter_workspace(workspace_id)
    |> Repo.all()
    |> Enum.sort_by(&String.length(&1.path), :desc)
  end

  @doc """
  `path` itself plus every ancestor directory prefix (each ending in `/`).

      iex> Platform.Org.Wiki.Nodes.covering_paths("org/page/eng/x.md")
      ["org/page/eng/x.md", "org/page/eng/", "org/page/", "org/"]
  """
  @spec covering_paths(String.t()) :: [String.t()]
  def covering_paths(path) when is_binary(path) do
    segments = path |> String.trim_trailing("/") |> String.split("/")

    ancestors =
      segments
      |> Enum.drop(-1)
      |> Enum.scan(fn seg, acc -> acc <> "/" <> seg end)
      |> Enum.map(&(&1 <> "/"))
      |> Enum.reverse()

    Enum.uniq([path | ancestors])
  end

  @doc """
  The current node paths at or under `prefix` (the prefix node itself
  included). `prefix` must end in `/`.
  """
  @spec current_under(String.t(), opts()) :: [NodePath.t()]
  def current_under(prefix, opts \\ []) when is_binary(prefix) do
    workspace_id = Keyword.get(opts, :workspace_id)

    from(p in NodePath,
      where: is_nil(p.valid_to),
      where: fragment("starts_with(?, ?)", p.path, ^prefix),
      order_by: [asc: p.path]
    )
    |> filter_workspace(workspace_id)
    |> Repo.all()
  end

  @doc "The subset of `paths` that currently hold a node."
  @spec occupied([String.t()], opts()) :: [String.t()]
  def occupied(paths, opts \\ []) when is_list(paths) do
    workspace_id = Keyword.get(opts, :workspace_id)

    from(p in NodePath,
      where: is_nil(p.valid_to) and p.path in ^paths,
      select: p.path
    )
    |> filter_workspace(workspace_id)
    |> Repo.all()
  end

  # ── move ──────────────────────────────────────────────────────────────

  @doc """
  Moves the node at `old` to `new` and, when both end in `/`, every node
  under `old` to the same relative location under `new`. Call it inside the
  rename's transaction, after the page rows moved.

  A node already current at a target location is DISPLACED: its interval is
  closed and its grants are merged into the moved node
  (`Platform.Access.Grants.merge_memory_nodes/2`, deny kept). With no node at or
  under `old` nothing happens.

  Returns `{:ok, moved_count}`.

  ## Options
    * `:workspace_id` (default nil)
  """
  @spec move(String.t(), String.t(), opts()) :: {:ok, non_neg_integer()} | {:error, term()}
  def move(old, new, opts \\ []) when is_binary(old) and is_binary(new) do
    workspace_id = Keyword.get(opts, :workspace_id)

    cond do
      prefix?(old) != prefix?(new) ->
        {:error, :prefix_mismatch}

      old == new ->
        {:ok, 0}

      true ->
        Repo.transaction(fn -> do_move(old, new, workspace_id) end)
    end
  end

  defp do_move(old, new, workspace_id) do
    moving =
      if prefix?(old) do
        current_under(old, workspace_id: workspace_id)
      else
        current_rows([old], workspace_id)
      end

    case moving do
      [] ->
        0

      rows ->
        now = DateTime.utc_now()
        pairs = Enum.map(rows, fn row -> {row, retarget(row.path, old, new)} end)

        close_intervals(Enum.map(rows, & &1.id), now)

        displaced =
          pairs
          |> Enum.map(&elem(&1, 1))
          |> current_rows(workspace_id)
          |> Map.new(&{&1.path, &1})

        close_intervals(Enum.map(Map.values(displaced), & &1.id), now)

        Enum.each(pairs, fn {row, target} ->
          case Map.get(displaced, target) do
            nil ->
              :ok

            %NodePath{node_id: displaced_id} ->
              Grants.merge_memory_nodes(displaced_id, row.node_id)
          end

          case open_interval(row.node_id, workspace_id, target, now) do
            {:ok, _} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

        length(pairs)
    end
  end

  defp retarget(path, old, new) do
    if path == old, do: new, else: new <> String.replace_prefix(path, old, "")
  end

  defp current_rows([], _workspace_id), do: []

  defp current_rows(paths, workspace_id) do
    from(p in NodePath, where: is_nil(p.valid_to) and p.path in ^paths)
    |> filter_workspace(workspace_id)
    |> Repo.all()
  end

  defp close_intervals([], _now), do: :ok

  defp close_intervals(ids, now) do
    from(p in NodePath, where: p.id in ^ids)
    |> Repo.update_all(set: [valid_to: now])

    :ok
  end

  defp open_interval(node_id, workspace_id, path, now) do
    %NodePath{}
    |> NodePath.open_changeset(%{
      node_id: node_id,
      workspace_id: workspace_id,
      path: path,
      valid_from: now
    })
    |> Repo.insert()
  end

  defp filter_workspace(query, nil), do: from(p in query, where: is_nil(p.workspace_id))

  defp filter_workspace(query, workspace_id),
    do: from(p in query, where: p.workspace_id == ^workspace_id)
end
