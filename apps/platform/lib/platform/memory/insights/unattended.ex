defmodule Platform.Memory.Insights.Unattended do
  @moduledoc """
  Who acts when an insight is applied with no person clicking. Task
  `01a15587-afc8-7000-b76d-4e1c48eee5ed`, stage 2. Used by
  `Platform.Memory.Insights.Actions.apply_unattended/2`.

  ## Eligibility: only the dreaming agent's own insights

  `eligible?/1` is true only for an insight whose `authored_by` is the
  agent currently holding `memory.dreaming`
  (`Platform.Roles.assignee_for/1`). Any agent or person can append a
  `<synthesis-insight>` block to a journal, so without this check anyone
  could make the Historian write a page by writing a block: a confused
  deputy. Every other insight stays person-actable on the Insights tab
  exactly as before. `authored_by` names an agent or a user and carries no
  foreign key; it is compared for equality here and never joined on.

  ## The acting identities

    * `page_edit` acts as the agent holding the `historian` ROLE
      (`Platform.Roles.agent_id_for_role/1`). `page_edit_actor/1` requires
      BOTH `Platform.Org.Wiki.Routing.gate_write/3` for that agent on the
      target key (the predicate the memory_* MCP tools use) AND
      `Platform.Access.can?(scope, "memory.write", {:memory, key})` on the
      agent's runtime scope. `Platform.Org.Wiki.upsert_page/3` performs no
      authorization of its own, so these two checks are the gate.
    * `task` acts as the agent holding `memory.dreaming` (the agent that
      wrote the insight and sends the briefing). `task_actor/0` returns its
      runtime scope; the project is then checked through
      `Platform.Access.task_target/3` with `tasks.write` in `Actions`.

  An agent's scope is `Platform.Access.Scope.for_runtime/1` of its BRAIN
  runtime, `Platform.Federation.get_runtime_for_agent/1` (the row
  `agent.runtime_id` points at), so it is capped by that runtime's profile
  AND its owner's scope. Not the most recently connected row: an agent may
  also own voice runtimes (`Platform.Federation.register_voice_runtime/3`),
  and one that connected later with a broader profile must not widen what
  the agent does unattended (task 01a15587 stage 3). An agent with no brain
  runtime has no scope and cannot act.

  Access records no "agent X acted for person Y": the audit trail is
  `acted_by` = the acting agent, the sponsor / addressee = the person.

  ## Undo runs as the identity that acted (stage 4)

  `undo_page_edit_actor/2` and `undo_task_actor/1` resolve the agent whose
  id the act stored (`pre_image["acting_agent_id"]`), NOT the current role
  or responsibility holder, so an undo after a Historian handover still
  runs as the agent that did the act. The same checks as acting apply
  again, now: the wiki gate and `memory.write` on the page for a revert, a
  brain runtime scope for a task delete (whose `tasks.write` on the task is
  then checked in `Actions`). An agent that has since lost them cannot
  undo, and nothing is written. Who may ASK for the undo (the recipient of
  the briefing) is decided in `Platform.Memory.Insights.Actions`.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Access
  alias Platform.Access.Scope
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Federation
  alias Platform.Memory.Insight
  alias Platform.Org.Wiki.Routing, as: WikiRouting
  alias Platform.Repo
  alias Platform.Responsibilities.Handlers.Dreaming
  alias Platform.Roles

  @historian_role "historian"

  @doc """
  True when `insight` was authored by the current `memory.dreaming` holder.
  False with no holder, or a nil author.
  """
  @spec eligible?(Insight.t()) :: boolean()
  def eligible?(%Insight{authored_by: author}) when is_binary(author) do
    case dreaming_agent() do
      %Agent{id: ^author} -> true
      _ -> false
    end
  end

  def eligible?(_insight), do: false

  @doc """
  The Historian and its runtime scope, permitted to write page `file_key`.
  `{:error, :no_historian}` when the role is unassigned or names no agent;
  `{:error, :unauthorized}` when the agent has no runtime, the wiki gate
  refuses the key, or the scope lacks `memory.write` on it.
  """
  @spec page_edit_actor(String.t()) ::
          {:ok, Agent.t(), Scope.t()} | {:error, :no_historian | :unauthorized}
  def page_edit_actor(file_key) when is_binary(file_key) do
    with %Agent{} = agent <- historian() || {:error, :no_historian} do
      page_writer(agent, file_key)
    end
  end

  def page_edit_actor(_file_key), do: {:error, :unauthorized}

  @doc """
  The agent `agent_id` (the one that applied a page edit) and its runtime
  scope, permitted NOW to write `file_key` by the same two checks as
  `page_edit_actor/1`. `{:error, :unauthorized}` otherwise, including an
  agent that no longer exists.
  """
  @spec undo_page_edit_actor(term(), term()) ::
          {:ok, Agent.t(), Scope.t()} | {:error, :unauthorized}
  def undo_page_edit_actor(agent_id, file_key) when is_binary(file_key) do
    with %Agent{} = agent <- agent(agent_id) || {:error, :unauthorized} do
      page_writer(agent, file_key)
    end
  end

  def undo_page_edit_actor(_agent_id, _file_key), do: {:error, :unauthorized}

  @doc """
  The agent `agent_id` (the one that filed a task) and its runtime scope.
  `{:error, :unauthorized}` when the agent is gone or has no brain runtime.
  """
  @spec undo_task_actor(term()) :: {:ok, Agent.t(), Scope.t()} | {:error, :unauthorized}
  def undo_task_actor(agent_id) do
    with %Agent{} = agent <- agent(agent_id) || {:error, :unauthorized},
         %Scope{} = scope <- runtime_scope(agent) || {:error, :unauthorized} do
      {:ok, agent, scope}
    end
  end

  defp page_writer(%Agent{} = agent, file_key) do
    with :ok <- gate(agent, file_key),
         %Scope{} = scope <- runtime_scope(agent) || {:error, :unauthorized},
         true <-
           Access.can?(scope, "memory.write", {:memory, file_key}) || {:error, :unauthorized} do
      {:ok, agent, scope}
    end
  end

  @doc """
  The `memory.dreaming` holder and its runtime scope. `{:error, :no_agent}`
  when nobody holds the responsibility or the holder has no runtime.
  """
  @spec task_actor() :: {:ok, Agent.t(), Scope.t()} | {:error, :no_agent}
  def task_actor do
    with %Agent{} = agent <- dreaming_agent() || {:error, :no_agent},
         %Scope{} = scope <- runtime_scope(agent) || {:error, :no_agent} do
      {:ok, agent, scope}
    end
  end

  defp gate(agent, file_key) do
    case WikiRouting.gate_write(agent, file_key) do
      :ok -> :ok
      {:error, _error} -> {:error, :unauthorized}
    end
  end

  defp historian, do: agent(Roles.agent_id_for_role(@historian_role))

  # The id is a `role_assignments.agent_id` uuid column value, or the
  # `acting_agent_id` an act stored in the insight's `pre_image` (a jsonb
  # value, so it is checked before the pinned `where` can cast it).
  defp agent(id) do
    if Platform.UUID.valid?(id),
      do: Repo.one(from(a in Agent, where: a.id == ^id)),
      else: nil
  end

  defp dreaming_agent, do: Roles.assignee_for(Dreaming.key())

  # The brain runtime only (see the moduledoc), never the latest-connected
  # row an agent owns.
  defp runtime_scope(%Agent{} = agent) do
    case Federation.get_runtime_for_agent(agent) do
      %AgentRuntime{} = runtime -> Scope.for_runtime(runtime)
      nil -> nil
    end
  end
end
