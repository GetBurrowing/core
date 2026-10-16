defmodule Platform.Federation.PlayToolsTest do
  @moduledoc """
  The `play` bundle (task 01a0db5f stage 2): invisible and refused with the
  flag off, refused by `ToolAuthorization` without the bundle, and working
  with both.

  NOT async: cases toggle `:game_stream, :enabled` (global app env)
  and track runtimes in the global `RuntimePresence` map.

  ## The literal-list GUARD on the tool list

  With `GAME_STREAM_ENABLED` unset, `ToolSurface.tool_definitions/0` names
  must equal main's, typed out below. The list was MEASURED on main
  (23ff27a0) by a probe that printed `tool_definitions/0` — not copied from
  this branch, which would make the guard agree with whatever the branch
  does. When main legitimately gains a tool, add it here in its catalogue
  position; that edit is the point at which someone looks. The guard is
  shown to fire in its own case: with the flag ON the same comparison fails.
  """

  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Access.{Grant, RuntimeProfiles}
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Federation.PlayTools
  alias Platform.Federation.RuntimePresence
  alias Platform.Federation.ToolAuthorization
  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.CanvasAttachments

  # main's catalogue at 23ff27a0, in order (119 tools). Measured, not derived.
  # 120 with `validation_payload_amend` after `plan_reject` (task 01a0acb4
  # stage 2). 121 with `task_delivery_candidate_list` after
  # `task_close_as_delivered` (task 01a044b0 stage 4). 122 with
  # `dispatch_metrics_list` after `experiment_promote` (task 01a114a8 stage 1).
  # 123 with `suite_run` (bundle `code_mode`) last (task 01a114a8 stage 2).
  # 124 with `suite_run_describe` after it (task 01a114a8 stage 3).
  # 125 with `code_mode_report` after `dispatch_metrics_list` (task 01a114a8
  # stage 4).
  # 126 with `janitor_hand_back` after `stack_assign_agents` (task
  # 019fa1ac-6685 stage 3, carried into Play at the PR #1226 main merge).
  # 129 with `prototype.publish`, `prototype.versions`, `prototype.rollback`
  # (bundle `prototype`) last (task 01a1316b-4e46 stage 1).
  # 128 with `vault_fetch` and `vault_list` after `federation_status`
  # (task 01a131c5 stage 1).
  # 131 with both (rollup merge of stack prototype-runtime onto main).
  # 135 with the four access tools (RBAC v2 agent-first Access UI).
  @main_tool_names ~w(
    canvas.create canvas.patch canvas.describe canvas.list_kinds canvas.template canvas.versions
    canvas.restore send_media react project_list org_list_descendants project_update epic_list
    epic_update epic_create task_create task_get task_transition_list runtime_event_list
    execution_lease_list task_list task_complete task_close_as_delivered task_delivery_candidate_list task_update task_start
    task_ack alarm_silence task_dependencies task_attach_canvas task_design_decline
    task_detach_canvas task_list_canvases stack_create stack_update stack_get stack_list
    stack_add stack_add_dependency stack_remove_dependency stack_eject stack_abandon
    stack_complete stack_start stack_retry_member_merge stack_start_planning stack_assign_agents
    janitor_hand_back
    plan_create plan_update plan_get plan_submit plan_approve plan_reject validation_payload_amend
    plan_architecture_verdict stage_architecture_audit stage_start stage_list validation_evaluate
    validation_pass stage_complete report_blocker validation_list prompt_template_list
    prompt_template_update review_request_create review_request_get review_item_list
    design_critique_request space_create space_list space_list_agents space_leave dm_create
    space_get_context space_search_messages space_get_messages canvas_list canvas_get
    principal_search federation_status vault_fetch vault_list memory_view memory_create
    memory_str_replace memory_insert
    memory_delete memory_rename memory_search org_memory_recently_edited
    org_memory_recently_deleted org_memory_feedback_at_path skill.list skill.get skill.upsert
    attachment.upload_inline attachment.get_inline attachment.upload_start file_list
    file_get_text file_get_metadata file_search file_add file_delete meeting_create meeting_say
    meeting_activity_push intent_ack experiment_surface_list experiment_list experiment_get
    experiment_create experiment_variant_add experiment_start experiment_stop experiment_conclude
    experiment_results experiment_signals_list experiment_exclude experiment_goal_set
    experiment_goal_list experiment_promote dispatch_metrics_list code_mode_report suite_run
    suite_run_describe prototype.publish prototype.versions prototype.rollback
    access_explain access_propose access_apply access_undo
  )

  @names ~w(play_session_start play_session_stop play_session_status)
  @sha "0123456789abcdef0123456789abcdef01234567"

  defmodule StubRunner do
    @moduledoc false
    def branch_head_sha(%{branch: branch}) do
      case Process.get(:stub_heads, %{}) do
        %{^branch => sha} -> {:ok, sha}
        _ -> {:error, :ref_not_found}
      end
    end
  end

  setup do
    previous = Application.get_env(:game_stream, :enabled)
    previous_bp = Application.get_env(:platform, :branch_provisioner)
    Application.delete_env(:game_stream, :enabled)

    on_exit(fn ->
      stop_all_sessions()

      if is_nil(previous),
        do: Application.delete_env(:game_stream, :enabled),
        else: Application.put_env(:game_stream, :enabled, previous)

      Application.put_env(:platform, :branch_provisioner, previous_bp)
    end)

    :ok
  end

  defp enable!, do: Application.put_env(:game_stream, :enabled, true)

  defp runtime(modules) do
    owner = Platform.ExternalUserFixtures.create_user!()
    org = Platform.Tenancy.get_org_by_slug!("sxi")
    Platform.ExternalUserFixtures.plain_member!(owner, org)
    {:ok, project} = Tasks.create_project(%{name: "Play permission #{unique()}", org_id: org.id})

    Repo.insert!(%Grant{
      org_id: org.id,
      principal_type: "user",
      principal_id: owner.id,
      permission: "play.use",
      resource_type: "project",
      resource_id: project.id,
      effect: "allow"
    })

    {:ok, runtime} =
      Federation.register_runtime(owner.id, %{
        runtime_id: "play-tools-profile-#{unique()}",
        tool_profile: modules
      })

    runtime
  end

  defp unique, do: System.unique_integer([:positive])

  # Sessions live under a global DynamicSupervisor; one a case left running
  # would hold its host claim into the next case.
  defp stop_all_sessions do
    sup = Platform.GameStream.Supervisor.sessions()

    for {_, pid, _, _} <- DynamicSupervisor.which_children(sup), is_pid(pid) do
      DynamicSupervisor.terminate_child(sup, pid)
    end
  end

  defp catalogue_names, do: Enum.map(ToolSurface.tool_definitions(), & &1.name)

  describe "GUARD: with GAME_STREAM_ENABLED unset the tool list is main's" do
    test "tool_definitions/0 names equal main's 135, in order" do
      assert length(@main_tool_names) == 135
      assert catalogue_names() == @main_tool_names
    end

    test "the guard FIRES: with the flag on, the same comparison fails" do
      enable!()
      refute catalogue_names() == @main_tool_names
      assert catalogue_names() == @main_tool_names ++ @names
    end
  end

  describe "flag unset" do
    test "the play bundle lists nothing, even for a runtime granted it" do
      assert ToolSurface.list_tools(["play"]) == []
      granted = runtime(AgentRuntime.default_tool_profile() ++ ["play"])
      refute Enum.any?(ToolAuthorization.tool_names(granted), &(&1 in @names))
    end

    test "every play tool is refused with the structured disabled error before anything runs" do
      for name <- @names do
        assert {:error, %{code: :game_stream_disabled, error: error}} =
                 ToolSurface.execute(name, %{"task_id" => Ecto.UUID.generate()}, %{})

        assert error == "game_stream is disabled: GAME_STREAM_ENABLED is unset"
      end

      # Even garbage arguments get the disabled refusal, not an argument error.
      assert {:error, %{code: :game_stream_disabled}} =
               ToolSurface.execute("play_session_start", nil, nil)
    end

    test "over the transports, the denial message names the flag, not a lookup miss" do
      granted = runtime(AgentRuntime.default_tool_profile() ++ ["play"])

      for name <- @names do
        assert ToolAuthorization.authorize(name, granted) == {:error, :forbidden}
        assert ToolAuthorization.deny_message(name) =~ "game_stream is disabled"
      end

      # Any other unknown name keeps its lookup-miss wording.
      assert ToolAuthorization.deny_message("play_session_nope") =~ "name lookup miss"
    end
  end

  describe "flag set" do
    setup do
      enable!()
      :ok
    end

    test "the bundle is grantable, not a default, and lists exactly the play tools" do
      assert "play" in ToolSurface.all_bundles()
      assert "play" in RuntimeProfiles.valid_modules()
      refute "play" in AgentRuntime.default_tool_profile()
      assert RuntimeProfiles.tool_profile(%AgentRuntime{}) == []

      assert Enum.map(ToolSurface.list_tools(["play"]), & &1.name) == @names
      assert Enum.all?(ToolSurface.list_tools(["play"]), &(&1.bundle == "play"))

      others = ToolSurface.list_tools(ToolSurface.all_bundles() -- ["play"])
      refute Enum.any?(others, &String.starts_with?(&1.name, "play_session_"))
    end

    test "without the bundle ToolAuthorization refuses every play tool" do
      default = runtime(AgentRuntime.default_tool_profile())

      for name <- @names do
        assert ToolAuthorization.authorize(name, default) == {:error, :forbidden}

        assert ToolAuthorization.deny_message(name) ==
                 "tool '#{name}' requires permission 'play.use', which this agent does not hold or is capped at its owner"
      end
    end

    test "with the bundle every play tool is authorized" do
      granted = runtime(AgentRuntime.default_tool_profile() ++ ["play"])

      for name <- @names do
        assert ToolAuthorization.authorize(name, granted) == :ok
      end
    end

    test "a loaded play profile cannot exceed its owner's permission" do
      granted = runtime(["play"])
      assert ToolAuthorization.authorize("play_session_start", granted) == :ok
      Repo.delete_all(from(g in Grant, where: g.principal_id == ^granted.owner_user_id))
      assert RuntimeProfiles.tool_profile(granted) == ["play"]
      assert ToolAuthorization.authorize("play_session_start", granted) == {:error, :forbidden}
    end

    test "an explicit empty restriction refuses play without unloading its profile" do
      granted = runtime(["play"])
      assert ToolAuthorization.authorize("play_session_start", granted) == :ok
      assert {:ok, _profile} = RuntimeProfiles.restrict(granted, %{})
      assert RuntimeProfiles.tool_profile(granted) == ["play"]
      assert ToolAuthorization.authorize("play_session_start", granted) == {:error, :forbidden}
    end

    test "every definition carries the six-component rubric" do
      for tool <- PlayTools.definitions() do
        for field <- [:description, :returns, :limitations, :when_to_use] do
          assert is_binary(Map.fetch!(tool, field)) and Map.fetch!(tool, field) != ""
        end

        assert is_map(tool.parameters)
      end
    end

    test "play_session_start starts, creates and attaches the canvas; stop ends it" do
      user =
        Repo.insert!(%User{
          email: "pt-#{unique()}@example.com",
          name: "PT User",
          oidc_sub: "pt-#{unique()}"
        })

      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{slug: "pt-agent-#{unique()}", name: "PT Agent", status: "active"})
        |> Repo.insert()

      {:ok, project} =
        Tasks.create_project(%{
          name: "Voltron #{unique()}",
          repo_url: "https://github.com/rowanellis/voltron"
        })

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Play #{unique()}"})
      task = task |> Ecto.Changeset.change(status: "in_review") |> Repo.update!()
      Process.put(:stub_heads, %{("task/" <> task.id) => @sha})
      Application.put_env(:platform, :branch_provisioner, runner: StubRunner)

      # The caller works on the task: a participant in its execution space.
      {:ok, space} = ExecutionSpace.find_or_create(task.id)
      {:ok, _p} = Chat.add_agent_participant(space.id, agent, display_name: agent.name)

      host_id = "play-host-#{unique()}"

      {:ok, host} =
        Federation.register_runtime(user.id, %{
          runtime_id: host_id,
          tool_profile: [],
          metadata: %{"client_info" => %{"features" => ["game_stream_host"]}}
        })

      {:ok, _host, _token} = Federation.activate_runtime(host)
      RuntimePresence.track(host_id)
      on_exit(fn -> RuntimePresence.untrack(host_id) end)

      assert {:ok, result} =
               ToolSurface.execute(
                 "play_session_start",
                 %{"task_id" => task.id},
                 %{agent_id: agent.id}
               )

      assert result.review_sha == @sha
      assert result.branch == "task/" <> task.id
      assert result.state == "building"
      assert is_binary(result.canvas_id), inspect(result)
      assert result.view_url =~ result.canvas_id

      canvas = Chat.get_canvas(result.canvas_id)
      assert canvas.space_id == space.id
      [gs] = canvas.document["root"]["children"]
      assert gs["type"] == "game_stream"
      assert gs["props"]["session_id"] == result.session_id
      assert gs["props"]["review_sha"] == @sha

      assert Enum.any?(
               CanvasAttachments.list_task_canvases(task.id),
               &(&1.attachment.canvas_id == result.canvas_id)
             )

      assert {:ok, %{state: "building"}} =
               ToolSurface.execute(
                 "play_session_status",
                 %{"session_id" => result.session_id},
                 %{agent_id: agent.id}
               )

      # No force_relay argument: the viewer may use every candidate type.
      assert {:ok, %{force_relay: false}} = Platform.GameStream.status(result.session_id)

      assert {:ok, %{state: "ended"}} =
               ToolSurface.execute(
                 "play_session_stop",
                 %{"session_id" => result.session_id},
                 %{agent_id: agent.id}
               )

      # force_relay: true reaches the session the viewer attaches to (stage 5).
      assert {:ok, relayed} =
               ToolSurface.execute(
                 "play_session_start",
                 %{"task_id" => task.id, "force_relay" => true},
                 %{agent_id: agent.id}
               )

      assert {:ok, %{force_relay: true}} = Platform.GameStream.status(relayed.session_id)
    end

    test "refusals are structured: missing args, no branch, no host, unknown session" do
      assert {:error, %{code: :invalid_arguments}} =
               ToolSurface.execute("play_session_start", %{}, %{})

      assert {:error, %{code: :task_not_found}} =
               ToolSurface.execute("play_session_start", %{"task_id" => "nope"}, %{})

      assert {:error, %{code: :not_found}} =
               ToolSurface.execute(
                 "play_session_status",
                 %{"session_id" => Ecto.UUID.generate()},
                 %{}
               )

      assert {:error, %{code: :unknown_tool}} =
               ToolSurface.execute("play_session_nope", %{}, %{})
    end
  end
end
