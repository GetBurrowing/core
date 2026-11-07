defmodule Platform.Secretary do
  @moduledoc """
  The per-person triage agent that replaces the inbox (task 01a1b721).

  This module is the ONE place the product name lives. Every surface that
  shows the name reads `name/0`, so a rename is a one-line change here; a
  test scans `lib/` for the quoted literal anywhere else.

  Stage 1 is the data substrate only: settings
  (`Platform.Secretary.Settings`), the evaluation, feedback, batch and
  reach-out store (`Platform.Secretary.Store`), the person's own list
  (`Platform.Secretary.Todos`), the readable-input gatherer
  (`Platform.Secretary.Inputs`), the person's context
  (`Platform.Secretary.Context`) and the experiment surface
  (`Platform.Experiments.Surfaces.SecretaryPolicy`). No model call, UI or
  push happens here.

  Stage 3 adds the evaluator pass: `Platform.Secretary.Scheduler` turns
  arrivals into debounced per-person batches, `Platform.Secretary.Pass`
  runs one (prompt, budget, host call), `Platform.Secretary.Submit` writes
  a validated answer and `Platform.Secretary.Fallback` covers every case
  without one.
  """

  alias Platform.Secretary.Scheduler

  @name "Secretary"

  @doc "The product name, as the UI shows it."
  @spec name() :: String.t()
  def name, do: @name

  @doc "The PubSub topic a person's secretary view listens on."
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(user_id), do: "secretary:#{user_id}"

  @doc "Broadcasts `{:secretary_updated, user_id}` on `topic/1`."
  @spec broadcast_updated(Ecto.UUID.t()) :: :ok
  def broadcast_updated(user_id) when is_binary(user_id) do
    Phoenix.PubSub.broadcast(Platform.PubSub, topic(user_id), {:secretary_updated, user_id})
  end

  @doc """
  Something new arrived for `user_id`. A cast to the scheduler that never
  fails and never blocks: with the scheduler down it does nothing. Called by
  `Platform.Inbox.emit/1` after its broadcast and by meeting briefing
  delivery.
  """
  @spec note_arrival(term()) :: :ok
  def note_arrival(user_id) do
    if is_binary(user_id), do: GenServer.cast(Scheduler, {:arrival, user_id})
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
