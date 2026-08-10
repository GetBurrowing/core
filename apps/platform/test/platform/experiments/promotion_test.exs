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
