defmodule Platform.Orchestration.HeartbeatSchedulerFeedbackTest do
  @moduledoc """
  Task 01a11ec3 stage 2: the assigns `HeartbeatScheduler` builds for every
  task dispatch and for the nudge carry `feedback_guidance` from the same
  capability predicate `ToolSurface` lists `feedback_submit` under, so a
  dispatch advertises the tool exactly when the receiving agent can call it.

  Rendered through the real entry points (`dispatch_prompt/4`,
  `nudge_prompt/3`) against seeded rows, and for the nudge also through the
  hardcoded fallback taken when its row is missing. Each seeded row is the
  SHIPPED descriptor, written in setup, so the result does not depend on the
  age of the test database (see `heartbeat_scheduler_stage_description_test`).

  Written before the implementation: against the unfixed base the enabled
  renders fail (nothing supplies the guidance) and the disabled renders
  cannot set the policy module's key meaningfully.

  async: false — flips `:feedback_policy` and rewrites seeded template rows.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Orchestration.PromptTemplate
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo

  @slugs ~w(dispatch.planning dispatch.in_progress dispatch.in_review dispatch.review_e2e dispatch.deploying dispatch.fallback nudge)

  setup do
    saved = Application.fetch_env(:platform, :feedback_policy)

    on_exit(fn ->
      case saved do
        {:ok, v} -> Application.put_env(:platform, :feedback_policy, v)
        :error -> Application.delete_env(:platform, :feedback_policy)
      end
    end)

    for slug <- @slugs do
      descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == slug))

      case Repo.get_by(PromptTemplate, slug: slug) do
        nil ->
          {:ok, _} = PromptTemplates.create_template(descriptor)

        row ->
          {:ok, _} =
            PromptTemplates.update_template(row, %{
              content: descriptor.content,
              variables: descriptor.variables
            })
      end
    end

    :ok
  end

  defp set_policy(value), do: Application.put_env(:platform, :feedback_policy, value)

  defp task(status) do
    %{
      id: "01a11ec3-6566-7001-8047-544e77a39d68",
      title: "Feedback guidance fixture",
      description: "Fixture body.",
      status: status,
      priority: "medium",
      project: %{repo_url: "https://github.com/test/router", default_branch: "main"}
    }
  end

  defp stage(name, kind) do
    %{
      id: "01a11f32-c312-7002-98f2-259a7211ab53",
      position: 1,
      name: name,
      status: "running",
      description: "Stage body.",
      started_at: DateTime.add(DateTime.utc_now(), -300, :second),
      validations: [
        %{
          id: "01a11f32-c312-7003-bed6-7a53171580b1",
          kind: kind,
          status: "pending",
          evaluation_payload: %{"setup" => "s", "actions" => "a", "expected" => "e"}
        }
      ]
    }
  end

  defp plan(stage), do: %{version: 1, stages: [stage]}

  defp dispatches do
    in_progress = stage("Implement", "test_pass")
    in_review = stage("Review", "manual_approval")
    review_e2e = stage("Task-level review", "e2e_behavior")
    deploying = stage("Deploy: PR merge", "pr_merged")

    [
      {"planning", fn -> HeartbeatScheduler.dispatch_prompt(task("planning"), nil, nil) end},
      {"in_progress",
       fn ->
         HeartbeatScheduler.dispatch_prompt(task("in_progress"), plan(in_progress), in_progress)
       end},
      {"in_review",
       fn -> HeartbeatScheduler.dispatch_prompt(task("in_review"), plan(in_review), in_review) end},
      {"review_e2e",
       fn ->
         HeartbeatScheduler.dispatch_prompt(task("in_review"), plan(review_e2e), review_e2e)
       end},
      {"deploying",
       fn -> HeartbeatScheduler.dispatch_prompt(task("deploying"), plan(deploying), deploying) end},
      {"fallback", fn -> HeartbeatScheduler.dispatch_prompt(task("todo"), nil, nil) end},
      {"nudge", fn -> HeartbeatScheduler.nudge_prompt(task("in_progress"), in_progress) end}
    ]
  end

  test "every task dispatch and the nudge advertise feedback_submit when enabled" do
    for value <- ["quarantined", "trusted"] do
      set_policy(value)

      for {phase, render} <- dispatches() do
        prompt = render.()
        assert prompt =~ "`feedback_submit`", "#{phase} (#{value}) must advertise feedback_submit"
        refute prompt =~ "{{feedback_guidance}}", "#{phase} left the placeholder unresolved"
      end
    end
  end

  test "no task dispatch or nudge mentions it when disabled" do
    set_policy("disabled")

    for {phase, render} <- dispatches() do
      prompt = render.()
      refute prompt =~ "feedback_submit", "#{phase} advertised a tool the agent cannot call"
      refute prompt =~ "Reporting a defect in Burrow itself"
      refute prompt =~ "{{feedback_guidance}}"
    end
  end

  test "the hardcoded nudge fallback is gated the same way" do
    Repo.delete_all(from(t in PromptTemplate, where: t.slug == "nudge"))
    in_progress = stage("Implement", "test_pass")

    set_policy("quarantined")

    assert HeartbeatScheduler.nudge_prompt(task("in_progress"), in_progress) =~
             "`feedback_submit`"

    set_policy("disabled")
    refute HeartbeatScheduler.nudge_prompt(task("in_progress"), in_progress) =~ "feedback_submit"
  end

  test "the enabled nudge stays inside the short-form budget" do
    set_policy("quarantined")
    prompt = HeartbeatScheduler.nudge_prompt(task("in_progress"), stage("Implement", "test_pass"))
    assert String.length(prompt) < 2000
  end
end
