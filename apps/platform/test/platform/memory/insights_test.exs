defmodule Platform.Memory.InsightsTest do
  @moduledoc """
  Task 01a13867 stage 1: the ephemeral insight store and the durable
  verdicts beside it.

  The two lifetimes are the point. Every TTL test reads the table back with
  `Repo.aggregate/3` or `Repo.all/1` after a REAL `Purger.sweep/1`, never a
  stubbed clock inside the context, so a purge that forgets its predicate or
  over-reaches into verdicts turns a named test red (mutation probes (a) and
  (b) in the stage text).
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Experiments
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Signal
  alias Platform.Experiments.Subject
  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Variant
  alias Platform.Memory.Insight
  alias Platform.Memory.Insights
  alias Platform.Memory.Insights.Purger
  alias Platform.Memory.InsightVerdict
  alias Platform.Repo

  @journal "org/journal/2026-10-18.md"

  @briefing ~s(<synthesis-insight action="briefing" confidence="high" evidence="org/journal/2026-10-17.md">
  Release notes keep landing a day after the deploy they describe.
  </synthesis-insight>)

  @question ~s(<synthesis-insight action="question" confidence="medium">
  Which install owns the shared staging bucket?
  </synthesis-insight>)

  defp ingest!(content, workspace_id \\ nil) do
    {:ok, count} = Insights.ingest_from_journal(workspace_id, @journal, content, nil)
    count
  end

  defp only_insight! do
    [insight] = Repo.all(Insight)
    insight
  end

  describe "ingest_from_journal/4" do
    test "inserts one open insight per block, with a deterministic run id" do
      assert ingest!(@briefing <> "\n" <> @question) == 2

      rows = Repo.all(from(i in Insight, order_by: i.action_type))
      assert Enum.map(rows, & &1.action_type) == ["briefing", "question"]
      assert Enum.all?(rows, &(&1.state == "open" and &1.origin == "dreaming"))
      assert Enum.all?(rows, &(&1.run_id == Insights.run_id(nil, "2026-10-18")))
      assert Enum.all?(rows, &(&1.journal_path == @journal))
    end

    test "the run id differs per date and per workspace" do
      a = Insights.run_id(nil, "2026-10-18")
      refute a == Insights.run_id(nil, "2026-10-19")
      refute a == Insights.run_id(Ecto.UUID.generate(), "2026-10-18")
      assert a == Insights.run_id(nil, ~D[2026-10-18])
      assert Platform.UUID.valid?(a)
    end

    test "re-ingesting the same journal inserts nothing" do
      assert ingest!(@briefing) == 1
      assert ingest!(@briefing) == 0
      assert Repo.aggregate(Insight, :count) == 1
    end

    test "a synthesis-proposal block is not ingested" do
      proposal = ~s(<synthesis-proposal category="recurring-theme" confidence="high">
      A theme.
      </synthesis-proposal>)

      assert ingest!(proposal) == 0
      assert Repo.aggregate(Insight, :count) == 0
    end

    test "a rejected block never re-ingests" do
      assert ingest!(@briefing) == 1
      insight = only_insight!()
      assert {:ok, _} = Insights.reject(insight, "already on the release page")

      # The row is gone after its TTL; the verdict stays and is what blocks
      # the block from coming back.
      {:ok, 1} = Purger.sweep(now: DateTime.add(insight.expires_at, 1, :second))
      assert Repo.aggregate(Insight, :count) == 0

      assert ingest!(@briefing) == 0
      assert Repo.aggregate(Insight, :count) == 0
    end

    test "only the high-confidence insight is disseminable under the control" do
      ingest!(@briefing <> @question)
      by_type = Map.new(Repo.all(Insight), &{&1.action_type, &1.disseminable})
      assert by_type == %{"briefing" => true, "question" => false}
    end

    # Task 01a15587 stage 1: page_edit and task are held to
    # auto_apply_min_confidence (control "medium"), briefing and question
    # keep min_confidence (control "high").
    test "a medium page_edit is disseminable under the control arm; a medium briefing is not" do
      assert Insights.auto_apply_min_confidence(Insights.run_id(nil, "2026-10-18")) == "medium"

      page_edit =
        ~s(<synthesis-insight action="page_edit" confidence="medium" target="org/page/runbook.md" source="query:agent_runtimes.last_connected_at">
      The runbook still names the old deploy host.
      <old>deploy to host-a</old><new>deploy to host-b</new>
      </synthesis-insight>)

      task =
        ~s(<synthesis-insight action="task" confidence="medium">
      Add a release-notes check to the deploy checklist.
      </synthesis-insight>)

      low_task =
        ~s(<synthesis-insight action="task" confidence="low">
      Rename the staging bucket.
      </synthesis-insight>)

      briefing =
        ~s(<synthesis-insight action="briefing" confidence="medium">
      The staging bucket is filling up again.
      </synthesis-insight>)

      assert ingest!(page_edit <> task <> low_task <> briefing) == 4

      rows =
        Repo.all(Insight)
        |> Enum.map(&{&1.action_type, &1.confidence, &1.downgraded_from, &1.disseminable})
        |> Enum.sort()

      assert rows == [
               {"briefing", "medium", nil, false},
               {"page_edit", "medium", nil, true},
               {"task", "low", nil, false},
               {"task", "medium", nil, true}
             ]
    end

    test "a page_edit grounding downgrades to a question is held to the question threshold" do
      ungrounded =
        ~s(<synthesis-insight action="page_edit" confidence="medium" target="org/page/runbook.md">
      The runbook still names the old deploy host.
      <old>deploy to host-a</old><new>deploy to host-b</new>
      </synthesis-insight>)

      assert ingest!(ungrounded) == 1

      assert %Insight{action_type: "question", downgraded_from: "page_edit", disseminable: false} =
               only_insight!()
    end

    test "broadcasts each ingested insight on the memory_insights topic" do
      Phoenix.PubSub.subscribe(Platform.PubSub, Insights.topic())
      ingest!(@briefing)
      assert_receive {:memory_insights, :ingested, %Insight{action_type: "briefing"}}
    end

    test "journal_path?/1 accepts journal keys only" do
      assert Insights.journal_path?("org/journal/2026-10-18.md")
      assert Insights.journal_path?("project/abc/journal/2026-10-18.md")
      refute Insights.journal_path?("org/page/x.md")
      refute Insights.journal_path?(nil)
    end
  end

  describe "the journal write paths" do
    test "a page-backed journal write ingests insights through the context hook" do
      {:ok, _} =
        Platform.Org.Context.upsert_context_file(@journal, %{content: @briefing, updated_by: nil})

      assert %Insight{action_type: "briefing"} = only_insight!()
    end
  end

  describe "TTL" do
    test "an acted-on insight leaves no row after its TTL" do
      ingest!(@briefing)
      insight = only_insight!()

      assert {:ok, %Insight{state: "done"} = acted} =
               Insights.record_outcome(insight, :acted, artefact_ref: "page:org/page/x.md")

      assert acted.acted_at
      assert acted.artefact_ref == "page:org/page/x.md"

      # Still inside its TTL: the row is kept, acted on or not.
      assert {:ok, 0} = Purger.sweep(now: DateTime.add(insight.expires_at, -1, :second))
      assert Repo.aggregate(Insight, :count) == 1

      assert {:ok, 1} = Purger.sweep(now: DateTime.add(insight.expires_at, 1, :second))
      assert Repo.aggregate(Insight, :count) == 0
    end

    test "a rejection survives past the TTL and feeds exemplars" do
      ingest!(@briefing)
      insight = only_insight!()
      assert {:ok, %Insight{state: "dismissed"}} = Insights.reject(insight, "  not news  ")

      assert {:ok, 1} = Purger.sweep(now: DateTime.add(insight.expires_at, 1, :second))
      assert Repo.aggregate(Insight, :count) == 0
      assert Repo.aggregate(InsightVerdict, :count) == 1

      assert [
               %{
                 body: "Release notes keep landing a day after the deploy they describe.",
                 reason: "not news",
                 kind: "rejected",
                 action_type: "briefing"
               }
             ] = Insights.exemplars()
    end

    test "list_open hides an expired row before the purge runs" do
      ingest!(@briefing)
      insight = only_insight!()

      assert [%Insight{}] = Insights.list_open()
      assert [] = Insights.list_open(now: DateTime.add(insight.expires_at, 1, :second))

      Repo.update_all(from(i in Insight, where: i.id == ^insight.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      assert [] = Insights.list_open()
      # Not purged yet: the row is still there, only hidden.
      assert Repo.aggregate(Insight, :count) == 1
    end
  end

  describe "verdicts" do
    test "reject and flag refuse a blank reason" do
      ingest!(@briefing)
      insight = only_insight!()

      for reason <- [nil, "", "   \n "] do
        assert {:error, %Ecto.Changeset{} = cs} = Insights.reject(insight, reason)
        assert {:reason, _} = List.keyfind(cs.errors, :reason, 0)
        assert {:error, %Ecto.Changeset{}} = Insights.flag(insight, reason)
      end

      assert Repo.aggregate(InsightVerdict, :count) == 0
      assert %Insight{state: "open"} = Repo.get!(Insight, insight.id)
    end

    test "a flag leaves the insight's state alone and records a flagged verdict" do
      ingest!(@briefing)
      {:ok, acted} = Insights.record_outcome(only_insight!(), :acted)
      assert {:ok, %Insight{state: "done"}} = Insights.flag(acted, "wrong page")
      assert [%{kind: "flagged", reason: "wrong page"}] = Insights.exemplars()
    end

    test "exemplars are newest first and limited to three" do
      for n <- 1..4 do
        Repo.insert!(%InsightVerdict{
          block_hash: "h#{n}",
          kind: "rejected",
          reason: "r#{n}",
          body: "b#{n}",
          inserted_at: DateTime.add(~U[2026-10-01 00:00:00.000000Z], n, :hour)
        })
      end

      assert Enum.map(Insights.exemplars(), & &1.reason) == ["r4", "r3", "r2"]
    end

    test "render_exemplars labels kind and reason" do
      ingest!(@briefing)
      {:ok, _} = Insights.reject(only_insight!(), "already known")
      rendered = Insights.render_exemplars()
      assert rendered =~ "[rejected briefing] Release notes keep landing"
      assert rendered =~ "Reason: already known"
    end

    test "render_exemplars has a placeholder when there is nothing" do
      assert Insights.render_exemplars() == "(no prior rejections in the recent window)"
    end
  end

  describe "get/1" do
    test "returns nil for a non-UUID or missing id" do
      assert Insights.get("not-a-uuid") == nil
      assert Insights.get(Ecto.UUID.generate()) == nil
      assert Insights.get(nil) == nil
    end
  end

  describe "experiment signals" do
    defp running_experiment!(payload) do
      {:ok, experiment} =
        Experiments.create_experiment(%{
          slug: "insights-#{System.unique_integer([:positive])}",
          name: "Insight synthesis",
          surface_key: "memory.insight_synthesis",
          surface_target: "memory.dreaming"
        })

      {:ok, _} =
        Experiments.add_variant(experiment, %{slug: "treatment", payload: payload, weight: 1})

      {:ok, %Experiment{status: "running"} = running} =
        Experiments.start(experiment, Platform.TenancyFixtures.root_admin!())

      Repo.update_all(
        from(v in Variant,
          where: v.experiment_id == ^running.id and v.slug == ^Experiment.control_slug()
        ),
        set: [weight: 0]
      )

      running
    end

    test "a signal carries no insight body" do
      experiment =
        running_experiment!(%{"directive" => "Prefer questions.", "min_confidence" => "low"})

      run_id = Insights.run_id(nil, "2026-10-18")

      assert {:variant, _, "treatment", _} =
               Surfaces.resolve(
                 "memory.insight_synthesis",
                 "memory.dreaming",
                 Subject.new("dreaming_run", run_id)
               )

      ingest!(@briefing <> @question)
      [briefing, question] = Repo.all(from(i in Insight, order_by: i.action_type))

      # The treatment's min_confidence "low" reached the ingest.
      assert question.disseminable

      {:ok, _} = Insights.record_outcome(briefing, :acted)
      {:ok, _} = Insights.reject(question, "nobody owns that bucket")

      signals = Repo.all(from(s in Signal, where: s.experiment_id == ^experiment.id))
      assert Enum.sort(Enum.map(signals, & &1.label)) == ["accepted", "rejected"]

      for signal <- signals do
        assert signal.source_type == "memory_insight"
        assert signal.subject_id == run_id

        for field <- Map.values(Map.from_struct(signal)), is_binary(field) do
          refute field =~ "Release notes keep landing"
          refute field =~ "shared staging bucket"
        end
      end

      assert Enum.find(signals, &(&1.label == "rejected")).reason == "nobody owns that bucket"
      assert Enum.find(signals, &(&1.label == "accepted")).reason == nil

      assert {:ok, %{value: 0.5, n: 2, unit: :ratio}} =
               Experiments.Metrics.InsightAcceptanceRate.compute(experiment.id, "treatment")
    end

    test "an arm's auto_apply_min_confidence reaches the ingest" do
      running_experiment!(%{
        "directive" => nil,
        "min_confidence" => "high",
        "auto_apply_min_confidence" => "high"
      })

      assert Insights.auto_apply_min_confidence(Insights.run_id(nil, "2026-10-18")) == "high"

      ingest!(~s(<synthesis-insight action="task" confidence="medium">
      Add a release-notes check to the deploy checklist.
      </synthesis-insight>))

      # Below the arm's threshold: not disseminable, still an open task for a person.
      assert %Insight{action_type: "task", state: "open", disseminable: false} = only_insight!()
    end

    test "an arm without auto_apply_min_confidence gets the control's value" do
      running_experiment!(%{"directive" => nil, "min_confidence" => "low"})
      assert Insights.auto_apply_min_confidence(Insights.run_id(nil, "2026-10-18")) == "medium"
    end

    test "no experiment, no signal" do
      ingest!(@briefing)
      {:ok, _} = Insights.record_outcome(only_insight!(), :acted)
      assert Repo.aggregate(Signal, :count) == 0
    end

    test "the treatment directive is rendered as a block; the control renders none" do
      assert Insights.directive_block(nil, "2026-10-18") == ""

      running_experiment!(%{
        "directive" => "Prefer questions over page edits.",
        "min_confidence" => "high"
      })

      assert Insights.directive_block(nil, "2026-10-18") ==
               "\n\n## Experiment directive (memory.insight_synthesis)\n\n" <>
                 "Prefer questions over page edits.\n"
    end
  end
end
