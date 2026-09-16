defmodule Platform.Tasks.TransitionActor do
  @moduledoc """
  Process-local attribution context for task status transitions.

  `Ecto.Changeset.prepare_changes/2` — the choke point that records
  `Platform.Tasks.PhaseTransition` rows — receives only the changeset. It
  gets no actor argument and cannot be given one without changing the
  signature of every status writer in the codebase. So the actor travels
  out-of-band, in the process dictionary.

  That is sound here specifically because the write always happens in the
  calling process: `Repo.update/1` is synchronous, and `Repo.transaction(fn
  -> ... end)` runs the function in the caller. There is no hand-off to a
  pool worker between `with_actor/3` setting the context and
  `prepare_changes` reading it. If a future writer ever moves a status
  update into a spawned task, it must call `with_actor/3` again inside that
  process — the context does not cross process boundaries.

  ## The default is `unknown`, not `system`

  A write with no surrounding context records `actor_kind: "unknown"`. It
  would be easy, and wrong, to default to `"system"`: that would silently
  file every unattributed write as engine time, and the entire point of the
  `actor_kind` column is to separate human wait from engine wait. An
  unattributed write must be visibly unattributed so it can be found and
  attributed later.

  ## Reading a row: `via` and `actor_kind` are two separate questions

  `via` answers "which code path wrote this"; `actor_kind` answers "who
  asked for it". They fail independently, and the PAIR is what a reader
  must look at:

    * `via` non-nil, `actor_kind` in `user | agent | system` — fully
      attributed. The normal case.
    * `via` non-nil, `actor_kind` `"unknown"` — KNOWN code path, caller
      genuinely not identifiable from it. Two shipped instances: the
      `cleanup_ghost_tasks` mix task (run by a human at a shell whose
      identity never enters the BEAM) and an MCP `task_complete` whose
      call context carried no `agent_id`. Nothing more is knowable here
      without changing the CALLER; the recorder already did its job.
    * `via` nil, `actor_kind` `"unknown"` — NOT CAPTURED. Some status
      writer ran outside `with_actor/3` entirely. That is a measurement
      gap and a defect in the writer: find it and wrap it.

  So `via` is the field that separates "we looked and there is no actor"
  from "we never looked". It deliberately carries work a fifth
  `actor_kind` value would otherwise do: `actor_kind` is a four-value
  domain declared and inclusion-validated on
  `Platform.Tasks.PhaseTransition`, and widening it needs a migration
  plus an audit of every consumer that buckets human-wait against
  engine-wait.

  THE LIMIT OF THAT ENCODING, stated rather than glossed: a row written
  BEFORE its path was wrapped also carries `via: nil`. On historical data
  "not captured" and "written before the stamp landed" are therefore NOT
  distinguishable from the row alone — only by comparing `occurred_at`
  against the commit that wrapped that path.

  Pass `:unattributed` when a path is reachable but its caller is not
  threaded through: it records exactly the honest default while still
  stamping `via`, and reads at the call site as a deliberate choice
  rather than an omission.
  """

  @key :platform_task_transition_actor

  @default %{actor_kind: "unknown", actor_id: nil, actor_label: nil, via: nil}

  @doc """
  Run `fun` with `actor` and `via` recorded as the ambient transition
  context.

  The previous value is restored in an `after` block, so nesting works: an
  inner `with_actor/3` does not clobber the outer one for code that runs
  after it returns.
  """
  def with_actor(actor, via, fun) when is_function(fun, 0) do
    previous = Process.get(@key)
    {kind, id} = normalize(actor)

    Process.put(@key, %{
      actor_kind: kind,
      actor_id: id,
      actor_label: label_for(actor),
      via: via
    })

    try do
      fun.()
    after
      if is_nil(previous) do
        Process.delete(@key)
      else
        Process.put(@key, previous)
      end
    end
  end

  @doc """
  The ambient transition context, or the honest `unknown` default.
  """
  def current, do: Process.get(@key, @default)

  @doc """
  Map the actor shapes that flow through `Platform.Tasks` to an
  `{actor_kind, actor_id}` pair.

  The canonical shape in `Platform.Tasks` is the `t:Platform.Tasks.actor/0`
  triple — `{:user, uuid}` | `{:agent, uuid}` | `:system` — which mirrors
  `Platform.Audit.Event`. A bare `%Platform.Accounts.User{}` and a bare
  binary agent id are accepted too, because callers at the UI edge hold
  those directly. Anything unrecognised is `unknown`; it is never guessed
  into `system`.
  """
  def normalize({:user, id}) when is_binary(id), do: {"user", id}
  def normalize({:agent, id}) when is_binary(id), do: {"agent", id}
  def normalize(:system), do: {"system", nil}

  # Explicit "this path has no knowable caller". Same recorded value as the
  # fall-through below, but it is a DECISION at the call site rather than an
  # accident, and it keeps `via` stamped. See the moduledoc's two-field
  # reading.
  def normalize(:unattributed), do: {"unknown", nil}

  def normalize(%{__struct__: Platform.Accounts.User, id: id}) when is_binary(id),
    do: {"user", id}

  def normalize(id) when is_binary(id), do: {"agent", id}
  def normalize(_other), do: {"unknown", nil}

  defp label_for({:user, _}), do: "user"
  defp label_for({:agent, _}), do: "agent"
  defp label_for(:system), do: "system:auto"
  defp label_for(:unattributed), do: nil
  defp label_for(%{__struct__: Platform.Accounts.User}), do: "user"
  defp label_for(id) when is_binary(id), do: "agent"
  defp label_for(_), do: nil
end
