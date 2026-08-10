defmodule Platform.Experiments.PromotionTest do
  @moduledoc """
  Tests for `Platform.Experiments.Promotion` (task 019fe6ba, ADR-0048).

  The properties under test are the ones that fail silently: a snapshot
  taken outside the transaction (present only when nothing went wrong), an
  audit event with a payload too vague to review, and a revert that restores
  something merely similar to the original.
  """

  use Platform.DataCase, async: true

  alias Platform.Audit
  alias Platform.Experiments
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Metric.Result
  alias Platform.Experiments.Promotion
  alias Platform.Experiments.Promotion.Refusal
  alias Platform.Experiments.PromptTemplateHistory
  alias Platform.Experiments.Variant
  alias Platform.Orchestration.PromptTemplate

  @original "ORIGINAL template body, verbatim, with trailing detail.\n"
  @winner "WINNING variant body — measurably different.\n"

  defp insert_template(content \\ @original) do
    %PromptTemplate{}
    |> PromptTemplate.changeset(%{
      slug: "tpl-#{System.unique_integer([:positive])}",
      name: "Planner",
      content: content
    })
    |> Repo.insert!()
  end

  defp running_experiment(template, attrs \\ %{}) do
    {:ok, experiment} =
      Experiments.create_experiment(
        Map.merge(
          %{slug: "exp-#{System.unique_integer([:positive])}", name: "Shorter preamble"},
          attrs
        )
      )

    {:ok, experiment} = Experiments.activate(experiment, template)

    {:ok, variant} =
      Experiments.add_variant(experiment, %{slug: "treatment", content: @winner, weight: 1})

    {experiment, variant}
  end

  defp history_rows(template) do
    Repo.all(from(h in PromptTemplateHistory, where: h.template_id == ^template.id))
  end

  defp promotion_events do
    Audit.list(event_type: Promotion.promoted_event_type())
  end

  describe "promote/2 happy path" do
    test "snapshots, updates the content, and records the audit event" do
      template = insert_template()
      {experiment, variant} = running_experiment(template)

      assert {:ok, %{template: promoted, history: history, event: event}} =
               Promotion.promote(experiment,
                 variant: variant,
                 actor_type: "user",
                 result: %Result{value: 0.18, n: 41, unit: :ratio}
               )

      # The content moved.
      assert promoted.content == @winner
      assert Repo.get!(PromptTemplate, template.id).content == @winner

      # The snapshot holds what the template said BEFORE, byte for byte.
      assert [persisted_history] = history_rows(template)
      assert persisted_history.id == history.id
      assert history.content == @original
      assert history.promotion_experiment_id == experiment.id

      # The five named payload fields. Asserted by name: an event whose
      # payload is vague is an unreviewable change to every agent's
      # behaviour.
      assert event.event_type == Promotion.promoted_event_type()
      assert event.metadata["template_slug"] == template.slug
      assert event.metadata["experiment_id"] == experiment.id
      assert event.metadata["winning_variant"] == "treatment"
      assert event.metadata["effect"] == 0.18
      assert event.metadata["n"] == 41

      assert [persisted] = promotion_events()
      assert persisted.id == event.id
    end

    test "accepts the winning variant by slug" do
      template = insert_template()
      {experiment, _variant} = running_experiment(template)

      assert {:ok, %{template: promoted}} =
               Promotion.promote(experiment, variant: "treatment", effect: 0.1, n: 40)

      assert promoted.content == @winner
    end

    test "refuses a variant slug the experiment does not have" do
      template = insert_template()
      {experiment, _variant} = running_experiment(template)

      assert {:error, :variant_not_found} =
               Promotion.promote(experiment, variant: "nope", effect: 0.1, n: 40)

      assert Repo.get!(PromptTemplate, template.id).content == @original
      assert history_rows(template) == []
    end
  end

  describe "promote/2 auto trigger" do
    test "manual and auto promotion go through the same entry point" do
      template = insert_template()
      {experiment, variant} = running_experiment(template)

      experiment =
        experiment
        |> Experiment.changeset(%{auto_promote: true})
        |> Repo.update!()

      assert {:ok, %{event: event}} =
               Promotion.promote(experiment, variant: variant, trigger: :auto, effect: 0.2, n: 55)

      assert event.metadata["trigger"] == "auto"
      assert event.actor_type == "system"
      assert Repo.get!(PromptTemplate, template.id).content == @winner
    end

    test "auto promotion is off by default and is refused" do
      template = insert_template()
      {experiment, variant} = running_experiment(template)

      # The default is the thing under test: nothing set the flag.
      refute Repo.get!(Experiment, experiment.id).auto_promote

      assert {:error, :auto_promotion_disabled} =
               Promotion.promote(experiment, variant: variant, trigger: :auto, effect: 0.2, n: 55)

      assert Repo.get!(PromptTemplate, template.id).content == @original
      assert history_rows(template) == []
      assert promotion_events() == []
    end
  end

  describe "promote/2 forced failure partway" do
    test "a failure AFTER the history insert leaves no snapshot and no content change" do
      template = insert_template()
      {experiment, _variant} = running_experiment(template)

      # Force step (b) to fail: a winning variant whose blob is nil makes
      # the template changeset invalid at update time, which is strictly
      # after the history insert has already succeeded inside the multi.
      # Forced, not assumed — the point is to reach the second step.
      poisoned = %Variant{slug: "treatment", content: nil, experiment_id: experiment.id}

      assert {:error, %Ecto.Changeset{} = changeset} =
               Promotion.promote(experiment, variant: poisoned, effect: 0.3, n: 60)

      refute changeset.valid?

      # Both halves. Either one alone would pass with a snapshot written
      # outside the transaction.
      assert history_rows(template) == []
      assert Repo.get!(PromptTemplate, template.id).content == @original
      assert promotion_events() == []
    end

    test "the poisoned fixture would otherwise have written a history row" do
      # Anti-vacuity: prove the failing run actually reached the insert by
      # showing the same fixture, unpoisoned, writes exactly one row.
      template = insert_template()
      {experiment, variant} = running_experiment(template)

      assert {:ok, _} = Promotion.promote(experiment, variant: variant, effect: 0.3, n: 60)
      assert [_one] = history_rows(template)
    end
  end

  # ── Guardrails ─────────────────────────────────────────────────────────

  defp assign_subjects(experiment, count) do
    for _ <- 1..count do
      {:ok, assignment} =
        Experiments.Assignments.assign_once(experiment, {"task", Ecto.UUID.generate()})

      assignment
    end
  end

  describe "guard 1 — the stop rule" do
    test "refuses below the stop rule, carrying observed and required as integers" do
      template = insert_template()
      {experiment, variant} = running_experiment(template, %{stop_rule: %{"min_subjects" => 40}})
      assign_subjects(experiment, 12)

      assert {:error, %Refusal{} = refusal} =
               Promotion.promote(experiment, variant: variant, effect: 0.2, n: 12)

      assert refusal.reason == :insufficient_data

      # Discrete fields, not a sentence to parse. The UI renders
      # "12 of 40 subjects" from these two integers.
      assert refusal.observed_subjects == 12
      assert refusal.required_subjects == 40
      assert is_integer(refusal.observed_subjects)
      assert is_integer(refusal.required_subjects)

      assert Repo.get!(PromptTemplate, template.id).content == @original
      assert history_rows(template) == []
      assert promotion_events() == []
    end

    test "an experiment that has reached its stop rule promotes" do
      # Anti-vacuity for the test above: the same fixture with enough
      # subjects goes through, so the refusal is about the count and not
      # about the fixture being broken.
      template = insert_template()
      {experiment, variant} = running_experiment(template, %{stop_rule: %{"min_subjects" => 5}})
      assign_subjects(experiment, 5)

      assert {:ok, %{template: promoted}} =
               Promotion.promote(experiment, variant: variant, effect: 0.2, n: 5)

      assert promoted.content == @winner
    end

    test "excluded subjects do not count toward the stop rule" do
      template = insert_template()
      {experiment, variant} = running_experiment(template, %{stop_rule: %{"min_subjects" => 3}})
      [first | _] = assign_subjects(experiment, 3)

      {:ok, _} =
        Experiments.Assignments.exclude(
          experiment,
          {first.subject_type, first.subject_id},
          "bad run"
        )

      assert {:error, %Refusal{reason: :insufficient_data} = refusal} =
               Promotion.promote(experiment, variant: variant, effect: 0.2, n: 2)

      assert refusal.observed_subjects == 2
    end

    test "the stop-rule refusal is overridable with an explicit option and an actor" do
      template = insert_template()
      {experiment, variant} = running_experiment(template, %{stop_rule: %{"min_subjects" => 40}})
      assign_subjects(experiment, 12)

      actor_id = Ecto.UUID.generate()

      assert {:ok, %{template: promoted, event: event}} =
               Promotion.promote(experiment,
                 variant: variant,
                 override: true,
                 actor_id: actor_id,
                 effect: 0.2,
                 n: 12
               )

      assert promoted.content == @winner

      # Recorded AS an override. An override indistinguishable from an
      # ordinary promotion is not an audit trail.
      assert event.metadata["override"] == true
      assert event.metadata["override_actor_id"] == actor_id
      assert event.metadata["override_observed_subjects"] == 12
      assert event.metadata["override_required_subjects"] == 40
    end

    test "an ordinary promotion is not flagged as an override" do
      # The absence assertion needs its own side, or the one above passes
      # against a module that stamps every event with override: true.
      template = insert_template()
      {experiment, variant} = running_experiment(template, %{stop_rule: %{"min_subjects" => 2}})
      assign_subjects(experiment, 2)

      assert {:ok, %{event: event}} =
               Promotion.promote(experiment, variant: variant, effect: 0.2, n: 2)

      refute Map.has_key?(event.metadata, "override")
    end

    test "override: true without an actor is not an override" do
      template = insert_template()
      {experiment, variant} = running_experiment(template, %{stop_rule: %{"min_subjects" => 40}})
      assign_subjects(experiment, 12)

      assert {:error, %Refusal{reason: :insufficient_data}} =
               Promotion.promote(experiment, variant: variant, override: true, effect: 0.2, n: 12)
    end
  end

  describe "guard 2 — the cooldown" do
    test "refuses a second promotion inside the window, with an absolute date" do
      template = insert_template()
      {experiment, variant} = running_experiment(template)

      assert {:ok, _} = Promotion.promote(experiment, variant: variant, effect: 0.2, n: 40)

      {second, second_variant} = running_experiment(Repo.get!(PromptTemplate, template.id))

      assert {:error, %Refusal{} = refusal} =
               Promotion.promote(second, variant: second_variant, effect: 0.3, n: 40)

      assert refusal.reason == :cooldown_active
      assert %Date{} = refusal.available_from
      assert %DateTime{} = refusal.last_promoted_at
      assert refusal.cooldown_days == 14

      # The date is the last promotion plus the window — a value a reader
      # can put in a calendar, not a countdown that goes stale on a page
      # left open.
      assert refusal.available_from ==
               Date.add(DateTime.to_date(refusal.last_promoted_at), 14)

      assert Date.compare(refusal.available_from, Date.utc_today()) == :gt
    end

    test "override: true does NOT bypass the cooldown" do
      template = insert_template()
      {experiment, variant} = running_experiment(template)

      assert {:ok, _} = Promotion.promote(experiment, variant: variant, effect: 0.2, n: 40)

      {second, second_variant} = running_experiment(Repo.get!(PromptTemplate, template.id))

      assert {:error, %Refusal{reason: :cooldown_active}} =
               Promotion.promote(second,
                 variant: second_variant,
                 override: true,
                 actor_id: Ecto.UUID.generate(),
                 effect: 0.3,
                 n: 40
               )

      # And the refusal actually held: the content is still the first
      # promotion's blob, not the second experiment's.
      assert Repo.get!(PromptTemplate, template.id).content == @winner
      assert [_only_one] = history_rows(template)
    end
  end

  describe "guard 3 — the multi-metric gate" do
    test "refuses a 6% regression over a large n and NAMES the metric" do
      template = insert_template()
      {experiment, variant} = running_experiment(template)

      assert {:error, %Refusal{} = refusal} =
               Promotion.promote(experiment,
                 variant: variant,
                 effect: 0.2,
                 n: 40,
                 secondary_results: [
                   {"cycle_time", %Result{value: -0.06, n: 34, unit: :ratio}}
                 ]
               )

      assert refusal.reason == :secondary_metric_regressed

      # "a secondary metric regressed" is unactionable. The UI renders
      # "cycle time regressed 6% over 34 subjects" from these three.
      assert refusal.metric == "cycle_time"
      assert refusal.delta == -0.06
      assert refusal.n == 34
      assert refusal.threshold == 0.05

      assert Repo.get!(PromptTemplate, template.id).content == @original
      assert history_rows(template) == []
    end

    test "override: true does NOT bypass the metric gate" do
      template = insert_template()
      {experiment, variant} = running_experiment(template)

      assert {:error, %Refusal{reason: :secondary_metric_regressed}} =
               Promotion.promote(experiment,
                 variant: variant,
                 override: true,
                 actor_id: Ecto.UUID.generate(),
                 effect: 0.2,
                 n: 40,
                 secondary_results: [{"cycle_time", %Result{value: -0.06, n: 34, unit: :ratio}}]
               )

      assert Repo.get!(PromptTemplate, template.id).content == @original
    end

    test "the same 6% over 5 subjects promotes, and the audit event keeps the regression" do
      template = insert_template()
      {experiment, variant} = running_experiment(template)

      assert {:ok, %{event: event}} =
               Promotion.promote(experiment,
                 variant: variant,
                 effect: 0.2,
                 n: 40,
                 secondary_results: [
                   {"cycle_time", %Result{value: -0.06, n: 5, unit: :ratio}}
                 ]
               )

      assert Repo.get!(PromptTemplate, template.id).content == @winner

      # Not blocking is not the same as not recorded: an
      # override-by-small-sample has to be reviewable afterwards.
      assert [ignored] = event.metadata["ignored_regressions"]
      assert ignored["metric"] == "cycle_time"
      assert ignored["delta"] == -0.06
      assert ignored["n"] == 5
    end

    test "a regression under the 5% limit neither blocks nor is recorded as ignored" do
      template = insert_template()
      {experiment, variant} = running_experiment(template)

      assert {:ok, %{event: event}} =
               Promotion.promote(experiment,
                 variant: variant,
                 effect: 0.2,
                 n: 40,
                 secondary_results: [{"cycle_time", %Result{value: -0.02, n: 100, unit: :ratio}}]
               )

      refute Map.has_key?(event.metadata, "ignored_regressions")
    end

    test "an IMPROVING secondary metric of the same magnitude never blocks" do
      # The gate is about regression, not about movement. A +6% secondary
      # over a large n must go through, or the gate refuses good news.
      template = insert_template()
      {experiment, variant} = running_experiment(template)

      assert {:ok, %{template: promoted}} =
               Promotion.promote(experiment,
                 variant: variant,
                 effect: 0.2,
                 n: 40,
                 secondary_results: [{"cycle_time", %Result{value: 0.06, n: 34, unit: :ratio}}]
               )

      assert promoted.content == @winner
    end
  end

  describe "sticky assignment" do
    test "an in-flight subject keeps its PRE-promotion variant" do
      template = insert_template()
      {experiment, variant} = running_experiment(template)

      subject = {"task", Ecto.UUID.generate()}
      {:ok, assignment} = Experiments.Assignments.assign_once(experiment, subject)
      before_slug = assignment.variant_slug

      assert {:ok, _} = Promotion.promote(experiment, variant: variant, effect: 0.2, n: 40)

      after_assignment = Experiments.Assignments.get_assignment(experiment, subject)

      # The row itself, not merely a re-resolution: an update that rewrote
      # variant_slug in place would still "resolve" consistently.
      assert after_assignment.id == assignment.id
      assert after_assignment.variant_slug == before_slug
      assert after_assignment.assigned_at == assignment.assigned_at
      assert after_assignment.updated_at == assignment.updated_at
    end

    test "the promotion path contains no update or delete against assignments" do
      # A source check, because the behavioural test above can only observe
      # the assignments the fixture happened to create.
      source = File.read!("lib/platform/experiments/promotion.ex")

      refute source =~ ~r/Assignment[^\n]*\|>[^\n]*Repo\.(update|delete)/
      refute source =~ ~r/Repo\.(update_all|delete_all)/
      refute source =~ ~r/Assignment\.changeset/
    end
  end

  describe "revert/2" do
    test "restores the pre-promotion content byte for byte" do
      template = insert_template()
      original = template.content
      {experiment, variant} = running_experiment(template)

      assert {:ok, %{history: history}} =
               Promotion.promote(experiment, variant: variant, effect: 0.4, n: 70)

      assert Repo.get!(PromptTemplate, template.id).content == @winner

      assert {:ok, reverted} = Promotion.revert(history)

      restored = Repo.get!(PromptTemplate, template.id).content

      # Byte equality, not `=~`: a substring match cannot detect a longer
      # value, and "close enough" is not a revert.
      assert restored == original
      assert reverted.content == original
    end
  end
end
