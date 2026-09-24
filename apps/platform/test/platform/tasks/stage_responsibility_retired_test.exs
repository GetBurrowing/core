defmodule Platform.Tasks.StageResponsibilityRetiredTest do
  @moduledoc """
  Absence guard for ADR-0046 stack member 9 (task `019f9b29-e447`).

  Stage-level responsibility — `Stage.responsibility`, its resolution through
  `Roles.agent_id_for_role/1` in the TaskRouter, its `:role_unresolvable`
  telemetry, and its MCP plan surface — was removed across stages 2-4. Nothing
  in the schema or the type system can now express it, so nothing in the schema
  or the type system stops a future change from reintroducing it as a free-form
  hint. This test is that stop: a source grep over the three files the concept
  lived in.

  Shape borrowed from `Platform.Federation.ToolSurfaceT5E2ETest` (reads a lib
  file off `Mix.Project.project_file/0` and refutes a retired string).

  ## The two halves are both load-bearing

  The **fix detector** refutes the word in `stage.ex`, `task_router.ex` and
  `tool_surface.ex`. The **positive control** asserts the three unrelated
  concepts that share the word are still present. Without the second half the
  refutes pass just as happily against a mistyped path or an emptied file, and
  a future reader has no way to tell "the concept is gone" from "the test is
  looking at nothing".

  The positive control also pins the boundary this ADR draws. "Responsibility"
  denoted four unrelated things; this task retired exactly one of them:

    * the responsibilities trigger tree, keyed `<feature>.<verb>` — SURVIVES
    * the ADR-0029 task-lifecycle phase split — SURVIVES
    * `:ext_single_responsibility`, agent narrowness (ADR-0040) — SURVIVES
    * the stage role key — RETIRED, and this test keeps it retired

  ## Why `tool_surface.ex` is checked narrowly

  `tool_surface.ex` legitimately still contains the word: the `agent_directory`
  result-row description names `ext_single_responsibility` as an agent
  classification. That is the agent-narrowness meaning, not the stage meaning.
  Rather than drop the file from the guard — which would leave the whole MCP
  plan surface unwatched — the assertion is narrowed to *what it forbids*:
  every occurrence of "responsibility" in that file must be part of
  `ext_single_responsibility`. A reintroduced stage hint would be an occurrence
  that is not, and detonates. Do not relax this into "the file may contain the
  word": amending a guard to accommodate what it detects is the failure mode
  ADR-0046 catalogues.
  """

  use ExUnit.Case, async: true

  # Files the stage-level concept lived in, and must not return to.
  @stage_file "lib/platform/tasks/stage.ex"
  @router_file "lib/platform/orchestration/task_router.ex"
  @tool_surface_file "lib/platform/federation/tool_surface.ex"

  # The one occurrence in @tool_surface_file that is a different concept.
  @agent_kind_literal "ext_single_responsibility"

  # Two more, added by task 019fe844 stage 3: the `design_critique_request`
  # clause translates `Platform.Design.Critique`'s error atoms into caller-
  # facing envelopes. Those atoms name the RESPONSIBILITIES TRIGGER TREE
  # sense (`design.critique`, keyed `<feature>.<verb>`) — the first bullet in
  # the moduledoc's boundary list, explicitly SURVIVES. They are exempted as
  # specific literals rather than by widening the refute, exactly as the
  # failure message instructs; the surrounding prose in that clause was
  # written to avoid the word entirely so these are the only two.
  @trigger_tree_literals ["responsibility_unfilled", "responsibility_not_registered"]

  # Not exempted, because it is not in the file: the Email module's
  # `mail_draft_create` / `mail_draft_update` tools (task 01a0cf21 stage 5)
  # take a `responsibility` argument — the delivery-row attribution on
  # `Platform.Mail.Draft`, a different concept from the retired stage-level
  # one — and are defined in `Platform.Federation.MailDraftTools` so this
  # file-level refute keeps its full strength over the plan surface.

  defp app_root, do: Mix.Project.project_file() |> Path.dirname()

  defp repo_root, do: app_root() |> Path.join("../..") |> Path.expand()

  defp read_app!(relative), do: app_root() |> Path.join(relative) |> File.read!()

  defp read_repo!(relative), do: repo_root() |> Path.join(relative) |> File.read!()

  describe "fix detector: the stage-level concept stays gone" do
    test "#{@stage_file} declares no responsibility field" do
      src = @stage_file |> read_app!() |> String.downcase()

      refute String.contains?(src, "responsibility"),
             """
             #{@stage_file} mentions "responsibility" again.

             ADR-0046 stack member 9 dropped the `responsibility` field and the
             `stages.responsibility` column (migration
             20260726052350_drop_responsibility_from_stages.exs). The column was
             named for one concept and held another: it stored a ROLE key, which
             the TaskRouter resolved with `Roles.agent_id_for_role/1`, while the
             responsibilities tree keys on `<feature>.<verb>`. A stage carrying a
             genuine responsibility key resolved to nil in silence.

             If design or architecture input needs to reach a task, fire the
             responsibility step (`Platform.Responsibilities.fire/2`); do not
             re-add a per-stage hint.
             """
    end

    test "#{@router_file} carries no stage-responsibility resolution path" do
      src = @router_file |> read_app!() |> String.downcase()

      refute String.contains?(src, "responsibility"),
             """
             #{@router_file} mentions "responsibility" again.

             Stage 2 removed `resolve_stage_dispatch_assignee/3` and its
             `:role_unresolvable` telemetry, which reported
             `responsibility: stage.responsibility` while the value was a role.

             NOTE for whoever trips this: the responsibility ROUTER (ADR-0044,
             `Platform.Responsibilities.Router`) is a different, live concept and
             may legitimately be called from orchestration code. If that is what
             you are adding, it belongs behind `Platform.Responsibilities` /
             `Platform.Tasks.record_planning_step/3` rather than inside a
             stage-dispatch path — narrow this assertion to the stage sense the
             way the tool_surface test below does. Do NOT delete the guard.
             """
    end

    test "#{@tool_surface_file} mentions responsibility only as the agent-kind classification" do
      src = @tool_surface_file |> read_app!() |> String.downcase()

      # Exemption is pinned to a live line, not asserted in prose: if the
      # classification is ever renamed or removed, this fails and forces a
      # re-read of the residual check below rather than silently widening it.
      assert String.contains?(src, @agent_kind_literal),
             """
             #{@tool_surface_file} no longer names `#{@agent_kind_literal}`.

             The residual check below exempts exactly that literal. If the
             agent-kind classification moved off the MCP surface, drop the
             exemption and restore the plain refute — do not leave a stale
             carve-out behind.
             """

      for literal <- @trigger_tree_literals do
        assert String.contains?(src, literal),
               """
               #{@tool_surface_file} no longer names `#{literal}`.

               The residual check below exempts exactly that literal. If the
               design-critique error translation moved off the MCP surface,
               drop the exemption rather than leaving a stale carve-out.
               """
      end

      residual =
        Enum.reduce(
          [@agent_kind_literal | @trigger_tree_literals],
          src,
          &String.replace(&2, &1, "")
        )

      refute String.contains?(residual, "responsibility"),
             """
             #{@tool_surface_file} mentions "responsibility" outside the
             `#{@agent_kind_literal}` agent classification.

             Stage 3 removed `responsibility` from the `plan_create` stage
             schema and from `serialize_stage/1`, so the MCP plan surface can
             neither accept nor emit a stage-level responsibility. A stale key
             sent by an older planner session is ignored, not rejected.

             If you are adding a genuinely different responsibility concept to
             the tool surface, extend the exemption to that specific literal.
             Do not weaken this to "the file may contain the word".
             """
    end
  end

  describe "positive control: the three surviving meanings of responsibility" do
    test "the responsibilities tree still keys on responsibility_key" do
      roles = read_app!("lib/platform/roles.ex")
      panel = read_app!("lib/platform_web/live/control_center/roles_panel.ex")

      assert String.contains?(roles, "responsibility_key"),
             "Platform.Roles no longer keys on responsibility_key — the refutes above are checking nothing meaningful."

      assert String.contains?(panel, "responsibility_key"),
             "The Control Center roles panel no longer keys on responsibility_key."

      # `assignee_for/1` (responsibility key, override-aware) and
      # `agent_id_for_role/1` (role key, NOT override-aware) are distinct
      # resolvers and both survive. Member 9 removed one CALLER of the second,
      # not the function: eight call sites remain across meetings, chat, the
      # Historian dispatcher, the wiki write-gate and MeetingLive.
      assert String.contains?(roles, "def assignee_for(")
      assert String.contains?(roles, "def agent_id_for_role(")
      assert Code.ensure_loaded?(Platform.Roles)
      assert function_exported?(Platform.Roles, :agent_id_for_role, 1)
    end

    test "the ADR-0029 lifecycle-phase meaning survives" do
      adr = read_repo!("docs/decisions/0029-task-lifecycle-responsibility-split.md")
      task_schema = read_app!("lib/platform/tasks/task.ex")

      assert String.contains?(adr, "Responsibility Split")

      assert String.contains?(task_schema, "phase_assignees"),
             "ADR-0029's per-phase assignee split is the lifecycle meaning of 'responsibility' and is unaffected by member 9."
    end

    test "the :ext_single_responsibility agent-narrowness meaning survives" do
      kind = read_app!("lib/platform/agents/kind.ex")

      assert String.contains?(kind, ":#{@agent_kind_literal}")

      assert Platform.Agents.Kind.classify(%Platform.Agents.Agent{kind: "external"}) ==
               :ext_single_responsibility
    end
  end
end
