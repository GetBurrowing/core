defmodule Platform.Mobile.AppEntitiesTest do
  @moduledoc """
  Task 01a10db6 stage 1: `Platform.Mobile.AppEntities`, the queries behind
  the App Intents endpoints.
  """
  # async: false: Inbox.emit fans out to push delivery processes.
  use Platform.DataCase, async: false

  import Platform.ExternalUserFixtures

  alias Platform.Chat
  alias Platform.Inbox
  alias Platform.Mobile
  alias Platform.Mobile.AppEntities

  defp emit!(user, kind, source_type \\ "task") do
    {:ok, item} =
      Inbox.emit(%{
        user_id: user.id,
        kind: kind,
        source_type: source_type,
        source_id: Ecto.UUID.generate(),
        title: "t",
        body: "b",
        url: "/inbox"
      })

    item
  end

  describe "list_approvals/1 parity with counts_for_user/1" do
    test "same kinds as the badge counts" do
      assert AppEntities.approval_kinds() == ~w(task_plan_review review_request_pending)
    end

    test "internal user: length equals the approvals count, dismissed rows drop out" do
      user = create_user!()
      plan = emit!(user, "task_plan_review")
      emit!(user, "review_request_pending", "task_review")
      emit!(user, "chat_mention", "chat_message")
      emit!(create_user!(), "task_plan_review")

      assert length(AppEntities.list_approvals(user)) == Mobile.counts_for_user(user).approvals
      assert Mobile.counts_for_user(user).approvals == 2

      {:ok, _} = Inbox.mark_dismissed(plan.id, user.id)
      assert length(AppEntities.list_approvals(user)) == Mobile.counts_for_user(user).approvals
      assert Mobile.counts_for_user(user).approvals == 1
    end

    test "external user: the reachable scope applies to both" do
      world = external_world()
      emit!(world.ext, "task_plan_review")
      emit!(world.ext, "review_request_pending", "task_review")

      assert length(AppEntities.list_approvals(world.ext)) ==
               Mobile.counts_for_user(world.ext).approvals
    end

    test "a row whose task is gone still lists, with the inbox title and no space" do
      user = create_user!()
      item = emit!(user, "task_plan_review")

      assert [
               %{
                 id: id,
                 kind: "plan",
                 title: "t",
                 space_name: nil,
                 space_path_segment: nil,
                 summary: "b"
               }
             ] = AppEntities.list_approvals(user)

      assert id == item.id
    end
  end

  describe "authorize_space/2" do
    test "admits a participant, refuses everything else" do
      user = create_user!()
      mine = channel!()
      add_user!(mine.id, user.id)
      theirs = channel!()

      assert {:ok, %Chat.Space{id: id}, %Chat.Participant{}} =
               AppEntities.authorize_space(user, mine.id)

      assert id == mine.id

      for space_id <- [theirs.id, Ecto.UUID.generate(), "nope", nil, 42] do
        assert AppEntities.authorize_space(user, space_id) == {:error, :forbidden}
      end
    end

    test "refuses an archived space even for a participant" do
      user = create_user!()
      space = channel!()
      add_user!(space.id, user.id)

      Platform.Repo.update_all(
        Ecto.Query.from(s in Chat.Space, where: s.id == ^space.id),
        set: [archived_at: DateTime.utc_now()]
      )

      assert AppEntities.authorize_space(user, space.id) == {:error, :forbidden}
    end

    test "an external user is refused an out-of-scope space" do
      world = external_world()
      assert {:ok, _, _} = AppEntities.authorize_space(world.ext, world.a.id)
      assert AppEntities.authorize_space(world.ext, world.b.id) == {:error, :forbidden}
    end
  end

  describe "list_tasks/2" do
    test "a LIKE wildcard in q is matched literally" do
      user = create_user!()

      {:ok, project} =
        Platform.Tasks.create_project(%{name: "Like #{System.unique_integer([:positive])}"})

      for title <- ["100% done", "1000 done"] do
        {:ok, _} =
          Platform.Tasks.create_task(%{
            project_id: project.id,
            title: title,
            status: "in_progress",
            assignee_type: "user",
            assignee_id: user.id
          })
      end

      assert [%{title: "100% done"}] = AppEntities.list_tasks(user, q: "0%")
    end
  end

  describe "clamp_limit/3" do
    test "defaults, caps and rejects junk" do
      assert AppEntities.clamp_limit(nil, 25, 50) == 25
      assert AppEntities.clamp_limit("10", 25, 50) == 10
      assert AppEntities.clamp_limit("500", 25, 50) == 50
      assert AppEntities.clamp_limit(7, 25, 50) == 7
      assert AppEntities.clamp_limit("0", 25, 50) == 25
      assert AppEntities.clamp_limit("-3", 25, 50) == 25
      assert AppEntities.clamp_limit("ten", 25, 50) == 25
    end
  end

  describe "poll_messages/3" do
    test "a malformed cursor is refused, not passed to the query" do
      user = create_user!()
      space = channel!()
      add_user!(space.id, user.id)

      assert AppEntities.poll_messages(user, space.id, after: "x") == {:error, :invalid_cursor}
      assert {:ok, []} = AppEntities.poll_messages(user, space.id, after: nil)
    end
  end
end
