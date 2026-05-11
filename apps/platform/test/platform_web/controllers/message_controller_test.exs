defmodule PlatformWeb.MessageControllerTest do
  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts
  alias Platform.Chat
  alias Platform.Chat.{Message, MessageVersions, PubSub}
  alias Platform.Repo

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp create_user! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.find_or_create_from_oidc(%{
        sub: "sub-#{n}",
        email: "u#{n}@example.com",
        name: "Test User"
      })

    user
  end

  defp create_space! do
    slug = "msgctl-space-#{System.unique_integer([:positive, :monotonic])}"
    {:ok, space} = Chat.create_space(%{name: "MsgCtl Test", slug: slug, kind: "channel"})
    space
  end

  defp add_user_participant!(space_id, user_id, display_name \\ "Alice") do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user_id,
        joined_at: DateTime.utc_now(),
        display_name: display_name
      })

    p
  end

  defp post_text_message!(space_id, participant_id, content \\ "original content") do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space_id,
        participant_id: participant_id,
        content_type: "text",
        content: content
      })

    # Backfill v1 row so version counting works (the migration backfilled
    # pre-existing rows; in production Task 3+ will call record_v1!/1 from
    # the message creation path, but Chat.post_message hasn't been wired
    # yet for that).
    MessageVersions.record_v1!(msg)
    msg
  end

  defp login(conn, user_id) do
    Plug.Test.init_test_session(conn, %{current_user_id: user_id})
  end

  defp authed_setup do
    user = create_user!()
    space = create_space!()
    participant = add_user_participant!(space.id, user.id, "Alice")
    message = post_text_message!(space.id, participant.id, "original content")
    %{user: user, space: space, participant: participant, message: message}
  end

  # ── PATCH /api/messages/:id ─────────────────────────────────────────────

  describe "PATCH /api/messages/:id — authentication" do
    test "returns 401 when no session", %{conn: conn} do
      %{message: msg} = authed_setup()

      conn = patch(conn, ~p"/api/messages/#{msg.id}", %{content: "new"})

      assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
    end
  end

  describe "PATCH /api/messages/:id — error matrix" do
    test "returns 404 when the message does not exist", %{conn: conn} do
      user = create_user!()
      bogus_id = Ecto.UUID.generate()

      conn =
        conn
        |> login(user.id)
        |> patch(~p"/api/messages/#{bogus_id}", %{content: "new"})

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end

    test "returns 404 when the message is soft-deleted", %{conn: conn} do
      %{user: user, message: msg} = authed_setup()

      {:ok, _} =
        msg |> Message.changeset(%{deleted_at: DateTime.utc_now()}) |> Repo.update()

      conn =
        conn
        |> login(user.id)
        |> patch(~p"/api/messages/#{msg.id}", %{content: "new"})

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end

    test "returns 403 forbidden_not_in_space when the user is not a participant", %{conn: conn} do
      other_user = create_user!()
      %{message: msg} = authed_setup()

      conn =
        conn
        |> login(other_user.id)
        |> patch(~p"/api/messages/#{msg.id}", %{content: "new"})

      assert %{"error" => %{"code" => "forbidden_not_in_space"}} = json_response(conn, 403)
    end

    test "returns 403 forbidden_not_author when the user is in the space but not the author",
         %{conn: conn} do
      %{space: space, message: msg} = authed_setup()
      bob = create_user!()
      _bob_p = add_user_participant!(space.id, bob.id, "Bob")

      conn =
        conn
        |> login(bob.id)
        |> patch(~p"/api/messages/#{msg.id}", %{content: "new"})

      assert %{"error" => %{"code" => "forbidden_not_author"}} = json_response(conn, 403)
    end

    test "returns 422 validation_failed when content is empty", %{conn: conn} do
      %{user: user, message: msg} = authed_setup()

      conn =
        conn
        |> login(user.id)
        |> patch(~p"/api/messages/#{msg.id}", %{content: ""})

      assert %{"error" => %{"code" => "validation_failed", "errors" => %{"content" => _}}} =
               json_response(conn, 422)
    end

    test "returns 422 validation_failed when content exceeds 10_000 chars", %{conn: conn} do
      %{user: user, message: msg} = authed_setup()
      too_long = String.duplicate("x", 10_001)

      conn =
        conn
        |> login(user.id)
        |> patch(~p"/api/messages/#{msg.id}", %{content: too_long})

      assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)
    end

    test "returns 409 frozen with freezing_action payload when the message is frozen",
         %{conn: conn} do
      %{user: user, space: space, message: msg} = authed_setup()
      freezer = add_user_participant!(space.id, create_user!().id, "Saru")

      {:ok, _} = MessageVersions.freeze(msg, freezer.id)

      conn =
        conn
        |> login(user.id)
        |> patch(~p"/api/messages/#{msg.id}", %{content: "new"})

      body = json_response(conn, 409)
      assert body["error"]["code"] == "frozen"
      assert %{"freezing_action" => freezing} = body["error"]
      assert freezing["participant_id"] == freezer.id
      assert freezing["participant_display_name"] == "Saru"
    end
  end

  # ── Happy path + side effects ───────────────────────────────────────────

  describe "PATCH /api/messages/:id — happy path" do
    test "updates content, sets edited_at, records v2, broadcasts :message_edited",
         %{conn: conn} do
      %{user: user, space: space, message: msg} = authed_setup()

      :ok = PubSub.subscribe(space.id)

      conn =
        conn
        |> login(user.id)
        |> patch(~p"/api/messages/#{msg.id}", %{content: "edited body"})

      body = json_response(conn, 200)
      assert body["data"]["content"] == "edited body"
      assert body["data"]["versions_count"] == 2
      assert body["data"]["edited_at"] != nil

      # V2 row appended to chat_message_versions
      versions = MessageVersions.list_versions(msg.id)
      assert [%{version_number: 2, content: "edited body"}, %{version_number: 1}] = versions

      # Broadcast received
      assert_received {:message_edited, payload}
      assert payload.message.id == msg.id
      assert payload.message.content == "edited body"
      assert payload.previous_content == "original content"
      assert payload.version_number == 2
    end

    test "diff payload lists removed-word runs when the edit shortens content",
         %{conn: conn} do
      %{user: user, space: space, participant: participant} = authed_setup()

      msg =
        post_text_message!(
          space.id,
          participant.id,
          "please contact support@example.com for help"
        )

      :ok = PubSub.subscribe(space.id)

      conn =
        conn
        |> login(user.id)
        |> patch(~p"/api/messages/#{msg.id}", %{content: "please contact for help"})

      assert json_response(conn, 200)
      assert_received {:message_edited, %{removed_substrings: removed}}
      assert "support@example.com" in removed
    end

    test "is idempotent on identical content — no new version, no broadcast", %{conn: conn} do
      %{user: user, space: space, message: msg} = authed_setup()

      :ok = PubSub.subscribe(space.id)

      conn =
        conn
        |> login(user.id)
        |> patch(~p"/api/messages/#{msg.id}", %{content: "original content"})

      body = json_response(conn, 200)
      assert body["data"]["content"] == "original content"
      assert body["data"]["versions_count"] == 1

      refute_received {:message_edited, _}
    end
  end

  # ── GET /api/messages/:id/versions ──────────────────────────────────────

  describe "GET /api/messages/:id/versions" do
    test "returns versions newest-first for an authorized space participant",
         %{conn: conn} do
      %{user: user, message: msg, participant: participant} = authed_setup()

      {:ok, _} =
        MessageVersions.record_edit(msg.id, %{
          content: "v2",
          edited_by_participant_id: participant.id,
          edited_by_display_name: "Alice"
        })

      conn =
        conn
        |> login(user.id)
        |> get(~p"/api/messages/#{msg.id}/versions")

      body = json_response(conn, 200)
      assert [v2, v1] = body["data"]
      assert v2["version_number"] == 2
      assert v2["content"] == "v2"
      assert v1["version_number"] == 1
      assert v1["content"] == "original content"
    end

    test "returns 404 when the message does not exist", %{conn: conn} do
      user = create_user!()
      bogus_id = Ecto.UUID.generate()

      conn =
        conn
        |> login(user.id)
        |> get(~p"/api/messages/#{bogus_id}/versions")

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end

    test "returns 403 when the user is not a space participant", %{conn: conn} do
      other_user = create_user!()
      %{message: msg} = authed_setup()

      conn =
        conn
        |> login(other_user.id)
        |> get(~p"/api/messages/#{msg.id}/versions")

      assert %{"error" => %{"code" => "forbidden_not_in_space"}} = json_response(conn, 403)
    end
  end
end
