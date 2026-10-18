defmodule Platform.Orchestration.HeartbeatSchedulerDesignCanvasesTest do
  @moduledoc """
  Task 01a13ae7 stage 1 — attached design canvases rendered INTO the
  planning, execution and review dispatch bodies
  (`HeartbeatScheduler.render_design_canvases_section/2`).

  The Claude Code bridge builds the agent's message from `message.content`
  only and drops the attention signal's `context`, where
  `ContextAssembler` has always put the canvases. For that runtime the
  rendered prompt is the only text the agent sees.

  Plain-map fixtures, async, no sandbox: HeartbeatScheduler must not touch the
  Repo for this block — the canvases arrive through `opts[:canvases]` only.

  Every expectation is a LITERAL, never a string recomputed by calling the
  renderer under test. Every absence is paired with a presence produced by the
  same instrument in the same test.
  """
  use ExUnit.Case, async: true

  alias Platform.Orchestration.HeartbeatScheduler

  # Plain substring, written literally. Stage 3 briefly line-anchored this
  # because the design fidelity sections quoted the heading mid-line; stage 4
  # reworded those sections, so the bare string now appears only where the
  # block renders (pinned by the occurrence-count describe block below).
  @heading "## Attached design canvases — the design spec"
  @ui_sentence "Before writing any code for this stage, open every canvas above with canvas_get(mode: \"full\") and capture a screenshot of it using the recipe below; post the screenshots to the execution space before your first commit."
  @reference_sentence "Reference only: this stage's description names no UI file. If this stage nonetheless changes what renders, the screenshot-first rule applies."
  @recipe_marker "Page.setDocumentContent"

  @canvas_id "01a13886-5781-7001-a1fb-41929d2b7521"
  @view_url "https://suite.example.test/canvases/01a13886-5781-7001-a1fb-41929d2b7521"

  defp canvas(overrides \\ %{}) do
    Map.merge(
      %{
        id: @canvas_id,
        title: "Quiet reconnect",
        kind: "stack",
        note: "use the badge treatment",
        attached_at: ~U[2026-10-14 12:00:00Z],
        canvas_present: true,
        view_url: @view_url
      },
      overrides
    )
  end

  defp task(status) do
    %{
      id: "01a13ae7-0000-7000-8000-000000000001",
      title: "Design fidelity fixture",
      description: "Fixture task body.",
      status: status,
      priority: "medium",
      project: %{repo_url: "https://github.com/test/design-canvases", default_branch: "main"}
    }
  end

  defp exec_stage(description) do
    %{
      id: "01a13ae7-0000-7000-8000-000000000002",
      position: 1,
      name: "build",
      status: "running",
      description: description,
      validations: [
        %{id: "01a13ae7-0000-7000-8000-000000000003", kind: "test_pass", status: "pending"}
      ]
    }
  end

  defp plan, do: %{version: 1, stages: [%{}, %{}]}

  @ui_description "Edit apps/platform/lib/platform_web/live/tasks_live.ex to render the badge."
  @backend_description "Edit apps/platform/lib/platform/tasks/plan_engine.ex only."

  describe "execution dispatch" do
    test "(a)+(b) a UI stage carries the block with one canvas and none of it with none" do
      stage = exec_stage(@ui_description)

      with_canvas =
        HeartbeatScheduler.dispatch_prompt(task("in_progress"), plan(), stage,
          canvases: [canvas()]
        )

      assert with_canvas =~ @canvas_id
      assert with_canvas =~ @heading
      assert with_canvas =~ @ui_sentence
      assert with_canvas =~ @view_url
      assert with_canvas =~ "\"Quiet reconnect\" (root: stack)"
      assert with_canvas =~ "note: use the badge treatment"
      assert with_canvas =~ @recipe_marker

      without =
        HeartbeatScheduler.dispatch_prompt(task("in_progress"), plan(), stage, canvases: [])

      refute without =~ @canvas_id
      refute without =~ @heading
      refute without =~ @ui_sentence
      refute without =~ @recipe_marker

      # Same instrument, so the absence above is not an empty render.
      assert without =~ "Design fidelity fixture"
      assert String.length(without) > 500
    end

    test "with no :canvases opt at all the body carries no block" do
      prompt =
        HeartbeatScheduler.dispatch_prompt(
          task("in_progress"),
          plan(),
          exec_stage(@ui_description)
        )

      refute prompt =~ @heading
      assert prompt =~ "Design fidelity fixture"
    end

    test "(c) a non-UI stage gets the reference sentence, not the screenshot-first rule" do
      prompt =
        HeartbeatScheduler.dispatch_prompt(
          task("in_progress"),
          plan(),
          exec_stage(@backend_description),
          canvases: [canvas()]
        )

      assert prompt =~ @canvas_id
      assert prompt =~ @heading
      assert prompt =~ @reference_sentence
      refute prompt =~ @ui_sentence

      # Discriminating half: the mode follows the description, it is not a constant.
      ui_prompt =
        HeartbeatScheduler.dispatch_prompt(
          task("in_progress"),
          plan(),
          exec_stage("Touch apps/platform/lib/platform_web/components/badge.ex."),
          canvases: [canvas()]
        )

      assert ui_prompt =~ @ui_sentence
      refute ui_prompt =~ @reference_sentence
    end

    test "(d) a soft-deleted canvas (canvas_present: false) renders no block" do
      stage = exec_stage(@ui_description)

      deleted =
        HeartbeatScheduler.dispatch_prompt(task("in_progress"), plan(), stage,
          canvases: [canvas(%{canvas_present: false, title: nil, kind: nil})]
        )

      refute deleted =~ @heading
      refute deleted =~ @canvas_id
      refute deleted =~ @ui_sentence

      present =
        HeartbeatScheduler.dispatch_prompt(task("in_progress"), plan(), stage,
          canvases: [canvas()]
        )

      assert present =~ @heading
    end

    test "(f) an @-mention token in a title or note renders escaped" do
      prompt =
        HeartbeatScheduler.dispatch_prompt(
          task("in_progress"),
          plan(),
          exec_stage(@ui_description),
          canvases: [canvas(%{title: "Ping @[Saru] about this", note: "cc @[Dalton]"})]
        )

      assert prompt =~ "Ping ＠[Saru] about this"
      assert prompt =~ "cc ＠[Dalton]"
      refute prompt =~ "@[Saru]"
      refute prompt =~ "@[Dalton]"
    end

    test "the list is capped and the overflow points at task_list_canvases" do
      canvases =
        for n <- 1..7 do
          canvas(%{
            id: "01a13ae7-0000-7000-8000-00000000010#{n}",
            view_url: "https://suite.example.test/canvases/c#{n}"
          })
        end

      prompt =
        HeartbeatScheduler.dispatch_prompt(
          task("in_progress"),
          plan(),
          exec_stage(@ui_description),
          canvases: canvases
        )

      assert prompt =~ "01a13ae7-0000-7000-8000-000000000105"
      refute prompt =~ "01a13ae7-0000-7000-8000-000000000106"
      assert prompt =~ "2 more attached; list them with `task_list_canvases`"
    end
  end

  describe "(e) other phases" do
    test "planning and review_e2e renders carry the canvas; deploying does not" do
      planning =
        HeartbeatScheduler.dispatch_prompt(task("planning"), nil, nil, canvases: [canvas()])

      assert planning =~ @canvas_id
      assert planning =~ @heading
      refute planning =~ @ui_sentence
      refute planning =~ @reference_sentence

      e2e_stage = %{
        id: "01a13ae7-0000-7000-8000-000000000004",
        position: 2,
        name: "Task-level review",
        status: "running",
        validations: [
          %{
            id: "01a13ae7-0000-7000-8000-000000000005",
            kind: "e2e_behavior",
            status: "pending",
            evaluation_payload: %{
              "setup" => "boot",
              "actions" => "render",
              "expected" => "matches"
            }
          }
        ]
      }

      review =
        HeartbeatScheduler.dispatch_prompt(task("in_review"), plan(), e2e_stage,
          canvases: [canvas()],
          execution_space_id: "01a13ae7-0000-7000-8000-000000000006"
        )

      assert review =~ "behavioral review"
      assert review =~ @canvas_id
      assert review =~ @heading
      refute review =~ @ui_sentence

      deploy_stage = %{
        id: "01a13ae7-0000-7000-8000-000000000007",
        position: 3,
        name: "Deploy: PR merge",
        status: "running",
        validations: [
          %{id: "01a13ae7-0000-7000-8000-000000000008", kind: "pr_merged", status: "pending"}
        ]
      }

      deploying =
        HeartbeatScheduler.dispatch_prompt(
          Map.put(task("deploying"), :deploy_strategy, %{"type" => "pr_merge", "config" => %{}}),
          plan(),
          deploy_stage,
          canvases: [canvas()]
        )

      assert deploying =~ "Deploy Stage Contract"
      refute deploying =~ @canvas_id
      refute deploying =~ @heading
    end
  end

  defp occurrences(haystack, needle), do: length(:binary.matches(haystack, needle))

  defp e2e_stage do
    %{
      id: "01a13ae7-0000-7000-8000-000000000004",
      position: 2,
      name: "Task-level review",
      status: "running",
      validations: [
        %{
          id: "01a13ae7-0000-7000-8000-000000000005",
          kind: "e2e_behavior",
          status: "pending",
          evaluation_payload: %{"setup" => "boot", "actions" => "render", "expected" => "ok"}
        }
      ]
    }
  end

  defp render(:planning, canvases),
    do: HeartbeatScheduler.dispatch_prompt(task("planning"), nil, nil, canvases: canvases)

  defp render(:in_progress, canvases),
    do:
      HeartbeatScheduler.dispatch_prompt(
        task("in_progress"),
        plan(),
        exec_stage(@ui_description),
        canvases: canvases
      )

  defp render(:review_e2e, canvases),
    do:
      HeartbeatScheduler.dispatch_prompt(task("in_review"), plan(), e2e_stage(),
        canvases: canvases,
        execution_space_id: "01a13ae7-0000-7000-8000-000000000006"
      )

  describe "plain-substring occurrences of the heading (task 01a13ae7 stage 4)" do
    # Review gate 01a13af2 measured the bare heading once in every
    # canvas-less body, quoted by the design fidelity sections. A plain
    # search must now discriminate, for agents as well as tests: 0 without a
    # canvas, exactly 1 with one, in the same phase, same instrument.
    for {phase, section_marker} <- [
          planning: "### Attached design canvases: plan from an inventory, not a paraphrase",
          in_progress: "If this dispatch carries an Attached design canvases block",
          review_e2e: "the recipe in this dispatch's Attached design canvases block"
        ] do
      test "#{phase}: 0 without a canvas, exactly 1 with one" do
        phase = unquote(phase)
        without = render(phase, [])
        with_canvas = render(phase, [canvas()])

        # The canvas-less body is a real render of the same phase: it carries
        # that phase's design fidelity section, the text that used to quote
        # the heading.
        assert without =~ "Design fidelity fixture"
        assert without =~ unquote(section_marker)

        assert occurrences(without, @heading) == 0
        assert occurrences(without, @canvas_id) == 0
        assert occurrences(without, "/canvases/" <> @canvas_id) == 0

        # Positive control: the same instrument finds the block when it renders.
        assert occurrences(with_canvas, @heading) == 1
        assert occurrences(with_canvas, @canvas_id) >= 1
      end
    end

    test "the heading constant is the literal these tests search for" do
      assert HeartbeatScheduler.design_canvases_heading() == @heading
    end
  end

  # Task 01a14b9e stage 3: the render recipe points at the org's browser-rig
  # skill instead of naming one install's hosts and LAN address.
  describe "render recipe rig line" do
    test "names the browser-rig skill, not a host or address" do
      body = HeartbeatScheduler.render_design_canvases_section([canvas()], :ui)

      assert body =~
               "Rig: use the CDP endpoint named in your org's browser-rig skill (`skill_list` query: browser rig); never run a BEAM or Chrome on a person's workstation."

      assert body =~ @recipe_marker
      refute body =~ ":9222"
      refute body =~ "Rig by runtime"
    end
  end
end
