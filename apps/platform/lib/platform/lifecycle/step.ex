defmodule Platform.Lifecycle.Step do
  @moduledoc """
  The behaviour every lifecycle hook step implements (ADR-0046 Amendment 1,
  task 019fe1b6-f1ee-73d4-8e6f-bd9f191c6a95 stage 2).

  Contract only. Nothing here runs a step, orders a pipeline, halts one on a
  divert or enforces a budget — that is a later member of this stack.

  ## The interface is async-shaped, and the sync case is subsumed by it

  `start/2` never blocks on wall clock the caller does not control. A
  deterministic step (write a row, publish an event) returns a terminal tuple
  immediately; an agent step returns `{:running, ref}` and settles later.

  This is deliberate and is not a "for now" shape. A single synchronous
  `run/2` would force the pipeline executor to hold a caller's process for an
  agent's wall clock, and there was a worked example of where that leads in
  this repo: `Platform.Orchestration.TaskRouter`'s
  `@design_step_timeout_ms 1_800_000` — a thirty-minute hold, with its own
  timer, arm/cancel pair and expiry path, because the only place the wait
  could live was inside the caller. Hiding the async case behind a sync
  signature reintroduces exactly that.

  That example is now historical: task 019fe1b7 stage 2 moved the design step
  onto this behaviour (`Platform.Design.PreplanLifecycleStep`) and deleted the
  router's copy of the machinery.

  There is consequently NO second behaviour and no separate sync path. A
  `:sync` step is one whose `start/2` happens to always return terminally.

  ## Settlement, and why a step that never settles is EXPECTED

  A step that answered `{:running, ref}` settles by sending

      {:lifecycle_step_settled, ref, outcome}

  to `context[:reply_to]`, where `outcome` is one of the terminal tuples.
  The `ref` is the one `start/2` returned, so a caller awaiting several steps
  can tell them apart.

  **Non-delivery is a normal outcome, not a defect to be assumed away.** An
  agent runtime can die between ack and reply, a container can be killed, a
  network partition can eat the message. A step author cannot promise
  delivery and the executor must not be written as though they had.

  What bounds the wait is therefore the BUDGET, never the step's good
  behaviour — see `Platform.Lifecycle.step_timeout_ms/0` and
  `Platform.Lifecycle.edge_budget_ms/0`. A contract that assumes delivery is
  itself the bug: it produces a pipeline that hangs forever on the one
  failure mode agent steps actually have.

  ## Outcomes

    * `{:completed, term()}` — ran and returned normally.
    * `{:diverted, term()}` — ran and is sending the task back. Only a step
      declared `can_divert` may answer this; the first divert halts the
      remainder of the edge (Amendment 1 decision 4).
    * `{:failed, term()}` — RAN and errored. Distinct from a budget kill,
      which the executor records as `timed_out` and which a step can never
      report about itself, because a step that was killed does not get to
      answer. See `Platform.Lifecycle.StepRun` for why those two must not be
      collapsed.
    * `{:running, reference()}` — settlement will arrive, or will not.

  ## `kind/0` is a declaration, not a dispatch switch

  `kind/0` answers `:sync` or `:async`. It exists so configuration and
  tooling can describe a step without invoking it (a `:sync` step is safe to
  place on an edge that forbids awaiting). The executor does not branch on
  it: it branches on what `start/2` actually returned, because the return
  value is the fact and `kind/0` is a claim about it.
  """

  @typedoc "What a step resolves to, whether immediately or on settlement."
  @type outcome :: {:completed, term()} | {:diverted, term()} | {:failed, term()}

  @typedoc "What `start/2` returns: a terminal outcome, or a pending handle."
  @type start_result :: outcome() | {:running, reference()}

  @doc """
  Begin the step. Returns terminally, or `{:running, ref}` to settle later.

  `step_config` is the step's own declaration map as validated by
  `Platform.Lifecycle.PipelineConfig` (string keys — it round-trips through
  jsonb). `context` carries the firing: at minimum `:task`, `:edge` and
  `:reply_to`, the pid a `{:lifecycle_step_settled, ref, outcome}` message
  must be sent to.

  Must not block on anything it does not control.
  """
  @callback start(step_config :: map(), context :: map()) :: start_result()

  @doc "Whether this step settles inside `start/2` (`:sync`) or later (`:async`)."
  @callback kind() :: :sync | :async
end
