defmodule Platform.Context.Item do
  @moduledoc """
  A single context item within a scoped session.

  Items are the atomic units stored in the context plane.  Each item has:

    - `key`     — unique string key within its scope session
    - `value`   — arbitrary serializable term
    - `kind`    — semantic category (e.g. `:task_description`, `:env_var`)
    - `version` — the session version at which this item was last written
    - `meta`    — arbitrary metadata map for extensions
    - `ttl_ms`  — optional lifetime in ms; eviction handled by the Cache

  Item kinds are declared in `Platform.Context.Item.Kind`.
  """

  @enforce_keys [:key, :value, :version]
  defstruct key: nil,
            value: nil,
            kind: :generic,
            version: 0,
            meta: %{},
            ttl_ms: nil,
            inserted_at: nil

  @type t :: %__MODULE__{
          key: String.t(),
          value: term(),
          kind: atom(),
          version: non_neg_integer(),
          meta: map(),
          ttl_ms: non_neg_integer() | nil,
          inserted_at: DateTime.t() | nil
        }

  @doc "Builds a new context item."
  @spec new(String.t(), term(), non_neg_integer(), keyword()) :: t()
  def new(key, value, version, opts \\ []) do
    %__MODULE__{
      key: to_string(key),
      value: value,
      kind: Keyword.get(opts, :kind, :generic),
      version: version,
      meta: Keyword.get(opts, :meta, %{}),
      ttl_ms: Keyword.get(opts, :ttl_ms),
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }
  end

  @doc "Serializes an item to a plain map for wire/storage."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = item) do
    %{
      "key" => item.key,
      "value" => item.value,
      "kind" => Atom.to_string(item.kind),
      "version" => item.version,
      "meta" => item.meta,
      "ttl_ms" => item.ttl_ms,
      "inserted_at" => if(item.inserted_at, do: DateTime.to_iso8601(item.inserted_at), else: nil)
    }
  end
end

defmodule Platform.Context.Item.Kind do
  @moduledoc """
  Well-known context item kinds.

  Kind atoms drive promotion/eviction rules in `Platform.Context.Cache`:

    - `:generic`          — untyped catch-all; evicted on run end
    - `:task_description` — task description text; scoped to task lifetime
    - `:task_metadata`    — structured task fields (title, status, etc.)
    - `:epic_context`     — epic-level context; scoped to epic lifetime
    - `:project_config`   — project-level config; evicted on project close
    - `:env_var`          — environment variable for runners; run-scoped
    - `:artifact_ref`     — reference to an artifact produced by a run (mirrors the `Platform.Artifacts` record into context)
    - `:runner_hint`      — advisory hints pushed by runners; run-scoped
    - `:system_event`     — internal platform events; short-lived

  Promotion rules:
    - `:env_var`, `:runner_hint`, `:artifact_ref`, `:system_event` are
      run-scoped and evicted when their run session ends.
    - `:task_description`, `:task_metadata` are task-scoped.
    - `:epic_context` is epic-scoped.
    - `:project_config` is project-scoped.
  """

  @run_scoped [:env_var, :runner_hint, :artifact_ref, :system_event, :generic]
  @task_scoped [:task_description, :task_metadata]
  @epic_scoped [:epic_context]
  @project_scoped [:project_config]

  @all @run_scoped ++ @task_scoped ++ @epic_scoped ++ @project_scoped

  @doc "All valid kind atoms."
  @spec all() :: [atom()]
  def all, do: @all

  @doc "Returns true if `kind` is valid."
  @spec valid?(atom()) :: boolean()
  def valid?(kind) when is_atom(kind), do: kind in @all
  def valid?(_), do: false

  @doc """
  Returns the eviction scope for `kind`.

  `:run` items are evicted when the run session ends.
  `:task` items survive run-end but are evicted when the task closes.
  `:epic` items survive task-end but are evicted when the epic closes.
  `:project` items survive epic-end but are evicted when the project closes.
  """
  @spec eviction_scope(atom()) :: :run | :task | :epic | :project
  def eviction_scope(kind) when kind in @run_scoped, do: :run
  def eviction_scope(kind) when kind in @task_scoped, do: :task
  def eviction_scope(kind) when kind in @epic_scoped, do: :epic
  def eviction_scope(kind) when kind in @project_scoped, do: :project
  def eviction_scope(_), do: :run
end
