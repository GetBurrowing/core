defmodule Platform.Context.Session do
  @moduledoc """
  Value struct representing a scoped context session.

  A session is the primary unit of context isolation.  It maps one-to-one
  with a four-level scope key and holds:

    - `version`          — current write-version (monotonic integer)
    - `required_version` — the minimum version runners must acknowledge
    - `scope`            — the `%Scope{}` this session belongs to
    - `inserted_at`      — wall-clock creation time
    - `updated_at`       — last mutation time
  """

  @enforce_keys [:scope]
  defstruct scope: nil,
            version: 0,
            required_version: 0,
            inserted_at: nil,
            updated_at: nil

  @type t :: %__MODULE__{
          scope: Scope.t(),
          version: non_neg_integer(),
          required_version: non_neg_integer(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  # ---------------------------------------------------------------------------
  # Scope
  # ---------------------------------------------------------------------------

  defmodule Scope do
    @moduledoc """
    Identifies a context session.

    All four fields are optional strings.  The cache key is the
    slash-joined tuple of non-nil fields.
    """

    @enforce_keys []
    defstruct project_id: nil,
              epic_id: nil,
              task_id: nil,
              run_id: nil

    @type t :: %__MODULE__{
            project_id: String.t() | nil,
            epic_id: String.t() | nil,
            task_id: String.t() | nil,
            run_id: String.t() | nil
          }
  end

  @type scope_input :: Scope.t() | map() | keyword()

  # ---------------------------------------------------------------------------
  # Construction helpers
  # ---------------------------------------------------------------------------

  @doc "Creates a new session for `scope` at version 0."
  @spec new(Scope.t()) :: t()
  def new(%Scope{} = scope) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %__MODULE__{
      scope: scope,
      version: 0,
      required_version: 0,
      inserted_at: now,
      updated_at: now
    }
  end

  @doc "Builds a `%Scope{}` from various input shapes."
  @spec to_scope(scope_input()) :: {:ok, Scope.t()} | {:error, :invalid_scope}
  def to_scope(%Scope{} = scope), do: {:ok, scope}

  def to_scope(attrs) when is_list(attrs) do
    attrs |> Map.new() |> to_scope()
  end

  def to_scope(attrs) when is_map(attrs) do
    scope = %Scope{
      project_id: str_or_nil(Map.get(attrs, :project_id) || Map.get(attrs, "project_id")),
      epic_id: str_or_nil(Map.get(attrs, :epic_id) || Map.get(attrs, "epic_id")),
      task_id: str_or_nil(Map.get(attrs, :task_id) || Map.get(attrs, "task_id")),
      run_id: str_or_nil(Map.get(attrs, :run_id) || Map.get(attrs, "run_id"))
    }

    if all_nil?(scope) do
      {:error, :invalid_scope}
    else
      {:ok, scope}
    end
  end

  def to_scope(_), do: {:error, :invalid_scope}

  @doc """
  Returns the ETS/Registry cache key for a scope.

  The key is the canonical binary used to key all ETS operations.
  """
  @spec scope_key(scope_input()) :: {:ok, String.t()} | {:error, term()}
  def scope_key(%Scope{} = scope) do
    parts =
      [scope.project_id, scope.epic_id, scope.task_id, scope.run_id]
      |> Enum.reject(&is_nil/1)

    if parts == [] do
      {:error, :empty_scope}
    else
      {:ok, Enum.join(parts, "/")}
    end
  end

  def scope_key(input) do
    with {:ok, scope} <- to_scope(input) do
      scope_key(scope)
    end
  end

  # ---------------------------------------------------------------------------
  # Mutation helpers (return updated struct)
  # ---------------------------------------------------------------------------

  @doc "Bumps the session version and returns the new version + updated struct."
  @spec bump_version(t()) :: {non_neg_integer(), t()}
  def bump_version(%__MODULE__{} = session) do
    new_version = session.version + 1
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    updated = %__MODULE__{session | version: new_version, updated_at: now}
    {new_version, updated}
  end

  @doc "Sets `required_version` to the current `version`."
  @spec set_required(t()) :: t()
  def set_required(%__MODULE__{} = session) do
    %__MODULE__{session | required_version: session.version}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp str_or_nil(nil), do: nil
  defp str_or_nil(v), do: to_string(v)

  defp all_nil?(%Scope{} = s) do
    is_nil(s.project_id) and is_nil(s.epic_id) and is_nil(s.task_id) and is_nil(s.run_id)
  end
end
