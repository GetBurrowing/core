defmodule Platform.Orchestration.DispatchAckPreambleDerivationTest do
  @moduledoc """
  The ack-first preamble has ONE source — `PromptTemplates.task_ack_preamble/0`
  (task 019ff45b stage 1). This file guards the derivation that turns that
  constant into the hardcoded fallback body in `HeartbeatScheduler`.

  ## Why this is not part of `dispatch_fallback_parity_test.exs`

  That file asserts a different relation: fallback tool-set ⊇ template tool-set,
  with `normalize_tool_name/1` stripping the `suite_` prefix from both sides on
  purpose. It therefore cannot see wording drift at all, and it compares
  `task_ack` and `suite_task_ack` as EQUAL — which is how the fallback kept the
  bare, non-federated tool names for a week after #712 renamed them.

  ## What is asserted

  1. Every non-placeholder LINE of the single constant appears verbatim in the
     rendered fallback. Reword the constant and the wording travels; delete the
     derivation and this fails naming the line.
  2. No residual `{{`, `__TASK_ID__`, `__STAGE_ID__`, `__SUBAGENT_ID__`. A
     collapse fails silently by leaving a placeholder unsubstituted.
  3. The fixture ids actually appear — otherwise (2) passes vacuously on an
     empty substitution.
  4. Regression pin (task 019fa469 stage 5): the PLANNING fallback carries NO
     ack preamble. A planning dispatch has no running stage, so an ack
     instruction there is one the resolver rejects.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Orchestration.PromptTemplate
  alias Platform.Orchestration.PromptTemplates

  @task_id "00000000-0000-0000-0000-0000000000aa"
  @stage_id "00000000-0000-0000-0000-0000000000cc"

  @sentinels ["{{", "__TASK_ID__", "__STAGE_ID__", "__SUBAGENT_ID__"]

  # The prose subagent slot is substituted away, so its line is compared with
  # the slot removed rather than skipped entirely — skipping the line would
  # stop guarding the rest of that sentence.
  @subagent_slot "<the id returned when you spawned the SuiteExecutor / SuiteReviewer via the Agent tool>"

  setup do
    :ok = PromptTemplates.seed_defaults()
    :ok
  end

  defp task(status) do
    %{
      id: @task_id,
      title: "Ack derivation fixture task",
      description: "Ack derivation fixture description",
      status: status,
      priority: "high"
    }
  end

  defp stage(name) do
    %{
      id: @stage_id,
      name: name,
      description: "Ack derivation fixture stage description",
      position: 1,
      status: "running",
      validations: []
    }
  end

  # Same technique as `fallback_body!/1` in the parity test: delete the row so
  # production's fallback path is the one taken. The sandbox rolls it back.
  defp fallback_body!(slug, {task, plan, stage}) do
    Platform.Repo.delete_all(from(t in PromptTemplate, where: t.slug == ^slug))
    HeartbeatScheduler.dispatch_prompt(task, plan, stage)
  end

  # `deploying`, not `in_progress`. Since task 019ff10f the in_progress and
  # in_review branches DERIVE their row-less body from the source descriptor
  # (`derived_or_hardcoded/3`), so deleting the row there renders the
  # descriptor's mustache form, not the hardcoded body — and the derivation
  # under test never runs. The deploying branch is the one that reaches
  # `render_task_ack_preamble/3`, so that is where this guard has to look. If
  # the deploying branch is ever moved onto `derived_or_hardcoded/3` too, this
  # test's assertion 3 (the sentinel-substituted subagent slot) goes red rather
  # than passing on the wrong body.
  defp hardcoded_fallback do
    task =
      task("deploying")
      |> Map.put(:project, %{
        repo_url: "https://github.com/test/router",
        default_branch: "main",
        deploy_strategy: %{"type" => "manual", "config" => %{}}
      })

    fallback_body!(
      "dispatch.deploying",
      {task, %{id: "00000000-0000-0000-0000-0000000000bb", version: 1, stages: [%{}]},
       stage("deploy")}
    )
  end

  # Split the constant into comparable units: drop blank lines, and rewrite the
  # two substitutions the derivation is ALLOWED to make.
  defp expected_fragments do
    PromptTemplates.task_ack_preamble()
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn line ->
      line
      |> String.replace("{{task_id}}", @task_id)
      |> String.replace("{{stage_id}}", @stage_id)
      |> String.replace(@subagent_slot, "<unknown — spawn a subagent first>")
    end)
  end

  describe "the fallback ack preamble is derived from the single constant" do
    test "every non-placeholder line of task_ack_preamble/0 appears verbatim in the fallback" do
      body = hardcoded_fallback()

      fragments = expected_fragments()

      assert length(fragments) >= 3,
             "split the constant into #{length(fragments)} lines — the splitter is broken, " <>
               "which would make this assertion pass vacuously."

      missing = Enum.reject(fragments, &String.contains?(body, &1))

      assert missing == [],
             """
             The hardcoded fallback body is missing #{length(missing)} line(s) from
             `PromptTemplates.task_ack_preamble/0` — there is ONE constant, so the
             derivation in HeartbeatScheduler.fallback_form/3 is what broke. Missing:

             #{Enum.map_join(missing, "\n\n", &("  " <> &1))}
             """
    end

    test "the derivation is total — no residual placeholder survives" do
      body = hardcoded_fallback()

      residual = Enum.filter(@sentinels, &String.contains?(body, &1))

      assert residual == [],
             "the rendered fallback still carries unsubstituted placeholder(s): " <>
               "#{inspect(residual)} — HeartbeatScheduler.fallback_form/3 did not " <>
               "convert every slot."
    end

    test "the interpolated ids actually appear in the fallback" do
      # Without this, the totality assertion above passes vacuously whenever the
      # substitution produces an empty string.
      body = hardcoded_fallback()

      assert String.contains?(body, ~s(task_id="#{@task_id}")),
             "fixture task_id absent from the rendered fallback"

      assert String.contains?(body, ~s(stage_id="#{@stage_id}")),
             "fixture stage_id absent from the rendered fallback"
    end

    test "the PLANNING fallback still carries no ack preamble" do
      body = fallback_body!("dispatch.planning", {task("planning"), nil, nil})

      refute body =~ "Your first tool call must be",
             "the planning fallback gained the ack preamble — a planning dispatch has " <>
               "no running stage, so an ack instruction there is rejected by the resolver " <>
               "(task 019fa469 stage 5)."

      refute body =~ "suite_task_ack(",
             "the planning fallback names an ack call it cannot make."

      assert body =~ "No ack is expected for this dispatch.",
             "the planning fallback lost `PromptTemplates.planning_no_ack_notice/0`."
    end
  end
end
