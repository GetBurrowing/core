defmodule Platform.Experiments.SchemasTest do
  @moduledoc """
  Schema and changeset-level tests for the experiments substrate
  (task 019fe6b9, ADR-0048).

  The contracts under test here are the ones whose violation is SILENT: a
  status collapse, an assignment recomputed on a second read, a control that
  drifts. Each test below therefore tries to state not just that the right
  thing happened, but that the wrong thing was actually reachable in the
  fixture — an assertion that is true by construction proves nothing.
  """

  use Platform.DataCase, async: true

  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.PromptTemplateHistory
  alias Platform.Experiments.Variant
  alias Platform.Orchestration.PromptTemplate

  # Local errors_on helper mirroring the shape used across other schema tests.
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp experiment_attrs(attrs \\ %{}) do
    Map.merge(
      %{
        slug: "exp-#{System.unique_integer([:positive])}",
        name: "Shorter planning preamble",
        hypothesis: "A shorter preamble raises plan acceptance.",
        primary_metric: "plan_acceptance_rate"
      },
      attrs
    )
  end

  defp insert_experiment(attrs \\ %{}) do
    %Experiment{}
    |> Experiment.changeset(experiment_attrs(attrs))
    |> Repo.insert!()
  end

  defp insert_variant(experiment, slug, content \\ "the prompt body") do
    %Variant{}
    |> Variant.changeset(%{
      experiment_id: experiment.id,
      slug: slug,
      content: content,
      weight: 1
    })
    |> Repo.insert!()
  end

  defp insert_template(content \\ "you are a planner") do
    %PromptTemplate{}
    |> PromptTemplate.changeset(%{
      slug: "tpl-#{System.unique_integer([:positive])}",
      name: "Planner",
      content: content
    })
    |> Repo.insert!()
  end

  describe "Experiment.changeset/2 required fields" do
    test "slug and name are required" do
      changeset = Experiment.changeset(%Experiment{}, %{})

      assert %{slug: ["can't be blank"], name: ["can't be blank"]} = errors_on(changeset)
    end

    test "a fully specified draft experiment is valid" do
      changeset = Experiment.changeset(%Experiment{}, experiment_attrs())

      assert changeset.valid?
      # The default must be `draft`, not `running` — a new experiment that
      # started running would bypass the activation snapshot entirely.
      assert get_field(changeset, :status) == "draft"
    end
  end

  describe "Experiment status inclusion" do
    test "rejects a status outside the four" do
      changeset = Experiment.changeset(%Experiment{}, experiment_attrs(%{status: "paused"}))

      refute changeset.valid?
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "accepts every one of the four, and stopped/concluded stay DISTINCT" do
      # `running` is excluded here on purpose: it is the one status that is
      # not reachable by a bare changeset, because of the control guard. It
      # gets its own test below.
      for status <- ~w(draft stopped concluded) do
        changeset = Experiment.changeset(%Experiment{}, experiment_attrs(%{status: status}))

        assert changeset.valid?, "expected #{status} to be a valid status"
        assert get_field(changeset, :status) == status
      end

      # The real hazard is not "is `stopped` accepted" but "does `stopped`
      # survive a round trip as itself". A collapse onto `concluded` would
      # keep every assertion above green.
      stopped = insert_experiment(%{status: "stopped"})
      concluded = insert_experiment(%{status: "concluded"})

      assert Repo.get!(Experiment, stopped.id).status == "stopped"
      assert Repo.get!(Experiment, concluded.id).status == "concluded"

      refute Repo.get!(Experiment, stopped.id).status ==
               Repo.get!(Experiment, concluded.id).status
    end
  end

  describe "activation guard — a changeset cannot reach `running` without a control" do
    test "refuses `running` when the experiment has NO variants at all" do
      experiment = insert_experiment()

      changeset = Experiment.changeset(experiment, %{status: "running"})

      refute changeset.valid?
      assert %{status: [message]} = errors_on(changeset)
      assert message =~ "control variant"
    end

    test "refuses `running` when variants exist but none is the control" do
      experiment = insert_experiment()
      insert_variant(experiment, "treatment")

      # Anti-vacuity: the experiment really does have a variant, so the
      # refusal below is about the control specifically and not about an
      # experiment that happens to have no rows.
      assert Repo.aggregate(
               from(v in Variant, where: v.experiment_id == ^experiment.id),
               :count
             ) == 1

      changeset = Experiment.changeset(experiment, %{status: "running"})

      refute changeset.valid?
      assert %{status: [_]} = errors_on(changeset)
    end

    test "accepts `running` once a control variant row exists" do
      experiment = insert_experiment()
      insert_variant(experiment, "control", "snapshot of the live template")

      changeset = Experiment.changeset(experiment, %{status: "running"})

      assert changeset.valid?
      assert {:ok, updated} = Repo.update(changeset)
      assert updated.status == "running"
    end

    test "the guard turns on the variant SLUG and nothing else" do
      # A direction control. Both experiments are built identically and each
      # gets exactly one variant; the ONLY thing that differs is that slug.
      # If the answer did not flip, the guard would be keying off something
      # incidental — the presence of any variant, the row count, the status
      # itself — and one-directional evidence could not tell the difference.
      without = insert_experiment()
      insert_variant(without, "treatment")

      with_control = insert_experiment()
      insert_variant(with_control, "control")

      refute Experiment.changeset(without, %{status: "running"}).valid?
      assert Experiment.changeset(with_control, %{status: "running"}).valid?
    end

    test "the guard is not bypassed by a preloaded association" do
      experiment = insert_experiment()
      insert_variant(experiment, "treatment")

      preloaded = Repo.preload(experiment, :variants)
      assert length(preloaded.variants) == 1

      refute Experiment.changeset(preloaded, %{status: "running"}).valid?
    end

    test "the guard does not fire on transitions that are not INTO running" do
      experiment = insert_experiment()
      insert_variant(experiment, "control")

      running =
        experiment
        |> Experiment.changeset(%{status: "running"})
        |> Repo.update!()

      # Stopping a running experiment must not be blocked, and re-saving an
      # unrelated field on one must not re-run the guard.
      assert Experiment.changeset(running, %{status: "stopped"}).valid?
      assert Experiment.changeset(running, %{name: "renamed"}).valid?
    end
  end

  describe "Variant.changeset/2" do
    test "requires the experiment, slug and the full content blob" do
      changeset = Variant.changeset(%Variant{}, %{})

      errors = errors_on(changeset)
      assert errors[:experiment_id] == ["can't be blank"]
      assert errors[:slug] == ["can't be blank"]
      assert errors[:content] == ["can't be blank"]
    end

    test "stores the content verbatim, blob and all" do
      experiment = insert_experiment()
      blob = "line one\n\nline two with {{a_variable}} and trailing space   "

      variant = insert_variant(experiment, "treatment", blob)

      # Byte-for-byte. A variant that normalised, trimmed or re-composed its
      # content would no longer be what was dispatched.
      assert Repo.get!(Variant, variant.id).content == blob
    end

    test "the same slug cannot be used twice within one experiment" do
      experiment = insert_experiment()
      insert_variant(experiment, "control")

      assert {:error, changeset} =
               %Variant{}
               |> Variant.changeset(%{
                 experiment_id: experiment.id,
                 slug: "control",
                 content: "a second control",
                 weight: 1
               })
               |> Repo.insert()

      refute changeset.valid?
    end

    test "the same slug IS allowed across different experiments" do
      # Confirms the uniqueness is scoped per experiment rather than global —
      # otherwise the previous test would pass under a far too broad index.
      first = insert_experiment()
      second = insert_experiment()

      insert_variant(first, "control")
      assert %Variant{} = insert_variant(second, "control")
    end
  end

  describe "assignment stickiness — the unique index on (experiment, subject_type, subject_id)" do
    setup do
      experiment = insert_experiment()
      insert_variant(experiment, "control")

      %{experiment: experiment, subject_id: Ecto.UUID.generate()}
    end

    defp assignment_attrs(experiment, subject_id, attrs \\ %{}) do
      Map.merge(
        %{
          experiment_id: experiment.id,
          subject_type: "task",
          subject_id: subject_id,
          variant_slug: "control",
          assigned_at: DateTime.utc_now()
        },
        attrs
      )
    end

    test "a second insert for the same triple is refused", %{
      experiment: experiment,
      subject_id: subject_id
    } do
      assert {:ok, _first} =
               %Assignment{}
               |> Assignment.changeset(assignment_attrs(experiment, subject_id))
               |> Repo.insert()

      # The second insert names a DIFFERENT variant. If the index were absent
      # this would succeed and the subject would hold two conflicting
      # assignments — variant A at planning, variant B at execution.
      assert {:error, changeset} =
               %Assignment{}
               |> Assignment.changeset(
                 assignment_attrs(experiment, subject_id, %{variant_slug: "treatment"})
               )
               |> Repo.insert()

      # It must come back as a CHANGESET ERROR, not a raised
      # Ecto.ConstraintError. That is the whole point of pinning the index
      # name: Ecto's derived name for these three columns is 66 bytes and
      # Postgres truncates at 63, so a constraint declared under the derived
      # name would never match and this insert would raise instead.
      refute changeset.valid?
      assert errors_on(changeset)[:subject_id] != nil

      assert Repo.aggregate(
               from(a in Assignment, where: a.experiment_id == ^experiment.id),
               :count
             ) == 1
    end

    test "the constraint name in the changeset matches a real index", %{
      experiment: experiment
    } do
      # A direct check on the thing that silently rots. If someone renames the
      # index, or lets Ecto derive (and Postgres truncate) it, the test above
      # would start raising rather than returning a changeset — but only under
      # the exact race it exists to cover.
      name = Assignment.unique_index_name() |> Atom.to_string()

      assert String.length(name) <= 63

      {:ok, %{rows: rows}} =
        Ecto.Adapters.SQL.query(
          Repo,
          "select indexname from pg_indexes where tablename = $1 and indexname = $2",
          ["experiment_assignments", name]
        )

      assert rows == [[name]], "no index named #{name} exists on experiment_assignments"
      assert %Experiment{} = experiment
    end

    test "the same subject_id under a DIFFERENT subject_type is a different assignment", %{
      experiment: experiment,
      subject_id: subject_id
    } do
      # Proves the index spans all three columns rather than collapsing to
      # (experiment_id, subject_id). Without this, a later dispatch-level
      # subject sharing a uuid with a task would be wrongly refused.
      assert {:ok, _} =
               %Assignment{}
               |> Assignment.changeset(assignment_attrs(experiment, subject_id))
               |> Repo.insert()

      assert {:ok, _} =
               %Assignment{}
               |> Assignment.changeset(
                 assignment_attrs(experiment, subject_id, %{subject_type: "dispatch"})
               )
               |> Repo.insert()
    end

    test "an exclusion records a reason and the row SURVIVES", %{
      experiment: experiment,
      subject_id: subject_id
    } do
      {:ok, assignment} =
        %Assignment{}
        |> Assignment.changeset(assignment_attrs(experiment, subject_id))
        |> Repo.insert()

      {:ok, excluded} =
        assignment
        |> Assignment.changeset(%{excluded_reason: "subject cancelled before dispatch"})
        |> Repo.update()

      assert excluded.excluded_reason == "subject cancelled before dispatch"

      reloaded = Repo.get(Assignment, assignment.id)
      assert reloaded != nil, "an excluded assignment must never be deleted"
      assert reloaded.excluded_reason == "subject cancelled before dispatch"
      assert reloaded.variant_slug == "control", "exclusion must not erase the original variant"
    end

    test "excluded_reason is optional on creation", %{
      experiment: experiment,
      subject_id: subject_id
    } do
      assert {:ok, assignment} =
               %Assignment{}
               |> Assignment.changeset(assignment_attrs(experiment, subject_id))
               |> Repo.insert()

      assert assignment.excluded_reason == nil
    end
  end

  describe "PromptTemplateHistory" do
    test "captures a template's content against a real prompt_templates row" do
      template = insert_template("original body")
      captured_at = DateTime.utc_now()

      assert {:ok, history} =
               %PromptTemplateHistory{}
               |> PromptTemplateHistory.changeset(%{
                 template_id: template.id,
                 content: template.content,
                 captured_at: captured_at,
                 captured_by: "promotion"
               })
               |> Repo.insert()

      assert history.template_id == template.id
      assert history.content == "original body"
    end

    test "a capture does NOT move when the live template is edited afterwards" do
      template = insert_template("original body")

      {:ok, history} =
        %PromptTemplateHistory{}
        |> PromptTemplateHistory.changeset(%{
          template_id: template.id,
          content: template.content,
          captured_at: DateTime.utc_now()
        })
        |> Repo.insert()

      {:ok, edited} =
        template
        |> PromptTemplate.changeset(%{content: "rewritten body"})
        |> Repo.update()

      # Anti-vacuity: the edit really landed, so "unchanged" below is a
      # statement about the snapshot rather than about an edit that no-oped.
      assert edited.content == "rewritten body"
      assert Repo.get!(PromptTemplate, template.id).content == "rewritten body"

      assert Repo.get!(PromptTemplateHistory, history.id).content == "original body"
    end

    test "requires a template, content and a capture time" do
      changeset = PromptTemplateHistory.changeset(%PromptTemplateHistory{}, %{})

      errors = errors_on(changeset)
      assert errors[:template_id] == ["can't be blank"]
      assert errors[:content] == ["can't be blank"]
      assert errors[:captured_at] == ["can't be blank"]
    end

    test "promotion_experiment_id is optional and round-trips when given" do
      template = insert_template()
      experiment = insert_experiment()

      {:ok, history} =
        %PromptTemplateHistory{}
        |> PromptTemplateHistory.changeset(%{
          template_id: template.id,
          content: "body",
          captured_at: DateTime.utc_now(),
          promotion_experiment_id: experiment.id
        })
        |> Repo.insert()

      assert Repo.get!(PromptTemplateHistory, history.id).promotion_experiment_id == experiment.id
    end
  end
end
