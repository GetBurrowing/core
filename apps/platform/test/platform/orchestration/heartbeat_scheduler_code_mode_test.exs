defmodule Platform.Orchestration.HeartbeatSchedulerCodeModeTest do
  @moduledoc """
  Task 01a114a8 stage 4: the `dispatch.code_mode` surface on the planning,
  in_progress and review renders, enrolled by a `task_cohort` on `agent_id`.

  Every render goes through the public `HeartbeatScheduler.dispatch_prompt/4`.

  ## The byte-identity literals

  `@pre_change` holds the sha256 and byte size of each render of the
  fixture task below, measured at bbc9a4d32 (the commit BEFORE this stage)
  by a throwaway probe on the moon rig. They are NOT re-rendered here: a
  non-cohort agent's render under a running code_mode experiment must equal
  what the code produced before the surface existed.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Experiments
  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.PolicySpec
  alias Platform.Experiments.Policies.TaskCohort
  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Surfaces.CodeMode
  alias Platform.Experiments.Variant
  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Orchestration.PromptTemplates

  @agent_a "0a114a80-0000-4000-8000-0000000000a2"
  @agent_b "0a114a80-0000-4000-8000-0000000000b2"
  @fixture_task_id "0a114a80-c0de-4000-8000-000000000001"

  @pre_change %{
    planning: {"3985d1a5c1a4fa182ee72157968edb2515b7ca58c4b556425630f8dd27c90ac8", 26_208},
    in_progress: {"3b6df0b69dd3810447e798bb5be64387cffd9cd1a32d382b8720312756ad3339", 15_731},
    in_review: {"b174acfa67f4c50c2d30586f7310a1d47e53c238512f1184ce6678fdc056d678", 18_616}
  }

  @treatment_block "\n\n## Experiment directive (dispatch.code_mode)\n\n" <>
                     "Code mode is ON for this task. Suite tools are available to you as bindings inside suite_run scripts.\n\n" <>
                     "1. Call suite_run_describe first, naming only the tools you need (for example task_get, stage_list, validation_pass), to read their typed signatures.\n" <>
                     "2. Prefer ONE suite_run script that makes several Suite calls and returns only what you need over many sequential direct tool calls. Calls inside a script are synchronous: suite.task_get({task_id}) returns the data directly.\n" <>
                     "3. Pass this task's task_id (and stage_id, when you have one) in the script's inputs, so every inner call is attributed to this dispatch.\n" <>
                     "4. A script returns ok:false with an error kind (forbidden, timeout, fuel, memory, call_limit, output_limit, script_error) instead of raising; read the kind before retrying.\n" <>
                     "5. Local tools (shell, file reads, git) are unchanged. Code mode covers Suite tool calls only.\n"

  @control_block "\n\n## Experiment directive (dispatch.code_mode)\n\n" <>
                   "Code mode is OFF for this task: do not call suite_run on this task. Call Suite tools directly, one at a time.\n"

  setup do
    :ok = PromptTemplates.seed_defaults()
    :ok
  end

  defp admin, do: %User{id: Ecto.UUID.generate()}

  # The probe's task, byte for byte: only `id` and the assignee vary here.
  defp task(status, agent_id, id \\ @fixture_task_id) do
    slot = %{"assignee_id" => agent_id, "assignee_type" => "agent"}

    %{
      id: id,
      title: "Code mode probe task",
      description: "Byte-identity probe for the code mode surface.",
      status: status,
      priority: "medium",
      project_id: nil,
      epic_id: nil,
      inserted_at: ~U[2026-10-07 08:00:00Z],
      assignee_id: agent_id,
      assignee_type: "agent",
      phase_assignees: %{"planning" => slot, "execution" => slot, "review" => slot}
    }
  end

  defp stage(kind) do
    %{
      id: "0a114a80-c0de-4000-8000-000000000051",
      position: 2,
      name: "Do the work",
      description: "The stage's own description.",
      status: "running",
      validations: [
        %{id: "0a114a80-c0de-4000-8000-0000000000a1", kind: kind, status: "pending"}
      ]
    }
  end

  defp render(:planning, task), do: HeartbeatScheduler.dispatch_prompt(task, nil, nil)

  defp render(:in_progress, task) do
    s = stage("test_pass")

    HeartbeatScheduler.dispatch_prompt(
      %{task | status: "in_progress"},
      %{version: 1, stages: [s]},
      s
    )
  end

  defp render(:in_review, task) do
    s = stage("manual_approval")

    HeartbeatScheduler.dispatch_prompt(
      %{task | status: "in_review"},
      %{version: 1, stages: [s]},
      s
    )
  end

  defp sha(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

  # A running dispatch.code_mode experiment enrolling `cohort` by agent_id.
  # `arm` zeroes the other arm's weight so a new subject's arm is known.
  defp running!(cohort, arm) do
    {:ok, experiment} =
      Experiments.create_experiment(%{
        slug: "code-mode-#{System.unique_integer([:positive])}",
        name: "Code mode",
        surface_key: "dispatch.code_mode",
        surface_target: "dispatch.prompt_directive",
        assignment_policy: %{"type" => "task_cohort", "cohort" => %{"agent_id" => cohort}}
      })

    {:ok, _} =
      Experiments.add_variant(experiment, %{
        slug: "treatment",
        payload: %{"suite_run" => true},
        weight: 1
      })

    {:ok, %Experiment{status: "running"} = running} = Experiments.start(experiment, admin())

    zero = if arm == "control", do: "treatment", else: Experiment.control_slug()

    Repo.update_all(
      from(v in Variant, where: v.experiment_id == ^running.id and v.slug == ^zero),
      set: [weight: 0]
    )

    running
  end

  defp assignments_for(task_id),
    do: Repo.all(from(a in Assignment, where: a.subject_id == ^task_id))

  describe "the surface" do
    test "is registered on the dispatch path with one target" do
      assert Surfaces.get("dispatch.code_mode") == CodeMode
      assert CodeMode.path() == :dispatch
      assert CodeMode.subject_type() == "task"
      assert CodeMode.targets() == ["dispatch.prompt_directive"]
    end

    test "validates its payload" do
      assert CodeMode.validate_payload(%{"suite_run" => true}) == {:ok, %{"suite_run" => true}}
      assert CodeMode.validate_payload(%{suite_run: false}) == {:ok, %{"suite_run" => false}}
      assert CodeMode.validate_payload(%{}) == {:error, ["suite_run must be a boolean"]}

      assert CodeMode.validate_payload(%{"suite_run" => "yes", "x" => 1}) ==
               {:error, ["suite_run must be a boolean", "unknown keys: x"]}

      assert CodeMode.validate_payload([]) == {:error, ["payload must be an object"]}
    end

    test "the control is suite_run false, and BOTH arms render text" do
      assert CodeMode.control_payload("dispatch.prompt_directive", []) ==
               {:ok, %{"suite_run" => false}}

      assert "\n\n## Experiment directive (dispatch.code_mode)\n\n" <>
               CodeMode.render_directive(%{"suite_run" => true}) <> "\n" == @treatment_block

      assert "\n\n## Experiment directive (dispatch.code_mode)\n\n" <>
               CodeMode.render_directive(%{"suite_run" => false}) <> "\n" == @control_block

      assert CodeMode.render_directive(%{}) == nil
    end

    test "neither directive carries a mention token" do
      for payload <- [%{"suite_run" => true}, %{"suite_run" => false}] do
        refute CodeMode.render_directive(payload) =~ "@["
      end
    end
  end

  describe "agent_id as a cohort key" do
    test "task_cohort accepts agent_id and builds the existing policy" do
      assert {TaskCohort, opts} =
               PolicySpec.build(%{
                 "type" => "task_cohort",
                 "cohort" => %{"agent_id" => [@agent_a]}
               })

      assert Keyword.fetch!(opts, :cohort) == [agent_id: [@agent_a]]
    end
  end

  describe "byte identity for a non-cohort agent" do
    test "the pre-change literals hold with NO experiment" do
      for {phase, {digest, bytes}} <- @pre_change do
        prompt = render(phase, task("planning", @agent_b))
        assert {phase, sha(prompt), byte_size(prompt)} == {phase, digest, bytes}
      end
    end

    test "a running code_mode experiment on another agent leaves every render pre-change" do
      running!([@agent_a], "treatment")

      for {phase, {digest, bytes}} <- @pre_change do
        prompt = render(phase, task("planning", @agent_b))
        assert {phase, sha(prompt), byte_size(prompt)} == {phase, digest, bytes}
      end

      assert assignments_for(@fixture_task_id) == []
    end
  end

  describe "a cohort agent's task" do
    test "resolves to one sticky arm, and every phase renders that arm's block" do
      experiment = running!([@agent_a], "treatment")
      t = task("planning", @agent_a, Ecto.UUID.generate())

      planning = render(:planning, t)
      assert [%Assignment{variant_slug: "treatment"} = row] = assignments_for(t.id)
      assert row.experiment_id == experiment.id

      in_progress = render(:in_progress, t)
      in_review = render(:in_review, t)

      for prompt <- [planning, in_progress, in_review] do
        assert String.ends_with?(prompt, @treatment_block)

        assert prompt |> String.split("## Experiment directive (dispatch.code_mode)") |> length() ==
                 2
      end

      # Sticky: flipping the weights does not move an assigned task.
      Repo.update_all(
        from(v in Variant, where: v.experiment_id == ^experiment.id and v.slug == "treatment"),
        set: [weight: 0]
      )

      Repo.update_all(
        from(v in Variant, where: v.experiment_id == ^experiment.id and v.slug == "control"),
        set: [weight: 1]
      )

      assert String.ends_with?(render(:in_progress, t), @treatment_block)
      assert [%Assignment{variant_slug: "treatment"}] = assignments_for(t.id)
    end

    test "the control arm renders the do-not-use line on every phase" do
      running!([@agent_a], "control")
      t = task("planning", @agent_a, Ecto.UUID.generate())

      for phase <- [:planning, :in_progress, :in_review] do
        assert String.ends_with?(render(phase, t), @control_block), "#{phase}"
      end

      assert [%Assignment{variant_slug: "control"}] = assignments_for(t.id)
    end

    test "the phase's own assignee decides: a cohort executor on a non-cohort planner's task" do
      running!([@agent_a], "treatment")
      id = Ecto.UUID.generate()

      t = %{
        task("planning", @agent_b, id)
        | phase_assignees: %{
            "planning" => %{"assignee_id" => @agent_b, "assignee_type" => "agent"},
            "execution" => %{"assignee_id" => @agent_a, "assignee_type" => "agent"}
          }
      }

      refute render(:planning, t) =~ "dispatch.code_mode"
      assert assignments_for(id) == []

      assert String.ends_with?(render(:in_progress, t), @treatment_block)
      assert [%Assignment{variant_slug: "treatment"}] = assignments_for(id)
    end

    test "a user assignee in the phase slot is not an agent and enrols nothing" do
      running!([@agent_a], "treatment")
      id = Ecto.UUID.generate()

      t = %{
        task("planning", @agent_a, id)
        | phase_assignees: %{
            "planning" => %{"assignee_id" => @agent_a, "assignee_type" => "user"}
          }
      }

      refute render(:planning, t) =~ "dispatch.code_mode"
      assert assignments_for(id) == []
    end

    test "with no phase slot the top-level agent assignee is used" do
      running!([@agent_a], "treatment")
      id = Ecto.UUID.generate()
      t = %{task("planning", @agent_a, id) | phase_assignees: %{}}

      assert String.ends_with?(render(:planning, t), @treatment_block)
      assert [%Assignment{variant_slug: "treatment"}] = assignments_for(id)
    end
  end
end
