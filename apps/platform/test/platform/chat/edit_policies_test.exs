defmodule Platform.Chat.EditPoliciesTest do
  @moduledoc """
  Editable-messages contract — section **f (agent interaction model)**,
  Policies 1, 3 and 4. Companion to `EditPermissionsTest` (Policies 2 + 3
  on the permission side); this file covers the trust-defining policies
  that affect what agents see (Policy 1, notification scoping), what the
  user is warned about (Policy 4, the removal guard), and how agent
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

  # ── Policy 4: the removal guard (Section f.4) ──────────────────────────
  #
  # Redesign rung 9 stage 4: the warning is the NATIVE confirm the
  # MessageEditor hook raises on submit when the edit removes more than half
  # the text (assets/test/hooks/message_editor.test.js). A declined confirm
  # never reaches the server, so `save_edit` applies whatever it receives,
  # and no custom modal exists to render.

  describe "Policy 4 — save_edit applies directly" do
    test "a large removal applies at once: the content changes, a version is added, no modal",
         %{conn: conn} do
      user = insert_user!()
      space = create_space!()
      participant = add_user_participant!(space.id, user.id, "Alice")
      msg = post_message!(space.id, participant.id, "please contact support@example.com for help")
      versions_before = Platform.Chat.MessageVersions.count_versions(msg.id)

      conn = authenticated_conn(conn, user)
      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

      render_hook(view, "edit_message_clicked", %{"message-id" => msg.id})
      render_hook(view, "save_edit", %{"message_id" => msg.id, "body" => "help"})

      assert Repo.get(Platform.Chat.Message, msg.id).content == "help"
      assert Platform.Chat.MessageVersions.count_versions(msg.id) == versions_before + 1
      refute has_element?(view, "#edit-removal-warning")
      # The editor closed: the edit was applied, not parked.
      refute has_element?(view, "#msg-editor-#{msg.id}")
    end

    test "an additive edit applies at once too", %{conn: conn} do
      user = insert_user!()
      space = create_space!()
      participant = add_user_participant!(space.id, user.id, "Alice")
      msg = post_message!(space.id, participant.id, "original content")

      conn = authenticated_conn(conn, user)
      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

      render_hook(view, "edit_message_clicked", %{"message-id" => msg.id})

      render_hook(view, "save_edit", %{
        "message_id" => msg.id,
        "body" => "original content plus additions"
      })

      assert Repo.get(Platform.Chat.Message, msg.id).content == "original content plus additions"
      refute has_element?(view, "#edit-removal-warning")
    end
  end

  # Policy 1 coverage: see
  # `apps/platform/test/platform/chat/policy_1_edit_scoping_test.exs`
  # (Task 019e1e83, shipped via PR #345 / squash e185599). That file
  # owns the canonical adversarial battery — multi-agent fan-out,
  # cross-space scoping, dedup, empty-recipient baseline. Kept out of
  # this file to avoid duplicate-shape tests.
end
