defmodule Platform.Security.VoiceRecordTagForgeryTest do
  @moduledoc """
  A client cannot tag its own message as a Voice tab record (voice DM
  stage 1).

  `AttentionRouter.dm_voice_record?/2` suppresses ALL routing for a DM message
  whose metadata carries `"source" => "voice"` and a `"voice_session_id"`. If
  a client could set those keys it could silence the DM's agent, suppress the
  other party's push, or forge "voice turns". So every client post path must
  build message metadata server-side and drop whatever metadata the caller
  sends. One test per path, each sending the voice tag every way a caller
  could (top-level keys, a `metadata` map, nested in the form params):

    * the chat composer (`ChatLive` `"send_message"`)
    * the native app API (`POST /api/app/spaces/:space_id/messages`)
    * the runtime channel `"reply"` event (an agent runtime)
    * the MCP `send_media` and `dm_create` tools

  Each asserts the stored row is NOT a voice record and still routes: a
  user-authored DM message `:directed` to the agent, an agent-authored one to
  the human (a non-empty decision list, so not the `:voice_record` exit).
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.ChannelTest, except: [connect: 2, connect: 3, push: 3]
  require Phoenix.ChannelTest
  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{AttentionRouter, Message, Participant}
  alias Platform.Federation
  alias Platform.Federation.ToolSurface
  alias Platform.Mobile
  alias Platform.Repo

  setup do
    previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)
    previous_root = Application.get_env(:platform, :chat_attachments_root)
    upload_root = Platform.TestTemp.mkdir!("voice_record_forgery_uploads")

    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)
    Application.put_env(:platform, :chat_attachments_root, upload_root)

    on_exit(fn ->
      restore(:chat_agent_dispatch_mode, previous_mode)
      restore(:chat_attachments_root, previous_root)
      File.rm_rf(upload_root)
    end)

    router = Process.whereis(AttentionRouter) || start_supervised!({AttentionRouter, []})
    Sandbox.allow(Repo, self(), router)

    user = user!()
    agent = agent!()
    {:ok, dm} = Chat.find_or_create_dm(user.id, "agent", agent.id)

    %{
      user: user,
      agent: agent,
      dm: dm,
      user_p: participant!(dm, "user", user.id),
      agent_p: participant!(dm, "agent", agent.id)
    }
  end

  defp restore(key, nil), do: Application.delete_env(:platform, key)
  defp restore(key, value), do: Application.put_env(:platform, key, value)

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "voice-forgery-#{n}@example.com",
      name: "Test User",
      oidc_sub: "oidc-voice-forgery-#{n}"
    })
  end

  defp agent! do
    n = System.unique_integer([:positive])

    %Agent{}
    |> Agent.changeset(%{
      slug: "helper-agent-#{n}",
      name: "Helper Agent",
      status: "active",
      runtime_type: "external"
    })
    |> Repo.insert!()
  end

  defp participant!(space, type, id),
    do: Repo.get_by!(Participant, space_id: space.id, participant_type: type, participant_id: id)

  defp voice_tag, do: %{"source" => "voice", "voice_session_id" => Ecto.UUID.generate()}

  # Every way a caller could try to hand the tag over.
  defp forged(params), do: params |> Map.merge(voice_tag()) |> Map.put("metadata", voice_tag())

  defp only_message!(space, content) do
    assert [%Message{} = message] =
             space.id
             |> Chat.list_messages(limit: 100)
             |> Enum.filter(&(&1.content == content))

    message
  end

  defp assert_not_a_voice_record(%Message{} = message) do
    metadata = message.metadata || %{}
    refute metadata["source"] == "voice"
    refute Map.has_key?(metadata, "voice_session_id")
    refute AttentionRouter.voice_record?(message)
  end

  defp assert_routes_directed(%Message{} = message, agent_p) do
    agent_p_id = agent_p.id

    assert {:ok, decisions} = AttentionRouter.route(message)
    assert Enum.any?(decisions, &match?(%{participant_id: ^agent_p_id, reason: :directed}, &1))
    :ok = GenServer.call(AttentionRouter, :__drain__)
  end

  defp assert_routes_somewhere(%Message{} = message) do
    assert {:ok, [_ | _]} = AttentionRouter.route(message)
    :ok = GenServer.call(AttentionRouter, :__drain__)
  end

  test "the chat composer drops a client-supplied voice tag", ctx do
    %{conn: conn, user: user, dm: dm, agent_p: agent_p} = ctx
    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, ~p"/chat/#{dm.id}")

    text = "composer forgery #{System.unique_integer([:positive])}"
    render_submit(view, "send_message", forged(%{"compose" => forged(%{"text" => text})}))

    message = only_message!(dm, text)
    assert_not_a_voice_record(message)
    assert_routes_directed(message, agent_p)
  end

  test "the app API drops a client-supplied voice tag", ctx do
    %{conn: conn, user: user, dm: dm, agent_p: agent_p} = ctx
    {verifier, challenge} = pkce()
    {:ok, code} = Mobile.issue_exchange_code(user, challenge)
    {:ok, %{token: token}} = Mobile.exchange_code(code, verifier, %{app_install_id: "install-1"})

    text = "api forgery #{System.unique_integer([:positive])}"

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/app/spaces/#{dm.id}/messages", forged(%{"text" => text}))

    assert %{"message" => %{"id" => id}} = json_response(conn, 201)
    message = Repo.get!(Message, id)
    assert_not_a_voice_record(message)
    assert_routes_directed(message, agent_p)
  end

  test "the runtime channel reply drops a client-supplied voice tag", ctx do
    %{user: user, agent: agent, dm: dm} = ctx

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "rt-voice-forgery-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, raw_token} = Federation.activate_runtime(runtime)
    {:ok, _linked} = Federation.link_agent(activated, agent)

    {:ok, socket} =
      Phoenix.ChannelTest.connect(PlatformWeb.RuntimeSocket, %{
        "runtime_id" => activated.runtime_id,
        "token" => raw_token
      })

    {:ok, _reply, socket} = subscribe_and_join(socket, "runtime:#{activated.runtime_id}", %{})

    text = "runtime forgery #{System.unique_integer([:positive])}"

    ref =
      Phoenix.ChannelTest.push(socket, "reply", forged(%{"space_id" => dm.id, "content" => text}))

    assert_reply ref, :ok, _, 2_000

    message = only_message!(dm, text)
    assert_not_a_voice_record(message)
    assert message.metadata["source"] == "external_runtime"
    assert_routes_somewhere(message)
  end

  test "the MCP send_media tool drops a client-supplied voice tag", ctx do
    %{agent: agent, dm: dm} = ctx
    text = "send_media forgery #{System.unique_integer([:positive])}"

    assert {:ok, %{message_id: id}} =
             ToolSurface.execute(
               "send_media",
               forged(%{
                 "space_id" => dm.id,
                 "content" => text,
                 "file_base64" => Base.encode64("voice forgery bytes"),
                 "filename" => "note.txt"
               }),
               %{agent_id: agent.id}
             )

    message = Repo.get!(Message, id)
    assert_not_a_voice_record(message)
    assert_routes_somewhere(message)
  end

  test "the MCP dm_create tool drops a client-supplied voice tag", ctx do
    %{agent: agent, user: user, dm: dm} = ctx
    text = "dm_create forgery #{System.unique_integer([:positive])}"

    assert {:ok, %{message_id: id, space_id: space_id}} =
             ToolSurface.execute(
               "dm_create",
               forged(%{"user_id" => user.id, "message" => text}),
               %{agent_id: agent.id}
             )

    assert space_id == dm.id
    message = Repo.get!(Message, id)
    assert_not_a_voice_record(message)
    assert_routes_somewhere(message)
  end

  defp pkce do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end
end
