defmodule Platform.Experiments.SchemaConstraintsTest do
  @moduledoc """
  The install-wide singleton indexes (task 01a0d415, the
  experimentation-layer ADR-0052).

  A NULL `org_id` means "the install-wide row". Under Postgres's default
  NULLS DISTINCT a unique index never compares two NULLs, so without
  `nulls_distinct: false` a second install-wide row inserts cleanly and every
  reader of "the" install-wide row gets whichever the planner returned.

  MUTATION RECORD (stage 1): dropping `nulls_distinct: false` from the
  `experiment_guardrails` index in the migration made
  "a second install-wide guardrail row is refused" FAIL — the second insert
  returned `{:ok, _}`. The goals test below is the POSITIVE CONTROL that the
  fix is not over-applied: two install-wide goals must both insert.

  `async: false`: two concurrent sandbox transactions inserting the same
  install-wide key would block on each other's uncommitted index entry.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Experiments
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Goal
  alias Platform.Experiments.Guardrail
  alias Platform.Experiments.SurfaceDefault
  alias Platform.Experiments.Surfaces

  defp insert_guardrail(attrs) do
    %Guardrail{}
    |> Guardrail.changeset(Map.merge(%{max_live: 3}, attrs))
    |> Repo.insert()
  end

  defp install_wide_guardrails do
    Repo.aggregate(from(g in Guardrail, where: is_nil(g.org_id)), :count)
  end

  defp insert_default(target, seq, payload, org_id \\ nil) do
    %SurfaceDefault{}
    |> SurfaceDefault.changeset(%{
      surface_key: "dispatch.prompt",
      surface_target: target,
      org_id: org_id,
      seq: seq,
      kind: "promote",
      payload: payload
    })
    |> Repo.insert()
  end

  defp target, do: "tgt-#{System.unique_integer([:positive])}"

  describe "experiment_guardrails — one row per org, exactly one install-wide row" do
    test "a second install-wide guardrail row is refused, and exactly one remains" do
      assert {:ok, %Guardrail{org_id: nil}} = insert_guardrail(%{org_id: nil})
      assert {:error, %Ecto.Changeset{} = changeset} = insert_guardrail(%{org_id: nil})

      assert {"has already been taken", meta} = changeset.errors[:org_id]
      assert meta[:constraint] == :unique
      assert meta[:constraint_name] == "experiment_guardrails_org_id_index"

      assert install_wide_guardrails() == 1
    end

    test "a raw second install-wide insert raises Ecto.ConstraintError" do
      Repo.insert!(%Guardrail{org_id: nil, max_live: 3})

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%Guardrail{org_id: nil, max_live: 5})
      end
    end

    test "a second row for the same org fails; rows for two different orgs both succeed" do
      org_a = tenant_org_id("initech")
      org_b = tenant_org_id("globex")

      assert {:ok, _} = insert_guardrail(%{org_id: org_a})
      assert {:ok, _} = insert_guardrail(%{org_id: org_b})
      assert {:error, %Ecto.Changeset{}} = insert_guardrail(%{org_id: org_a})

      assert Repo.aggregate(from(g in Guardrail, where: g.org_id == ^org_a), :count) == 1
      assert Repo.aggregate(from(g in Guardrail, where: g.org_id == ^org_b), :count) == 1
    end

    test "launch approval is opt-in: require_human_approval defaults to false" do
      {:ok, row} = insert_guardrail(%{org_id: nil})
      reloaded = Repo.get!(Guardrail, row.id)

      assert reloaded.require_human_approval == false
      assert reloaded.allow_auto_promote == false
      assert reloaded.max_live == 3
      assert reloaded.allowed_surfaces == []
    end
  end

  describe "experiment_surface_defaults — seq-keyed append-only history" do
    test "the same (key, target, NULL org, seq) twice fails on the second" do
      t = target()

      assert {:ok, _} = insert_default(t, 1, %{"content" => "one"})
      assert {:error, %Ecto.Changeset{} = changeset} = insert_default(t, 1, %{"content" => "two"})

      assert {"has already been taken", meta} = changeset.errors[:seq]
      assert meta[:constraint_name] == "experiment_surface_defaults_key_seq_index"
    end

    test "seq 1 and seq 2 for one null-org key both insert; current_default/3 returns seq 2's payload" do
      t = target()

      assert {:ok, _} = insert_default(t, 2, %{"content" => "second"})
      assert {:ok, _} = insert_default(t, 1, %{"content" => "first"})

      assert Surfaces.current_default("dispatch.prompt", t, nil) == %{"content" => "second"}
    end

    test "an org's history is separate from the install-wide history" do
      t = target()
      org = tenant_org_id("initech")

      assert {:ok, _} = insert_default(t, 1, %{"content" => "install-wide"})
      assert {:ok, _} = insert_default(t, 1, %{"content" => "org"}, org)

      assert Surfaces.current_default("dispatch.prompt", t, nil) == %{"content" => "install-wide"}
      assert Surfaces.current_default("dispatch.prompt", t, org) == %{"content" => "org"}
      assert Surfaces.current_default("dispatch.prompt", target(), nil) == nil
    end
  end

  describe "experiment_goals — NOT a singleton (positive control)" do
    test "two install-wide goals both insert" do
      for statement <- ["Raise reply rate", "Shorten planning"] do
        assert {:ok, %Goal{org_id: nil}} =
                 %Goal{}
                 |> Goal.changeset(%{statement: statement})
                 |> Repo.insert()
      end

      assert Repo.aggregate(from(g in Goal, where: is_nil(g.org_id)), :count) == 2
    end
  end

  describe "stop-with-feedback columns" do
    test "stop_feedback, stopped_by_user_id and stopped_at exist and are nullable" do
      %{rows: rows} =
        Repo.query!(
          """
          SELECT column_name, is_nullable, data_type
            FROM information_schema.columns
           WHERE table_name = 'experiments'
             AND column_name IN ('stop_feedback', 'stopped_by_user_id', 'stopped_at')
           ORDER BY column_name
          """,
          []
        )

      assert rows == [
               ["stop_feedback", "YES", "text"],
               ["stopped_at", "YES", "timestamp without time zone"],
               ["stopped_by_user_id", "YES", "uuid"]
             ]
    end

    test "a stop may carry feedback, and stamps stopped_at" do
      {:ok, experiment} =
        Experiments.create_experiment(%{
          slug: "stop-#{System.unique_integer([:positive])}",
          name: "S"
        })

      user_id = Ecto.UUID.generate()

      assert {:ok, stopped} =
               Experiments.stop(experiment, %{
                 stop_feedback: "Replies got curt.",
                 stopped_by_user_id: user_id
               })

      assert stopped.status == "stopped"
      assert stopped.stop_feedback == "Replies got curt."
      assert stopped.stopped_by_user_id == user_id
      assert %DateTime{} = stopped.stopped_at
    end

    test "stop_feedback without a stop transition is a changeset error" do
      {:ok, experiment} =
        Experiments.create_experiment(%{
          slug: "nostop-#{System.unique_integer([:positive])}",
          name: "N"
        })

      changeset = Experiment.changeset(experiment, %{stop_feedback: "not stopping"})

      refute changeset.valid?

      assert {"can only be set by the transition that stops the experiment", _} =
               changeset.errors[:stop_feedback]
    end
  end
end
