defmodule PlatformWeb.VoiceLiveListeningTest do
  @moduledoc """
  Task 01a21e8d stage 2: the on-device Voice page tracks the partner's DM as
  a voice listener (`PlatformWeb.VoiceLive.Listening`), so an agent reply the
  phone is speaking is not also pushed. The entry clears when the page is
  hidden, the partner changes, on-device voice goes away, or the LiveView
  process dies, and every one of those is followed by a delivered push.

  Driven through `/voice` with `render_hook/3`, as the VoiceTab hook drives
  it. Pushes are observed through the router's `:notifications_module`
  seam. Fixture names are generic.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, AttentionRouter, Presence}
  alias Platform.Repo

  defmodule PushRecorder do
    def fan_out_to_user(user_id, payload, _opts \\ []) do
      send(:persistent_term.get({__MODULE__, :owner}), {:voice_push, user_id, payload})
      :ok
    end

    def fan_out_to_humans(ids, payload, opts \\ []) do
      send(:persistent_term.get({__MODULE__, :owner}), {:voice_push_humans, ids, payload, opts})
      :ok
    end
  end

  setup %{conn: conn} do
    previous = Application.get_env(:platform, :notifications_module)
    Application.put_env(:platform, :notifications_module, PushRecorder)
    :persistent_term.put({PushRecorder, :owner}, self())

    on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, :notifications_module, previous),
        else: Application.delete_env(:platform, :notifications_module)

      :persistent_term.erase({PushRecorder, :owner})
    end)

    viewer = user!()
    agent = burrow!()
    {:ok, conn: init_test_session(conn, current_user_id: viewer.id), viewer: viewer, agent: agent}
  end

  # ── 1: on Voice in that DM, an agent reply is spoken and not pushed ────

  test "after voice_native_ready the DM carries a voice entry and an agent reply is not pushed",
       %{conn: conn, viewer: viewer} do
    view = ready!(conn)
    c = assigns(view).native_conn

    assert voice_entry?(c.space_id, viewer.id)

    # A turn first, so the page speaks the reply (it proves the LiveView got
    # `{:new_message, _}`). The router is not running yet, so the turn itself
    # is not routed to the agent.
    hook(view, "voice_native_turn", %{"text" => "status?", "client_turn_id" => "ct-1"})

    {:ok, reply} = reply!(c, "The build is green.")
    reply_id = reply.id
    assert_push_event(view, "voice_native_speak", %{id: ^reply_id})
    refute_pushed(viewer)
  end

  # ── 2: hidden pushes, visible again suppresses ────────────────────────

  test "voice_native_visible false clears the entry and the next reply is pushed; true restores it",
       %{conn: conn, viewer: viewer} do
    view = ready!(conn)
    c = assigns(view).native_conn

    hook(view, "voice_native_visible", %{"visible" => false})
    refute voice_entry?(c.space_id, viewer.id)
    {:ok, _} = reply!(c, "First.")
    assert_pushed(viewer)

    hook(view, "voice_native_visible", %{"visible" => true})
    assert voice_entry?(c.space_id, viewer.id)
    {:ok, _} = reply!(c, "Second.")
    refute_pushed(viewer)
  end

  test "a malformed voice_native_visible payload changes nothing", %{conn: conn, viewer: viewer} do
    view = ready!(conn)
    c = assigns(view).native_conn

    for payload <- [%{}, %{"visible" => "false"}, %{"visible" => nil}] do
      hook(view, "voice_native_visible", payload)
      assert voice_entry?(c.space_id, viewer.id)
    end
  end

  # ── 3: partner change moves the entry ─────────────────────────────────

  test "a partner change untracks the old DM, tracks the new one, and the old DM's reply is pushed",
       %{conn: conn, viewer: viewer} do
    other = agent!("helper-#{System.unique_integer([:positive])}", "Helper")
    view = ready!(conn)
    old = assigns(view).native_conn

    view |> element("#partner-opt-#{other.id}") |> render_click()
    new = assigns(view).native_conn
    assert new.space_id != old.space_id

    refute voice_entry?(old.space_id, viewer.id)
    assert voice_entry?(new.space_id, viewer.id)

    {:ok, _} = reply!(old, "From the old partner.")
    assert_pushed(viewer)

    {:ok, _} = reply!(new, "From the new partner.")
    refute_pushed(viewer)
  end

  test "on-device voice going away (available false) untracks the DM and replies are pushed",
       %{conn: conn, viewer: viewer} do
    view = ready!(conn)
    c = assigns(view).native_conn

    hook(view, "voice_native_ready", %{"available" => false, "reason" => "assets_missing"})
    refute voice_entry?(c.space_id, viewer.id)

    {:ok, _} = reply!(c, "Still there?")
    assert_pushed(viewer)
  end

  # ── 4: a dropped socket clears the entry ──────────────────────────────

  test "when the LiveView process dies the entry is gone and a reply is pushed",
       %{conn: conn, viewer: viewer} do
    Process.flag(:trap_exit, true)
    view = ready!(conn)
    c = assigns(view).native_conn
    assert voice_entry?(c.space_id, viewer.id)

    ref = Process.monitor(view.pid)
    Process.exit(view.pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}
    await_no_entry!(c.space_id, viewer.id)

    {:ok, _} = reply!(c, "Anyone?")
    assert_pushed(viewer)
  end

  # ── 5: ready while hidden tracks nothing ──────────────────────────────

  test "voice_native_ready with visible false tracks nothing until visible true",
       %{conn: conn, viewer: viewer} do
    view = ready!(conn, %{"visible" => false})
    c = assigns(view).native_conn
    assert c

    refute voice_entry?(c.space_id, viewer.id)
    {:ok, _} = reply!(c, "While hidden.")
    assert_pushed(viewer)

    hook(view, "voice_native_visible", %{"visible" => true})
    assert voice_entry?(c.space_id, viewer.id)
  end

  # ── 6: no Voice page, no suppression ──────────────────────────────────

  test "without the Voice page an agent reply to the same user is pushed",
       %{viewer: viewer, agent: agent} do
    {:ok, dm} = Chat.find_or_create_dm(viewer.id, "agent", agent.id)

    agent_p =
      Repo.get_by!(Chat.Participant,
        space_id: dm.id,
        participant_type: "agent",
        participant_id: agent.id
      )

    refute voice_entry?(dm.id, viewer.id)
    {:ok, _} = post_as(agent_p.id, dm.id, "Nobody listening.")
    assert_pushed(viewer)
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

  defp hook(view, event, params), do: view |> element("#voice-area") |> render_hook(event, params)

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp voice_entry?(space_id, user_id) do
    space_id |> Presence.list_space() |> Presence.voice_listener_ids() |> MapSet.member?(user_id)
  end

  defp await_no_entry!(space_id, user_id, tries \\ 100) do
    cond do
      not Map.has_key?(Presence.list_space(space_id), user_id) ->
        :ok

      tries == 0 ->
        flunk("presence entry never cleared")

      true ->
        Process.sleep(20)
        await_no_entry!(space_id, user_id, tries - 1)
    end
  end

  defp reply!(conn_state, text),
    do: post_as(conn_state.agent_participant_id, conn_state.space_id, text)

  # Started on first use, so a `voice_native_turn` posted before it is not
  # routed to the agent (no agent dispatch runs in these tests).
  defp router! do
    router = Process.whereis(AttentionRouter) || start_supervised!({AttentionRouter, []})
    Sandbox.allow(Repo, self(), router)
    store = Process.whereis(ActiveAgentStore) || start_supervised!({ActiveAgentStore, []})
    Sandbox.allow(Repo, self(), store)
    :ok
  end

  defp post_as(participant_id, space_id, text) do
    :ok = router!()

    result =
      Chat.post_message(%{
        space_id: space_id,
        participant_id: participant_id,
        content_type: "text",
        content: text
      })

    :ok = GenServer.call(AttentionRouter, :__drain__)
    result
  end

  defp assert_pushed(viewer) do
    id = viewer.id
    assert_receive {:voice_push, ^id, %{kind: "chat_message"}}, 1_000
  end

  defp refute_pushed(viewer) do
    id = viewer.id
    refute_receive {:voice_push, ^id, _}, 200
  end

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      name: "Voice listener #{n}",
      email: "voice_listening_#{n}@example.com",
      oidc_sub: "oidc-voice-listening-#{n}"
    })
  end

  defp burrow! do
    from(a in Agent, where: a.slug == "meeting-assistant")
    |> Repo.update_all(
      set: [slug: "meeting-assistant-old-#{System.unique_integer([:positive])}", status: "paused"]
    )

    agent!("meeting-assistant", "Burrow")
  end

  defp agent!(slug, name) do
    agent =
      %Agent{}
      |> Agent.changeset(%{slug: slug, name: name, status: "active", color: "orange"})
      |> Repo.insert!()

    {:ok, _runtime, _raw} =
      Platform.Federation.register_voice_runtime(user!().id, agent, %{
        metadata: %{
          "client_info" => %{
            "features" => ["meeting_voice"],
            "livekit_agent_name" => "meeting-voice-agent"
          }
        }
      })

    Repo.reload(agent)
  end
end
