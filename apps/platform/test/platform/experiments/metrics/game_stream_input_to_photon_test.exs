defmodule Platform.Experiments.Metrics.GameStreamInputToPhotonTest do
  @moduledoc """
  `GameStreamInputToPhoton` — mean per-session median input-to-photon round
  trip over a variant's ended play sessions (task 01a0db5f stage 2).

  `n` is asserted with every value: it counts SESSIONS, and it is the only
  observable that separates "a session was excluded" from "a session counted
  as zero". A stats-less session must be excluded, never read as 0 ms, which
  would be a perfect result.
  """

  use Platform.DataCase

  alias Platform.Experiments
  alias Platform.Experiments.Metric.Result
  alias Platform.Experiments.Metrics
  alias Platform.Experiments.Metrics.GameStreamInputToPhoton
  alias Platform.GameStream.SessionRecord
  alias Platform.Repo
  alias Platform.Tasks

  @sha "0123456789abcdef0123456789abcdef01234567"

  setup do
    {:ok, project} = Tasks.create_project(%{name: "GS Metric Project #{unique()}"})

    {:ok, experiment} =
      Experiments.create_experiment(%{
        slug: "gs-metric-#{unique()}",
        name: "GS Metric Experiment",
        status: "draft"
      })

    {:ok, _} = Experiments.add_variant(experiment, %{slug: "control", content: "c", weight: 1})
    {:ok, _} = Experiments.add_variant(experiment, %{slug: "treatment", content: "t", weight: 1})

    %{project: project, experiment: experiment}
  end

  defp unique, do: System.unique_integer([:positive])

  defp subject(project, experiment, slug \\ "treatment", opts \\ []) do
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "GS Task #{unique()}"})

    Repo.insert!(%Platform.Experiments.Assignment{
      experiment_id: experiment.id,
      subject_type: "task",
      subject_id: task.id,
      variant_slug: slug,
      assigned_at: DateTime.utc_now(),
      excluded_reason: Keyword.get(opts, :excluded_reason)
    })

    task
  end

  defp session!(task, attrs) do
    now = DateTime.utc_now()

    base = %{
      id: Ecto.UUID.generate(),
      task_id: task.id,
      review_sha: @sha,
      branch: "task/" <> task.id,
      host_runtime_id: "play-host-wave",
      ended_state: "ended",
      started_at: now,
      ended_at: now
    }

    %SessionRecord{} |> SessionRecord.changeset(Map.merge(base, attrs)) |> Repo.insert!()
  end

  defp compute(experiment, slug \\ "treatment"),
    do: GameStreamInputToPhoton.compute(experiment.id, slug)

  test "is registered, lower is better" do
    assert Metrics.metric_module("game_stream_input_to_photon") == GameStreamInputToPhoton

    assert %{direction: :lower_is_better} =
             Enum.find(Metrics.catalog(), &(&1.slug == "game_stream_input_to_photon"))
  end

  test "no subjects is :insufficient_data", ctx do
    assert compute(ctx.experiment) == :insufficient_data
  end

  test "subjects with no sessions is :insufficient_data, not 0", ctx do
    subject(ctx.project, ctx.experiment)
    assert compute(ctx.experiment) == :insufficient_data
  end

  test "the mean of per-session p50s, over sessions that ran this arm", ctx do
    e = ctx.experiment
    a = subject(ctx.project, e)
    b = subject(ctx.project, e)

    session!(a, %{experiment_id: e.id, variant_slug: "treatment", rtt_p50_ms: 40.0})
    session!(b, %{experiment_id: e.id, variant_slug: "treatment", rtt_p50_ms: 30.0})

    # Excluded: never reported stats (not zero).
    session!(a, %{experiment_id: e.id, variant_slug: "treatment", rtt_p50_ms: nil})
    # Excluded: the same task played outside the experiment (default arm).
    session!(a, %{experiment_id: nil, variant_slug: nil, rtt_p50_ms: 900.0})

    assert {:ok, %Result{value: 35.0, n: 2, unit: :ms}} = compute(e)
  end

  test "another arm's sessions and excluded subjects do not count", ctx do
    e = ctx.experiment
    c = subject(ctx.project, e, "control")
    x = subject(ctx.project, e, "treatment", excluded_reason: "manual")
    t = subject(ctx.project, e)

    session!(c, %{experiment_id: e.id, variant_slug: "control", rtt_p50_ms: 10.0})
    session!(x, %{experiment_id: e.id, variant_slug: "treatment", rtt_p50_ms: 500.0})
    session!(t, %{experiment_id: e.id, variant_slug: "treatment", rtt_p50_ms: 50.0})

    assert {:ok, %Result{value: 50.0, n: 1}} = compute(e)
    assert {:ok, %Result{value: 10.0, n: 1}} = compute(e, "control")
  end

  describe "the roster arm (task 01a0dbd6)" do
    test "a session that ran the experiment as its ROSTER arm counts; another arm does not",
         ctx do
      e = ctx.experiment
      a = subject(ctx.project, e)
      b = subject(ctx.project, e)

      session!(a, %{
        roster_experiment_id: e.id,
        roster_variant_slug: "treatment",
        rtt_p50_ms: 50.0
      })

      session!(b, %{roster_experiment_id: e.id, roster_variant_slug: "control", rtt_p50_ms: 10.0})

      assert {:ok, %Result{value: 50.0, n: 1}} = compute(e)
    end

    test "the worst-slot p95 metric means rtt_p95_ms, excluding sessions without one", ctx do
      alias Platform.Experiments.Metrics.GameStreamInputToPhotonP95
      e = ctx.experiment
      a = subject(ctx.project, e)
      b = subject(ctx.project, e)
      c = subject(ctx.project, e)

      session!(a, %{
        roster_experiment_id: e.id,
        roster_variant_slug: "treatment",
        rtt_p95_ms: 60.0
      })

      session!(b, %{experiment_id: e.id, variant_slug: "treatment", rtt_p95_ms: 40.0})
      session!(c, %{experiment_id: e.id, variant_slug: "treatment", rtt_p50_ms: 20.0})

      assert {:ok, %Result{value: 50.0, n: 2}} =
               GameStreamInputToPhotonP95.compute(e.id, "treatment")

      assert GameStreamInputToPhotonP95.compute(e.id, "control") == :insufficient_data
    end
  end
end
