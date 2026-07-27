defmodule Platform.Tasks.PlanRejectionTest do
  @moduledoc """
  ADR-0046 member 6 stage 2 — the hoisted plan-rejection feedback post.

  ## No DETECTOR in this stage, deliberately

  Nothing is broken on unfixed `main` for a test here to detonate against.
  The change is structural: two private functions moved out of a LiveView
  into a context module, with the call site left in place. The behaviour on
  the human path is IDENTICAL before and after, which is the whole
  acceptance criterion — a detector would have to assert a defect that does
  not exist. The mandatory fix detectors for this task are in stages 3 and
  4, where the module is wired into the architecture gate and the bound
  actually stops a loop.

  The real regression net for the hoist is not in this file at all: it is
  the four pre-existing cases in `tasks_live_test.exs` (`describe
  "reject-with-feedback inline UI"` and `describe "reject-with-feedback
  execution-space post"`), which must pass BYTE-IDENTICAL. Expected churn
  from this stage is zero; a failure there means the move changed
  behaviour.

  What this file adds on top of them is coverage of the ONE semantic
  widening — `actor_display_name/1` resolving an AGENT id, which stage 3
  needs and no existing test could have exercised — and exact-string
  pinning of the composed body, which nothing pinned before.

  ## VACUITY CONTROLS, MEASURED (7/7 detected, at commit 9f5d8270)

  Each control changes exactly one thing in `Platform.Tasks.PlanRejection`
  and nothing in either test file. The control set is this file plus the
  two pre-existing `reject-with-feedback` describes in `tasks_live_test.exs`
  — 15 tests, 0 failures unmodified.

    1. CONSTANT NAME: `actor_display_name/1` returns `"the reviewer"` for
       every input. 5 failures — 3 here, 2 in `tasks_live_test.exs`.
       Detected.
    2. AGENT TIER DROPPED: removed the `agent_name/1` arm of the `cond`,
       restoring the pre-hoist behaviour exactly. 2 failures, both the
       agent halves, and NOTHING in `tasks_live_test.exs`. Detected — and
       the shape of the result is the point: the widening is invisible to
       every pre-existing test, so it is guarded here or nowhere.
    3a. `post_log/2` SUBSTITUTED for `post_engagement/3` — the realistic
       "tidy the two posts into one". 4 failures. Detected, but NOT by the
       `log_only` assertion: `post_log/2` drops the caller's metadata, so
       the tests fail at the `metadata["reason"] == "plan_rejected"` filter
       before reaching it. That is why 3b exists.
    3b. `log_only` FLIPPED IN ISOLATION: kept `post_engagement/3` and its
       metadata, then flipped the persisted row to `log_only: true`. 2
       failures, both of them the `assert msg.log_only == false` line — one
       here, one in the pre-existing LiveView test. Detected. This is the
       control that matters most, because stage 4 posts `log_only: true`
       DELIBERATELY; if the flag could move without a test noticing, the
       wake-up asymmetry that bounds the whole loop would be unguarded.
    4. EMPTY SHORT-CIRCUIT REMOVED: deleted the `(_, _, "")` clause so
       empty feedback posts a stub. 1 failure, HERE ONLY. Detected — and
       the absence of a second failure is a real finding: the LiveView
       refuses empty feedback in its own `cond` before ever calling this
       module, so the pre-existing "does NOT post a stub" test cannot see
       this clause at all. The clause exists for stage 3's caller, and this
       file is its only guard.
    5. WHITESPACE DRIFT: body separator `\\n\\n` -> `\\n`. 6 failures.
       Detected — `=~` would have passed every one of them, which is why
       this file asserts `==`.
    6. VERSION HARDCODED: `"Plan v\#{plan.version}"` -> `"Plan v1"`. 1
       failure, the version test. Detected — every other assertion in the
       control set happens to use a v1 plan, so without that one test a
       hardcoded version ships clean.
    7. MISSING-SPACE GUARD REMOVED: deleted the `nil -> :ok` arm so a task
       with no execution space raises. 2 failures. Detected.

  ### Assertions that pass trivially, declared rather than counted

    * `assert :ok == PlanRejection.post_feedback(...)` is a return-value
      assertion on a function typed `:: :ok`. It cannot fail while the
      function returns at all. Its real content is that the call does not
      RAISE — which control 7 confirms is the assertion doing the work, and
      which is what the no-execution-space test is named for.
    * The SECOND assertion in `tasks_live_test.exs`'s new exact-string case
      (comparing the posted content against `compose_message/3`'s own
      output) is trivial ON ITS OWN: both sides drift together under
      control 5. It is there to name the composer as the source of the
      string, not to pin the string. The literal above it is the assertion
      with teeth.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Plan
  alias Platform.Tasks.PlanRejection

  defp u, do: System.unique_integer([:positive])

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Plan Rejection Project #{u()}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Plan rejection task #{u()}",
        status: "planning"
      })

    {:ok, plan} =
      %Plan{}
      |> Plan.changeset(%{task_id: task.id, version: 1, status: "rejected"})
      |> Repo.insert()

    %{project: project, task: task, plan: plan}
  end

  defp a_user(name) do
    n = u()

    %User{}
    |> User.changeset(%{
      email: "plan-rejection-#{n}@example.com",
      name: name,
      oidc_sub: "oidc-plan-rejection-#{n}"
    })
    |> Repo.insert!()
  end

  defp an_agent(name) do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "plan-rejection-architect-#{u()}",
        name: name,
        status: "active",
        kind: "native",
        workspace_id: nil
      })
      |> Repo.insert()

    agent
  end

  defp messages_in(space_id) do
    Repo.all(from(m in Chat.Message, where: m.space_id == ^space_id, order_by: m.inserted_at))
  end

  defp plan_rejected_messages(space_id) do
    space_id
    |> messages_in()
    |> Enum.filter(fn m -> Map.get(m.metadata || %{}, "reason") == "plan_rejected" end)
  end

  describe "compose_message/3" do
    # GUARD (PAIRED, the anti-drift assertion). Three actor kinds, ONE
    # composed shape, asserted by exact equality rather than `=~` — the
    # string is what a planner agent reads, and a whitespace change to it
    # is a silent contract break with no other guard in the codebase.
    #
    # The three clauses are paired against each other on purpose: the
    # user half alone passes against a function that resolves nothing (it
    # is the pre-hoist behaviour), and the placeholder half alone passes
    # against a function that resolves nothing AND against one that
    # resolves everything. Only all three together pin the resolution
    # ORDER that stage 3 depends on.
    test "renders the exact body for a user, an agent, and an unresolvable actor", %{plan: plan} do
      feedback = "Use postgres instead of sqlite for the metrics store."

      user = a_user("Rowan Ellis")

      assert PlanRejection.compose_message(plan, user.id, feedback) ==
               "Plan v1 rejected by Rowan Ellis:\n\nUse postgres instead of sqlite for the metrics store."

      # The ONE semantic widening in this stage: an AGENT id resolves to
      # the agent's name. Stage 3's actor is the architect agent, not a
      # user, so without this tier the architecture rejection would be
      # attributed to "the reviewer" and the human could not tell which
      # party objected.
      agent = an_agent("Fixture Architect")

      assert PlanRejection.compose_message(plan, agent.id, feedback) ==
               "Plan v1 rejected by Fixture Architect:\n\nUse postgres instead of sqlite for the metrics store."

      # A well-formed id matching neither table falls back to the fixed
      # placeholder rather than echoing the raw UUID.
      assert PlanRejection.compose_message(plan, Ecto.UUID.generate(), feedback) ==
               "Plan v1 rejected by the reviewer:\n\nUse postgres instead of sqlite for the metrics store."
    end

    # The pre-hoist code guarded `rejected_by && Accounts.get_user(...)`,
    # so nil was already a supported input on the human path (a LiveView
    # session with no `current_user_id`). Pinned so the hoist cannot drop
    # it, and extended to the non-UUID case: `Repo.get/2` RAISES on a
    # binary that will not cast, and this function runs on a
    # must-not-raise path.
    test "a nil, blank-named, or non-UUID actor renders the placeholder", %{plan: plan} do
      assert PlanRejection.compose_message(plan, nil, "x") ==
               "Plan v1 rejected by the reviewer:\n\nx"

      # A real user row whose name is blank — the pre-hoist match was
      # `is_binary(name) and name != ""`, and dropping the emptiness half
      # would leak an empty name into the sentence.
      #
      # Inserted as a bare struct on purpose, and this is worth saying out
      # loud: `User.changeset/2` VALIDATES `:name` as required, so a blank
      # name cannot be produced through the sanctioned writer at all. The
      # emptiness half of the guard is therefore defensive-only, inherited
      # verbatim from the pre-hoist code. It is pinned rather than dropped
      # because dropping it would be a behaviour change smuggled into a
      # move, but a reader should not mistake this row for one the
      # application can create.
      nameless =
        Repo.insert!(%User{
          email: "plan-rejection-blank-#{u()}@example.com",
          name: "",
          oidc_sub: "oidc-plan-rejection-blank-#{u()}"
        })

      assert PlanRejection.actor_display_name(nameless.id) == "the reviewer"

      assert PlanRejection.actor_display_name("not-a-uuid") == "the reviewer"
    end

    test "the version comes from the plan, not a literal", %{task: task} do
      {:ok, v7} =
        %Plan{}
        |> Plan.changeset(%{task_id: task.id, version: 7, status: "rejected"})
        |> Repo.insert()

      assert PlanRejection.compose_message(v7, nil, "x") ==
               "Plan v7 rejected by the reviewer:\n\nx"
    end
  end

  describe "post_feedback/3" do
    setup %{task: task} do
      {:ok, space} = ExecutionSpace.find_or_create(task.id)
      %{space: space}
    end

    # GUARD, PAIRED: the absence half (empty feedback posts nothing) runs
    # against the same fixture and the same mechanism as the positive
    # half, so neither can pass against a module that posts nothing at
    # all or against one that posts unconditionally.
    test "posts exactly one engagement message, and posts nothing for empty feedback",
         %{plan: plan, space: space} do
      before = length(messages_in(space.id))

      assert :ok == PlanRejection.post_feedback(plan, nil, "")
      assert length(messages_in(space.id)) == before

      user = a_user("Rowan Ellis")
      assert :ok == PlanRejection.post_feedback(plan, user.id, "Split stage 2.")

      assert [msg] = plan_rejected_messages(space.id)
      assert msg.content == "Plan v1 rejected by Rowan Ellis:\n\nSplit stage 2."
      assert msg.metadata["reason"] == "plan_rejected"
      assert msg.metadata["plan_id"] == plan.id

      # NOT decoration. `log_only: false` is what makes AttentionRouter
      # route this message to the task's assigned agent, which is the
      # ONLY thing that causes a v2 to be authored — TaskRouter goes
      # :waiting_human on a rejection and does not re-dispatch. Stage 4
      # posts `log_only: true` DELIBERATELY, to record an escalation
      # WITHOUT waking the planner. These two assertions are what stop
      # the two paths from being conflated later.
      assert msg.log_only == false
      assert msg.metadata["log_only"] == false
    end

    test "an agent actor is named in the posted body", %{plan: plan, space: space} do
      agent = an_agent("Fixture Architect")

      assert :ok == PlanRejection.post_feedback(plan, agent.id, "Move the dispatch call.")

      assert [msg] = plan_rejected_messages(space.id)
      assert msg.content == "Plan v1 rejected by Fixture Architect:\n\nMove the dispatch call."
    end
  end

  # GUARD: the rejection is already persisted by the time this runs, so a
  # missing execution space must be a silent no-op rather than an error.
  # The task in `setup` has no space unless a test creates one.
  test "returns :ok and does not raise when the task has no execution space", %{
    task: task,
    plan: plan
  } do
    assert ExecutionSpace.find_by_task_id(task.id) == nil
    assert :ok == PlanRejection.post_feedback(plan, nil, "Nowhere to put this.")
  end
end
