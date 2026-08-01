defmodule Platform.Orchestration.HeartbeatSchedulerStageDescriptionTest do
  @moduledoc """
  Task 019fba28 stage 1 — the DB-ROW half of the stage-description guard.

  `PromptTemplates.render_template/2` is tried FIRST and the seeded
  `dispatch.in_progress` row wins in every migrated environment, so a change
  made only to the hardcoded fallback reaches no real agent. The sibling
  assertions in `heartbeat_scheduler_test.exs` run without DB ownership and
  therefore exercise the fallback branch only; these run the rendered row.

  The setup deliberately writes the SHIPPED DEFAULT body into the live row
  before rendering. Two reasons:

    * Determinism. The row in the test database was inserted by
      `20260324200001_seed_prompt_templates` whenever that database was first
      migrated, which may predate this branch. Reading whatever happens to be
      there makes the test depend on the age of a developer's Postgres volume.
    * Honesty about what is proved. Writing the default and then asserting a
      LITERAL sentinel in the rendered output tests the descriptor body, the
      assigns wiring and `interpolate/2` end to end. It is NOT the vacuous
      `get_template_by_slug(slug).content == default_content_for_slug(slug)`
      shape, which is true by construction in this database and stays green
      with every force-update migration in the repo deleted.

  Getting that default body into a REAL environment's row is stage 2's
  migration, and it is tested there against a deliberately stale row.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Orchestration.PromptTemplate
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo

  @slug "dispatch.in_progress"

  # LITERALS. Never `stage.description`, and never a value recomputed by
  # calling the formatter under test — an expectation derived from the
  # function under test cannot fail for any value that function returns.
  @sentinel "MUTATION-CONTROL-SENTINEL: the guard must be shown to fire"
  @tail_sentinel "NOT-IN-SCOPE-SENTINEL: the tail of the block must survive too"
  @heading "## Stage Description (authored by the planner — this is your specification)"

  setup do
    descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == @slug))
    refute is_nil(descriptor), "the #{@slug} descriptor must exist to be seeded"

    case Repo.get_by(PromptTemplate, slug: @slug) do
      nil ->
        {:ok, _} = PromptTemplates.create_template(descriptor)

      existing ->
        {:ok, _} =
          PromptTemplates.update_template(existing, %{
            content: descriptor.content,
            variables: descriptor.variables
          })
    end

    :ok
  end

  defp task_fixture do
    %{
      id: "019fba28-fadf-7fb1-804e-e62817c06211",
      title: "Carry the stage description into the execution dispatch",
      description: "Ticket body — planner-only material, must NOT reach this dispatch.",
      status: "in_progress",
      priority: "medium",
      project: %{repo_url: "https://github.com/test/router", default_branch: "main"}
    }
  end

  defp plan_and_stage(description) do
    stage = %{
      id: "019fba30-c97d-7869-a2ec-975f0f176d3a",
      position: 1,
      name: "coding",
      description: description,
      validations: []
    }

    {%{version: 1, stages: [stage, %{}]}, stage}
  end

  describe "dispatch.in_progress DB row carries the stage description" do
    test "the rendered row contains the planner's stage prose verbatim" do
      {plan, stage} =
        plan_and_stage("""
        Opening paragraph of the specification.

        #{@sentinel}

        #{@tail_sentinel}
        """)

      prompt = HeartbeatScheduler.dispatch_prompt(task_fixture(), plan, stage)

      assert prompt =~ @heading,
             "the seeded template body must interpolate {{stage_description}}"

      assert prompt =~ @sentinel,
             "the stage description must reach the implementer through the DB row"

      assert prompt =~ @tail_sentinel,
             "the block must not be truncated — a cap here would reintroduce the defect"

      refute prompt =~ "{{stage_description}}",
             "the placeholder must resolve, not render verbatim"
    end

    test "the description block lands after the Plan: v line" do
      {plan, stage} = plan_and_stage(@sentinel)

      prompt = HeartbeatScheduler.dispatch_prompt(task_fixture(), plan, stage)

      plan_line_at = :binary.match(prompt, "Plan: v1 (stage 1/2 — coding)") |> elem(0)
      heading_at = :binary.match(prompt, @heading) |> elem(0)
      sentinel_at = :binary.match(prompt, @sentinel) |> elem(0)

      assert plan_line_at < heading_at
      assert heading_at < sentinel_at
    end

    test "nil and whitespace-only descriptions render no heading and do not crash" do
      for description <- [nil, "   ", "\n\n"] do
        {plan, stage} = plan_and_stage(description)

        prompt = HeartbeatScheduler.dispatch_prompt(task_fixture(), plan, stage)

        refute prompt =~ "## Stage Description",
               "description #{inspect(description)} must render nothing, not a dangling heading"
      end
    end

    test "the ticket body is still NOT carried into the execution dispatch" do
      # The fixture's task description is real and non-empty precisely so this
      # refute has something to be wrong about. Option (a) — carrying the task
      # body — was argued and rejected; if someone later interpolates it here,
      # this goes red and they have to argue it again.
      {plan, stage} = plan_and_stage(@sentinel)

      prompt = HeartbeatScheduler.dispatch_prompt(task_fixture(), plan, stage)

      refute prompt =~ "Ticket body — planner-only material"
    end

    test "the template no longer tells the agent to treat `context` as its source of truth" do
      # The `context` field exists on the broadcast payload
      # (`TaskRouter.dispatch_attention/5`) but the channel bridge surfaces
      # `message.content` only, so the old sentence pointed the reader at text
      # it cannot see.
      {plan, stage} = plan_and_stage(@sentinel)

      prompt = HeartbeatScheduler.dispatch_prompt(task_fixture(), plan, stage)

      refute prompt =~ "Use it as your source of truth",
             "the dispatch must not point the agent at a `context` field it cannot read"

      assert prompt =~ "The Stage Description block above is your specification"
    end
  end
end
