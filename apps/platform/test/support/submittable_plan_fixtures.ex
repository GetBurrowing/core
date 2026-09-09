defmodule Platform.SubmittablePlanFixtures do
  @moduledoc """
  Plan fixtures that can actually be submitted for review.

  Task 01a0588e stage 2 gave `Platform.Tasks.submit_plan_for_review/1` an
  authored-stage precondition: a draft with no planner-authored stage is
  refused with `{:error, :no_authored_stages}` and never reaches the
  architecture gate, because that gate cannot express a well-formed reject
  for a plan with no stage to hang a finding on.

  A large number of suites created a bare `Tasks.create_plan/1` and
  submitted it as a shortcut — a fixture shape that has never been
  reachable in production, where `plan_create` requires stages. Those
  fixtures were CORRECTED to carry a real stage, not exempted: there is no
  bypass option on the guard and none should be added, since a fixture-only
  bypass is the same permissive hole the guard exists to close.

  Use `create_submittable_plan/2` wherever a test needs a draft it will
  submit. Tests that are ABOUT the stageless case (the `:empty_plan`
  auto-approve skip, `retry_auto_approval/1`'s no-stages refusal) keep
  building bare plans deliberately and must not use this.
  """

  alias Platform.Tasks

  @doc """
  A draft plan carrying one planner-authored stage.

  `attrs` is passed through to `Tasks.create_plan/1` verbatim, so callers
  keep control of `:task_id`, `:version`, and anything else. The stage is
  `origin: "authored"` by default (see `Platform.Tasks.Stage`), which is
  what the guard counts.
  """
  def create_submittable_plan(attrs, stage_attrs \\ %{}) do
    {:ok, plan} = Tasks.create_plan(attrs)
    {:ok, _stage} = create_authored_stage(plan, stage_attrs)
    {:ok, plan}
  end

  @doc """
  Give an existing draft plan one planner-authored stage.

  For suites that already hold a plan struct and only need it to satisfy
  the precondition.
  """
  def create_authored_stage(plan, stage_attrs \\ %{}) do
    Tasks.create_stage(
      Map.merge(
        %{
          plan_id: plan.id,
          position: 1,
          name: "Implement the change",
          description: "The planner-authored work stage this fixture needs to be submittable."
        },
        stage_attrs
      )
    )
  end
end
