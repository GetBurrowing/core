defmodule PlatformWeb.AppMessagesControllerTest do
  @moduledoc """
  Task 01a111bb stage 2: edit, unsend and read for the iOS 27 messages
  domain (`PATCH|DELETE /api/app/messages/:id`,
  `POST /api/app/spaces/:space_id/read`).
  """
  use PlatformWeb.ConnCase, async: false

  import Platform.ExternalUserFixtures

  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Chat.Participant
  alias Platform.Mobile
  alias Platform.Repo

  defp token!(user) do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {:ok, code} = Mobile.issue_exchange_code(user, challenge)
    {:ok, %{token: token}} = Mobile.exchange_code(code, verifier, %{app_install_id: "install-1"})
    token
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp participant!(space_id, user, name) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  setup %{conn: conn} do
    me = create_user!(%{name: "Author"})
    other = create_user!(%{name: "Other"})
    space = channel!()
    mine = participant!(space.id, me, "Author")
    theirs = participant!(space.id, other, "Other Person")

    %{
      conn: conn,
      me: me,
      space: space,
      mine: mine,
      theirs: theirs,
      token: token!(me),
      my_message: post!(space.id, mine.id, "original"),
      their_message: post!(space.id, theirs.id, "theirs")
    }
  end

  describe "401" do
    test "every route refuses a missing bearer", %{conn: conn, space: space, my_message: m} do
      assert json_response(patch(conn, "/api/app/messages/#{m.id}", %{"text" => "x"}), 401)
      assert json_response(delete(conn, "/api/app/messages/#{m.id}"), 401)
      assert json_response(post(conn, "/api/app/spaces/#{space.id}/read", %{}), 401)
    end
  end

  describe "PATCH /api/app/messages/:id" do
    test "edits the caller's own message", %{conn: conn, token: token, my_message: m} do
      body =
        conn
        |> bearer(token)
        |> patch("/api/app/messages/#{m.id}", %{"text" => "edited"})
        |> json_response(200)

      assert body["id"] == m.id
      assert Repo.get!(Message, m.id).content == "edited"
    end

    test "another user's message is 403 and unchanged", %{
      conn: conn,
      token: token,
      their_message: m
    } do
      conn1 = conn |> bearer(token) |> patch("/api/app/messages/#{m.id}", %{"text" => "x"})
      assert json_response(conn1, 403) == %{"error" => "forbidden"}
      assert Repo.get!(Message, m.id).content == "theirs"
    end

    test "a frozen message is 409 with only who froze it", %{
      conn: conn,
      token: token,
      my_message: m,
      theirs: theirs
    } do
      {:ok, _} =
        m
        |> Message.freeze_changeset(%{
          frozen_at: DateTime.utc_now(),
          frozen_by_participant_id: theirs.id
        })
        |> Repo.update()

      conn1 = conn |> bearer(token) |> patch("/api/app/messages/#{m.id}", %{"text" => "late"})
      assert json_response(conn1, 409) == %{"error" => "frozen", "by" => "Other Person"}
      assert Repo.get!(Message, m.id).content == "original"
    end

    test "blank text is 422; a missing or malformed id is 404", %{
      conn: conn,
      token: token,
      my_message: m
    } do
      conn1 = conn |> bearer(token) |> patch("/api/app/messages/#{m.id}", %{"text" => "  "})
      assert json_response(conn1, 422) == %{"error" => "empty_text"}

      for id <- [Ecto.UUID.generate(), "nope"] do
        c = conn |> bearer(token) |> patch("/api/app/messages/#{id}", %{"text" => "x"})
        assert json_response(c, 404) == %{"error" => "not_found"}
      end
    end

    test "a message in a space the caller is not in is 404", %{conn: conn, token: token} do
      elsewhere = channel!()
      stranger = participant!(elsewhere.id, create_user!(), "Stranger")
      m = post!(elsewhere.id, stranger.id, "far away")

      c = conn |> bearer(token) |> patch("/api/app/messages/#{m.id}", %{"text" => "x"})
      assert json_response(c, 404) == %{"error" => "not_found"}
    end
  end

  describe "DELETE /api/app/messages/:id" do
    test "unsends the caller's own message", %{conn: conn, token: token, my_message: m} do
      assert conn |> bearer(token) |> delete("/api/app/messages/#{m.id}") |> response(204)
      assert %Message{deleted_at: %DateTime{}} = Repo.get!(Message, m.id)
    end

    test "another user's message is 403 and stays", %{
      conn: conn,
      token: token,
      their_message: m
    } do
      c = conn |> bearer(token) |> delete("/api/app/messages/#{m.id}")
      assert json_response(c, 403) == %{"error" => "forbidden"}
      assert Repo.get!(Message, m.id).deleted_at == nil
    end
  end

  describe "POST /api/app/spaces/:space_id/read" do
    test "read: true moves the caller's read cursor to that message", %{
      conn: conn,
      token: token,
      space: space,
      mine: mine,
      their_message: m
    } do
      body =
        conn
        |> bearer(token)
        |> post("/api/app/spaces/#{space.id}/read", %{"message_id" => m.id, "read" => true})
        |> json_response(200)

      assert body == %{"read" => true, "message_id" => m.id}
      assert Repo.get!(Participant, mine.id).last_read_message_id == m.id
    end

    test "read: false is 422 not_supported and moves nothing", %{
      conn: conn,
      token: token,
      space: space,
      mine: mine,
      their_message: m
    } do
      c =
        conn
        |> bearer(token)
        |> post("/api/app/spaces/#{space.id}/read", %{"message_id" => m.id, "read" => false})

      assert json_response(c, 422) == %{"error" => "not_supported"}
      assert Repo.get!(Participant, mine.id).last_read_message_id == nil
    end

    test "a space the caller is not in is 404", %{conn: conn, token: token} do
      elsewhere = channel!()

      c =
        conn
        |> bearer(token)
        |> post("/api/app/spaces/#{elsewhere.id}/read", %{
          "message_id" => Ecto.UUID.generate(),
          "read" => true
        })

      assert json_response(c, 404) == %{"error" => "not_found"}
    end
  end

  describe "external scope" do
    test "an external user can edit their own message in an in-scope space, and cannot reach an out-of-scope one",
         %{conn: conn} do
      world = external_world()
      token = token!(world.ext)

      # Positive control: their own message in channel A.
      own = post!(world.a.id, world.p_a_ext.id, "ext original")

      assert conn
             |> bearer(token)
             |> patch("/api/app/messages/#{own.id}", %{"text" => "ext edited"})
             |> json_response(200)

      # Channel B: EXT is not a participant.
      far = post!(world.b.id, world.p_b.id, "b message")
      c = conn |> bearer(token) |> delete("/api/app/messages/#{far.id}")
      assert json_response(c, 404) == %{"error" => "not_found"}
      assert Repo.get!(Message, far.id).deleted_at == nil

      c2 =
        conn
        |> bearer(token)
        |> post("/api/app/spaces/#{world.b.id}/read", %{"message_id" => far.id, "read" => true})

      assert json_response(c2, 404) == %{"error" => "not_found"}
    end
  end
end
