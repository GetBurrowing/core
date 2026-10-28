defmodule Platform.Orchestration.TaskAckPreambleTruthfulnessTest do
  @moduledoc """
  The ack-first preamble and the `subagent_id` tool descriptions must describe
  what `task_ack` / `intent_ack` actually check (task 01a0ac55).

  They used to say that requiring a `subagent_id` makes it "structurally
  impossible" to ack a dispatch you never spawned a subagent for, and that
  "presence forces spawn-before-ack ordering". It does not: the server checks
  only that the id is a present, non-blank string of at most 128 bytes. It
  holds no record of client-side spawns and cannot correlate the id with one.
  Measured on test-host prod (4,039 `execution.acked` rows), the stored ids include
  UUIDs, session ids and freeform labels alongside real Agent-tool ids.

  What is asserted:

  1. Every seeded stage-scoped dispatch row (`dispatch.in_progress`,
     `dispatch.in_review`, `dispatch.deploying`)
     rendered through `render_template/2` drops the impossibility claim, keeps
     the spawn-first instruction and the pass-the-spawned-id instruction, and
     still carries `subagent_id=` on the ack call line.
  The stage-less scribe completion prompt instead uses its authenticated
  meeting callback and canonical run identities, without a task/stage lease
  (task 01a17f00-832c-7000-b480-64ab6d710532).

  2. The same holds on the row-less `HeartbeatScheduler.dispatch_prompt/3`
     path for every phase that carries the preamble.
  3. The `subagent_id` parameter descriptions of `task_ack` and `intent_ack`
     no longer claim the check forces anything.
  4. The guard that does exist still bites: a blank or nil `subagent_id` is
     rejected with `subagent_id is required`.
  """
  use Platform.DataCase, async: false

  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Orchestration.PromptTemplate
  alias Platform.Orchestration.PromptTemplates

  @slugs ~w(dispatch.in_progress dispatch.in_review dispatch.deploying)

  @old_claim "structurally impossible"
  @spawn_first "Spawn the subagent FIRST"
  @pass_spawned_id "pass the id of the subagent you actually spawned"

  setup do
    :ok = PromptTemplates.seed_defaults()

    {:ok, task_id} = Ecto.UUID.generate() |> Platform.UUID.cast()
    {:ok, stage_id} = Ecto.UUID.generate() |> Platform.UUID.cast()
    {:ok, plan_id} = Ecto.UUID.generate() |> Platform.UUID.cast()

    %{task_id: task_id, stage_id: stage_id, plan_id: plan_id}
  end

  defp assert_truthful_preamble!(body, task_id, stage_id, where) do
    refute body =~ @old_claim,
           "#{where} still claims the ack ordering is #{@old_claim} (task 01a0ac55)"

    assert body =~ @spawn_first, "#{where} lost the spawn-first instruction"

    assert body =~ @pass_spawned_id,
           "#{where} no longer tells the caller to pass the spawned subagent's id"

    assert body =~ ~s|task_ack(task_id="#{task_id}", stage_id="#{stage_id}", subagent_id=|,
           "#{where} ack call line lost its interpolated ids or its subagent_id= slot"
  end

  describe "seeded dispatch rows served by render_template/2" do
    for slug <- @slugs do
      test "#{slug} states only what the server checks", ctx do
        assigns = %{
          task_id: ctx.task_id,
          stage_id: ctx.stage_id,
          task_title: "Ack truthfulness fixture task",
          task_description: "Ack truthfulness fixture description",
          stage_info: "Plan: v1 (stage 1/1 — fixture)",
          federation_preamble: PromptTemplates.federation_preamble()
        }

        assert {:ok, rendered} = PromptTemplates.render_template(unquote(slug), assigns)

        assert_truthful_preamble!(rendered, ctx.task_id, ctx.stage_id, unquote(slug))
      end
    end
  end

  test "stage-less scribe completion renders a canonical callback without a task ack", ctx do
    assert {:ok, rendered} =
             PromptTemplates.render_template("dispatch.scribe_completion", %{
               task_id: ctx.task_id,
               stage_id: ctx.stage_id,
               federation_preamble: "Meeting callback fixture preamble",
               meeting_name: "Finalized meeting",
               space_id: Ecto.UUID.generate(),
               transcript_id: Ecto.UUID.generate(),
               room_id: "finalized-room",
               execution_space_id: Ecto.UUID.generate(),
               skills_reference: ""
             })

    refute rendered =~ "task_ack"
    refute rendered =~ "{{task_id}}"
    refute rendered =~ "{{stage_id}}"
    refute rendered =~ ctx.task_id
    refute rendered =~ ctx.stage_id
    assert rendered =~ "meeting_scribe_complete"

    for identity <- ~w(meeting_id run_id transcript_id canvas_id snapshot_hash),
        do: assert(rendered =~ identity)
  end

  describe "row-less HeartbeatScheduler.dispatch_prompt/3 fallback" do
    defp fixture_task(task_id, status) do
      %{
        id: task_id,
        title: "Ack truthfulness fixture task",
        description: "Ack truthfulness fixture description",
        status: status,
        priority: "high",
        project: %{
          repo_url: "https://github.com/test/router",
          default_branch: "main",
          deploy_strategy: %{"type" => "manual", "config" => %{}}
        }
      }
    end

    defp fixture_stage(stage_id, name, kind) do
      %{
        id: stage_id,
        name: name,
        description: "Ack truthfulness fixture stage description",
        position: 1,
        status: "running",
        validations: [%{id: "val-1", kind: kind, status: "pending"}]
      }
    end

    for {slug, status, stage_name, kind} <- [
          {"dispatch.in_progress", "in_progress", "Implement", "test_pass"},
          {"dispatch.in_review", "in_review", "Review", "manual_approval"},
          {"dispatch.deploying", "deploying", "Deploy: pr_merge", "pr_merged"}
        ] do
      test "#{slug} fallback states only what the server checks", ctx do
        Platform.Repo.delete_all(from(t in PromptTemplate, where: t.slug == ^unquote(slug)))

        body =
          HeartbeatScheduler.dispatch_prompt(
            fixture_task(ctx.task_id, unquote(status)),
            %{id: ctx.plan_id, version: 1, stages: [%{}]},
            fixture_stage(ctx.stage_id, unquote(stage_name), unquote(kind))
          )

        assert_truthful_preamble!(body, ctx.task_id, ctx.stage_id, "#{unquote(slug)} fallback")
      end
    end
  end

  describe "subagent_id parameter descriptions" do
    # task_ack ships in the `task` bundle and intent_ack in `meetings`
    # (tool_surface_intent_ack_test.exs pins that split), so both are listed.
    @bundles ["task", "meetings"]

    for tool <- ~w(task_ack intent_ack) do
      test "#{tool} does not claim presence forces spawn-before-ack" do
        spec = ToolSurface.list_tools(@bundles) |> Enum.find(&(&1.name == unquote(tool)))

        assert spec, "#{unquote(tool)} missing from list_tools(#{inspect(@bundles)})"

        description = spec.parameters.subagent_id.description

        refute description =~ ~r/cannot ack|structurally impossible|Presence forces/,
               "#{unquote(tool)} subagent_id description still overstates the check: " <>
                 description

        assert description =~ "does not verify that the id names a real spawn"
      end
    end

    test "intent_ack keeps the cancellation-addressing requirement" do
      spec = ToolSurface.list_tools(@bundles) |> Enum.find(&(&1.name == "intent_ack"))

      assert spec.parameters.subagent_id.description =~
               "It is also what a later cancellation is addressed to, so it must identify the ACTUAL subagent."
    end
  end

  describe "the guard that does exist still bites" do
    for {label, value} <- [{"empty string", ""}, {"nil", nil}] do
      test "task_ack rejects a #{label} subagent_id", ctx do
        assert {:error, %{error: "subagent_id is required"}} =
                 ToolSurface.execute(
                   "task_ack",
                   %{
                     "task_id" => ctx.task_id,
                     "stage_id" => ctx.stage_id,
                     "subagent_id" => unquote(value)
                   },
                   %{}
                 )
      end
    end
  end
end
