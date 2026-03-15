defmodule Platform.Agents.Context do
  @moduledoc """
  Runtime context assembled for an agent session.

  T3 introduces the persistent memory/workspace loading layer that later runtime
  tasks (AgentServer, ContextBroker, orchestration) will consume. The struct is
  intentionally small and serializable: workspace files are materialized into a
  key/value map and memories are grouped by type.
  """

  @type memory_bucket :: %{optional(atom()) => [Platform.Agents.Memory.t()]}

  @type t :: %__MODULE__{
          agent_id: Ecto.UUID.t(),
          session_id: Ecto.UUID.t() | nil,
          workspace: %{optional(String.t()) => String.t()},
          memory: memory_bucket(),
          inherited: map(),
          local: map(),
          metadata: map()
        }

  @enforce_keys [:agent_id]
  defstruct agent_id: nil,
            session_id: nil,
            workspace: %{},
            memory: %{},
            inherited: %{},
            local: %{},
            metadata: %{}
end
