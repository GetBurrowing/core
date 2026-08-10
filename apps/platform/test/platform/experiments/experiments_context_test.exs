defmodule Platform.ExperimentsContextTest do
  @moduledoc """
  Context-level tests for `Platform.Experiments` and
  `Platform.Experiments.Assignments` (task 019fe6b9, ADR-0048).

  The properties under test are the ones that fail SILENTLY when broken: a
  control that drifts with the live template, an assignment recomputed on a
  second call, a `stopped` experiment quietly filtered out of a listing.
  None of those raise, so each test below tries to establish that the wrong
  outcome was actually reachable in its fixture.
  """

  use Platform.DataCase, async: true

  alias Platform.Experiments
  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Assignments
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Variant
  alias Platform.Orchestration.PromptTemplate

  defp insert_template(content \\ "ORIGINAL template body") do
    %PromptTemplate{}
    |> PromptTemplate.changeset(%{
      slug: "tpl-#{System.unique_integer([:positive])}",
      name: "Planner",
      content: content
    })
    |> Repo.insert!()
  end

  defp create_experiment(attrs \\ %{}) do
    {:ok, experiment} =
      Experiments.create_experiment(
        Map.merge(
          %{
            slug: "exp-#{System.unique_integer([:positive])}",
            name: "Shorter planning preamble"
          },
          attrs
        )
      )

    experiment
  end

  describe "create_experiment/1" do
    test "inserts in draft even when the caller asks for running" do
      # The status must not be caller-controlled. An experiment born
      # `running` would never pass through activation, and activation is the
      # only thing that snapshots the control.
      experiment = create_experiment(%{status: "running"})

      assert experiment.status == "draft"
      assert Repo.get!(Experiment, experiment.id).status == "draft"
    end

    test "returns a changeset error on invalid attrs" do
      assert {:error, %Ecto.Changeset{} = changeset} = Experiments.create_experiment(%{})
      refute changeset.valid?
    end
  end

  describe "activate/2 — the control snapshot" do
    test "copies the live template content into a control variant" do
      template = insert_template("ORIGINAL template body")
      experiment = create_experiment()
      {:ok, _} = Experiments.add_variant(experiment, %{slug: "treatment", content: "variant B"})

      assert {:ok, activated} = Experiments.activate(experiment, template)
      assert activated.status == "running"

      control = Repo.get_by!(Variant, experiment_id: experiment.id, slug: "control")
      assert control.content == "ORIGINAL template body"
    end

    test "the snapshot does NOT move when the template is edited afterwards" do
      template = insert_template("ORIGINAL template body")
      experiment = create_experiment()
      {:ok, _} = Experiments.add_variant(experiment, %{slug: "treatment", content: "variant B"})

      {:ok, _activated} = Experiments.activate(experiment, template)

      {:ok, edited} =
        template
        |> PromptTemplate.changeset(%{content: "REWRITTEN mid-experiment"})
        |> Repo.update()

      # Anti-vacuity: the edit really landed. Without this, "the control is
      # unchanged" would also be true of an edit that silently no-oped, and
      # the test would prove nothing about the snapshot.
      assert edited.content == "REWRITTEN mid-experiment"
      assert Repo.get!(PromptTemplate, template.id).content == "REWRITTEN mid-experiment"

      control = Repo.get_by!(Variant, experiment_id: experiment.id, slug: "control")
      assert control.content == "ORIGINAL template body"
      refute control.content == Repo.get!(PromptTemplate, template.id).content
    end

    test "accepts the template slug as well as the struct" do
      template = insert_template("by slug")
      experiment = create_experiment()

      assert {:ok, activated} = Experiments.activate(experiment, template.slug)
      assert activated.status == "running"

      control = Repo.get_by!(Variant, experiment_id: experiment.id, slug: "control")
      assert control.content == "by slug"
    end

    test "refuses with {:error, changeset} when the source template is missing" do
      experiment = create_experiment()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Experiments.activate(experiment, "no-such-template-slug")

      refute changeset.valid?

      # It must REFUSE, not raise and not partially apply.
      assert Repo.get!(Experiment, experiment.id).status == "draft"
      assert Repo.aggregate(variants_of(experiment), :count) == 0
    end

    test "activation is atomic — a failed control insert rolls the status flip back" do
      # Drive the transaction into failure at the control step by planting a
      # variant that already occupies the `control` slug, so the insert hits
      # the (experiment_id, slug) unique index. The status flip must roll
      # back with it: a `running` experiment whose control was never
      # snapshotted in this transaction is exactly the state activation
      # exists to make unreachable.
      template = insert_template("live body")
      experiment = create_experiment()

      {:ok, planted} =
        Experiments.add_variant(experiment, %{slug: "control", content: "NOT a snapshot"})

      assert {:error, %Ecto.Changeset{} = changeset} = Experiments.activate(experiment, template)
      refute changeset.valid?

      assert Repo.get!(Experiment, experiment.id).status == "draft",
             "the status flip must not survive a failed snapshot"

      # The pre-existing row is untouched and no second control appeared.
      assert Repo.aggregate(variants_of(experiment), :count) == 1
      assert Repo.get!(Variant, planted.id).content == "NOT a snapshot"
    end

    test "activating twice does not take a second snapshot" do
      template = insert_template("first body")
      experiment = create_experiment()

      {:ok, activated} = Experiments.activate(experiment, template)
      assert activated.status == "running"

      {:ok, _} =
        template
        |> PromptTemplate.changeset(%{content: "second body"})
        |> Repo.update()

      # A second activation must not overwrite the control with the template's
      # newer content — that would be the drift the snapshot prevents,
      # reintroduced through the front door.
      assert {:error, %Ecto.Changeset{}} = Experiments.activate(activated, template)

      control = Repo.get_by!(Variant, experiment_id: experiment.id, slug: "control")
      assert control.content == "first body"
      assert Repo.aggregate(variants_of(experiment), :count) == 1
    end

    test "a caller who preloaded :variants before activation still succeeds" do
      # Regression guard. The changeset consults an already-loaded :variants
      # list when it has one; if activate/2 reused the caller's struct, that
      # stale list (captured before the control existed) would make the
      # guard refuse an activation whose control it had just inserted.
      template = insert_template()
      experiment = create_experiment()
      {:ok, _} = Experiments.add_variant(experiment, %{slug: "treatment", content: "B"})

      stale = Repo.preload(experiment, :variants)
      assert Enum.map(stale.variants, & &1.slug) == ["treatment"]

      assert {:ok, activated} = Experiments.activate(stale, template)
      assert activated.status == "running"
    end
  end

  describe "stop/2 and conclude/2 are DIFFERENT terminal statuses" do
    setup do
      template = insert_template()

      running = fn ->
        experiment = create_experiment()
        {:ok, activated} = Experiments.activate(experiment, template)
        activated
      end

      %{running: running}
    end

    test "each writes its own status and neither collapses onto the other", %{running: running} do
      {:ok, stopped} = Experiments.stop(running.())
      {:ok, concluded} = Experiments.conclude(running.())

      assert stopped.status == "stopped"
      assert concluded.status == "concluded"
      refute stopped.status == concluded.status

      assert Repo.get!(Experiment, stopped.id).status == "stopped"
      assert Repo.get!(Experiment, concluded.id).status == "concluded"
    end

    test "list_experiments/0 returns BOTH, neither filtered nor mapped", %{running: running} do
      {:ok, stopped} = Experiments.stop(running.())
      {:ok, concluded} = Experiments.conclude(running.())

      by_id = Map.new(Experiments.list_experiments(), &{&1.id, &1.status})

      assert by_id[stopped.id] == "stopped",
             "a stopped experiment must stay visible — it is often the most instructive row"

      assert by_id[concluded.id] == "concluded"
    end
  end

  describe "assign_once/2 — stickiness" do
    setup do
      template = insert_template()
      experiment = create_experiment()

      # Several distinct variants, so a re-roll on the second call has real
      # room to differ. With one variant, "the same slug came back" would be
      # true by construction and the stickiness assertion would be vacuous.
      for slug <- ~w(alpha beta gamma delta) do
        {:ok, _} = Experiments.add_variant(experiment, %{slug: slug, content: "body #{slug}"})
      end

      {:ok, experiment} = Experiments.activate(experiment, template)

      %{
        experiment: experiment,
        subject: %{subject_type: "task", subject_id: Ecto.UUID.generate()}
      }
    end

    test "the fixture really can produce different variants", %{experiment: experiment} do
      # Anti-vacuity for the test below. If variant resolution happened to be
      # constant, "both calls returned the same slug" would prove nothing
      # about the read-before-write path. Assigning many DIFFERENT subjects
      # must produce more than one distinct slug.
      slugs =
        for _ <- 1..60 do
          subject = %{subject_type: "task", subject_id: Ecto.UUID.generate()}
          {:ok, assignment} = Assignments.assign_once(experiment, subject)
          assignment.variant_slug
        end

      assert length(Enum.uniq(slugs)) > 1,
             "resolution is constant, so the stickiness test would be vacuous"
    end

    test "two calls return the same slug and leave exactly ONE row", %{
      experiment: experiment,
      subject: subject
    } do
      assert {:ok, first} = Assignments.assign_once(experiment, subject)

      assert Repo.aggregate(assignments_for(experiment, subject), :count) == 1

      assert {:ok, second} = Assignments.assign_once(experiment, subject)

      # Both halves are needed. The count alone cannot tell you WHICH row
      # survived, and the slug alone cannot tell you whether a second row was
      # written.
      assert second.variant_slug == first.variant_slug
      assert second.id == first.id
      assert Repo.aggregate(assignments_for(experiment, subject), :count) == 1
    end

    test "repeated calls never drift", %{experiment: experiment, subject: subject} do
      {:ok, first} = Assignments.assign_once(experiment, subject)

      for _ <- 1..20 do
        {:ok, again} = Assignments.assign_once(experiment, subject)
        assert again.variant_slug == first.variant_slug
        assert again.id == first.id
      end

      assert Repo.aggregate(assignments_for(experiment, subject), :count) == 1
    end

    test "a repeat call performs NO insert — it reads", %{
      experiment: experiment,
      subject: subject
    } do
      # Why this test exists, recorded because it is not obvious.
      #
      # Removing the read-before-write lookup from assign_once/2 entirely —
      # so that every call attempts an insert — does NOT change any
      # observable return value. The unique index rejects the second insert,
      # the conflict path re-reads, and the caller gets back the same row
      # with the same slug. Every other assertion in this file stays green
      # under that mutation; it was run, and it did not detonate.
      #
      # So the read path is indistinguishable through return values alone,
      # and asserting harder on them would never reach it. The channel that
      # DOES distinguish the two is whether an INSERT is issued at all.
      # Without this test the lookup is untested by construction —
      # dead-looking code a later reader could delete with a green suite,
      # turning every repeat assignment into a failed write plus a recovery.
      {:ok, _first} = Assignments.assign_once(experiment, subject)

      test_pid = self()
      handler_id = "assign-once-insert-probe-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:platform, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          # Only this process's queries: the suite runs async, and a global
          # handler would otherwise count a sibling test's inserts.
          if self() == test_pid and metadata[:source] == "experiment_assignments" do
            send(test_pid, {:probe_query, String.slice(metadata[:query] || "", 0, 6)})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, second} = Assignments.assign_once(experiment, subject)

      queries = drain_probe_queries([])

      # Anti-vacuity: the handler really did fire, so "no INSERT" below is a
      # statement about what ran rather than about a handler that was never
      # attached or a source name that never matched.
      assert queries != [], "telemetry captured nothing; this test would prove nothing"
      assert "SELECT" in queries

      refute "INSERT" in queries,
             "assign_once/2 attempted an insert for an already-assigned subject; " <>
               "the existing row must be READ, not re-inserted and recovered by the constraint"

      assert second.variant_slug != nil
    end

    test "a different subject gets its own assignment", %{
      experiment: experiment,
      subject: subject
    } do
      # Confirms stickiness is scoped to the subject rather than the whole
      # experiment returning one shared row.
      {:ok, _} = Assignments.assign_once(experiment, subject)
      other = %{subject_type: "task", subject_id: Ecto.UUID.generate()}
      {:ok, second} = Assignments.assign_once(experiment, other)

      assert Repo.aggregate(assignments_for(experiment, other), :count) == 1
      assert second.subject_id == other.subject_id
      assert length(Assignments.list_assignments(experiment)) == 2
    end

    test "accepts a {type, id} tuple as well as a map", %{experiment: experiment} do
      id = Ecto.UUID.generate()

      {:ok, from_tuple} = Assignments.assign_once(experiment, {"task", id})

      {:ok, from_map} =
        Assignments.assign_once(experiment, %{subject_type: "task", subject_id: id})

      assert from_map.id == from_tuple.id
    end

    test "a malformed subject_id returns nil rather than raising", %{experiment: experiment} do
      # `where: a.subject_id == ^value` raises Ecto.Query.CastError on a
      # malformed binary exactly as Repo.get/2 does, and the subject is
      # caller-supplied. Folding it into the nil this function already
      # returns for an unassigned subject keeps it total.
      assert Assignments.get_assignment(experiment, {"task", "not-a-uuid"}) == nil
      assert Assignments.get_assignment(experiment, {"task", ""}) == nil

      # Anti-vacuity: a well-formed id that is genuinely unassigned returns
      # nil too, so the assertions above must not be read as "this id was
      # rejected" unless a real lookup would have found something. Confirm
      # the same function DOES find a row when one exists.
      subject = %{subject_type: "task", subject_id: Ecto.UUID.generate()}
      {:ok, assigned} = Assignments.assign_once(experiment, subject)
      assert Assignments.get_assignment(experiment, subject).id == assigned.id
    end

    test "assign_once with a malformed subject_id refuses instead of raising", %{
      experiment: experiment
    } do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Assignments.assign_once(experiment, {"task", "not-a-uuid"})

      refute changeset.valid?
    end

    test "an experiment with no variants cannot assign" do
      experiment = create_experiment()

      assert {:error, :no_variants} =
               Assignments.assign_once(experiment, {"task", Ecto.UUID.generate()})
    end
  end

  describe "exclude/3" do
    setup do
      template = insert_template()
      experiment = create_experiment()
      {:ok, _} = Experiments.add_variant(experiment, %{slug: "treatment", content: "B"})
      {:ok, experiment} = Experiments.activate(experiment, template)

      subject = %{subject_type: "task", subject_id: Ecto.UUID.generate()}
      {:ok, assignment} = Assignments.assign_once(experiment, subject)

      %{experiment: experiment, subject: subject, assignment: assignment}
    end

    test "records a reason and the row SURVIVES", %{
      experiment: experiment,
      subject: subject,
      assignment: assignment
    } do
      assert {:ok, excluded} = Assignments.exclude(experiment, subject, "subject cancelled")

      assert excluded.excluded_reason == "subject cancelled"

      reloaded = Repo.get(Assignment, assignment.id)
      assert reloaded != nil, "an exclusion must never delete the row"
      assert reloaded.excluded_reason == "subject cancelled"

      assert reloaded.variant_slug == assignment.variant_slug,
             "exclusion must not erase which variant the subject was given"

      assert Repo.aggregate(assignments_for(experiment, subject), :count) == 1
    end

    test "an excluded subject still appears in list_assignments/1", %{
      experiment: experiment,
      subject: subject
    } do
      {:ok, _} = Assignments.exclude(experiment, subject, "cancelled")

      assert [%Assignment{excluded_reason: "cancelled"}] =
               Assignments.list_assignments(experiment)
    end

    test "assign_once/2 after an exclusion does NOT re-roll the subject", %{
      experiment: experiment,
      subject: subject,
      assignment: assignment
    } do
      {:ok, _} = Assignments.exclude(experiment, subject, "cancelled")
      {:ok, again} = Assignments.assign_once(experiment, subject)

      assert again.id == assignment.id
      assert again.variant_slug == assignment.variant_slug
      assert again.excluded_reason == "cancelled", "the exclusion must survive a later read"
    end

    test "excluding an unassigned subject is an error, not a silent insert", %{
      experiment: experiment
    } do
      assert {:error, :not_assigned} =
               Assignments.exclude(experiment, {"task", Ecto.UUID.generate()}, "why")
    end
  end

  describe "the public surface itself is a contract" do
    test "Assignments exposes no function that recomputes or deletes an assignment" do
      # Checked against the compiled module's exports rather than by grepping
      # the source: prose in a moduledoc legitimately contains the word
      # "recomputed", and a source grep would either match that or force the
      # documentation to avoid naming the hazard it exists to explain.
      names =
        Assignments.__info__(:functions)
        |> Enum.map(fn {name, _arity} -> Atom.to_string(name) end)

      for name <- names do
        refute name =~ ~r/reassign|recompute|force/,
               "#{name}/? recomputes an assignment; if that is ever needed it must be " <>
                 "named so its danger is legible at the call site"

        refute name =~ ~r/^delete|^destroy|^remove/,
               "#{name}/? deletes an assignment; exclusions are recorded, never removed"
      end

      # Anti-vacuity: the list is non-empty and really contains the surface
      # being constrained, so the loop above is not passing over nothing.
      assert "assign_once" in names
      assert "exclude" in names
    end

    test "Experiments exposes no delete for assignments" do
      names =
        Experiments.__info__(:functions)
        |> Enum.map(fn {name, _arity} -> Atom.to_string(name) end)

      refute Enum.any?(names, &(&1 =~ ~r/assignment/ and &1 =~ ~r/delete|remove/))
      assert "list_experiments" in names
    end
  end

  defp drain_probe_queries(acc) do
    receive do
      {:probe_query, verb} -> drain_probe_queries([verb | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp variants_of(%Experiment{id: id}), do: from(v in Variant, where: v.experiment_id == ^id)

  defp assignments_for(%Experiment{id: id}, subject) do
    subject_type = subject[:subject_type]
    subject_id = subject[:subject_id]

    from(a in Assignment,
      where:
        a.experiment_id == ^id and a.subject_type == ^subject_type and
          a.subject_id == ^subject_id
    )
  end
end
