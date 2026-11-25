defmodule PlatformWeb.VoiceLiveOnDeviceTest do
  @moduledoc """
  The Voice tab's on-device path (task 01a20dc5 stage 2), driven through
  `/voice` as the VoiceTab hook drives it (`render_hook/3`):

    * without `voice_native_ready`, or with `available: false` for any
      reason, the tab renders exactly what it rendered before;
    * with `available: true` a `voice_native_turn` posts one plain DM
      message (deduped by `client_turn_id`), the agent's reply is pushed as
      `voice_native_speak` without markdown, the user's own echo is not, and
      a partner change pushes `voice_native_stop` and releases the `:voice`
      hold;
    * the on-device states (speaking outline, Stopped, permission card, test
      caption, mic in use) render only on that path.

  Fixture names are generic.
  """

  use PlatformWeb.ConnCase, async: false

  doctest PlatformWeb.Components.Voice, only: [pocket_credit: 1]

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Repo
  alias PlatformWeb.Components.Voice
  alias PlatformWeb.SpaceTopics

  @reasons ~w(os_too_old unavailable locale_unsupported speech_permission_denied assets_missing)

  setup %{conn: conn} do
    viewer = user!()
    agent = burrow!()
    {:ok, conn: init_test_session(conn, current_user_id: viewer.id), viewer: viewer, agent: agent}
  end

  # ── fallback: nothing changes ─────────────────────────────────────────

  test "without voice_native_ready the tab is today's", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/voice")
    d = doc(view)

    assert text(d, "#listen-text") == Voice.idle_line()
    assert q(d, "#voice-native-pending") |> Enum.count() == 0
    assert q(d, "#voice-native-caption") |> Enum.count() == 0
    assert q(d, "#voice-permission") |> Enum.count() == 0
    assert q(d, "[data-on-device]") |> Enum.count() == 0
    assert q(d, "#mic") |> Enum.count() == 1
  end

  test "voice_native_ready with available false, for every reason, changes nothing",
       %{conn: conn} do
    for reason <- @reasons ++ ["something-new"] do
      {:ok, view, _html} = live(conn, ~p"/voice")
      before = stable(view)

      hook(view, "voice_native_ready", %{
        "available" => false,
        "reason" => reason,
        "test_build" => true,
        "route" => "Bluetooth"
      })

      assert stable(view) == before, "reason #{reason} changed the render"
      refute assigns(view).on_device?
      assert assigns(view).native_conn == nil
    end
  end

  # ── a reconnect keeps the conversation (task 01a20dc5, device report) ──

  # On a real iPhone a dropped socket remounted VoiceLive on its default,
  # Burrow, mid-conversation with another agent. The device now remembers the
  # partner per user (VoiceContext, data-keys) and pushes it back after every
  # mount and reconnect.
  test "a reconnect puts the remembered partner back instead of the default",
       %{conn: conn, viewer: viewer} do
    other = agent!("helper-#{System.unique_integer([:positive])}", "Helper")
    key = "burrow-voice-partner:#{viewer.id}"

    {:ok, view, _html} = live(conn, ~p"/voice")
    assert attr_of(view, "#voice-screen", "data-keys") =~ key
    view |> element("#partner-opt-#{other.id}") |> render_click()
    assert_push_event(view, "voice_saved", %{key: ^key, id: picked})
    assert picked == other.id

    # The socket drops and comes back: LiveView mounts a fresh view, which
    # starts on the default until the device speaks.
    {:ok, again, _html} = live(conn, ~p"/voice")
    assert assigns(again).partner.agent.slug == "meeting-assistant"
    again |> element("#voice-screen") |> render_hook("voice_restore", %{key => other.id})

    assert assigns(again).partner.agent.id == other.id
    assert text(doc(again), "#partner-name") == "Helper"
  end

  test "on the device the restored partner's DM is the one held", %{conn: conn, viewer: viewer} do
    other = agent!("helper-#{System.unique_integer([:positive])}", "Helper")
    view = ready!(conn)
    burrow_dm = assigns(view).native_conn.space_id

    view
    |> element("#voice-screen")
    |> render_hook("voice_restore", %{"burrow-voice-partner:#{viewer.id}" => other.id})

    refute SpaceTopics.held_by?(socket(view), burrow_dm, :voice)
    assert assigns(view).native_conn.agent_id == other.id
    assert SpaceTopics.held_by?(socket(view), assigns(view).native_conn.space_id, :voice)
  end

  test "meeting-assistant stays the default when nothing is remembered; a stale id is cleared",
       %{conn: conn, viewer: viewer} do
    key = "burrow-voice-partner:#{viewer.id}"
    {:ok, view, _html} = live(conn, ~p"/voice")
    assert assigns(view).partner.agent.slug == "meeting-assistant"

    view |> element("#voice-screen") |> render_hook("voice_restore", %{})
    assert assigns(view).partner.agent.slug == "meeting-assistant"

    view
    |> element("#voice-screen")
    |> render_hook("voice_restore", %{key => Ecto.UUID.generate()})

    assert_push_event(view, "voice_saved", %{key: ^key, id: nil})
    assert assigns(view).partner.agent.slug == "meeting-assistant"
  end

  # ── reply voices (on the device only) ────────────────────────────────

  @voices [
    %{"id" => "v-premium", "name" => "Zoe", "quality" => "premium"},
    %{"id" => "v-enhanced", "name" => "Ava", "quality" => "enhanced"},
    %{"id" => "v-default", "name" => "Samantha", "quality" => "default"}
  ]

  test "the reply-voice picker lists the phone's voices and a pick is sent to the phone",
       %{conn: conn} do
    {:ok, today, _html} = live(conn, ~p"/voice")
    hook(today, "voice_native_voices", %{"voices" => @voices, "selected" => "v-premium"})
    refute has_element?(today, "#voice-native-voice")

    view = ready!(conn)
    refute has_element?(view, "#voice-native-voice")

    hook(view, "voice_native_voices", %{
      "voices" => @voices,
      "selected" => "v-premium",
      "missing" => false
    })

    d = doc(view)
    assert text(d, "#voice-native-voice label > span") == "Reply voice"

    assert q(d, "#voice-native-voice-select option")
           |> Enum.map(&LazyHTML.text/1)
           |> Enum.map(&String.trim/1) ==
             ["Zoe · Premium", "Ava · Enhanced", "Samantha · Default"]

    assert has_element?(view, ~s|#voice-native-voice-select option[value="v-premium"][selected]|)
    refute has_element?(view, "#voice-native-voice-missing")

    view |> form("#voice-native-voice", %{"voice" => "v-enhanced"}) |> render_change()
    assert_push_event(view, "voice_native_voice", %{id: "v-enhanced"})
    assert has_element?(view, ~s|#voice-native-voice-select option[value="v-enhanced"][selected]|)
  end

  test "a remembered voice that is gone: the default is selected and the tab says so",
       %{conn: conn} do
    view = ready!(conn)

    hook(view, "voice_native_voices", %{
      "voices" => @voices,
      "selected" => "v-premium",
      "missing" => true
    })

    assert text(doc(view), "#voice-native-voice-missing") ==
             "Your chosen voice isn't on this iPhone. Using Zoe instead."

    view |> form("#voice-native-voice", %{"voice" => "v-default"}) |> render_change()
    refute has_element?(view, "#voice-native-voice-missing")
  end

  # ── the on-device turn ────────────────────────────────────────────────

  test "a turn posts one plain DM message; the agent's reply is spoken without markdown",
       %{conn: conn, viewer: viewer, agent: agent} do
    view = ready!(conn)
    d = doc(view)
    assert q(d, "#voice-native-pending[phx-update=ignore]") |> Enum.count() == 1
    assert text(d, "#listen-text") == Voice.idle_line()

    hook(view, "voice_native_turn", %{
      "text" => "what is left on the launch checklist",
      "client_turn_id" => "ct-1",
      "at" => "9:41 AM"
    })

    assert_reply(view, %{ok: true, message_id: message_id})

    [turn] = dm_rows(viewer, agent)
    assert turn.id == message_id

    # Stored as the words said, never with the agent-only instruction.
    assert turn.content == "what is left on the launch checklist"

    # The transcript shows only the words said (task 01a20fdd stage 3).
    refute Enum.any?(turn_texts(view), &(&1 =~ "burrow_reply_chunk"))
    assert turn.metadata == %{"input" => "on_device", "client_turn_id" => "ct-1"}

    assert turn_texts(view) |> List.last() =~ "on this iPhone · 9:41 AM"
    assert has_element?(view, "#voice-thinking")

    # The user's own message echoes back on the DM topic: never spoken.
    refute_push_event(view, "voice_native_speak", %{}, 100)

    conn_state = assigns(view).native_conn

    {:ok, reply} =
      post_as(conn_state.agent_participant_id, conn_state.space_id, "**Three items:** the deck")

    reply_id = reply.id
    assert_push_event(view, "voice_native_speak", %{id: ^reply_id, text: "Three items: the deck"})
    assert turn_texts(view) |> List.last() =~ "**Three items:** the deck"
    refute has_element?(view, "#voice-thinking")
    assert text(doc(view), "#voice-native-announce") == "Burrow replied"
  end

  test "a duplicate client_turn_id posts once, in this view and after a reconnect",
       %{conn: conn, viewer: viewer, agent: agent} do
    view = ready!(conn)
    hook(view, "voice_native_turn", %{"text" => "once", "client_turn_id" => "ct-dup"})
    assert_reply(view, %{ok: true, message_id: first})
    hook(view, "voice_native_turn", %{"text" => "once", "client_turn_id" => "ct-dup"})
    assert_reply(view, %{ok: true, message_id: ^first})

    # A Retry after the socket dropped lands in a NEW LiveView.
    again = ready!(conn)
    hook(again, "voice_native_turn", %{"text" => "once", "client_turn_id" => "ct-dup"})
    assert_reply(again, %{ok: true, message_id: ^first})

    assert length(dm_rows(viewer, agent)) == 1
  end

  test "a turn without the on-device path is refused", %{conn: conn, viewer: viewer, agent: agent} do
    {:ok, view, _html} = live(conn, ~p"/voice")
    hook(view, "voice_native_turn", %{"text" => "hello", "client_turn_id" => "ct-x"})
    assert_reply(view, %{ok: false})
    assert dm_rows(viewer, agent) == []
  end

  test "no answer in :voice_native_answer_timeout_ms shows today's failed reply", %{conn: conn} do
    Application.put_env(:platform, :voice_native_answer_timeout_ms, 30)
    on_exit(fn -> Application.delete_env(:platform, :voice_native_answer_timeout_ms) end)

    view = ready!(conn)
    hook(view, "voice_native_turn", %{"text" => "anyone there", "client_turn_id" => "ct-t"})
    assert_reply(view, %{ok: true})
    Process.sleep(80)
    assert has_element?(view, "#voice-failed", "Didn't get an answer.")
  end

  # ── changing partner or context ───────────────────────────────────────

  test "a partner change pushes voice_native_stop, releases the :voice hold and holds the new DM",
       %{conn: conn} do
    other = agent!("helper-#{System.unique_integer([:positive])}", "Helper")
    view = ready!(conn)
    old_dm = assigns(view).native_conn.space_id
    assert SpaceTopics.held_by?(socket(view), old_dm, :voice)

    view |> element("#partner-opt-#{other.id}") |> render_click()
    assert_push_event(view, "voice_native_stop", %{})

    refute SpaceTopics.held_by?(socket(view), old_dm, :voice)
    new_dm = assigns(view).native_conn.space_id
    assert new_dm != old_dm
    assert SpaceTopics.held_by?(socket(view), new_dm, :voice)
  end

  test "a context change pushes voice_native_stop and keeps the DM", %{conn: conn, viewer: viewer} do
    space = channel!(viewer)
    view = ready!(conn)
    dm = assigns(view).native_conn.space_id

    view |> element("#ctx-opt-#{space.id}") |> render_click()
    assert_push_event(view, "voice_native_stop", %{})
    assert assigns(view).native_conn.space_id == dm
    assert SpaceTopics.held_by?(socket(view), dm, :voice)
  end

  # ── the on-device states ──────────────────────────────────────────────

  test "an unreachable partner can still talk on the device", %{conn: conn} do
    burrow!(reachable: false)
    {:ok, view, _html} = live(conn, ~p"/voice")
    assert has_element?(view, "#mic[disabled]")

    hook(view, "voice_native_ready", %{"available" => true})
    refute has_element?(view, "#mic[disabled]")
    assert text(doc(view), "#listen-text") == Voice.idle_line()
  end

  test "held and toggled read Release to send / Tap to send; in use disables the mic",
       %{conn: conn} do
    view = ready!(conn)
    hook(view, "voice_native_mic", %{"state" => "held"})
    assert text(doc(view), "#listen-text") == "Release to send"
    assert has_element?(view, "#mic.bg-primary[aria-pressed=true]")
    refute has_element?(view, "#voice-live"), "the hook draws the forming words itself"

    hook(view, "voice_native_mic", %{"state" => "toggled"})
    assert text(doc(view), "#listen-text") == "Tap to send"

    hook(view, "voice_native_mic", %{"state" => "in_use"})
    assert text(doc(view), "#listen-text") == "Microphone in use by another app"
    assert has_element?(view, "#mic[disabled].text-secondary")

    hook(view, "voice_native_mic", %{"state" => "idle"})
    assert text(doc(view), "#listen-text") == Voice.idle_line()
  end

  test "preparing disables the mic with \"Preparing speech on this iPhone\" until the files are in",
       %{conn: conn} do
    view = ready!(conn)
    hook(view, "voice_native_mic", %{"state" => "preparing"})

    assert text(doc(view), "#listen-text") == "Preparing speech on this iPhone"
    assert has_element?(view, "#listen-text.text-secondary")
    assert has_element?(view, "#mic[disabled].preparing.text-secondary")

    hook(view, "voice_native_mic", %{"state" => "idle"})
    assert text(doc(view), "#listen-text") == Voice.idle_line()
    refute has_element?(view, "#mic[disabled]")
    refute has_element?(view, "#mic.preparing")
  end

  test "preparing that never finishes puts today's tab back and releases the :voice hold",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/voice")

    hook(view, "voice_native_ready", %{"available" => true, "test_build" => true})
    assert assigns(view).on_device?
    dm = assigns(view).native_conn.space_id
    hook(view, "voice_native_mic", %{"state" => "preparing"})
    hook(view, "voice_native_ready", %{"available" => false, "reason" => "assets_missing"})

    refute assigns(view).on_device?
    assert assigns(view).native_conn == nil
    refute SpaceTopics.held_by?(socket(view), dm, :voice)

    # Today's tab, as in the first test of this file.
    d = doc(view)
    assert text(d, "#listen-text") == Voice.idle_line()
    assert q(d, "#voice-native-pending") |> Enum.count() == 0
    assert q(d, "#voice-native-caption") |> Enum.count() == 0
    assert q(d, "#voice-permission") |> Enum.count() == 0
    assert q(d, "[data-on-device]") |> Enum.count() == 0
    assert q(d, "#mic") |> Enum.count() == 1
    assert q(d, "#mic[disabled]") |> Enum.count() == 0
  end

  test "speaking rings #partner-avatar until finished; stopped notes the reply", %{conn: conn} do
    view = ready!(conn)
    hook(view, "voice_native_turn", %{"text" => "go", "client_turn_id" => "ct-s"})
    assert_reply(view, %{ok: true})
    c = assigns(view).native_conn
    {:ok, reply} = post_as(c.agent_participant_id, c.space_id, "an answer")
    reply_id = reply.id
    assert_push_event(view, "voice_native_speak", %{id: ^reply_id})

    refute has_element?(view, "#partner-avatar[data-speaking]")
    hook(view, "voice_native_speaking", %{"id" => reply.id, "state" => "started"})
    assert has_element?(view, "#partner-avatar[data-speaking].outline-primary")

    hook(view, "voice_native_speaking", %{
      "id" => reply.id,
      "state" => "stopped",
      "reason" => "mic_opened"
    })

    refute has_element?(view, "#partner-avatar[data-speaking]")
    assert has_element?(view, "[data-reply-note]", "Stopped")

    hook(view, "voice_native_speaking", %{
      "id" => reply.id,
      "state" => "unheard",
      "reason" => "no_audio_route"
    })

    assert has_element?(view, "[data-reply-note]", "Reply shown as text")
  end

  test "a mic refusal shows the permission card with Type instead beneath it", %{conn: conn} do
    view = ready!(conn)
    hook(view, "voice_native_permission", %{"mic" => "denied"})
    d = doc(view)
    assert text(d, "#voice-permission-text") == "Burrow needs the microphone to hear you."
    assert text(d, "#voice-open-settings") == "Open Settings"
    assert q(d, "#voice-type-instead") |> Enum.count() == 1
    assert q(d, "#mic") |> Enum.count() == 0
    # Open Settings is the screen's only primary fill.
    assert q(d, "#voice-area .bg-primary") |> Enum.count() == 1

    view |> element("#voice-type-instead") |> render_click()
    assert has_element?(view, "#voice-type-form")
  end

  test "the test caption shows only on a test build, with the route's generic label",
       %{conn: conn} do
    view = ready!(conn)
    refute has_element?(view, "#voice-native-caption")

    view = ready!(conn, %{"test_build" => true})
    assert text(doc(view), "#voice-native-caption") == "On this iPhone"

    hook(view, "voice_native_route", %{"label" => "Bluetooth"})
    assert text(doc(view), "#voice-native-caption") == "On this iPhone · Bluetooth"

    # A device's own name never reaches the caption.
    hook(view, "voice_native_route", %{"label" => "A Person's Headset"})
    assert text(doc(view), "#voice-native-caption") == "On this iPhone"
  end

  # ── streamed replies (task 01a20fdd stage 3) ──────────────────────────

  defp turn!(view, id \\ "ct-s") do
    hook(view, "voice_native_turn", %{"text" => "tell me", "client_turn_id" => id})
    assert_reply(view, %{ok: true})
    assigns(view).native_conn
  end

  defp chunk(conn_state, chunk_id, text, opts \\ []) do
    Platform.Chat.PubSub.broadcast(
      conn_state.space_id,
      {:agent_reply_chunk,
       %{
         space_id: conn_state.space_id,
         chunk_id: chunk_id,
         text: text,
         done: Keyword.get(opts, :done, false),
         participant_id: Keyword.get(opts, :from, conn_state.agent_participant_id)
       }}
    )
  end

  test "chunks are spoken as their sentences complete; the posted reply adds only the rest, once",
       %{conn: conn} do
    view = ready!(conn)
    c = turn!(view)

    chunk(c, "c1", "First sentence. Sec")

    assert_push_event(view, "voice_native_speak_part", %{
      id: "c1",
      seq: 0,
      text: "First sentence.",
      final: false
    })

    chunk(c, "c1", "First sentence. Second one, e.g. this. Thi")

    assert_push_event(view, "voice_native_speak_part", %{
      id: "c1",
      seq: 1,
      text: "Second one, e.g. this.",
      final: false
    })

    chunk(c, "c1", "First sentence. Second one, e.g. this. Thi")
    refute_push_event(view, "voice_native_speak_part", %{seq: 2}, 100)

    {:ok, reply} =
      post_as(c.agent_participant_id, c.space_id, "First sentence. Second one, e.g. this. Third.")

    assert_push_event(view, "voice_native_speak_part", %{
      id: "c1",
      seq: 2,
      text: "Third.",
      final: true
    })

    refute_push_event(view, "voice_native_speak", %{}, 100)
    refute_push_event(view, "voice_native_speak_part", %{seq: 0}, 50)
    assert turn_texts(view) |> List.last() =~ "Third."
    refute has_element?(view, "#voice-thinking")

    # The phone's speech events use the chunk id and land on the posted turn.
    hook(view, "voice_native_speaking", %{"id" => "c1", "state" => "started"})
    assert assigns(view).speaking_id == "c1"

    hook(view, "voice_native_speaking", %{
      "id" => "c1",
      "state" => "stopped",
      "reason" => "mic_opened"
    })

    assert turn_texts(view) |> List.last() =~ "Stopped"
    assert Map.has_key?(assigns(view).native_replies, reply.id)
  end

  test "a reply posted with nothing left to stream still finishes its stream (empty final part)",
       %{conn: conn} do
    view = ready!(conn)
    c = turn!(view)
    chunk(c, "c1", "Only this. ")
    assert_push_event(view, "voice_native_speak_part", %{id: "c1", seq: 0, text: "Only this."})
    {:ok, _} = post_as(c.agent_participant_id, c.space_id, "Only this.")
    assert_push_event(view, "voice_native_speak_part", %{id: "c1", seq: 1, text: "", final: true})
  end

  test "a chunk from anyone else, before a turn, or of another id is ignored", %{conn: conn} do
    view = ready!(conn)
    hook(view, "voice_native_turn", %{"text" => "x", "client_turn_id" => "ct-pre"})
    assert_reply(view, %{ok: true})
    c = assigns(view).native_conn

    chunk(c, "c-user", "Not the agent. ", from: c.user_participant_id)
    refute_push_event(view, "voice_native_speak_part", %{}, 100)

    chunk(c, "c1", "Mine. ")
    assert_push_event(view, "voice_native_speak_part", %{id: "c1"})
    chunk(c, "c2", "Another reply. ")
    refute_push_event(view, "voice_native_speak_part", %{id: "c2"}, 100)
  end

  test "no chunk before a turn is spoken", %{conn: conn} do
    view = ready!(conn)
    c = assigns(view).native_conn
    chunk(%{c | turn_at: DateTime.utc_now()}, "c0", "Too early. ")
    refute_push_event(view, "voice_native_speak_part", %{}, 100)
  end

  test "with no chunk the one-shot speak runs unchanged", %{conn: conn} do
    view = ready!(conn)
    c = turn!(view)
    {:ok, reply} = post_as(c.agent_participant_id, c.space_id, "Plain reply. Two sentences.")
    reply_id = reply.id

    assert_push_event(view, "voice_native_speak", %{
      id: ^reply_id,
      text: "Plain reply. Two sentences."
    })

    refute_push_event(view, "voice_native_speak_part", %{}, 100)
  end

  test "a posted text that diverges from the stream stops speech, never re-reads it",
       %{conn: conn} do
    view = ready!(conn)
    c = turn!(view)
    chunk(c, "c1", "Alpha is first. ")
    assert_push_event(view, "voice_native_speak_part", %{id: "c1", seq: 0})
    {:ok, _} = post_as(c.agent_participant_id, c.space_id, "Something else entirely.")
    assert_push_event(view, "voice_native_stop_speaking", %{id: "c1"})
    refute_push_event(view, "voice_native_speak_part", %{final: true}, 100)
    refute_push_event(view, "voice_native_speak", %{}, 50)
    assert turn_texts(view) |> List.last() =~ "Something else entirely."
  end

  test "a stream the phone stopped (the mic) speaks nothing more and is shown Stopped",
       %{conn: conn} do
    view = ready!(conn)
    c = turn!(view)
    chunk(c, "c1", "One. ")
    assert_push_event(view, "voice_native_speak_part", %{id: "c1", seq: 0})

    hook(view, "voice_native_speaking", %{
      "id" => "c1",
      "state" => "stopped",
      "reason" => "mic_opened"
    })

    chunk(c, "c1", "One. Two. ")
    refute_push_event(view, "voice_native_speak_part", %{}, 100)
    {:ok, _} = post_as(c.agent_participant_id, c.space_id, "One. Two. Three.")
    refute_push_event(view, "voice_native_speak_part", %{}, 100)
    refute_push_event(view, "voice_native_speak", %{}, 50)
    assert turn_texts(view) |> List.last() =~ "Stopped"
  end

  test "a new turn retires the old stream: its late chunks never reach the new reply",
       %{conn: conn} do
    view = ready!(conn)
    c = turn!(view, "ct-1")
    chunk(c, "c-old", "Old one. ")
    assert_push_event(view, "voice_native_speak_part", %{id: "c-old"})
    c = turn!(view, "ct-2")
    chunk(c, "c-old", "Old one. Old two. ")
    refute_push_event(view, "voice_native_speak_part", %{id: "c-old"}, 100)
    chunk(c, "c-new", "New one. ")
    assert_push_event(view, "voice_native_speak_part", %{id: "c-new", seq: 0})
  end

  test "a partner change mid-stream clears it", %{conn: conn} do
    other = agent!("helper-#{System.unique_integer([:positive])}", "Helper")
    view = ready!(conn)
    c = turn!(view)
    chunk(c, "c1", "One. ")
    assert_push_event(view, "voice_native_speak_part", %{id: "c1"})
    assert assigns(view).native_stream.chunk_id == "c1"
    view |> element("#partner-opt-#{other.id}") |> render_click()
    assert_push_event(view, "voice_native_stop", %{})
    assert assigns(view).native_stream == nil
  end

  test "a context change mid-stream clears it", %{conn: conn, viewer: viewer} do
    space = channel!(viewer)
    view = ready!(conn)
    c = turn!(view)
    chunk(c, "c1", "One. ")
    assert_push_event(view, "voice_native_speak_part", %{id: "c1"})
    view |> element("#ctx-opt-#{space.id}") |> render_click()
    assert assigns(view).native_stream == nil
    chunk(c, "c1", "One. Two. ")
    refute_push_event(view, "voice_native_speak_part", %{id: "c1", seq: 1}, 100)
  end

  test "without the device path a chunk changes nothing", %{
    conn: conn,
    viewer: viewer,
    agent: agent
  } do
    {:ok, view, _html} = live(conn, ~p"/voice")
    before = stable(view)
    {:ok, dm} = Chat.find_or_create_dm(viewer.id, "agent", agent.id)

    Platform.Chat.PubSub.broadcast(
      dm.id,
      {:agent_reply_chunk,
       %{
         space_id: dm.id,
         chunk_id: "c",
         text: "Hi. ",
         done: false,
         participant_id: Ecto.UUID.generate()
       }}
    )

    refute_push_event(view, "voice_native_speak_part", %{}, 100)
    assert stable(view) == before
    refute render(view) =~ "Pocket TTS"
  end

  # ── Pocket TTS in the picker ─────────────────────────────────────────

  defp pocket(state, received \\ 0, total \\ 1000, name \\ "marius") do
    %{
      "id" => "pocket-tts:" <> name,
      "name" => "Pocket TTS (#{String.capitalize(name)})",
      "quality" => "neural",
      "model" => %{"state" => state, "received" => received, "total" => total}
    }
  end

  test "Pocket TTS is one more option in the same select, neural first", %{conn: conn} do
    view = ready!(conn)

    hook(view, "voice_native_voices", %{
      "voices" => [pocket("absent") | @voices],
      "selected" => "v-premium"
    })

    d = doc(view)

    assert q(d, "#voice-native-voice-select option") |> Enum.map(&String.trim(LazyHTML.text(&1))) ==
             [
               "Pocket TTS (Marius) · Neural",
               "Zoe · Premium",
               "Ava · Enhanced",
               "Samantha · Default"
             ]

    assert [%{quality: "neural", model: %{state: "absent", received: 0, total: 1000}} | _] =
             assigns(view).native_voices

    refute has_element?(view, "#voice-native-pocket-credit"),
           "no line while a system voice is chosen"
  end

  test "picked while downloading: progress, the system voice meanwhile, the credit", %{conn: conn} do
    view = ready!(conn)

    hook(view, "voice_native_voices", %{
      "voices" => [pocket("absent") | @voices],
      "selected" => "v-premium"
    })

    view |> form("#voice-native-voice", %{"voice" => "pocket-tts:marius"}) |> render_change()
    assert_push_event(view, "voice_native_voice", %{id: "pocket-tts:marius"})

    hook(view, "voice_native_model", %{
      "state" => "downloading",
      "received" => 427,
      "total" => 1000
    })

    d = doc(view)
    assert text(d, "#voice-native-pocket-progress") == "Downloading Pocket TTS · 42%"
    assert text(d, "#voice-native-pocket-meanwhile") == "Speaking with Zoe until it finishes"
    assert text(d, "#voice-native-pocket-credit") == "Pocket TTS by Kyutai · CC BY 4.0"
    refute has_element?(view, "#voice-native-pocket-unavailable")

    hook(view, "voice_native_model", %{"state" => "ready", "received" => 1000, "total" => 1000})
    refute has_element?(view, "#voice-native-pocket-progress")
    refute has_element?(view, "#voice-native-pocket-meanwhile")
    assert text(doc(view), "#voice-native-pocket-credit") == "Pocket TTS by Kyutai · CC BY 4.0"
  end

  test "a CC BY voice credits its source too; a CC0 one only the model (task 01a20fdd stage 4)",
       %{conn: conn} do
    view = ready!(conn)

    hook(view, "voice_native_voices", %{
      "voices" =>
        [pocket("ready"), pocket("ready", 0, 1000, "alba"), pocket("ready", 0, 1000, "george")] ++
          [pocket("ready", 0, 1000, "bill_boerst") | @voices],
      "selected" => "pocket-tts:alba"
    })

    credit = fn -> text(doc(view), "#voice-native-pocket-credit") end
    assert credit.() == "Pocket TTS by Kyutai · CC BY 4.0 · voice: Alba MacKenna"

    view |> form("#voice-native-voice", %{"voice" => "pocket-tts:george"}) |> render_change()

    assert credit.() ==
             "Pocket TTS by Kyutai · CC BY 4.0 · voice: VCTK corpus, CSTR, University of Edinburgh"

    view |> form("#voice-native-voice", %{"voice" => "pocket-tts:bill_boerst"}) |> render_change()
    assert credit.() == "Pocket TTS by Kyutai · CC BY 4.0"

    view |> form("#voice-native-voice", %{"voice" => "v-premium"}) |> render_change()
    refute has_element?(view, "#voice-native-pocket-credit")
  end

  test "every CC BY 4.0 voice the phone lists is credited (THIRD_PARTY.md)" do
    vctk = ~w(anna vera fantine charles paul eponine azelma george mary jane michael eve)
    cc0 = ~w(marius javert bill_boerst caro_davy peter_yearsley stuart_bell estelle)

    for name <- vctk do
      assert Voice.pocket_credit("pocket-tts:" <> name) =~
               "· voice: VCTK corpus, CSTR, University of Edinburgh"
    end

    assert Voice.pocket_credit("pocket-tts:alba") =~ "· voice: Alba MacKenna"

    for name <- cc0,
        do:
          assert(Voice.pocket_credit("pocket-tts:" <> name) == "Pocket TTS by Kyutai · CC BY 4.0")
  end

  test "Pocket rows never push a system voice out of the picker", %{conn: conn} do
    view = ready!(conn)
    pockets = for i <- 1..20, do: pocket("ready", 0, 1000, "voice#{i}")

    systems =
      for i <- 1..40, do: %{"id" => "sys-#{i}", "name" => "System #{i}", "quality" => "default"}

    hook(view, "voice_native_voices", %{"voices" => pockets ++ systems, "selected" => "sys-40"})

    voices = assigns(view).native_voices
    assert length(voices) == 60
    assert Enum.count(voices, &(&1.quality == "neural")) == 20
    assert List.last(voices).id == "sys-40"
    assert assigns(view).native_voice == "sys-40", "the last system voice is still selectable"

    flood = for i <- 1..50, do: pocket("ready", 0, 1000, "flood#{i}")

    hook(view, "voice_native_voices", %{
      "voices" =>
        flood ++ systems ++ [%{"id" => "sys-41", "name" => "Extra", "quality" => "default"}],
      "selected" => "sys-1"
    })

    voices = assigns(view).native_voices
    assert Enum.count(voices, &(&1.quality == "neural")) == 32
    assert Enum.count(voices, &(&1.quality != "neural")) == 40
  end

  test "a failed model, or a remembered Pocket voice the phone no longer offers, reads unavailable",
       %{conn: conn} do
    view = ready!(conn)

    hook(view, "voice_native_voices", %{
      "voices" => [pocket("failed") | @voices],
      "selected" => "pocket-tts:marius"
    })

    assert text(doc(view), "#voice-native-pocket-unavailable") ==
             "Pocket TTS unavailable on this iPhone"

    hook(view, "voice_native_voices", %{
      "voices" => @voices,
      "selected" => "v-premium",
      "missing" => true,
      "missing_pocket" => true
    })

    d = doc(view)
    assert text(d, "#voice-native-pocket-unavailable") == "Pocket TTS unavailable on this iPhone"
    refute has_element?(view, "#voice-native-voice-missing")
    refute has_element?(view, "#voice-native-pocket-credit")
  end

  test "a malformed model or quality is dropped, never trusted", %{conn: conn} do
    view = ready!(conn)

    hook(view, "voice_native_voices", %{
      "voices" => [
        %{"id" => "x", "name" => "X", "quality" => "neural", "model" => %{"state" => "hacked"}},
        %{"id" => "y", "name" => "Y", "quality" => "superb"}
      ],
      "selected" => "x"
    })

    assert [%{id: "x", quality: "neural"} = x, %{id: "y", quality: "default"}] =
             assigns(view).native_voices

    refute Map.has_key?(x, :model)
    hook(view, "voice_native_model", %{"state" => "nope"})
    refute Map.has_key?(hd(assigns(view).native_voices), :model)
  end

  test "ttfs is logged on a test build only, with no reply text", %{conn: conn} do
    import ExUnit.CaptureLog
    Logger.put_module_level(PlatformWeb.VoiceLive, :info)
    on_exit(fn -> Logger.delete_module_level(PlatformWeb.VoiceLive) end)
    test_view = ready!(conn, %{"test_build" => true})

    log =
      capture_log(fn ->
        hook(test_view, "voice_native_ttfs", %{"id" => "c1", "ms" => 742})
      end)

    assert log =~ "on-device ttfs ms=742 id=c1"

    store_view = ready!(conn)

    assert capture_log(fn ->
             hook(store_view, "voice_native_ttfs", %{"id" => "c1", "ms" => 742})
           end) == ""
  end

  # ── helpers ───────────────────────────────────────────────────────────

  defp ready!(conn, extra \\ %{}) do
    {:ok, view, _html} = live(conn, ~p"/voice")

    hook(
      view,
      "voice_native_ready",
      Map.merge(%{"available" => true, "locale" => "en-US"}, extra)
    )

    assert assigns(view).on_device?
    view
  end

  defp attr_of(view, sel, name),
    do: view |> doc() |> q(sel) |> LazyHTML.attribute(name) |> List.first()

  defp hook(view, event, params), do: view |> element("#voice-area") |> render_hook(event, params)

  defp socket(view), do: :sys.get_state(view.pid).socket
  defp assigns(view), do: socket(view).assigns

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()
  defp q(doc, sel), do: LazyHTML.query(doc, sel)
  defp text(doc, sel), do: doc |> q(sel) |> LazyHTML.text() |> String.trim()

  # The render with the per-mount ids (phx-*) taken out.
  defp stable(view) do
    view
    |> render()
    |> String.replace(~r/ (id|data-phx-[a-z-]+)="phx-[^"]*"/, "")
  end

  defp turn_texts(view) do
    view |> doc() |> q("#voice-turns > *") |> Enum.map(&String.trim(LazyHTML.text(&1)))
  end

  defp dm_rows(user, agent) do
    {:ok, dm} = Chat.find_or_create_dm(user.id, "agent", agent.id)
    from(m in Message, where: m.space_id == ^dm.id, order_by: [asc: m.id]) |> Repo.all()
  end

  defp post_as(participant_id, space_id, text) do
    Chat.post_message(%{
      space_id: space_id,
      participant_id: participant_id,
      content_type: "text",
      content: text
    })
  end

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      name: "Voice viewer #{n}",
      email: "voice_on_device_#{n}@example.com",
      oidc_sub: "oidc-voice-on-device-#{n}"
    })
  end

  # The default partner. No voice runtime unless asked: the on-device path
  # needs none.
  defp burrow!(opts \\ []) do
    from(a in Agent, where: a.slug == "meeting-assistant")
    |> Repo.update_all(
      set: [slug: "meeting-assistant-old-#{System.unique_integer([:positive])}", status: "paused"]
    )

    agent!("meeting-assistant", "Burrow", opts)
  end

  defp agent!(slug, name, opts \\ []) do
    agent =
      %Agent{}
      |> Agent.changeset(%{slug: slug, name: name, status: "active", color: "orange"})
      |> Repo.insert!()

    if Keyword.get(opts, :reachable, true) do
      {:ok, _runtime, _raw} =
        Platform.Federation.register_voice_runtime(user!().id, agent, %{
          metadata: %{
            "client_info" => %{
              "features" => ["meeting_voice"],
              "livekit_agent_name" => "meeting-voice-agent"
            }
          }
        })
    end

    Repo.reload(agent)
  end

  defp channel!(user) do
    {:ok, space} =
      Chat.create_space(%{
        name: "General",
        slug: "general-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    space
  end
end
