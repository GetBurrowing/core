defmodule Platform.Orchestration.DeployStageContractTest do
  @moduledoc """
  Pins the `## Deploy Stage Contract` block of the deploying dispatch across
  both render paths (the seeded `dispatch.deploying` row and the hardcoded
  fallback) and every deploy strategy (task 01a0e362).

  The contract used to carry two strings that contradicted the ONE-rule
  fix-forward text in the same dispatch's `### Deploy boundaries` section:

    * "- do NOT attempt code fixes during deploy."
    * a verbless blocker line, "- If CI fails or the deploy breaks with
      `task_id=...` and `stage_id=...` if you cannot make forward progress.",
      produced by passing a conditional as `report_blocker_instruction/3`'s
      old `prefix` argument.

  The contract is spliced in as code after either render path, so it is the
  one part of the dispatch that is the same on every install. Every expected
  string below is a LITERAL in this file, never derived from a descriptor or
  from rendering, so a change to the source cannot move the expectation with it.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Orchestration.PromptTemplate
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo

  @slug "dispatch.deploying"

  @retired_literals [
    "do NOT attempt code fixes",
    "If CI fails or the deploy breaks"
  ]

  @verbless_blocker_line ~r/^- If CI fails.*with `task_id=/m

  @required_literals [
    "A red CI follows the ONE rule",
    "and status `in_progress`",
    "- Use `report_blocker` with",
    "only when the deploy itself cannot proceed"
  ]

  @strategies [
    "pr_merge",
    "docker_deploy",
    "project_files",
    "email",
    "skill_driven",
    "manual",
    "no_op_wait_for_rollup",
    "unknown_strategy_x"
  ]

  # Forms in which a line may legitimately mention report_blocker: each one
  # carries a verb.
  @report_blocker_verb_forms [
    "Use `report_blocker`",
    "Use report_blocker",
    "Do NOT call `report_blocker`",
    "Do NOT file `report_blocker`",
    "report_blocker with task_id="
  ]

  defp task_for(type) do
    %{
      id: "task-contract-#{type}",
      title: "Deploy contract #{type}",
      description: "Ship it",
      status: "deploying",
      priority: "high",
      deploy_strategy: %{"type" => type, "config" => %{}},
      project: %{repo_url: "https://github.com/test/app", default_branch: "main"},
      stack_id: nil
    }
  end

  defp stage_for(type) do
    %{
      id: "stage-contract-#{type}",
      position: 2,
      name: "Deploy",
      validations: [%{id: "val-contract-#{type}", kind: "pr_merged"}]
    }
  end

  defp render(type) do
    HeartbeatScheduler.dispatch_prompt(
      task_for(type),
      %{version: 1, stages: [%{}, %{}]},
      stage_for(type)
    )
  end

  # Controls first, then the refutes, so a mutant that re-introduces a
  # retired string fails on the refute that names it.
  defp assert_contract(prompt, type, path) do
    assert prompt =~ "## Deploy Stage Contract",
           "#{path} / #{type}: no Deploy Stage Contract section"

    for literal <- @required_literals do
      assert prompt =~ literal,
             "#{path} / #{type}: required contract text missing: #{inspect(literal)}"
    end

    for literal <- @retired_literals do
      refute prompt =~ literal,
             "#{path} / #{type}: retired contract text present: #{inspect(literal)}"
    end

    refute Regex.match?(@verbless_blocker_line, prompt),
           "#{path} / #{type}: verbless `- If CI fails ... with `task_id=` blocker line present"
  end

  # The "## Deploy Stage Contract" section, up to the next `## ` heading or the
  # attention-signal anchor, whichever comes first.
  defp deploy_contract_section(prompt) do
    [_, rest] = String.split(prompt, "## Deploy Stage Contract", parts: 2)

    Enum.reduce(["\n## ", "\nThe attention signal"], rest, fn anchor, acc ->
      acc |> String.split(anchor, parts: 2) |> hd()
    end)
  end

  defp strip_deploy_boundaries(content) do
    String.replace(content, ~r/### Deploy boundaries\n.*?\n\n/s, "")
  end

  describe "row path (seeded dispatch.deploying)" do
    test "every strategy renders the rewritten contract and no retired text" do
      :ok = PromptTemplates.seed_defaults()

      assert {:ok, _} = PromptTemplates.render_template(@slug, %{}),
             "precondition: the dispatch.deploying row must be seeded"

      for type <- @strategies, do: assert_contract(render(type), type, "row")
    end
  end

  describe "fallback path (no dispatch.deploying row)" do
    test "every strategy renders the rewritten contract and no retired text" do
      :ok = PromptTemplates.seed_defaults()
      Repo.delete_all(from(t in PromptTemplate, where: t.slug == ^@slug))

      assert {:error, :not_found} = PromptTemplates.render_template(@slug, %{}),
             "precondition: the dispatch.deploying row must be absent"

      for type <- @strategies, do: assert_contract(render(type), type, "fallback")
    end
  end

  describe "hand-edited row without the Deploy boundaries section" do
    test "the contract alone still carries the ONE rule for a red CI" do
      :ok = PromptTemplates.seed_defaults()

      %PromptTemplate{content: content} = PromptTemplates.get_template_by_slug(@slug)
      assert content =~ "there is ONE rule", "precondition: seeded row carries the ONE rule"

      stripped = strip_deploy_boundaries(content)

      {1, _} =
        Repo.update_all(from(t in PromptTemplate, where: t.slug == ^@slug),
          set: [content: stripped]
        )

      stored = PromptTemplates.get_template_by_slug(@slug).content

      refute stored =~ "there is ONE rule",
             "precondition: the hand-edited row no longer carries Deploy boundaries"

      prompt = render("pr_merge")

      assert prompt =~ "A red CI follows the ONE rule"
      assert prompt =~ "and status `in_progress`"

      for literal <- @retired_literals do
        refute prompt =~ literal, "retired contract text present: #{inspect(literal)}"
      end
    end
  end

  # Scoped to the Deploy Stage Contract section, not the whole prompt. Over
  # the whole prompt two pre-existing preamble lines fall outside the verb
  # forms below while still carrying a verb: the ack preamble's "Do NOT use
  # `report_blocker(needs_human: false)`" and the blocker-discipline line
  # "Before you call `report_blocker` you must have done all three". Neither
  # is verbless, and neither is this task's text (task 01a0e362 stage 2).
  describe "every report_blocker line in the Deploy Stage Contract carries a verb" do
    test "pr_merge render on the row path" do
      :ok = PromptTemplates.seed_defaults()

      lines =
        "pr_merge"
        |> render()
        |> deploy_contract_section()
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "report_blocker"))

      assert lines != [], "expected at least one line mentioning report_blocker"

      verbless =
        Enum.reject(lines, fn line ->
          Enum.any?(@report_blocker_verb_forms, &String.contains?(line, &1))
        end)

      assert verbless == [],
             "report_blocker lines without a verb form:\n" <> Enum.join(verbless, "\n")
    end
  end
end
