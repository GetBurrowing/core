defmodule Platform.Chat.EditPermissionsTest do
  @moduledoc """
  Editable-messages contract — sections **e (permissions)** + **f (agent
  interaction model, Policies 2 and 3)**.

  Covers the explicit forbidden-edit matrix enumerated in Task 6 Stage 3:

    1. Edit another user's message → 403
    2. Edit a bot/agent message as a human → 403
    3. Edit own agent message as the agent itself → 403 (Policy 3)
    4. Edit after associated task in_progress → 409 (Policy 2, task-scoped)
    5. Edit after agent first state-changing op → 409 (Policy 2, ad-hoc)
    6. Planning-time tools (research, file reads, search) do NOT freeze.

  Case 1 is already covered by `MessageControllerTest`'s 403-not-author
  test; this file adds Case 2 explicitly (human → agent-authored
  message). Case 3 stays skipped because its enforcement is by
  architecture (the HTTP API only attaches user sessions, so an agent
  cannot reach the controller). Cases 4, 5, 6 are now active — they
  exercise the Policy 2 freeze triggers wired in by tasks
  `019e1e80-...` (task-scoped + ad-hoc) which shipped on main as
  PR #343.
  """
  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts
  alias Platform.Chat
  alias Platform.Chat.AdHocFreezeListener
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskRecord

  # ── Helpers (kept local for self-containment; mirrors the pattern in
  # MessageControllerTest so future authors can copy either freely) ──────

  defp create_user! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.find_or_create_from_oidc(%{
        sub: "edit-perms-sub-#{n}",
        email: "edit-perms-#{n}@example.com",
        name: "Test User #{n}"
      })

    user
  end

  defp create_space! do
    slug = "edit-perms-space-#{System.unique_integer([:positive, :monotonic])}"

    {:ok, space} =
      Chat.create_space(%{name: "Edit Permissions Test", slug: slug, kind: "channel"})

    space
  end

  defp add_user_participant!(space_id, user_id, display_name) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user_id,
        joined_at: DateTime.utc_now(),
        display_name: display_name
      })

    p
  end

  defp add_agent_participant!(space_id, display_name) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "agent",
        participant_id: Ecto.UUID.generate(),
        joined_at: DateTime.utc_now(),
        display_name: display_name
      })

    p
  end

  defp post_text_message!(space_id, participant_id, content) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space_id,
        participant_id: participant_id,
        content_type: "text",
        content: content
      })

    msg
  end

  defp login(conn, user_id) do
    Plug.Test.init_test_session(conn, %{current_user_id: user_id})
  end

  # Policy 2 fixtures — mirror the pattern in policy_2_freeze_test.exs so
  # behavior under test matches what the implementation suite already
  # asserts. The plan-approval dance is required because Tasks.transition_task
  # / apply_dispatch_gate auto-promotes to in_progress when a plan is
  # approved; we want to drive the transition ourselves in Case 4 so we
  # reset the status back to planning after approval.
  defp create_project! do
    n = System.unique_integer([:positive, :monotonic])
    {:ok, project} = Tasks.create_project(%{name: "EditPerms #{n}", slug: "editperms-#{n}"})
    project
  end

  defp create_task_with_approved_plan!(project, agent_id, opts) do
    title = Keyword.get(opts, :title, "Policy 2 freeze target")

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: title,
        status: "planning",
        assignee_type: "agent",
        assignee_id: agent_id
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

    plan
    |> Ecto.Changeset.change(%{status: "pending_review"})
    |> Repo.update!()

    {:ok, _approved} =
      Tasks.approve_plan(
        Repo.get!(Platform.Tasks.Plan, plan.id),
        Ecto.UUID.generate()
      )

    # Reset to planning so this test (not the dispatch gate) drives the
    # transition under test.
    task = Repo.get!(TaskRecord, task.id)

    task
    |> Ecto.Changeset.change(%{status: "planning"})
    |> Repo.update!()
  end

  defp seed_exec_space_with_user_author!(task, agent_id, agent_display_name, user) do
    {:ok, space} = ExecutionSpace.find_or_create(task.id)

    {:ok, agent_p} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent_id,
        joined_at: DateTime.utc_now(),
        display_name: agent_display_name
      })

    {:ok, user_p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now(),
        display_name: user.name || "TestUser"
      })

    {space, agent_p, user_p}
  end

  # ── Active tests ────────────────────────────────────────────────────────

  describe "PATCH /api/messages/:id — permission matrix (sections e + f)" do
    test "Case 2: 403 forbidden_not_author when human tries to edit an agent-authored message",
         %{conn: conn} do
      human = create_user!()
      space = create_space!()
      _human_participant = add_user_participant!(space.id, human.id, "Alice")
      agent_participant = add_agent_participant!(space.id, "Saru")
      agent_msg = post_text_message!(space.id, agent_participant.id, "agent said this")

      conn =
        conn
        |> login(human.id)
        |> patch(~p"/api/messages/#{agent_msg.id}", %{content: "human tries to rewrite"})

      assert json_response(conn, 403)["error"]["code"] == "forbidden_not_author"
      # Confirm the body in DB is unchanged
      reloaded = Platform.Repo.get(Platform.Chat.Message, agent_msg.id)
      assert reloaded.content == "agent said this"
    end
  end

  # ── Skipped tests — document the gaps without producing false confidence ─

  describe "PATCH /api/messages/:id — Policy 3 (agent self-edit), gated above the controller" do
    @tag :skip
    test "Case 3 (skip): 403 when an agent attempts to edit its own message via HTTP" do
      # The HTTP API is mounted under :require_auth_api (router pipeline) which
      # only attaches *user* sessions to the conn. An agent therefore cannot
      # authenticate to the PATCH endpoint at all — Policy 3 enforcement at the
      # HTTP layer is by absence of a code path, not by a runtime check. The
      # LV `save_edit` event path is a separate surface; see follow-up if a
      # dedicated agent-self-edit-via-LV test is needed.
      assert true
    end
  end

  describe "PATCH /api/messages/:id — Policy 2 freeze trigger (task-scoped + ad-hoc)" do
    # GAP-CLOSED — Stage 3 recon (2026-05-12) found no production caller of
    # MessageVersions.freeze. Tasks 019e1e80-... shipped both triggers via
    # PR #343 (squash 60f24be on main): the task-scoped trigger is wired in
    # Tasks.transition_task/2 (Stage 3 of that task), and the ad-hoc trigger
    # listens on chat:agent_runtime via Platform.Chat.AdHocFreezeListener
    # (Stage 4). Cases 4, 5, 6 below are the controller-level integration
    # tests proving Policy 2 enforcement end-to-end through the PATCH
    # endpoint that Cases 4-6 originally documented as gaps.
    #
    # Test strategy mirrors policy_2_freeze_test.exs and
    # ad_hoc_freeze_listener_test.exs: drive the listener's handle_info/2
    # directly rather than via PubSub, so the test is deterministic and
    # doesn't race the supervised GenServer's sandbox checkout.

    test "Case 4: 409 frozen when the associated task transitions to in_progress",
         %{conn: conn} do
      user = create_user!()
      project = create_project!()
      agent_id = Ecto.UUID.generate()
      task = create_task_with_approved_plan!(project, agent_id, title: "Case 4 task")

      {_space, _agent_p, user_p} =
        seed_exec_space_with_user_author!(task, agent_id, "Saru", user)

      msg = post_text_message!(user_p.space_id, user_p.id, "user message before transition")

      # Sanity: message starts unfrozen and editable.
      assert is_nil(Repo.get!(Platform.Chat.Message, msg.id).frozen_at)

      # Task-scoped Policy 2 trigger: status flip + freeze loop run in one
      # Repo.transaction (Stage 3 atomicity contract).
      assert {:ok, %TaskRecord{status: "in_progress"}} =
               Tasks.transition_task(task, "in_progress")

      # Message is now frozen by the agent's participant in this exec space.
      refreshed = Repo.get!(Platform.Chat.Message, msg.id)
      assert %DateTime{} = refreshed.frozen_at

      # PATCH as the user-author returns 409 with freezing_action context.
      conn =
        conn
        |> login(user.id)
        |> patch(~p"/api/messages/#{msg.id}", %{content: "user tries to revise"})

      body = json_response(conn, 409)
      assert body["error"]["code"] == "frozen"

      freezing_action = body["error"]["freezing_action"]
      assert freezing_action["participant_display_name"] == "Saru"
      refute is_nil(freezing_action["frozen_at"])

      # DB content unchanged.
      assert Repo.get!(Platform.Chat.Message, msg.id).content ==
               "user message before transition"
    end

    test "Case 5: 409 frozen after the assigned agent's first state-changing op",
         %{conn: conn} do
      # No task transition here — purely the ad-hoc trigger. The user posts
      # a message in an exec space whose task is assigned to the agent
      # (in-context per the Stage 2 task-arm predicate), then the agent
      # fires its first state-changing op via the chat:agent_runtime
      # listener.
      user = create_user!()
      project = create_project!()
      agent_id = Ecto.UUID.generate()
      task = create_task_with_approved_plan!(project, agent_id, title: "Case 5 task")

      {space, agent_p, user_p} =
        seed_exec_space_with_user_author!(task, agent_id, "Saru", user)

      msg = post_text_message!(space.id, user_p.id, "user message — agent in scope")

      assert is_nil(Repo.get!(Platform.Chat.Message, msg.id).frozen_at)

      # Drive the listener consumer directly (mirrors
      # ad_hoc_freeze_listener_test.exs's pattern: avoids the supervised
      # GenServer / sandbox race that PubSub.broadcast would introduce).
      {:noreply, _} =
        AdHocFreezeListener.handle_info(
          {:agent_first_state_op, agent_p.id, space.id},
          %{}
        )

      # Message is now frozen by the agent.
      refreshed = Repo.get!(Platform.Chat.Message, msg.id)
      assert %DateTime{} = refreshed.frozen_at
      assert refreshed.frozen_by_participant_id == agent_p.id

      # PATCH as the author returns 409 with the freezing_action naming
      # the agent that froze it.
      conn =
        conn
        |> login(user.id)
        |> patch(~p"/api/messages/#{msg.id}", %{content: "user tries to revise"})

      body = json_response(conn, 409)
      assert body["error"]["code"] == "frozen"
      assert body["error"]["freezing_action"]["participant_display_name"] == "Saru"

      assert Repo.get!(Platform.Chat.Message, msg.id).content ==
               "user message — agent in scope"
    end

    test "Case 6 (negative): planning-time signals do NOT trigger freeze; PATCH 200",
         %{conn: conn} do
      # The listener watches `chat:agent_runtime` for
      # {:agent_first_state_op, _, _} specifically; any other tuple shape
      # (read ops, search, file inspection) is silently ignored. This proves
      # planning-time tool calls do NOT freeze in-context messages —
      # editing remains permitted until the agent does its first STATE-
      # changing op.
      user = create_user!()
      project = create_project!()
      agent_id = Ecto.UUID.generate()
      task = create_task_with_approved_plan!(project, agent_id, title: "Case 6 task")

      {space, _agent_p, user_p} =
        seed_exec_space_with_user_author!(task, agent_id, "Saru", user)

      msg =
        post_text_message!(
          space.id,
          user_p.id,
          "user message — agent only doing planning-time reads"
        )

      assert is_nil(Repo.get!(Platform.Chat.Message, msg.id).frozen_at)

      # Fire a non-state-changing signal (the production listener will
      # match-fail on this clause and ignore it).
      {:noreply, _} =
        AdHocFreezeListener.handle_info(
          {:agent_read_op, agent_id, space.id},
          %{}
        )

      # Message is still unfrozen.
      assert is_nil(Repo.get!(Platform.Chat.Message, msg.id).frozen_at)

      # PATCH as the author succeeds with 200 OK and the content updates.
      new_content = "user successfully revised — agent was only reading"

      conn =
        conn
        |> login(user.id)
        |> patch(~p"/api/messages/#{msg.id}", %{content: new_content})

      body = json_response(conn, 200)
      assert body["data"]["content"] == new_content

      assert Repo.get!(Platform.Chat.Message, msg.id).content == new_content
    end
  end
end
