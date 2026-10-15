defmodule Platform.Experiments.SurfacePromotionTest do
  @moduledoc """
  `Promotion.promote/2` on a NON-prompt surface appends seq-keyed
  `experiment_surface_defaults` rows (task 01a0d415 stage 2). The prompt
  path's behaviour is pinned, unmodified, by `promotion_test.exs`.

  `async: false`: registers test surfaces through app env, and writes
  install-wide (null org) history rows under a NULLS NOT DISTINCT index.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Audit
  alias Platform.Experiments
  alias Platform.Experiments.Promotion
  alias Platform.Experiments.Promotion.Refusal
  alias Platform.Experiments.SurfaceDefault
  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.TestSurfaces

  setup do
    TestSurfaces.register()
    :ok
  end

  defp target, do: "planner-#{System.unique_integer([:positive])}"

  # A running experiment with a `tight` arm carrying `max_stages`.
  defp running_with_arm(target, max_stages, org_id \\ nil) do
    {:ok, experiment} =
      Experiments.create_experiment(%{
        slug: "sp-#{System.unique_integer([:positive])}",
        name: "Stage budget",
        surface_key: "test.budget",
        surface_target: target,
        org_id: org_id
      })

    {:ok, _} =
      Experiments.add_variant(experiment, %{
        slug: "tight",
        payload: %{"max_stages" => max_stages},
        weight: 1
      })

    {:ok, running} =
      Experiments.start(experiment, root_admin!())

    running
  end

  defp history(target, org_id \\ nil) do
    Repo.all(
      from(d in SurfaceDefault,
        where: d.surface_key == "test.budget" and d.surface_target == ^target,
        order_by: [asc: d.seq]
      )
    )
    |> Enum.filter(&(&1.org_id == org_id))
  end

  # The cooldown is 14 days; the second promotion in these tests is about
  # the seq history, not the cooldown, so the first row is aged past it.
  defp age_history!(target) do
    Repo.update_all(
      from(d in SurfaceDefault, where: d.surface_target == ^target),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -20 * 86_400, :second)]
    )
  end

  test "two promotions give seq 1 and 2; current_default is the second; a revert is seq 3 with the first payload" do
    t = target()

    first = running_with_arm(t, 3)

    assert {:ok, %{default: %SurfaceDefault{seq: 1, kind: "promote"}}} =
             Promotion.promote(first, variant: "tight")

    age_history!(t)
    {:ok, _} = Experiments.conclude(first)

    second = running_with_arm(t, 5)

    assert {:ok, %{default: %SurfaceDefault{seq: 2, kind: "promote"}}} =
             Promotion.promote(second, variant: "tight")

    assert Surfaces.current_default("test.budget", t, nil) == %{"max_stages" => 5}

    assert {:ok, %{default: %SurfaceDefault{seq: 3, kind: "revert", reverts_seq: 2} = revert}} =
             Promotion.revert_surface_default("test.budget", t, nil)

    assert revert.payload == %{"max_stages" => 3}
    assert Surfaces.current_default("test.budget", t, nil) == %{"max_stages" => 3}

    # Append-only: every row is still there, unchanged.
    assert [
             %{seq: 1, kind: "promote", payload: %{"max_stages" => 3}},
             %{seq: 2, kind: "promote", payload: %{"max_stages" => 5}},
             %{seq: 3, kind: "revert", payload: %{"max_stages" => 3}}
           ] = history(t)
  end

  test "reverting the only promotion appends a null payload: use the control" do
    t = target()
    experiment = running_with_arm(t, 4)
    {:ok, _} = Promotion.promote(experiment, variant: "tight")

    assert {:ok, %{default: %SurfaceDefault{seq: 2, kind: "revert", payload: nil}}} =
             Promotion.revert_surface_default("test.budget", t, nil)

    assert Surfaces.current_default("test.budget", t, nil) == nil
  end

  test "nothing to revert on an empty history" do
    assert {:error, :nothing_to_revert} =
             Promotion.revert_surface_default("test.budget", target(), nil)
  end

  test "an org's history is separate from the install-wide history" do
    t = target()
    org = tenant_org_id("soylent")

    in_org = running_with_arm(t, 2, org)

    assert {:ok, %{default: %SurfaceDefault{seq: 1, org_id: ^org}}} =
             Promotion.promote(in_org, variant: "tight")

    # An install-wide experiment on the same target overlaps the org's.
    {:ok, _} = Experiments.conclude(in_org)
    install_wide = running_with_arm(t, 7)

    assert {:ok, %{default: %SurfaceDefault{seq: 1, org_id: nil}}} =
             Promotion.promote(install_wide, variant: "tight")

    assert Surfaces.current_default("test.budget", t, org) == %{"max_stages" => 2}
    assert Surfaces.current_default("test.budget", t, nil) == %{"max_stages" => 7}
  end

  test "the audit event names the surface, seq, experiment and arm" do
    t = target()
    experiment = running_with_arm(t, 3)
    {:ok, %{event: event}} = Promotion.promote(experiment, variant: "tight", n: 12, effect: 0.4)

    assert event.event_type == Promotion.surface_promoted_event_type()
    assert event.event_type == "platform.experiments.experiment_surface_promoted"
    assert event.metadata["surface_key"] == "test.budget"
    assert event.metadata["surface_target"] == t
    assert event.metadata["seq"] == 1
    assert event.metadata["experiment_id"] == experiment.id
    assert event.metadata["winning_variant"] == "tight"
    assert event.metadata["n"] == 12

    assert [_] = Audit.list(event_type: "platform.experiments.experiment_surface_promoted")
  end

  test "the stop rule and the cooldown guard the surface path too" do
    t = target()
    experiment = running_with_arm(t, 3)

    {:ok, gated} =
      experiment
      |> Ecto.Changeset.change(stop_rule: %{"min_subjects" => 5})
      |> Repo.update()

    assert {:error,
            %Refusal{reason: :insufficient_data, observed_subjects: 0, required_subjects: 5}} =
             Promotion.promote(gated, variant: "tight")

    {:ok, _} = Promotion.promote(experiment, variant: "tight")

    assert {:error, %Refusal{reason: :cooldown_active, cooldown_days: 14}} =
             Promotion.promote(experiment, variant: "tight")

    assert [%{seq: 1}] = history(t)
  end

  # What this does NOT cover: the `{:error, :concurrent_promotion}` mapping
  # itself. Reaching it needs two transactions interleaved between the
  # MAX(seq) read and the insert, which one sandboxed connection cannot
  # produce. What IS pinned here is the half the mapping depends on: the
  # index refuses a duplicate seq for the install-wide key, so two racing
  # writers cannot both insert.
  test "a duplicate seq for the install-wide key is refused by the index; the entry point appends past it" do
    t = target()
    experiment = running_with_arm(t, 3)

    row = fn payload ->
      %SurfaceDefault{}
      |> SurfaceDefault.changeset(%{
        surface_key: "test.budget",
        surface_target: t,
        seq: 1,
        kind: "promote",
        payload: payload
      })
      |> Repo.insert()
    end

    assert {:ok, _} = row.(%{"max_stages" => 9})
    assert {:error, %Ecto.Changeset{} = changeset} = row.(%{"max_stages" => 3})
    assert {_, meta} = changeset.errors[:seq]
    assert meta[:constraint] == :unique

    age_history!(t)

    assert {:ok, %{default: %SurfaceDefault{seq: 2}}} =
             Promotion.promote(experiment, variant: "tight")

    assert [%{seq: 1, payload: %{"max_stages" => 9}}, %{seq: 2, payload: %{"max_stages" => 3}}] =
             history(t)
  end
end
