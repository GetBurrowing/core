defmodule Platform.Orchestration.FederationPreambleRowTest do
  @moduledoc """
  The `federation.preamble` row must exist and be byte-identical to
  `PromptTemplates.federation_preamble/0`.

  Every assertion here is exact `==`, never a substring check: a substring
  assertion passes for a truncated preamble AND for a doubled one, so it cannot
  distinguish the state under test from two ways of being wrong.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Orchestration.PromptTemplate
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo

  describe "federation.preamble descriptor" do
    test "default content is exactly the federation_preamble/0 constant" do
      assert PromptTemplates.default_content_for_slug("federation.preamble") ==
               PromptTemplates.federation_preamble()
    end

    test "descriptor declares no variables" do
      descriptor =
        Enum.find(PromptTemplates.default_templates(), &(&1.slug == "federation.preamble"))

      assert descriptor.variables == []

      # And the body must justify that: `interpolate/2` is a single
      # `Regex.replace` pass, so any `{{x}}` here would ship literally.
      refute PromptTemplates.federation_preamble() =~ ~r/\{\{\w+\}\}/
    end
  end

  describe "seed_defaults/0" do
    test "seeds a row whose content survives the DB round-trip unchanged" do
      :ok = PromptTemplates.seed_defaults()

      row = PromptTemplates.get_template_by_slug("federation.preamble")

      assert row
      assert row.content == PromptTemplates.federation_preamble()
    end

    test "re-running neither duplicates nor rewrites the row" do
      :ok = PromptTemplates.seed_defaults()
      first = PromptTemplates.get_template_by_slug("federation.preamble")

      :ok = PromptTemplates.seed_defaults()
      second = PromptTemplates.get_template_by_slug("federation.preamble")

      assert second.id == first.id
      assert second.content == first.content
      assert second.updated_at == first.updated_at

      count =
        Platform.Repo.aggregate(
          from(t in Platform.Orchestration.PromptTemplate,
            where: t.slug == "federation.preamble"
          ),
          :count
        )

      assert count == 1
    end
  end

  # ── Stage 2: federation_preamble/0 reads the row ─────────────────────────
  #
  # One assertion per side. An implementation that ALWAYS returns the constant
  # passes "row missing" and "blank row" and fails "row present"; one that
  # ALWAYS returns the row fails "row missing" and "blank row". Neither
  # direction can be green on the whole block by accident.

  @sentinel "SENTINEL-PREAMBLE-A"

  defp seed_row! do
    :ok = PromptTemplates.seed_defaults()
    PromptTemplates.get_template_by_slug("federation.preamble")
  end

  defp delete_row! do
    case PromptTemplates.get_template_by_slug("federation.preamble") do
      nil -> :ok
      row -> {:ok, _} = PromptTemplates.delete_template(row)
    end

    :ok
  end

  defp set_row_content!(content) do
    {:ok, row} = PromptTemplates.update_template(seed_row!(), %{content: content})
    row
  end

  # `PromptTemplate.changeset/2` runs `validate_required(:content)`, and Ecto's
  # required check treats a whitespace-only string as blank — so blank content
  # cannot be written through `update_template/2`. That guards ONE writer, not
  # the column: a psql edit, a bad migration, or a future writer that skips the
  # changeset all reach the DB directly. This sets the column the same way,
  # which is the only way to put `federation_preamble/0` in front of the state
  # it is written to survive.
  defp force_row_content!(content) do
    {1, _} =
      Repo.update_all(
        from(t in PromptTemplate, where: t.slug == "federation.preamble"),
        set: [content: content]
      )

    :ok
  end

  # A dispatch rendered through the REAL path, not a hand-built assigns map.
  defp planning_dispatch do
    HeartbeatScheduler.dispatch_prompt(
      %{
        id: "01a00c99-0000-0000-0000-00000000d151",
        title: "Preamble row probe",
        description: "Probe task for the federation.preamble row read",
        status: "planning",
        priority: "medium"
      },
      nil,
      nil
    )
  end

  describe "federation_preamble/0 row read" do
    test "byte-identical dispatch render with the row absent and with it seeded" do
      # The load-bearing assertion. `==`, never `=~`: a substring check is
      # satisfied by a truncated preamble AND by a doubled one, so it cannot
      # tell the refactor from either way of breaking it.
      :ok = delete_row!()
      without_row = planning_dispatch()

      _row = seed_row!()
      with_row = planning_dispatch()

      assert with_row == without_row
    end

    test "row present: its content wins, and reaches the rendered dispatch" do
      set_row_content!(@sentinel)

      assert PromptTemplates.federation_preamble() == @sentinel
      assert planning_dispatch() =~ @sentinel
    end

    test "row missing: the constant is returned and the dispatch is unchanged" do
      :ok = delete_row!()
      baseline = planning_dispatch()

      assert PromptTemplates.federation_preamble() ==
               PromptTemplates.default_content_for_slug("federation.preamble")

      # Re-rendering from the same missing-row state must be stable, and must
      # match the render taken with the seeded row (the case-1 invariant).
      _row = seed_row!()
      assert planning_dispatch() == baseline
    end

    test "blank row: the constant is returned, NOT an empty string" do
      # The invisible-failure case, asserted explicitly. This is NOT a
      # duplicate of the missing-row test: a blank row is PRESENT, so a
      # reader that only guards on `nil` returns "" here — stripping the
      # preamble from ~15 dispatch templates while every dispatch still
      # renders and sends without erroring.
      constant = PromptTemplates.default_content_for_slug("federation.preamble")

      for blank <- ["", "   ", "\n\n", " \t\n "] do
        _row = seed_row!()
        :ok = force_row_content!(blank)

        assert PromptTemplates.federation_preamble() == constant,
               "blank row content #{inspect(blank)} must fall back to the constant"

        refute PromptTemplates.federation_preamble() == ""
      end
    end

    test "direction control: a body with no placeholder renders identically either way" do
      # Proves the change is scoped to `{{federation_preamble}}` and did not
      # leak into interpolation generally.
      {:ok, _} =
        PromptTemplates.create_template(%{
          slug: "test.no_preamble_probe",
          name: "No-placeholder probe",
          description: "Direction control for the federation.preamble row read",
          variables: ["task_title"],
          content: "Static body for {{task_title}} with no preamble placeholder.\n"
        })

      assigns = %{task_title: "Probe"}

      set_row_content!(@sentinel)
      {:ok, with_sentinel} = PromptTemplates.render_template("test.no_preamble_probe", assigns)

      :ok = delete_row!()
      {:ok, without_row} = PromptTemplates.render_template("test.no_preamble_probe", assigns)

      assert with_sentinel == without_row
      refute with_sentinel =~ @sentinel
    end
  end

  # ── Stage 3: the slug is experiment-targetable ───────────────────────────

  @variant_slug "treatment"
  @variant_preamble "VARIANT-PREAMBLE-QUUX"

  defp subject(subject_id), do: %{subject_type: "task", subject_id: subject_id}

  # A RUNNING experiment targeting the `federation.preamble` row, weighted
  # entirely onto the treatment. The control snapshot is taken by
  # `activate/2` itself, never hand-written — the snapshot is part of what is
  # under test, so it has to come from the shipped path.
  defp running_experiment_on_preamble!(template) do
    {:ok, experiment} =
      Platform.Experiments.create_experiment(%{
        slug: "exp-preamble-#{System.unique_integer([:positive])}",
        name: "Federation preamble targeting probe",
        primary_metric: "cycle_time"
      })

    {:ok, _variant} =
      Platform.Experiments.add_variant(experiment, %{
        slug: @variant_slug,
        content: @variant_preamble,
        weight: 1
      })

    {:ok, running} = Platform.Experiments.activate(experiment, template)

    Repo.update_all(
      from(v in Platform.Experiments.Variant,
        where: v.experiment_id == ^running.id and v.slug == "control"
      ),
      set: [weight: 0]
    )

    running
  end

  describe "federation_preamble/1 experiment targeting" do
    test "a running experiment's variant wins over the row content" do
      row = set_row_content!(@sentinel)
      experiment = running_experiment_on_preamble!(row)
      task_id = Ecto.UUID.generate()

      # Exact `==`, both directions. Asserting only that the variant marker is
      # present would pass for an implementation that concatenated the variant
      # onto the row body; the row's own sentinel has to be ABSENT.
      assert PromptTemplates.federation_preamble(%{task_id: task_id}) == @variant_preamble
      refute PromptTemplates.federation_preamble(%{task_id: task_id}) =~ @sentinel

      assert %Platform.Experiments.Assignment{variant_slug: @variant_slug} =
               Platform.Experiments.Assignments.get_assignment(experiment, subject(task_id))
    end

    test "with no experiment defined, /1 and /0 return the same row content" do
      _row = set_row_content!(@sentinel)
      task_id = Ecto.UUID.generate()

      assert PromptTemplates.federation_preamble(%{task_id: task_id}) == @sentinel

      # Byte-identity between the arities, not merely "both non-empty": the
      # zero-arity call is the one ~15 dispatch bodies went through before
      # this stage, and a subject with no experiment must not change it.
      assert PromptTemplates.federation_preamble() ==
               PromptTemplates.federation_preamble(%{task_id: task_id})

      assert Repo.aggregate(Platform.Experiments.Assignment, :count) == 0
    end

    test "the empty-string task_id is NO subject — row content, and no assignment row" do
      # The trap `subject_id/1` documents: several dispatch sites pass
      # `contract_id(task, :id) || ""`, so `""` arrives as an ordinary value.
      # Treating it as a subject would collapse every unattributable dispatch
      # in the system into one shared pseudo-subject whose assignment rows
      # still get counted by the metric.
      row = set_row_content!(@sentinel)
      _experiment = running_experiment_on_preamble!(row)

      assert PromptTemplates.federation_preamble(%{task_id: ""}) == @sentinel
      refute PromptTemplates.federation_preamble(%{task_id: ""}) =~ @variant_preamble

      assert Repo.aggregate(Platform.Experiments.Assignment, :count) == 0
    end
  end

  describe "the confound caveat" do
    # REACH OF THIS TEST, stated honestly: it is a source scan over the
    # moduledoc. It pins that the words are PRESENT and cannot be silently
    # deleted. It does not and cannot show that anyone reads or acts on them,
    # and it is not a substitute for the behavioural tests above — those are
    # what pin that targeting actually works.
    @confound_phrase "every dispatch type at once"

    test "the moduledoc records that a preamble variant hits every dispatch type at once" do
      # Read the compiled @moduledoc, not the source file: a file scan is
      # satisfied by the phrase appearing anywhere in 5,000 lines — a code
      # comment, a seeded template body, or this test's own name in a
      # docstring. Fetching the doc chunk pins it to the attribute itself.
      {:docs_v1, _, _, _, %{"en" => raw}, _, _} = Code.fetch_docs(PromptTemplates)

      # Whitespace-normalised, and ONLY whitespace: the moduledoc is hard
      # wrapped at ~76 columns, so a phrase that happens to straddle a line
      # break today would make an exact scan fail on a pure reflow. What is
      # normalised away is line breaking; every word is still pinned.
      moduledoc = raw |> String.replace(~r/\s+/, " ") |> String.trim()

      assert moduledoc =~ @confound_phrase,
             "the PromptTemplates @moduledoc must keep the federation.preamble confound " <>
               "caveat, keyed on #{inspect(@confound_phrase)}"

      # The caveat is only useful if it names what the coarseness costs. Both
      # halves: what the experiment CAN answer and what it cannot.
      assert moduledoc =~ "cannot be attributed to a single agent behaviour"
      assert moduledoc =~ "which agent behaviour changed"
      assert moduledoc =~ "dispatch.planning"
    end
  end
end
