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

  def normalize(%{__struct__: Platform.Accounts.User, id: id}) when is_binary(id),
    do: {"user", id}

  def normalize(id) when is_binary(id), do: {"agent", id}
  def normalize(_other), do: {"unknown", nil}

  defp label_for({:user, _}), do: "user"
  defp label_for({:agent, _}), do: "agent"
  defp label_for(:system), do: "system:auto"
  defp label_for(%{__struct__: Platform.Accounts.User}), do: "user"
  defp label_for(id) when is_binary(id), do: "agent"
  defp label_for(_), do: nil
end
