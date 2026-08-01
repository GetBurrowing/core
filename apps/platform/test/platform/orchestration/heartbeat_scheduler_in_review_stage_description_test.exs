defmodule Platform.Orchestration.HeartbeatSchedulerInReviewStageDescriptionTest do
  @moduledoc """
  Task 019fba28 stage 3 — the DB-ROW half of the in_review stage-description
  guard.

  WHICH PATH THIS FILE EXERCISES: the seeded `dispatch.in_review` row.
  `PromptTemplates.render_template/2` is tried FIRST and the DB row wins in
  every migrated environment, so a change made only to the hardcoded fallback
  reaches no real agent. The sibling assertions in `heartbeat_scheduler_test.exs`
  run `use ExUnit.Case` with no DB ownership — `render_template/2` rescues its
  Repo call there and every `dispatch_prompt/4` silently takes the HARDCODED
  FALLBACK — so those cover the other branch and only the other branch.

  The setup deliberately writes the SHIPPED DEFAULT body into the live row
  before rendering, for the same two reasons stage 1's sibling file gives:
  determinism (the row in this database may predate the branch) and honesty
  about what is proved (asserting a LITERAL sentinel in the rendered output
  tests the descriptor body, the assigns wiring and `interpolate/2` end to end,
  and is NOT the vacuous `content == default_content_for_slug(slug)` shape).

  Getting that default body into a REAL environment's row is this stage's
  migration, tested against a deliberately stale row in
  `test/platform/repo/migrations/force_update_in_review_template_stage_description_test.exs`.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Orchestration.PromptTemplate
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo

  # Both rows are reseeded: the in_review row is the subject, the deploying row
  # is the discrimination control and must render from a known body too.
  @slugs ["dispatch.in_review", "dispatch.deploying"]

  # LITERALS. Never `stage.description`, and never a value recomputed by
  # calling the formatter under test — an expectation derived from the function
  # under test cannot fail for any value that function returns.
  @sentinel "MUTATION-CONTROL-SENTINEL: the reviewer must be shown the specification"
  @tail_sentinel "NOT-IN-SCOPE-SENTINEL: the tail of the block must survive too"
  @heading "## Stage Description (authored by the planner — this is your specification)"

  setup do
    for slug <- @slugs do
      descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == slug))
      refute is_nil(descriptor), "the #{slug} descriptor must exist to be seeded"

      case Repo.get_by(PromptTemplate, slug: slug) do
        nil ->
          {:ok, _} = PromptTemplates.create_template(descriptor)

        existing ->
          {:ok, _} =
            PromptTemplates.update_template(existing, %{
              content: descriptor.content,
              variables: descriptor.variables
            })
      end
    end

    :ok
  end

  defp task_fixture(status \\ "in_review") do
    %{
      id: "019fba28-fadf-7fb1-804e-e62817c06211",
      title: "Carry the stage description into the human-gate dispatch",
      description: "Ticket body — planner-only material, must NOT reach this dispatch.",
      status: status,
      priority: "medium",
      deploy_strategy: %{"type" => "pr_merge", "config" => %{"auto_merge" => false}},
      project: %{repo_url: "https://github.com/test/router", default_branch: "main"}
    }
  end

  # A `manual_approval`-pending stage. `DispatchPhase.resolve/3` routes a stage
  # whose pending validations are ALL manual_approval to `dispatch.in_review`.
  defp review_plan_and_stage(description) do
    stage = %{
      id: "019fba30-c97e-73b8-9480-9c93e6ce6a95",
      position: 1,
      name: "human gate",
      description: description,
      validations: [%{id: "val-manual-1", kind: "manual_approval", status: "pending"}]
    }

    {%{version: 1, stages: [stage, %{}]}, stage}
  end

  # The SAME description text, on a deploy-shaped stage. The `"Deploy: "` name
  # prefix is what `DeployStageBuilder.deploy_stage_name?/1` keys on, so this
  # goes through `DispatchPhase.resolve/3` for real and lands on
  # `dispatch.deploying` — the routing is exercised, not asserted around.
  defp deploy_plan_and_stage(description) do
    stage = %{
      id: "019fba30-dead-73b8-9480-9c93e6ce6a95",
      position: 2,
      name: "Deploy: PR merge",
      description: description,
      validations: [%{id: "val-pr-merged-1", kind: "pr_merged", status: "pending"}]
    }

    {%{version: 1, stages: [%{}, stage]}, stage}
  end

  describe "dispatch.in_review DB row carries the stage description" do
    test "the rendered row contains the planner's stage prose verbatim" do
      {plan, stage} =
        review_plan_and_stage("""
        Opening paragraph of the specification the reviewer must judge against.

        #{@sentinel}

        #{@tail_sentinel}
        """)

      prompt = HeartbeatScheduler.dispatch_prompt(task_fixture(), plan, stage)

      assert prompt =~ @heading,
             "the seeded dispatch.in_review body must interpolate {{stage_description}}"

      assert prompt =~ @sentinel,
             "the stage description must reach the reviewer through the DB row"

      assert prompt =~ @tail_sentinel,
             "the block must not be truncated — a cap here would reintroduce the defect"

      refute prompt =~ "{{stage_description}}",
             "the placeholder must resolve, not render verbatim"
    end

    test "the description block lands after the Plan: v line" do
      {plan, stage} = review_plan_and_stage(@sentinel)

      prompt = HeartbeatScheduler.dispatch_prompt(task_fixture(), plan, stage)

      plan_line_at = :binary.match(prompt, "Plan: v1 (stage 1/2 — human gate)") |> elem(0)
      heading_at = :binary.match(prompt, @heading) |> elem(0)
      sentinel_at = :binary.match(prompt, @sentinel) |> elem(0)

      assert plan_line_at < heading_at
      assert heading_at < sentinel_at
    end

    test "nil and whitespace-only descriptions render no heading and do not crash" do
      for description <- [nil, "   ", "\n\n"] do
        {plan, stage} = review_plan_and_stage(description)

        prompt = HeartbeatScheduler.dispatch_prompt(task_fixture(), plan, stage)

        refute prompt =~ "## Stage Description",
               "description #{inspect(description)} must render nothing, not a dangling heading"
      end
    end

    test "the ticket body is still NOT carried into the review dispatch" do
      # The fixture's task description is real and non-empty precisely so this
      # refute has something to be wrong about.
      {plan, stage} = review_plan_and_stage(@sentinel)

      prompt = HeartbeatScheduler.dispatch_prompt(task_fixture(), plan, stage)

      refute prompt =~ "Ticket body — planner-only material"
    end

    test "the template no longer tells the reviewer to treat `context` as its source of truth" do
      # The `context` field exists on the broadcast payload
      # (`TaskRouter.dispatch_attention/5`) but the channel bridge surfaces
      # `message.content` only, so the old sentence pointed the reader at text
      # it cannot see. The first-turn rule is likewise qualified so it no
      # longer closes the only remaining route to the specification.
      {plan, stage} = review_plan_and_stage(@sentinel)

      prompt = HeartbeatScheduler.dispatch_prompt(task_fixture(), plan, stage)

      refute prompt =~ "Use it as your source of truth",
             "the dispatch must not point the reviewer at a `context` field it cannot read"

      assert prompt =~
               "The Stage Description block above is the planner's own authored specification"

      assert prompt =~ "call `suite_plan_get` and read the stage description there"
    end
  end

  describe "discrimination — the deploy dispatch does NOT carry the stage description" do
    test "the same description on a deploy-routed stage renders no sentinel and no heading" do
      # WITHOUT THIS CASE the tests above cannot distinguish "in_review carries
      # the description" from "every dispatch carries it", which is the claim
      # actually being made. Both fixtures use the identical description text;
      # the only difference is the stage that `DispatchPhase.resolve/3` routes.
      description = "Opening line.\n\n#{@sentinel}\n\n#{@tail_sentinel}\n"

      {review_plan, review_stage} = review_plan_and_stage(description)
      {deploy_plan, deploy_stage} = deploy_plan_and_stage(description)

      review_prompt =
        HeartbeatScheduler.dispatch_prompt(task_fixture(), review_plan, review_stage)

      deploy_prompt =
        HeartbeatScheduler.dispatch_prompt(task_fixture("deploying"), deploy_plan, deploy_stage)

      # Positive half — proves the fixture text is capable of appearing at all.
      assert review_prompt =~ @sentinel
      assert review_prompt =~ @heading

      # The routing really happened: this is the deploy body, not the review one.
      assert deploy_prompt =~ "Deploy Stage Contract",
             "the deploy fixture must actually route to dispatch.deploying, or the " <>
               "refutes below are refuting the wrong prompt"

      refute deploy_prompt =~ @heading,
             "a deploy stage's description is engine-synthesized boilerplate from " <>
               "DeployStageBuilder — carrying it buys nothing and costs context"

      refute deploy_prompt =~ @sentinel
      refute deploy_prompt =~ @tail_sentinel
    end
  end
end
