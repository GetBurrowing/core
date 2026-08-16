defmodule Platform.Experiments.Metrics.ManualGateRejectionRateTest do
  @moduledoc """
  `ManualGateRejectionRate` — share of RESOLVED review requests a human sent
  back. Task 01a00b91.

  ## Every fixture drives the real review path

  Requests are filed with `ReviewRequests.create_review_request/1` and
  dispositioned with `approve_item/2` / `reject_item/3`, so resolution
  happens through `maybe_resolve_request/1` exactly as it does in
  production. Hand-inserting a `resolved` row would construct precisely the
  shape the metric's query expects, and the file would stay green even if
  nothing ever wrote that status.

  ## `n` is the observable that catches the `superseded` bug

  A superseded request wrongly counted as an approval leaves the ratio
  looking entirely plausible — it just drifts downward. The only thing that
  distinguishes "excluded" from "included as an approval" is `n`, so the
  superseded test asserts the count, not only the value.
  """

  use Platform.DataCase

  alias Platform.Experiments
  alias Platform.Experiments.Metric.Result
  alias Platform.Experiments.Metrics
  alias Platform.Experiments.Metrics.ManualGateRejectionRate
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.ReviewRequests

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Rejection Project #{unique()}"})

    {:ok, experiment} =
      Experiments.create_experiment(%{
        slug: "rejection-#{unique()}",
        name: "Rejection Experiment",
        status: "draft"
      })

    {:ok, _control} =
      Experiments.add_variant(experiment, %{slug: "control", content: "c", weight: 1})

    {:ok, _treatment} =
      Experiments.add_variant(experiment, %{slug: "treatment", content: "t", weight: 1})

    user =
      Repo.insert!(%Platform.Accounts.User{
        name: "Rejection User #{unique()}",
        email: "rejection-#{unique()}@example.com",
        oidc_sub: "rejection-sub-#{unique()}"
      })

    %{project: project, experiment: experiment, user: user}
  end

  defp unique, do: System.unique_integer([:positive])

  # Pins the subject into a named variant, so a test asserting a rate is not
  # also asserting the bucketing.
  defp subject(project, experiment) do
    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "Rejection Task #{unique()}"})

    Repo.insert!(%Platform.Experiments.Assignment{
      experiment_id: experiment.id,
      subject_type: "task",
      subject_id: task.id,
      variant_slug: "treatment",
      assigned_at: DateTime.utc_now()
    })

    task
  end

  # One plan per task carrying `count` stages, each with its own
  # `manual_approval` gate. A task may hold only one plan pending review, so
  # the gates have to come from a single plan rather than one plan apiece.
  defp manual_gates(task, count) do
    {:ok, plan} =
      Tasks.create_plan(%{task_id: task.id, title: "Plan #{unique()}", summary: "Rejection plan"})

    for position <- 1..count//1 do
      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: position,
          name: "Stage #{position}",
          description: "Stage #{position} of the rejection fixture"
        })

      {:ok, validation} =
        Tasks.create_validation(%{
          stage_id: stage.id,
          kind: "manual_approval",
          status: "pending"
        })

      validation
    end
  end

  defp file_request(task, validation) do
    {:ok, request} =
      ReviewRequests.create_review_request(%{
        validation_id: validation.id,
        task_id: task.id,
        items: [%{label: "Screenshot #{unique()}", content: "evidence"}]
      })

    request
  end

  defp approved_request(task, gate) do
    request = file_request(task, gate)
    for item <- items(request), do: {:ok, _} = ReviewRequests.approve_item(item.id, "reviewer")
    request
  end

  defp rejected_request(task, gate) do
    request = file_request(task, gate)

    for item <- items(request),
        do: {:ok, _} = ReviewRequests.reject_item(item.id, "reviewer", "needs work")

    request
  end

  defp pending_request(task, gate), do: file_request(task, gate)

  # A second request against the SAME validation supersedes the first, which
  # is the only production path that produces the status.
  defp superseded_request(task, validation) do
    first = file_request(task, validation)
    _second = file_request(task, validation)

    assert Repo.reload!(first).status == "superseded"
    first
  end

  defp items(request) do
    {:ok, request} = ReviewRequests.fetch_request_with_items(request.id)
    request.items
  end

  defp compute(experiment), do: ManualGateRejectionRate.compute(experiment.id, "treatment")

  describe "compute/2" do
    test "an all-approved subject set is 0.0 with n > 0", ctx do
      task = subject(ctx.project, ctx.experiment)
      [a, b] = manual_gates(task, 2)
      approved_request(task, a)
      approved_request(task, b)

      assert {:ok, %Result{value: +0.0, n: 2, unit: :ratio}} = compute(ctx.experiment)
    end

    test "a mixed set yields the exact ratio", ctx do
      task = subject(ctx.project, ctx.experiment)
      [a, b, c, d] = manual_gates(task, 4)
      rejected_request(task, a)
      approved_request(task, b)
      approved_request(task, c)
      approved_request(task, d)

      assert {:ok, %Result{value: value, n: 4, unit: :ratio}} = compute(ctx.experiment)
      assert value == 0.25
    end

    test "an all-pending subject set is :insufficient_data, not 0.0", ctx do
      task = subject(ctx.project, ctx.experiment)
      [a, b] = manual_gates(task, 2)
      pending_request(task, a)
      pending_request(task, b)

      # The atom exactly: a `%Result{value: 0.0}` would report a perfect
      # wave-through rate for requests nobody has answered.
      assert compute(ctx.experiment) == :insufficient_data
    end

    test "a superseded request leaves BOTH sides — n does not count it", ctx do
      task = subject(ctx.project, ctx.experiment)
      [a, b] = manual_gates(task, 2)
      superseded_request(task, a)
      approved_request(task, b)

      # `n` is the discriminator. Counted as an approval the value would
      # still be 0.0 here and the bug would be invisible.
      assert {:ok, %Result{value: +0.0, n: 1, unit: :ratio}} = compute(ctx.experiment)
    end

    test "superseded is excluded from the numerator too", ctx do
      task = subject(ctx.project, ctx.experiment)
      [a, b] = manual_gates(task, 2)
      superseded_request(task, a)
      rejected_request(task, b)

      assert {:ok, %Result{value: 1.0, n: 1, unit: :ratio}} = compute(ctx.experiment)
    end

    test "no subjects is :insufficient_data", ctx do
      assert compute(ctx.experiment) == :insufficient_data
    end

    test "another arm's requests do not contribute", ctx do
      task = subject(ctx.project, ctx.experiment)
      [gate] = manual_gates(task, 1)
      rejected_request(task, gate)

      assert {:ok, %Result{value: 1.0, n: 1}} = compute(ctx.experiment)
      assert ManualGateRejectionRate.compute(ctx.experiment.id, "control") == :insufficient_data
    end
  end

  describe "registry" do
    test "the slug resolves to this module and is registered neutral" do
      assert Metrics.metric_module("manual_gate_rejection_rate") == ManualGateRejectionRate
      assert "manual_gate_rejection_rate" in Metrics.known_metrics()

      entry =
        Enum.find(Metrics.catalog(), &(&1.slug == "manual_gate_rejection_rate"))

      assert entry.direction == :neutral
    end
  end
end
