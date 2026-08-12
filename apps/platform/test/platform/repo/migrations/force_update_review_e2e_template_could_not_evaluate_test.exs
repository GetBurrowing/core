defmodule Platform.Repo.Migrations.ForceUpdateReviewE2eTemplateCouldNotEvaluateTest do
  @moduledoc """
  Coverage for `20260812230100_force_update_review_e2e_template_could_not_evaluate`
  (task 019ff788 stage 3).

  READ THIS BEFORE ADDING AN ASSERTION — the obvious one is vacuous. In the
  test database the `dispatch.review_e2e` row is created by
  `20260324200001_seed_prompt_templates` running `seed_defaults/0` against the
  CURRENT code, so `row.content =~ "could_not_evaluate"` passes with this
  migration file DELETED. Every test below therefore stales the live row first
  (modelling a deployed environment whose row predates the change) and asserts
  the delta `up/0` produces.

  The last test is the one the stage spec demands by name: the served row and
  `HeartbeatScheduler`'s hardcoded fallback must BOTH carry the distinction.
  Either encoding alone recreates exactly the divergence this ticket fixes —
  an agent served the fallback would have no way to say "I could not run it",
  and would spend a round of the bound on a broken environment.
  """

  use Platform.DataCase, async: false

  alias Platform.Orchestration.PromptTemplates
  alias Platform.Tasks.ReviewDisposition

  @moduletag :regression

  @slug "dispatch.review_e2e"

  @migration_module Platform.Repo.Migrations.ForceUpdateReviewE2eTemplateCouldNotEvaluate

  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260812230100_force_update_review_e2e_template_could_not_evaluate.exs"
                  ])

  @stale_content "STALE E2E BODY {{pending_e2e_validations_json}} — two verdicts only."

  setup do
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration_path)
    end

    :ok
  end

  defp stale_the_row! do
    template = PromptTemplates.get_template_by_slug(@slug)
    refute is_nil(template), "#{@slug} must be seeded before this test can stale it"

    {:ok, staled} = PromptTemplates.update_template(template, %{content: @stale_content})

    # Before-state asserted, not assumed.
    refute staled.content =~ ReviewDisposition.marker()

    staled
  end

  describe "up/0 against a deployed-shaped (stale) row" do
    test "teaches the served row how to say \"could not evaluate\"" do
      stale_the_row!()

      assert :ok = @migration_module.up()

      reloaded = PromptTemplates.get_template_by_slug(@slug)

      assert reloaded.content =~ ReviewDisposition.marker()

      assert reloaded.content =~ ReviewDisposition.reason_key(),
             "the marker without a mandatory reason is counted as a genuine failure, " <>
               "so a body that names one but not the other misinstructs the reviewer"

      assert reloaded.content =~ "does NOT spend",
             "the reviewer needs the consequence, not just the syntax"

      refute reloaded.content == @stale_content
    end

    test "writes exactly the shipped descriptor body" do
      stale_the_row!()
      assert :ok = @migration_module.up()

      assert PromptTemplates.get_template_by_slug(@slug).content ==
               PromptTemplates.default_content_for_slug(@slug),
             "the frozen literal in the migration has drifted from the descriptor — " <>
               "the suite pins these equal, so one of the two was edited alone"
    end

    test "is idempotent" do
      stale_the_row!()

      assert :ok = @migration_module.up()
      first = PromptTemplates.get_template_by_slug(@slug).content

      assert :ok = @migration_module.up()
      assert PromptTemplates.get_template_by_slug(@slug).content == first
    end

    test "leaves the dispatch.in_review row alone" do
      before = PromptTemplates.get_template_by_slug("dispatch.in_review")
      refute is_nil(before)

      {:ok, _} =
        PromptTemplates.update_template(before, %{content: "IN_REVIEW SENTINEL {{task_title}}"})

      stale_the_row!()
      assert :ok = @migration_module.up()

      assert PromptTemplates.get_template_by_slug("dispatch.in_review").content ==
               "IN_REVIEW SENTINEL {{task_title}}"
    end
  end

  describe "up/0 when the row is absent" do
    test "skips without raising and does not create the row" do
      template = PromptTemplates.get_template_by_slug(@slug)
      {:ok, _} = PromptTemplates.delete_template(template)

      assert :ok = @migration_module.up()

      assert is_nil(PromptTemplates.get_template_by_slug(@slug)),
             "up/0 must skip an absent row — seed_defaults/0 owns first boot"
    end
  end

  describe "the served row and the hardcoded fallback say the same thing" do
    test "both carry the marker, the mandatory reason, and the round consequence" do
      stale_the_row!()
      assert :ok = @migration_module.up()

      served = PromptTemplates.get_template_by_slug(@slug).content
      fallback = hardcoded_review_e2e_body()

      for text <- [served, fallback], phrase <- [ReviewDisposition.marker(), "reason", "round"] do
        assert text =~ phrase,
               "both the served template and the hardcoded fallback must state " <>
                 "#{inspect(phrase)}; one encoding alone IS the divergence this ticket fixes"
      end
    end
  end

  # Render the fallback by deleting the row, which is the only condition under
  # which `HeartbeatScheduler` reaches its hardcoded body. Reading the source
  # file instead would assert about a string literal rather than about what an
  # agent is served.
  defp hardcoded_review_e2e_body do
    template = PromptTemplates.get_template_by_slug(@slug)
    {:ok, _} = PromptTemplates.delete_template(template)

    assert {:error, :not_found} = PromptTemplates.render_template(@slug, %{})

    task = %{
      id: "00000000-0000-0000-0000-0000000000aa",
      title: "Fallback fixture task",
      description: "Fallback fixture description",
      status: "in_review",
      priority: "high"
    }

    plan = %{id: "00000000-0000-0000-0000-0000000000bb", version: 1, stages: []}

    stage = %{
      id: "00000000-0000-0000-0000-0000000000cc",
      name: "Review",
      description: "Fallback fixture stage description",
      position: 1,
      status: "running",
      validations: [%{id: "val-1", kind: "e2e_behavior", status: "pending"}]
    }

    Platform.Orchestration.HeartbeatScheduler.dispatch_prompt(task, plan, stage)
  end
end
