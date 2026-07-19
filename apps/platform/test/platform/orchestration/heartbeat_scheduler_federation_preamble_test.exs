defmodule Platform.Orchestration.HeartbeatSchedulerFederationPreambleTest do
  @moduledoc """
  Stage 2 of task 019f5e2a — verifies `HeartbeatScheduler.dispatch_prompt/4`
  wires `federation_preamble: PromptTemplates.federation_preamble()` into
  the assigns map for every dispatch branch (planning, in_progress,
  in_review, deploying, fallback).

  The assertion strategy is forward-compatible with the Stage 3 retrofit:
  we set up a probe DB template per dispatch slug whose only content is the
  `{{federation_preamble}}` placeholder, then call `dispatch_prompt/4` and
  assert the rendered output contains `## Subagent-spawn discipline` — a
  stable anchor from Stage 1's preamble. This proves the assigns builder
  supplied a non-empty value under the `federation_preamble` key without
  depending on whether the real dispatch.* templates have been retrofitted
  to reference the placeholder yet (that's Stage 3).
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Orchestration.PromptTemplate
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo

  @dispatch_slugs ~w(
    dispatch.planning
    dispatch.in_progress
    dispatch.in_review
    dispatch.deploying
    dispatch.fallback
  )

  setup do
    # Force each dispatch.* slug to a probe template whose content is just
    # the `{{federation_preamble}}` placeholder. If Stage 3 has already
    # retrofitted the descriptor, this test still exercises the same
    # assigns-builder path (the assign key is unchanged); the probe just
    # gives us an unambiguous anchor to assert on.
    for slug <- @dispatch_slugs do
      case Repo.get_by(PromptTemplate, slug: slug) do
        nil ->
          {:ok, _} =
            PromptTemplates.create_template(%{
              slug: slug,
              name: "Federation preamble probe (#{slug})",
              description: "Test probe for federation_preamble assigns wiring",
              variables: ["federation_preamble"],
              content: "{{federation_preamble}}\n"
            })

        existing ->
          {:ok, _} =
            PromptTemplates.update_template(existing, %{content: "{{federation_preamble}}\n"})
      end
    end

    :ok
  end

  describe "dispatch_prompt/4 wires federation_preamble into assigns" do
    test "planning branch resolves the preamble placeholder" do
      task = %{
        id: "task-planning-1",
        title: "Planning probe",
        description: "Planning branch probe task",
        status: "planning",
        priority: "medium"
      }

      output = HeartbeatScheduler.dispatch_prompt(task, nil, nil)

      assert output =~ "## Subagent-spawn discipline",
             "planning dispatch must include the federation preamble via {{federation_preamble}}"

      refute output =~ "{{federation_preamble}}",
             "planning dispatch must resolve the placeholder, not emit it verbatim"
    end

    test "in_progress branch resolves the preamble placeholder" do
      task = %{
        id: "task-in-progress-1",
        title: "In-progress probe",
        description: "In-progress branch probe task",
        status: "in_progress",
        priority: "medium",
        project: %{repo_url: "https://github.com/test/repo", default_branch: "main"}
      }

      plan = %{version: 1, stages: [%{}]}

      stage = %{
        id: "stage-abc123",
        position: 1,
        name: "coding",
        validations: [%{id: "val-1", kind: "test_pass"}]
      }

      output = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert output =~ "## Subagent-spawn discipline",
             "in_progress dispatch must include the federation preamble via {{federation_preamble}}"

      refute output =~ "{{federation_preamble}}"
    end

    test "in_review branch resolves the preamble placeholder" do
      task = %{
        id: "task-in-review-1",
        title: "In-review probe",
        description: "In-review branch probe task",
        status: "in_review",
        priority: "medium",
        project: %{repo_url: "https://github.com/test/repo", default_branch: "main"}
      }

      plan = %{version: 1, stages: [%{}]}

      stage = %{
        id: "stage-review-1",
        position: 1,
        name: "review",
        validations: [%{id: "val-1", kind: "manual_approval"}]
      }

      output = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert output =~ "## Subagent-spawn discipline",
             "in_review dispatch must include the federation preamble via {{federation_preamble}}"

      refute output =~ "{{federation_preamble}}"
    end

    test "deploying branch resolves the preamble placeholder" do
      task = %{
        id: "task-deploying-1",
        title: "Deploying probe",
        description: "Deploying branch probe task",
        status: "deploying",
        priority: "medium",
        project: %{repo_url: "https://github.com/test/repo", default_branch: "main"}
      }

      plan = %{version: 1, stages: [%{}]}

      stage = %{
        id: "stage-deploy-1",
        position: 1,
        name: "deploy",
        validations: [%{id: "val-1", kind: "pr_merged"}]
      }

      output = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert output =~ "## Subagent-spawn discipline",
             "deploying dispatch must include the federation preamble via {{federation_preamble}}"

      refute output =~ "{{federation_preamble}}"
    end

    test "fallback branch resolves the preamble placeholder" do
      task = %{
        id: "task-fallback-1",
        title: "Fallback probe",
        description: "Fallback branch probe task",
        status: "backlog",
        priority: "medium"
      }

      output = HeartbeatScheduler.dispatch_prompt(task, nil, nil)

      assert output =~ "## Subagent-spawn discipline",
             "fallback dispatch must include the federation preamble via {{federation_preamble}}"

      refute output =~ "{{federation_preamble}}"
    end
  end
end
