defmodule Platform.Execution.Run do
  @moduledoc """
  Value struct representing a single execution run.

  A run is the atomic unit of work within the Execution domain.  It maps to a
  task attempt: one agent session, one runner process, one context session.

  ## Lifecycle

      created → starting → running → {completed | failed | cancelled}
                                  ↓
                              context_stale  (ack SLA missed)
                                  ↓
                              context_dead   (runner presumed dead)

  ## Context versioning

  Each run tracks:
    - `ctx_required_version`  — the version the runner must acknowledge
    - `ctx_acked_version`     — the last version the runner confirmed
    - `ctx_status`            — `:current | :pending | :stale | :dead`

  ## Provider ref

  When a runner is attached via `Platform.Execution.RunServer.spawn_provider/3`,
  the provider-specific handle is stored in `runner_ref`.  The shape is defined
  by each provider; local runners store `wrapper_pid` and `os_pid` here.
  """

  @valid_statuses ~w(created starting running completed failed cancelled)a
  @valid_ctx_statuses ~w(current pending stale dead)a

  @enforce_keys [:id, :task_id]
  defstruct id: nil,
            task_id: nil,
            project_id: nil,
            epic_id: nil,
            runner_type: :local,
            status: :created,
            ctx_required_version: 0,
            ctx_acked_version: nil,
            ctx_status: :current,
            runner_ref: %{},
            exit_code: nil,
            started_at: nil,
            finished_at: nil,
            inserted_at: nil,
            meta: %{}

  @type status :: :created | :starting | :running | :completed | :failed | :cancelled
  @type ctx_status :: :current | :pending | :stale | :dead

  @type t :: %__MODULE__{
          id: String.t(),
          task_id: String.t(),
          project_id: String.t() | nil,
          epic_id: String.t() | nil,
          runner_type: atom(),
          status: status(),
          ctx_required_version: non_neg_integer(),
          ctx_acked_version: non_neg_integer() | nil,
          ctx_status: ctx_status(),
          runner_ref: map(),
          exit_code: integer() | nil,
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          meta: map()
        }

  @doc "Creates a new run struct."
  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(run_id, task_id, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %__MODULE__{
      id: run_id,
      task_id: task_id,
      project_id: Keyword.get(opts, :project_id),
      epic_id: Keyword.get(opts, :epic_id),
      runner_type: Keyword.get(opts, :runner_type, :local),
      status: :created,
      ctx_required_version: 0,
      ctx_acked_version: nil,
      ctx_status: :current,
      runner_ref: %{},
      exit_code: nil,
      inserted_at: now,
      meta: normalize_map(Keyword.get(opts, :meta, %{}))
    }
  end

  @doc "Returns true if the run is in a terminal state."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in [:completed, :failed, :cancelled]

  @doc "Returns true if the context is healthy (current)."
  @spec context_current?(t()) :: boolean()
  def context_current?(%__MODULE__{ctx_status: :current}), do: true
  def context_current?(_), do: false

  @doc "Valid run statuses."
  @spec valid_statuses() :: [status()]
  def valid_statuses, do: @valid_statuses

  @doc "Valid context statuses."
  @spec valid_ctx_statuses() :: [ctx_status()]
  def valid_ctx_statuses, do: @valid_ctx_statuses

  @doc "Returns the context scope key for this run."
  @spec context_scope_key(t()) :: String.t()
  def context_scope_key(%__MODULE__{} = run) do
    parts =
      [run.project_id, run.epic_id, run.task_id, run.id]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, "/")
  end

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_), do: %{}
end
