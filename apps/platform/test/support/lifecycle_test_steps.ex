defmodule Platform.Lifecycle.TestSteps.Sync do
  @moduledoc """
  Test-only `Platform.Lifecycle.Step` that settles inside `start/2`.

  Reads its outcome from the current process dictionary, so a test case
  controls what the step "returns" without a real step implementation, and
  counts calls so a test can assert the step was NOT run (a divert upstream
  halted the edge) or was run exactly once.

  ## Usage

      Process.put({:lifecycle_test_step, :sync_outcome}, {:failed, :boom})
      # ... exercise code that starts the step ...
      assert Process.get({:lifecycle_test_step, :sync_calls}, 0) == 1

  Defaults to `{:completed, :ok}` when nothing is seeded.

  Introduced in task 019fe1b6-f1ee-73d4-8e6f-bd9f191c6a95 stage 2
  (ADR-0046 Amendment 1). Follows the process-dictionary convention of
  `Platform.Tasks.Stacks.DepInference.StubAdapter`: state is per-process, so
  an `async: true` case cannot see another's seeding.
  """

  @behaviour Platform.Lifecycle.Step

  @impl true
  def kind, do: :sync

  @impl true
  def start(_step_config, _context) do
    calls = Process.get({:lifecycle_test_step, :sync_calls}, 0)
    Process.put({:lifecycle_test_step, :sync_calls}, calls + 1)
    Process.get({:lifecycle_test_step, :sync_outcome}, {:completed, :ok})
  end
end

defmodule Platform.Lifecycle.TestSteps.Async do
  @moduledoc """
  Test-only `Platform.Lifecycle.Step` that returns `{:running, ref}` and
  settles ONLY when a test tells it to — or never.

  ## Never settling is the point

  A support step that always settles cannot produce the case the budget
  tests need. `Platform.Lifecycle.Step`'s contract says non-delivery is an
  EXPECTED outcome — an agent runtime dies, a container is killed, a message
  is lost — and that what bounds the wait is the budget, not the step's good
  behaviour. A fixture incapable of not-settling would let a pipeline
  executor that assumes delivery pass every test, which is precisely the
  defect the budget exists to catch.

  So this step never settles by default. `settle/2` is the only thing that
  makes it answer.

  ## Usage

      {:running, ref} = Async.start(%{}, %{reply_to: self()})
      # nothing arrives; the budget is what must end this wait
      refute_receive {:lifecycle_step_settled, ^ref, _}, 20

      Async.settle(ref, {:completed, :done})
      assert_receive {:lifecycle_step_settled, ^ref, {:completed, :done}}

  `settle/2` delivers to the pid recorded from `context[:reply_to]` at
  `start/2` time, so a test does not have to thread it through twice.

  Introduced in task 019fe1b6-f1ee-73d4-8e6f-bd9f191c6a95 stage 2.
  """

  @behaviour Platform.Lifecycle.Step

  @impl true
  def kind, do: :async

  @impl true
  def start(_step_config, context) do
    ref = make_ref()
    reply_to = Map.get(context, :reply_to, self())
    Process.put({:lifecycle_test_step, :async_reply_to, ref}, reply_to)

    calls = Process.get({:lifecycle_test_step, :async_calls}, 0)
    Process.put({:lifecycle_test_step, :async_calls}, calls + 1)

    {:running, ref}
  end

  @doc """
  Deliver settlement for a previously started run.

  Returns `:ok` when a `reply_to` was recorded for `ref`, `:error` when it
  was not — calling this for a ref this process never started is a test bug,
  and answering `:ok` would hide it.
  """
  @spec settle(reference(), Platform.Lifecycle.Step.outcome()) :: :ok | :error
  def settle(ref, outcome) when is_reference(ref) do
    case Process.get({:lifecycle_test_step, :async_reply_to, ref}) do
      nil ->
        :error

      reply_to ->
        send(reply_to, {:lifecycle_step_settled, ref, outcome})
        :ok
    end
  end
end
