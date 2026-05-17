defmodule Platform.Chat.EditCrossClientTest do
  @moduledoc """
  Editable-messages contract — cross-client behavior + search index
  re-ingest. Task 6 Stage 5.

  These tests confirm that edits made on one LV client propagate to a
  second LV client subscribed to the same space (the live `:message_edited`
  broadcast loop), and that PostgreSQL's full-text search index reflects
  the new content immediately (no separate re-ingest step needed because
  `chat_messages.search_vector` is a `GENERATED ALWAYS AS STORED` column
  — see `priv/repo/migrations/20260314080000_create_chat_tables.exs:106`).

  Note: this test exercises the BACKEND propagation path, not the
  full UX flow. The UX path is currently blocked by the 3-dot-menu
  deadclick (filed as task `019e1e78-16fd-7615-93fa-115ac4c8beaa`).
  Once that lands, the manual cross-client verification will also work
  end-to-end.
  """
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  defp insert_user!(slug) do
    Repo.insert!(%User{
      email: "cross-#{slug}@example.com",
      name: "Cross Client #{slug}",
      oidc_sub: "cross-#{slug}"
    })
  end

  defp authenticated_conn(conn, user) do
    Plug.Test.init_test_session(conn, current_user_id: user.id)
  end

  defp create_space! do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, space} =
      Chat.create_space(%{name: "Cross Client Space", slug: "cross-client-#{n}", kind: "channel"})

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

  defp post_message!(space_id, participant_id, content) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space_id,
        participant_id: participant_id,
        content_type: "text",
        content: content
      })

    msg
  end

  describe "cross-client sync (Section c — realtime propagation)" do
    test "edit on one LV propagates to a second LV subscribed to the same space",
         %{conn: conn} do
      # Author Alice owns the message; we mount TWO LV processes as Alice to
      # simulate "same user on two devices" — the broadcast fan-out path is
      # the same as for distinct users, because the broadcast targets the
      # space topic, and both LVs subscribe to that topic on mount.
      user = insert_user!("alice")
      space = create_space!()
      participant = add_user_participant!(space.id, user.id, "Alice")
      msg = post_message!(space.id, participant.id, "original cross-client body")

      conn_a = authenticated_conn(conn, user)
      conn_b = authenticated_conn(Phoenix.ConnTest.build_conn(), user)

      {:ok, view_a, _html_a} = live(conn_a, ~p"/chat/#{space.slug}")
      {:ok, view_b, _html_b} = live(conn_b, ~p"/chat/#{space.slug}")

      # Confirm both views render the original body
      assert render(view_a) =~ "original cross-client body"
      assert render(view_b) =~ "original cross-client body"

      # Edit via view A: open the editor, then save with no removal
      render_hook(view_a, "edit_message_clicked", %{"message-id" => msg.id})

      render_hook(view_a, "save_edit", %{
        "message_id" => msg.id,
        "body" => "updated cross-client body",
        "removes_content" => "false"
      })

      # View A reflects the edit
      assert render(view_a) =~ "updated cross-client body"

      # View B (subscribed to the same space PubSub) should also see the
      # new content within the LV process timing — the `:message_edited`
      # handler at messages_hooks.ex:533 calls stream_insert on the
      # updated message, which the second view's stream receives.
      assert render(view_b) =~ "updated cross-client body",
             "View B should see the edit propagated via PubSub broadcast"

      # Original content is gone from both views
      refute render(view_a) =~ "original cross-client body"
      refute render(view_b) =~ "original cross-client body"
    end
  end

  describe "search index re-ingest on edit (Section b ancillary)" do
    test "edited content is immediately searchable; removed substring is not" do
      space = create_space!()
      user = insert_user!("search-alice")
      participant = add_user_participant!(space.id, user.id, "Alice")

      msg = post_message!(space.id, participant.id, "patient FHIR lookup latency is bad")

      # Confirm the original content is searchable
      [initial_hit] = found_search(space.id, "FHIR latency")
      assert initial_hit.id == msg.id
      [searched_msg] = found_search(space.id, "patient")
      assert searched_msg.id == msg.id

      # Edit the message — remove "FHIR" and rephrase
      {:ok, edited} =
        Platform.Chat.Messages.Edit.apply_edit(
          msg,
          participant,
          "patient lookup latency improved"
        )

      # New content is searchable immediately (Postgres GENERATED column)
      [new_hit] = found_search(space.id, "improved")
      assert new_hit.id == edited.id

      # Removed substring no longer matches
      assert found_search(space.id, "FHIR") == [],
             "search must NOT return the message after the searched-for content was removed"

      # Unchanged words still match
      [still_hit] = found_search(space.id, "latency")
      assert still_hit.id == edited.id
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp found_search(space_id, query) do
    Chat.search_messages(space_id, query, limit: 10)
  end
end
