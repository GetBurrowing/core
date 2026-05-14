defmodule Platform.Chat.EditPoliciesTest do
  @moduledoc """
  Editable-messages contract — section **f (agent interaction model)**,
  Policies 1, 3 and 4. Companion to `EditPermissionsTest` (Policies 2 + 3
  on the permission side); this file covers the trust-defining policies
  that affect what agents see (Policy 1, notification scoping), what the
  user is warned about (Policy 4, removal warning), and how agent
  corrections render (Policy 3, the `corrects_message_id` flow).

  Policy 3 has two distinct surfaces: (a) "agents can't self-edit" — the
  permission gate covered by `EditPermissionsTest`; and (b) "agents
  correct via a NEW message with `corrects_message_id` set, which the UI
  renders with a 'Correction to earlier message' header" — the rendering
  gate covered here.

  Notification scoping (Policy 1) was originally tagged `:skip` here as an
  implementation gap. Task `019e1e83-...` shipped that work via PR #345
  (squash `e185599` on main), and the comprehensive adversarial coverage
  lives in `apps/platform/test/platform/chat/policy_1_edit_scoping_test.exs`
  (3-agent fan-out, cross-space scoping, dedup, empty-recipient baseline).
  This file's Policy 1 placeholder describe block has been removed to avoid
  duplicate-shape tests — see that file for the full battery.
  """
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.MessageVersions
  alias Platform.Repo

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp insert_user! do
    n = System.unique_integer([:positive, :monotonic])

    Repo.insert!(%User{
      email: "edit-policy-#{n}@example.com",
      name: "Edit Policy Tester #{n}",
      oidc_sub: "edit-policy-sub-#{n}"
    })
  end

  defp authenticated_conn(conn, user) do
    Plug.Test.init_test_session(conn, current_user_id: user.id)
  end

  defp create_space! do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, space} =
      Chat.create_space(%{name: "Edit Policy Space", slug: "edit-policy-#{n}", kind: "channel"})

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

  defp post_message!(space_id, participant_id, content, attrs \\ %{}) do
    {:ok, msg} =
      Chat.post_message(
        Map.merge(
          %{
            space_id: space_id,
            participant_id: participant_id,
            content_type: "text",
            content: content
          },
          attrs
        )
      )

    MessageVersions.record_v1!(msg)
    msg
  end

  # ── Policy 3: correction-message rendering (Section d.4) ────────────────

  describe "Policy 3 — correction-message rendering" do
    test "agent-issued message with corrects_message_id renders 'Correction to earlier message' header",
         %{conn: conn} do
      user = insert_user!()
      space = create_space!()
      _human = add_user_participant!(space.id, user.id, "Alice")
      agent = add_agent_participant!(space.id, "Saru")

      # The original message the correction will point at
      original = post_message!(space.id, agent.id, "the answer is 42")

      # The correction message — same agent, NEW message with corrects_message_id set
      _correction =
        post_message!(space.id, agent.id, "actually the answer is 41", %{
          corrects_message_id: original.id
        })

      conn = authenticated_conn(conn, user)
      {:ok, _view, html} = live(conn, ~p"/chat/#{space.slug}")

      assert html =~ "Correction to earlier message",
             "correction header copy missing from rendered chat"

      assert html =~ ~s(phx-value-id="#{original.id}"),
             "correction header should carry phx-value-id pointing at the original message"

      assert html =~ ~s(phx-click="scroll_to_message"),
             "correction header should fire scroll_to_message on click"
    end

    test "regular message (no corrects_message_id) does NOT render the correction header",
         %{conn: conn} do
      user = insert_user!()
      space = create_space!()
      _human = add_user_participant!(space.id, user.id, "Alice")
      agent = add_agent_participant!(space.id, "Saru")
      _regular = post_message!(space.id, agent.id, "just a normal message")

      conn = authenticated_conn(conn, user)
      {:ok, _view, html} = live(conn, ~p"/chat/#{space.slug}")

      refute html =~ "Correction to earlier message",
             "correction header should not appear on regular messages"
    end
  end

  # ── Policy 4: removal warning modal (Section f.4) ───────────────────────

  describe "Policy 4 — removal warning modal" do
    test "save_edit with removes_content=true stashes pending edit and renders the modal",
         %{conn: conn} do
      user = insert_user!()
      space = create_space!()
      participant = add_user_participant!(space.id, user.id, "Alice")
      msg = post_message!(space.id, participant.id, "please contact support@example.com for help")

      conn = authenticated_conn(conn, user)
      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

      # Open the editor
      render_hook(view, "edit_message_clicked", %{"message-id" => msg.id})

      # Drive save_edit with removes_content="true" — simulating the JS hook
      # having detected a substring removal.
      html =
        view
        |> render_hook("save_edit", %{
          "message_id" => msg.id,
          "body" => "please contact for help",
          "removes_content" => "true"
        })

      assert html =~ ~s(id="edit-removal-warning"),
             "removal-warning modal should be in the DOM when removes_content=true"

      assert html =~ "Edit removes text.",
             "removal-warning modal title copy missing"

      # The original content should still be in the DB — no PATCH fired yet
      reloaded = Repo.get(Platform.Chat.Message, msg.id)

      assert reloaded.content == "please contact support@example.com for help",
             "DB content must not have changed before the user confirms the modal"
    end

    test "save_edit with removes_content=false fires the edit immediately — no modal rendered",
         %{conn: conn} do
      user = insert_user!()
      space = create_space!()
      participant = add_user_participant!(space.id, user.id, "Alice")
      msg = post_message!(space.id, participant.id, "original content")

      conn = authenticated_conn(conn, user)
      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

      render_hook(view, "edit_message_clicked", %{"message-id" => msg.id})

      html =
        view
        |> render_hook("save_edit", %{
          "message_id" => msg.id,
          "body" => "original content plus additions",
          "removes_content" => "false"
        })

      refute html =~ ~s(id="edit-removal-warning"),
             "removal-warning modal must NOT render when removes_content=false"

      reloaded = Repo.get(Platform.Chat.Message, msg.id)

      assert reloaded.content == "original content plus additions",
             "additive edit should commit immediately"
    end

    test "confirm_save_edit on a stashed pending edit applies it and closes the modal",
         %{conn: conn} do
      user = insert_user!()
      space = create_space!()
      participant = add_user_participant!(space.id, user.id, "Alice")
      msg = post_message!(space.id, participant.id, "leaked secret token here")

      conn = authenticated_conn(conn, user)
      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

      render_hook(view, "edit_message_clicked", %{"message-id" => msg.id})

      render_hook(view, "save_edit", %{
        "message_id" => msg.id,
        "body" => "here",
        "removes_content" => "true"
      })

      # User clicks Continue / Edit anyway — the modal's confirm path
      html = render_hook(view, "confirm_save_edit", %{})

      refute html =~ ~s(id="edit-removal-warning"),
             "modal should be gone after confirm_save_edit"

      reloaded = Repo.get(Platform.Chat.Message, msg.id)
      assert reloaded.content == "here", "DB content should now reflect the confirmed edit"
    end
  end

  # Policy 1 coverage: see
  # `apps/platform/test/platform/chat/policy_1_edit_scoping_test.exs`
  # (Task 019e1e83, shipped via PR #345 / squash e185599). That file
  # owns the canonical adversarial battery — multi-agent fan-out,
  # cross-space scoping, dedup, empty-recipient baseline. Kept out of
  # this file to avoid duplicate-shape tests.
end
