defmodule Platform.Experiments.Metrics.UxFindingKeepRateTest do
  @moduledoc """
  `UxFindingKeepRate`: share of resolved UX findings a human kept rather than
  dismissed, per variant. Task 01a1af00 stage 1. Findings are resolved
  through `Platform.Ux.Finding.resolve_changeset/3`, the path a human's
  answer takes, not hand-written statuses.
  """

  use Platform.DataCase, async: true

  alias Platform.Experiments
  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Metric.Result
  alias Platform.Experiments.Metrics.UxFindingKeepRate
  alias Platform.Repo
  alias Platform.Ux.Finding

  defp u, do: System.unique_integer([:positive])

  setup do
    {:ok, experiment} =
      Experiments.create_experiment(%{slug: "ux-keep-#{u()}", name: "Ux Keep", status: "draft"})

    {:ok, _} = Experiments.add_variant(experiment, %{slug: "control", content: "c", weight: 1})
    {:ok, _} = Experiments.add_variant(experiment, %{slug: "strict", content: "s", weight: 1})

    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "ux-keep-#{u()}@example.com",
        name: "Ux Keep User",
        oidc_sub: "ux-keep-#{u()}"
      })

    %{experiment: experiment, user: user}
  end

  defp assign!(experiment, workspace_id, variant, excluded \\ nil) do
    Repo.insert!(%Assignment{
      experiment_id: experiment.id,
      subject_type: "workspace",
      subject_id: workspace_id,
      variant_slug: variant,
      assigned_at: DateTime.utc_now(),
      excluded_reason: excluded
    })
  end

  defp finding!(user, workspace_id, variant, resolution) do
    {:ok, finding} =
      %Finding{}
      |> Finding.changeset(%{
        recipient_user_id: user.id,
        workspace_id: workspace_id,
        question: "Keep this?",
        kind: "fyi",
        evidence: %{count: 3},
        group_key: "g-#{u()}",
        variant: variant
      })
      |> Repo.insert()

    case resolution do
      :open -> finding
      :kept -> finding |> Finding.resolve_changeset("answered", "yes") |> Repo.update!()
      :dismissed -> finding |> Finding.resolve_changeset("dismissed") |> Repo.update!()
    end
  end

  test "no resolved finding is insufficient data, not a zero", %{experiment: e, user: user} do
    ws = Ecto.UUID.generate()
    assign!(e, ws, "strict")
    finding!(user, ws, "strict", :open)

    assert UxFindingKeepRate.compute(e.id, "strict") == :insufficient_data
  end

  test "kept over kept plus dismissed, open findings excluded", %{experiment: e, user: user} do
    ws = Ecto.UUID.generate()
    assign!(e, ws, "strict")
    finding!(user, ws, "strict", :kept)
    finding!(user, ws, "strict", :kept)
    finding!(user, ws, "strict", :dismissed)
    finding!(user, ws, "strict", :open)

    assert {:ok, %Result{value: value, n: 3, unit: :ratio}} =
             UxFindingKeepRate.compute(e.id, "strict")

    assert_in_delta value, 2 / 3, 1.0e-9
  end

  test "only the arm's own variant and assigned, non-excluded workspaces count",
       %{experiment: e, user: user} do
    ws = Ecto.UUID.generate()
    excluded_ws = Ecto.UUID.generate()
    unassigned_ws = Ecto.UUID.generate()
    assign!(e, ws, "strict")
    assign!(e, excluded_ws, "strict", "test_exclusion")

    finding!(user, ws, "strict", :dismissed)
    # Another arm's finding in the same workspace, an excluded workspace and
    # an unassigned one: each would move n if it leaked in.
    finding!(user, ws, "control", :kept)
    finding!(user, excluded_ws, "strict", :kept)
    finding!(user, unassigned_ws, "strict", :kept)

    assert {:ok, %Result{value: +0.0, n: 1}} = UxFindingKeepRate.compute(e.id, "strict")
  end

  test "an org-wide finding (nil workspace) matches the nil-UUID subject",
       %{experiment: e, user: user} do
    assign!(e, "00000000-0000-0000-0000-000000000000", "control")
    finding!(user, nil, "control", :kept)

    assert {:ok, %Result{value: 1.0, n: 1}} = UxFindingKeepRate.compute(e.id, "control")
  end
end
