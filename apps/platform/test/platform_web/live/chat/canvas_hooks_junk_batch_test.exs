defmodule PlatformWeb.ChatLive.CanvasHooksJunkBatchTest do
  @moduledoc """
  Coverage for the `junk_batch:*` inline route added to
  `PlatformWeb.ChatLive.CanvasHooks.handle_event/3` for
  `"canvas_action_click"` (task 019f5e2b-8d29 stage 5, modal step
  layered on top by task 019f6e2c stage 4).

  Focuses on the routing + authorization + modal-open behavior. The
  underlying `Platform.Meetings.Triage.junk_batch/2` has its own
  coverage in `test/platform/meetings/triage_test.exs`.

  ⚠️  A parallel task (019f70ff-…) is fixing two known bugs in the
  canvas action-click plumbing (main-view event-bubbling swallow +
  empty-payload in the pinned sidebar view). If a test here observes
  either symptom, the fix ships as its own PR — not this task.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings.Triage
  alias Platform.{Repo, Tasks, Tenancy}
  alias Platform.Tasks.Task

  setup do
    previous_root = Application.get_env(:platform, :chat_attachments_root)

    upload_root =
      Path.join(
        System.tmp_dir!(),
        "junk_batch_hook_uploads_#{System.unique_integer([:positive])}"
      )

    Application.put_env(:platform, :chat_attachments_root, upload_root)

    on_exit(fn ->
      File.rm_rf(upload_root)
      Application.put_env(:platform, :chat_attachments_root, previous_root)
    end)

    :ok
  end

  defp insert_user(email) do
    Repo.insert!(%User{
      email: email,
      name: "User #{email}",
      oidc_sub: "oidc-#{email}-#{System.unique_integer([:positive])}"
    })
  end

  defp promote_admin(user) do
    {:ok, _} = Tenancy.promote_to_admin(user, actor_id: user.id, reason: "test-fixture")
    :ok
  end

  defp make_general_space! do
    case Chat.get_space_by_slug("general") do
      %Chat.Space{} = space ->
        space

      nil ->
        {:ok, space} =
          Chat.create_space(%{
            name: "General",
            slug: "general",
            kind: "channel"
          })

        space
    end
  end

  defp file_triage_batch(space, owner_user, project) do
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: owner_user.id,
        display_name: owner_user.name,
        joined_at: DateTime.utc_now()
      })

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => participant.id,
        "title" => "Meeting triage canvas"
      })

    {:ok, %{filed: filed}} =
      Triage.file_tasks_from_canvas(canvas,
        project_id: project.id,
        action_items: [
          %{title: "Ship mobile app v2.3"},
          %{title: "Rotate S3 access keys"},
          %{title: "Draft SXI engagement letter"}
        ]
      )

    {canvas, participant, filed}
  end

  describe "canvas_action_click routes junk_batch:* to the confirmation modal" do
    test "owner (canvas creator) click opens the modal with a preview count", %{conn: conn} do
      owner = insert_user("owner-modal@example.com")
      space = make_general_space!()

      {:ok, project} =
        Tasks.create_project(%{
          name: "JunkOwnerModal #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/junk-owner-modal"
        })

      {canvas, _participant, filed} = file_triage_batch(space, owner, project)

      conn = init_test_session(conn, current_user_id: owner.id)
      {:ok, view, _html} = live(conn, ~p"/chat/general", on_error: :warn)

      html =
        render_click(view, "canvas_action_click", %{
          "canvas-id" => canvas.id,
          "node-id" => "does-not-matter",
          "value" => "junk_batch:#{canvas.id}"
        })

      # Modal renders — the destructive step is now behind a confirm click.
      assert html =~ ~s(data-role="junk-batch-modal")
      assert html =~ ~s(data-role="junk-batch-confirm")
      assert html =~ ~s(data-role="junk-batch-preview-count")
      # The preview count is baked into the visible copy.
      assert html =~ "3"

      # DB unchanged — the intercept opens a modal, it does NOT fire the delete.
      for %Task{id: id} <- filed do
        refute Repo.get!(Task, id).deleted_at,
               "opening the modal must not soft-delete #{id}"
      end
    end

    test "fabrikam admin (non-owner) click also opens the modal", %{conn: conn} do
      owner = insert_user("owner-admin-modal@example.com")
      admin = insert_user("root-admin-modal@example.com")
      :ok = promote_admin(admin)

      space = make_general_space!()

      {:ok, project} =
        Tasks.create_project(%{
          name: "JunkAdminModal #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/junk-admin-modal"
        })

      {canvas, _owner_participant, filed} = file_triage_batch(space, owner, project)

      conn = init_test_session(conn, current_user_id: admin.id)
      {:ok, view, _html} = live(conn, ~p"/chat/general", on_error: :warn)

      html =
        render_click(view, "canvas_action_click", %{
          "canvas-id" => canvas.id,
          "node-id" => "does-not-matter",
          "value" => "junk_batch:#{canvas.id}"
        })

      assert html =~ ~s(data-role="junk-batch-modal")
      assert html =~ ~s(data-role="junk-batch-confirm")

      # Still no soft-delete until the admin clicks confirm.
      for %Task{id: id} <- filed do
        refute Repo.get!(Task, id).deleted_at
      end
    end

    test "non-owner, non-admin user is rejected before the modal opens", %{conn: conn} do
      owner = insert_user("real-owner-modal@example.com")
      stranger = insert_user("stranger-modal@example.com")
      space = make_general_space!()

      {:ok, project} =
        Tasks.create_project(%{
          name: "JunkStrangerModal #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/junk-stranger-modal"
        })

      {canvas, _participant, filed} = file_triage_batch(space, owner, project)

      conn = init_test_session(conn, current_user_id: stranger.id)
      {:ok, view, _html} = live(conn, ~p"/chat/general", on_error: :warn)

      html =
        render_click(view, "canvas_action_click", %{
          "canvas-id" => canvas.id,
          "node-id" => "does-not-matter",
          "value" => "junk_batch:#{canvas.id}"
        })

      # Unauthorized branch flashes, no modal.
      assert html =~ "Only the meeting author or an admin can junk this batch."
      refute html =~ ~s(data-role="junk-batch-modal")

      # DB unchanged.
      for %Task{id: id} <- filed do
        refute Repo.get!(Task, id).deleted_at,
               "stranger should not have been able to soft-delete #{id}"
      end
    end

    test "already-drained canvas opens the modal in its empty-state form", %{conn: conn} do
      owner = insert_user("owner-empty-modal@example.com")
      space = make_general_space!()

      {:ok, project} =
        Tasks.create_project(%{
          name: "JunkEmptyModal #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/junk-empty-modal"
        })

      {canvas, _participant, _filed} = file_triage_batch(space, owner, project)

      # Pre-junk the batch so the preview sees zero survivors.
      {:ok, _} = Triage.junk_batch(canvas, actor_id: owner.id)

      conn = init_test_session(conn, current_user_id: owner.id)
      {:ok, view, _html} = live(conn, ~p"/chat/general", on_error: :warn)

      html =
        render_click(view, "canvas_action_click", %{
          "canvas-id" => canvas.id,
          "node-id" => "does-not-matter",
          "value" => "junk_batch:#{canvas.id}"
        })

      # Empty-state renders — the confirm button is HIDDEN, only Close remains.
      # This IS the M5b acceptance-criterion-5 empty-batch guard.
      assert html =~ ~s(data-role="junk-batch-modal")
      assert html =~ "Nothing to roll back"
      refute html =~ ~s(data-role="junk-batch-confirm")
    end

    test "unrelated action values still fall through to the emit-only path", %{conn: conn} do
      owner = insert_user("emit-owner-modal@example.com")
      space = make_general_space!()

      {:ok, project} =
        Tasks.create_project(%{
          name: "EmitOnlyModal #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/emit-only-modal"
        })

      {canvas, _participant, _filed} = file_triage_batch(space, owner, project)

      conn = init_test_session(conn, current_user_id: owner.id)
      {:ok, view, _html} = live(conn, ~p"/chat/general", on_error: :warn)

      render_click(view, "canvas_action_click", %{
        "canvas-id" => canvas.id,
        "node-id" => "some-other-node",
        "value" => "approve"
      })

      html = render(view)

      # Generic flash lands rather than a junk-batch-specific string.
      assert html =~ "Canvas action:"
      refute html =~ ~s(data-role="junk-batch-modal")
    end
  end

  describe "confirm_junk_batch fires the underlying Triage.junk_batch/2" do
    test "clicking confirm from an open modal soft-deletes and closes the modal",
         %{conn: conn} do
      owner = insert_user("confirm-owner@example.com")
      space = make_general_space!()

      {:ok, project} =
        Tasks.create_project(%{
          name: "ConfirmJunk #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/confirm-junk"
        })

      {canvas, _participant, filed} = file_triage_batch(space, owner, project)

      conn = init_test_session(conn, current_user_id: owner.id)
      {:ok, view, _html} = live(conn, ~p"/chat/general", on_error: :warn)

      # 1. Open the modal.
      render_click(view, "canvas_action_click", %{
        "canvas-id" => canvas.id,
        "node-id" => "does-not-matter",
        "value" => "junk_batch:#{canvas.id}"
      })

      # 2. Fire confirm — this is what actually calls Triage.junk_batch/2.
      html = render_click(view, "confirm_junk_batch", %{})

      # Feedback flash + the modal is gone.
      assert html =~ "Batch rolled back"
      refute html =~ ~s(data-role="junk-batch-modal")

      # DB: every filed task is soft-deleted.
      for %Task{id: id} <- filed do
        assert Repo.get!(Task, id).deleted_at, "expected #{id} to be soft-deleted post-confirm"
      end
    end

    test "close_junk_batch_modal tears down state without firing the delete",
         %{conn: conn} do
      owner = insert_user("close-owner@example.com")
      space = make_general_space!()

      {:ok, project} =
        Tasks.create_project(%{
          name: "CloseModal #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/close-modal"
        })

      {canvas, _participant, filed} = file_triage_batch(space, owner, project)

      conn = init_test_session(conn, current_user_id: owner.id)
      {:ok, view, _html} = live(conn, ~p"/chat/general", on_error: :warn)

      render_click(view, "canvas_action_click", %{
        "canvas-id" => canvas.id,
        "node-id" => "does-not-matter",
        "value" => "junk_batch:#{canvas.id}"
      })

      html = render_click(view, "close_junk_batch_modal", %{})

      refute html =~ ~s(data-role="junk-batch-modal")

      # Backing DB untouched.
      for %Task{id: id} <- filed do
        refute Repo.get!(Task, id).deleted_at
      end
    end
  end
end
