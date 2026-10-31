defmodule PlatformWeb.VoiceLiveTest do
  @moduledoc """
  The Voice tab shell at `/voice` (task 01a1557a-eab7 stage 2): the bar's tab
  order and current tab, the partner and context pills with their sheets, the
  transcript stream, and the idle / unreachable / no-partner mic states.

  Elements are found with `LazyHTML.query/2` (it descends the whole tree) or
  `has_element?/2`, never `LazyHTML.filter/2`.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Repo

  @burrow_greeting "Morning. Anything on your mind? Hold the mic and just talk — I'll keep the thread."

  # ── fixtures ──────────────────────────────────────────────────────────

  defp user!(name \\ nil) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      name: name || "Voice viewer #{n}",
      email: "voice_live_#{n}@example.com",
      oidc_sub: "oidc-voice-live-#{n}"
    })
  end

  defp auth(conn, user), do: init_test_session(conn, current_user_id: user.id)

  # Burrow, made reachable (a voice runtime with a LiveKit dispatch target),
  # or not. Any Burrow already in the database is taken out of the picker so
  # the one under test is the only "meeting-assistant".
  defp burrow!(opts \\ []) do
    from(a in Agent, where: a.slug == "meeting-assistant")
    |> Repo.update_all(
      set: [slug: "meeting-assistant-old-#{System.unique_integer([:positive])}", status: "paused"]
    )

    agent!("meeting-assistant", "Burrow", Keyword.merge([color: "orange"], opts))
  end

  defp agent!(slug, name, opts) do
    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: slug,
        name: name,
        status: "active",
        color: Keyword.get(opts, :color),
        metadata: Keyword.get(opts, :metadata, %{})
      })
      |> Repo.insert!()

    if Keyword.get(opts, :reachable, true) do
      {:ok, _runtime, _raw} =
        Federation.register_voice_runtime(user!().id, agent, %{
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

  defp channel!(name, members, opts \\ []) do
    {:ok, space} =
      Chat.create_space(%{
        name: name,
        slug: "#{String.downcase(name)}-#{System.unique_integer([:positive])}",
        kind: "channel",
        topic: Keyword.get(opts, :topic)
      })

    for u <- members do
      {:ok, _} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: u.id,
          display_name: u.name,
          joined_at: DateTime.utc_now()
        })
    end

    space
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()
  defp q(doc, sel), do: LazyHTML.query(doc, sel)
  defp text(doc, sel), do: doc |> q(sel) |> LazyHTML.text() |> String.trim()
  defp attr(doc, sel, name), do: doc |> q(sel) |> LazyHTML.attribute(name)

  defp turn_texts(view) do
    view |> doc() |> q("#voice-turns > *") |> Enum.map(&String.trim(LazyHTML.text(&1)))
  end

  setup %{conn: conn} do
    viewer = user!()
    {:ok, conn: auth(conn, viewer), viewer: viewer}
  end

  # ── tab bar ───────────────────────────────────────────────────────────

  describe "the bar on /voice" do
    setup do
      burrow!()
      :ok
    end

    # Task 01a18d9f stage 5: Voice is a More-sheet row, so /voice lights More.
    test "is Chat, Calendar, Meetings, Inbox, More, and More is current", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/voice")
      d = doc(view)

      keys =
        d |> q("[data-bottom-rail] [data-destination]") |> LazyHTML.attribute("data-destination")

      assert keys == ["chat", "calendar", "meetings", "inbox", "more"]

      # More is a sheet trigger, never aria-current; it carries the active class.
      assert attr(d, "[data-bottom-rail] [aria-current=page]", "data-destination") == []

      assert has_element?(
               view,
               ~s([data-bottom-rail] [data-destination="more"].bottom-nav-tab--active .hero-ellipsis-horizontal-solid)
             )
    end
  end

  # ── idle screen ───────────────────────────────────────────────────────

  describe "idle, no context" do
    setup do
      %{burrow: burrow!()}
    end

    test "renders both pills, the thread line, Today and the greeting", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/voice")
      d = doc(view)

      assert text(d, "#partner-name") == "Burrow"
      assert attr(d, "#partner", "aria-label") == ["Voice partner: Burrow. Tap to change"]
      assert attr(d, "#partner", "aria-haspopup") == ["dialog"]
      assert text(d, "#partner-avatar") == "B"
      assert attr(d, "#partner-avatar", "data-agent-slot") == ["orange"]

      assert text(d, "#ctx .text-subtle") =~ "in:"
      assert text(d, "#ctx-name") == "No context"
      assert attr(d, "#ctx", "data-ctx") == ["none"]

      assert attr(d, "#ctx", "aria-label") == [
               "Context: none. Tap to choose where this transcript posts"
             ]

      assert text(d, "#thread-pair") == "Burrow ↔ you"
      assert text(d, "#thread-ctx") == "· nothing posted anywhere — pick a context above"
      assert text(d, "#convo > .day") == "Today"

      [greeting] = q(d, "#voice-turns > [data-partner-greeting]") |> Enum.to_list()
      assert LazyHTML.text(greeting) =~ @burrow_greeting
      assert text(greeting, ".from") == "Burrow"
      assert LazyHTML.attribute(greeting, "data-agent-slot") == ["orange"]
    end

    test "the transcript is a stream with stream dom ids", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/voice")
      d = doc(view)

      assert attr(d, "#voice-turns", "phx-update") == ["stream"]
      ids = d |> q("#voice-turns > *") |> LazyHTML.attribute("id")
      assert ids != []
      assert Enum.all?(ids, &String.starts_with?(&1, "turns-"))
    end

    test "the mic area is idle: line, 14-bar meter, enabled mic, info chip", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/voice")
      d = doc(view)

      assert text(d, "#listen-text") == "hold to talk · tap to toggle"
      assert d |> q("#meter i") |> Enum.count() == 14

      assert attr(d, "#mic", "aria-label") == [
               "Hold to talk to Burrow. Short tap toggles listening."
             ]

      refute has_element?(view, "#mic[disabled]")
      assert attr(d, "#mic", "aria-pressed") == ["false"]
      assert text(d, "#pipeline-info") == "uses meeting transcription · not a meeting"
      refute has_element?(view, "#voice-toast")

      view |> element("#pipeline-info") |> render_click()

      assert view |> doc() |> text("#voice-toast") ==
               "Same LiveKit + transcription as Meet, private 1:1 — no meeting created"
    end

    test "no phone surface carries a hover class; popover rows hover only at lg", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/voice")
      view |> element("#partner") |> render_click()
      d = doc(view)

      nodes =
        for sel <- ["#voice-screen", "#partner-sheet", "#ctx-sheet"],
            n <- q(d, sel <> " [class]"),
            do: n

      hovers =
        for n <- nodes,
            c <- LazyHTML.attribute(n, "class"),
            token <- String.split(c),
            token =~ "hover:",
            uniq: true,
            do: {token, "opt" in String.split(c)}

      assert nodes != []
      # The only hover paint is the popover rows' lg one (stage 4).
      assert hovers == [{"lg:hover:bg-base-200", true}]
    end
  end

  # ── partner sheet ─────────────────────────────────────────────────────

  describe "the partner sheet" do
    setup do
      burrow = burrow!()

      pixel =
        agent!("pixel-#{System.unique_integer([:positive])}", "Pixel",
          color: "teal",
          metadata: %{"description" => "design · variants, visuals"}
        )

      %{burrow: burrow, pixel: pixel}
    end

    test "opens titled Voice with, Burrow first as the default and current", %{
      conn: conn,
      burrow: burrow,
      pixel: pixel
    } do
      {:ok, view, _html} = live(conn, ~p"/voice")
      refute has_element?(view, "#partner-sheet.sheet-open")

      view |> element("#partner") |> render_click()
      assert has_element?(view, "#partner-sheet.sheet-open")
      d = doc(view)

      assert text(d, "#partner-sheet-title") == "Voice with"
      [first | _] = d |> q("#partner-list > .opt") |> LazyHTML.attribute("id")
      assert first == "partner-opt-#{burrow.id}"

      burrow_row = q(d, "#partner-opt-#{burrow.id}")
      assert text(burrow_row, "small.block") == "your default · knows every space"
      assert LazyHTML.attribute(burrow_row, "data-current") == ["true"]
      assert LazyHTML.text(burrow_row) =~ "current"

      pixel_row = q(d, "#partner-opt-#{pixel.id}")
      assert text(pixel_row, "small.block") == "design · variants, visuals"
      refute LazyHTML.text(pixel_row) =~ "current"

      assert pixel_row |> q("[data-agent-slot]") |> LazyHTML.attribute("data-agent-slot") == [
               "teal"
             ]
    end

    test "picking a partner resets the stream to that partner's greeting; Burrow says Back with you",
         %{conn: conn, burrow: burrow, pixel: pixel} do
      {:ok, view, _html} = live(conn, ~p"/voice")

      # A context note first, so the reset has something to drop.
      view |> element("#ctx") |> render_click()
      view |> element("#ctx-opt-none") |> render_click()
      assert length(turn_texts(view)) == 2

      view |> element("#partner") |> render_click()
      view |> element("#partner-opt-#{pixel.id}") |> render_click()

      refute has_element?(view, "#partner-sheet.sheet-open")
      assert [pixel_turn] = turn_texts(view)
      assert pixel_turn =~ "Hey, Pixel here — design · variants, visuals. Go ahead."
      d = doc(view)
      assert text(d, "#partner-name") == "Pixel"
      assert text(d, "#thread-pair") == "Pixel ↔ you"
      assert attr(d, "#partner", "aria-label") == ["Voice partner: Pixel. Tap to change"]

      assert attr(d, "#mic", "aria-label") == [
               "Hold to talk to Pixel. Short tap toggles listening."
             ]

      view |> element("#partner") |> render_click()
      view |> element("#partner-opt-#{burrow.id}") |> render_click()
      assert [back] = turn_texts(view)
      assert back =~ "Back with you."
    end
  end

  # ── the lg popovers (stage 4) ─────────────────────────────────────────

  describe "the pickers as lg popovers" do
    setup %{viewer: viewer} do
      %{burrow: burrow!(), space: channel!("Design", [viewer])}
    end

    test "both sheets render the popover variant, anchored under their pills", %{
      conn: conn,
      burrow: burrow,
      space: space
    } do
      {:ok, view, _html} = live(conn, ~p"/voice")
      d = doc(view)

      for {anchor, sheet, edge, pill} <- [
            {"#partner-anchor", "#partner-sheet", "start", "#partner"},
            {"#ctx-anchor", "#ctx-sheet", "end", "#ctx"}
          ] do
        node = q(d, "#{anchor} > #{sheet}.voice-sheet.voice-popover")
        assert Enum.count(node) == 1, "#{sheet} is not a popover inside #{anchor}"
        assert LazyHTML.attribute(node, "data-variant") == ["popover"]
        assert LazyHTML.attribute(node, "data-anchor") == [edge]
        assert LazyHTML.attribute(node, "data-return-focus") == [pill]
        assert LazyHTML.attribute(node, "phx-hook") == ["Sheet"]
        assert has_element?(view, "#{anchor} > #{pill}")
      end

      row_classes =
        for id <- ["#partner-opt-#{burrow.id}", "#ctx-opt-none", "#ctx-opt-#{space.id}"] do
          [c] = attr(d, id, "class")
          c
        end

      assert Enum.all?(row_classes, &("lg:hover:bg-base-200" in String.split(&1)))

      # The copy is stage 2's, unchanged by the variant.
      assert text(d, "#partner-sheet h2[aria-hidden]") == "Voice with"
      assert text(d, "#ctx-sheet h2[aria-hidden]") == "Talking about"
      assert attr(d, "#ctx-search", "placeholder") == ["Search spaces"]
    end

    test "the default variant is the plain bottom sheet, with no hover", %{burrow: burrow} do
      partner = %{agent: burrow, slot: "orange", reachable?: true, description: nil}

      html =
        render_component(&PlatformWeb.Components.Voice.partner_sheet/1,
          open: true,
          partners: [partner],
          current_id: burrow.id,
          default_slug: "meeting-assistant"
        )

      d = LazyHTML.from_fragment(html)
      assert attr(d, "#partner-sheet", "data-variant") == ["sheet"]
      assert q(d, "#partner-sheet.voice-popover") |> Enum.count() == 0
      [c] = attr(d, "#partner-opt-#{burrow.id}", "class")
      refute c =~ "hover:"
    end

    test "the pills carry a primary focus-visible outline", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/voice")
      d = doc(view)

      for pill <- ["#partner", "#ctx"] do
        [c] = attr(d, pill, "class")
        tokens = String.split(c)
        assert "focus-visible:outline-primary" in tokens
        assert "focus-visible:outline-2" in tokens
      end
    end

    test "Escape (the Sheet hook's close_sheet) closes the partner and the context popover", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/voice")

      for {pill, sheet} <- [{"#partner", "#partner-sheet"}, {"#ctx", "#ctx-sheet"}] do
        view |> element(pill) |> render_click()
        assert has_element?(view, "#{sheet}.sheet-open[data-open=true]")

        view |> element(sheet) |> render_hook("close_sheet", %{"key" => "Escape"})

        refute has_element?(view, "#{sheet}.sheet-open")
        assert has_element?(view, "#{sheet}[data-open=false]")
      end
    end
  end

  # ── context sheet ─────────────────────────────────────────────────────

  describe "the context sheet" do
    setup %{viewer: viewer} do
      burrow!()
      design = channel!("Design", [viewer], topic: "pixels and type")
      mobile = channel!("Mobile", [viewer])
      other = channel!("Elsewhere", [user!()])
      %{design: design, mobile: mobile, other: other}
    end

    test "lists No context and the viewer's spaces only, with search and No match.",
         %{conn: conn, design: design, mobile: mobile, other: other} do
      {:ok, view, _html} = live(conn, ~p"/voice")
      view |> element("#ctx") |> render_click()
      assert has_element?(view, "#ctx-sheet.sheet-open")
      d = doc(view)

      assert text(d, "#ctx-sheet-title") == "Talking about"
      assert attr(d, "#ctx-search", "placeholder") == ["Search spaces"]
      assert text(d, "#ctx-opt-none") =~ "No context"
      assert text(d, "#ctx-opt-none small") == "just a chat with Burrow"
      assert attr(d, "#ctx-opt-none", "data-selected") == ["true"]
      assert text(d, "#ctx-list .section-label") == "Spaces"
      assert has_element?(view, "#ctx-opt-#{design.id}")
      assert has_element?(view, "#ctx-opt-#{mobile.id}")
      refute has_element?(view, "#ctx-opt-#{other.id}")
      assert text(d, "#ctx-opt-#{design.id} small") == "pixels and type"

      view |> form("#ctx-search-form", ctx: %{q: "mob"}) |> render_change()
      assert has_element?(view, "#ctx-opt-#{mobile.id}")
      refute has_element?(view, "#ctx-opt-#{design.id}")
      refute has_element?(view, "#ctx-opt-none")

      view |> form("#ctx-search-form", ctx: %{q: "Elsewhere"}) |> render_change()
      assert view |> doc() |> text("#ctx-empty") == "No match."
    end

    test "picking a space sets the pill, the thread line and the day note, and saves it",
         %{conn: conn, design: design} do
      {:ok, view, _html} = live(conn, ~p"/voice")
      view |> element("#ctx") |> render_click()
      view |> element("#ctx-opt-#{design.id}") |> render_click()

      assert_push_event(view, "voice_ctx_saved", %{id: id})
      assert id == design.id
      refute has_element?(view, "#ctx-sheet.sheet-open")

      d = doc(view)
      assert text(d, "#ctx-name") == "Design"
      assert attr(d, "#ctx", "data-ctx") == ["set"]
      assert attr(d, "#ctx", "aria-label") == ["Context: Design. Tap to change"]
      assert text(d, "#thread-ctx") == "· Design"
      assert List.last(turn_texts(view)) == "now talking about Design · transcript posts there"

      view |> element("#ctx") |> render_click()
      view |> element("#ctx-opt-none") |> render_click()
      assert_push_event(view, "voice_ctx_saved", %{id: nil})
      assert List.last(turn_texts(view)) == "no context · transcript stays here"
      assert view |> doc() |> text("#ctx-name") == "No context"
    end

    test "the device's remembered context is restored once; a stale one is cleared",
         %{conn: conn, design: design, other: other} do
      {:ok, view, _html} = live(conn, ~p"/voice")
      assert attr(doc(view), "#voice-screen", "phx-hook") == ["VoiceContext"]

      render_hook(view, "voice_restore_context", %{"id" => design.id})
      assert view |> doc() |> text("#ctx-name") == "Design"
      # A restore adds no day note: only the greeting is in the stream.
      assert length(turn_texts(view)) == 1

      {:ok, view2, _html} = live(conn, ~p"/voice")
      render_hook(view2, "voice_restore_context", %{"id" => other.id})
      assert_push_event(view2, "voice_ctx_saved", %{id: nil})
      assert view2 |> doc() |> text("#ctx-name") == "No context"
    end
  end

  # ── unreachable and missing partner ───────────────────────────────────

  describe "a partner that cannot talk" do
    test "an unreachable Burrow keeps the pill but disables the mic", %{conn: conn} do
      burrow!(reachable: false)
      {:ok, view, _html} = live(conn, ~p"/voice")
      d = doc(view)

      assert text(d, "#partner-name") == "Burrow"
      assert has_element?(view, "#mic[disabled]")
      assert text(d, "#listen-text") == "Burrow can't talk right now."
      assert has_element?(view, "#listen-text.text-error")
    end

    test "no Burrow in the org: No voice partner, mic disabled, no greeting", %{conn: conn} do
      from(a in Agent, where: a.slug == "meeting-assistant")
      |> Repo.update_all(set: [status: "paused"])

      {:ok, view, _html} = live(conn, ~p"/voice")
      d = doc(view)

      assert text(d, "#partner-name") == "No voice partner"
      assert has_element?(view, "#mic[disabled]")
      assert turn_texts(view) == []
    end
  end

  # ── talking (stage 3) ─────────────────────────────────────────────────
  #
  # The VoiceTab hook's events, pushed with render_hook/3 at #voice-area.
  # LiveKit HTTP goes through the :livekit_req_client stub, which reports
  # every Twirp call to the test process.

  @create_dispatch "/twirp/livekit.AgentDispatchService/CreateDispatch"
  @send_data "/twirp/livekit.RoomService/SendData"

  defp livekit_stub! do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    {:ok, _} = Application.ensure_all_started(:req)
    Application.put_env(:platform, :livekit_req_client, Req.new(plug: {Req.Test, :voice_live}))
    test_pid = self()

    Req.Test.stub(:voice_live, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = if body == "", do: %{}, else: Jason.decode!(body)
      send(test_pid, {:twirp, conn.request_path, decoded})
      Req.Test.json(conn, %{})
    end)

    on_exit(fn ->
      Application.put_env(:platform, :livekit, original)
      Application.delete_env(:platform, :livekit_req_client)
      Application.delete_env(:platform, :voice_answer_timeout_ms)
    end)
  end

  defp twirp(path, acc \\ []) do
    receive do
      {:twirp, ^path, body} -> twirp(path, [body | acc])
      {:twirp, _other, _body} -> twirp(path, acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp signals do
    @send_data
    |> twirp()
    |> Enum.map(&{&1["room"], &1["topic"], Base.decode64!(&1["data"])})
  end

  defp squish(s), do: s |> String.split() |> Enum.join(" ")

  defp hook(view, event, params \\ %{}),
    do: view |> element("#voice-area") |> render_hook(event, params)

  defp started!(view) do
    hook(view, "voice_start")
    assert_reply(view, %{ok: true, room: room})
    room
  end

  defp dm_id(viewer, agent) do
    {:ok, dm} = Chat.find_or_create_dm(viewer.id, "agent", agent.id)
    dm.id
  end

  defp message_count, do: Repo.aggregate(Platform.Chat.Message, :count)

  defp pick_context!(view, space) do
    view |> element("#ctx") |> render_click()
    view |> element("#ctx-opt-#{space.id}") |> render_click()
  end

  describe "voice_start" do
    setup do
      livekit_stub!()
      %{burrow: burrow!()}
    end

    test "ok: replies with the token, url and the DM's room, and dispatches in voice mode", %{
      conn: conn,
      viewer: viewer,
      burrow: burrow
    } do
      {:ok, view, _html} = live(conn, ~p"/voice")
      hook(view, "voice_start")

      assert_reply(view, %{ok: true, token: token, url: "wss://livekit.test", room: room})
      assert is_binary(token) and token != ""
      assert room == "space-" <> dm_id(viewer, burrow)

      assert [dispatch] = twirp(@create_dispatch)
      assert dispatch["room"] == room
      assert Jason.decode!(dispatch["metadata"])["mode"] == "voice_1to1"

      # A second start reuses the session: same room, nothing re-dispatched.
      hook(view, "voice_start")
      assert_reply(view, %{ok: true, room: ^room})
      assert twirp(@create_dispatch) == []
    end

    test "error: replies ok false and the line reads {partner} can't talk right now.", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/voice")
      Application.put_env(:platform, :livekit, [])

      hook(view, "voice_start")
      assert_reply(view, %{ok: false})

      d = doc(view)
      assert text(d, "#listen-text") == "Burrow can't talk right now."
      assert has_element?(view, "#listen-text.text-error")
      refute has_element?(view, "#mic.on")
    end
  end

  describe "a turn: voice_press, voice_toggled, voice_release" do
    setup do
      livekit_stub!()
      %{burrow: burrow!()}
    end

    test "press opens the window and shows listening; release closes it and shows thinking", %{
      conn: conn,
      viewer: viewer,
      burrow: burrow
    } do
      {:ok, view, _html} = live(conn, ~p"/voice")
      room = started!(view)
      _ = signals()

      refute has_element?(view, "#mic.on")
      hook(view, "voice_press")

      d = doc(view)
      assert text(d, "#listen-text") == "listening…"
      assert has_element?(view, "#mic.on[aria-pressed=true]")
      assert has_element?(view, "#voice-area[data-live]")
      assert has_element?(view, "#voice-live.bubble.me.live .voice-caret")
      assert [{^room, "mva.ask_floor", open}] = signals()
      assert Jason.decode!(open)["event"] == "open"

      hook(view, "voice_toggled")
      assert text(doc(view), "#listen-text") == "listening… tap again to stop"

      hook(view, "voice_release", %{"duration_ms" => 1_200})
      d = doc(view)
      assert text(d, "#listen-text") == "Burrow is thinking…"
      refute has_element?(view, "#mic.on")
      refute has_element?(view, "#voice-live")
      assert has_element?(view, "#voice-thinking.bubble.agent .voice-dots")
      assert [{^room, "mva.ask_floor", closed}] = signals()
      assert Jason.decode!(closed)["event"] == "closed"
      assert room == "space-" <> dm_id(viewer, burrow)
    end

    test "a release under 400ms with no final caption is too short: no turn, idle line", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/voice")
      started!(view)
      hook(view, "voice_press")
      hook(view, "voice_release", %{"duration_ms" => 120})

      assert text(doc(view), "#listen-text") == "hold to talk · tap to toggle"
      refute has_element?(view, "#voice-thinking")
    end

    test "direction state 5: a 100ms tap toggles on, a second tap inside 400ms ends at idle", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/voice")
      started!(view)
      hook(view, "voice_press")
      hook(view, "voice_toggled")
      assert text(doc(view), "#listen-text") == "listening… tap again to stop"

      hook(view, "voice_release", %{"duration_ms" => 350})

      assert text(doc(view), "#listen-text") == "hold to talk · tap to toggle"
      refute has_element?(view, "#voice-thinking")
      refute has_element?(view, "#voice-live")
      refute has_element?(view, "#voice-turns .bubble.me")
      refute has_element?(view, "#mic.on")
    end

    test "no final agent caption in time: Didn't get an answer. with Try again; retry is idle",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/voice")
      started!(view)
      hook(view, "voice_press")
      hook(view, "voice_release", %{"duration_ms" => 900})

      # Fire the armed answer timer deterministically. A 0 ms send_after goes
      # through the timer service and can land after the next render call,
      # which made this test retry-green under CI load.
      ref = :sys.get_state(view.pid).socket.assigns.answer_ref
      assert is_reference(ref)
      send(view.pid, {:answer_timeout, ref})

      d = doc(view)
      assert text(d, "#voice-failed") =~ "Didn't get an answer."
      assert text(d, "#voice-retry") == "Try again"
      assert text(d, "#listen-text") == "hold to talk · tap to toggle"

      view |> element("#voice-retry") |> render_click()
      assert_push_event(view, "voice_focus_mic", %{})
      refute has_element?(view, "#voice-failed")
    end

    test "a final agent caption ends thinking and lands in the transcript", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/voice")
      started!(view)
      hook(view, "voice_press")
      hook(view, "voice_release", %{"duration_ms" => 900})

      hook(view, "voice_turn", %{"who" => "agent", "text" => "Two things."})
      d = doc(view)
      refute has_element?(view, "#voice-thinking")
      assert text(d, "#listen-text") == "hold to talk · tap to toggle"
      assert view |> turn_texts() |> List.last() |> squish() == "Burrow Two things."
    end

    test "a press with no session is refused back to the hook", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/voice")
      hook(view, "voice_press")
      assert_push_event(view, "voice_reset", %{})
      refute has_element?(view, "#mic.on")
    end
  end

  describe "voice_turn and posting" do
    setup %{viewer: viewer} do
      livekit_stub!()
      %{burrow: burrow!(), space: channel!("Alpha", [viewer])}
    end

    test "no context: your turn renders without posted to, and nothing is posted anywhere", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/voice")
      before = message_count()

      hook(view, "voice_turn", %{"who" => "me", "text" => "note one", "at" => "9:41 AM"})

      [mine] = view |> doc() |> q(".bubble.me") |> Enum.to_list()
      assert LazyHTML.text(mine) =~ "note one"
      assert mine |> LazyHTML.query(".meta") |> LazyHTML.text() == "🎙️ transcribed · 9:41 AM"
      assert message_count() == before
    end

    test "with a context: your final turn posts once, as you, source voice; the meta says so",
         %{conn: conn, viewer: viewer, space: space} do
      {:ok, view, _html} = live(conn, ~p"/voice")
      pick_context!(view, space)
      before = Chat.count_messages(space.id)

      hook(view, "voice_turn", %{"who" => "me", "text" => "note two", "at" => "9:42 AM"})

      assert text(doc(view), ".bubble.me .meta") == "🎙️ transcribed · 9:42 AM · posted to Alpha"
      assert Chat.count_messages(space.id) == before + 1

      [message] = space.id |> Chat.list_messages() |> Enum.filter(&(&1.content == "note two"))
      assert message.metadata["source"] == "voice"
      participant = Repo.get!(Platform.Chat.Participant, message.participant_id)
      assert {participant.participant_type, participant.participant_id} == {"user", viewer.id}
    end

    test "an agent turn never posts, context or not", %{conn: conn, space: space} do
      {:ok, view, _html} = live(conn, ~p"/voice")
      pick_context!(view, space)
      before = message_count()

      hook(view, "voice_turn", %{"who" => "agent", "text" => "agent words"})

      assert view |> turn_texts() |> List.last() |> squish() == "Burrow agent words"
      assert message_count() == before
    end

    test "blank text and an unknown speaker are ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/voice")
      before = turn_texts(view)
      hook(view, "voice_turn", %{"who" => "me", "text" => "   "})
      hook(view, "voice_turn", %{"who" => "someone", "text" => "hi"})
      assert turn_texts(view) == before
    end

    test "a context change tells the live session (mva.context)", %{conn: conn, space: space} do
      {:ok, view, _html} = live(conn, ~p"/voice")
      room = started!(view)
      _ = signals()

      pick_context!(view, space)

      assert [{^room, "mva.context", payload}] = signals()
      assert Jason.decode!(payload) == %{"kind" => "space", "id" => space.id, "name" => "Alpha"}
    end
  end

  describe "the microphone is blocked" do
    setup %{viewer: viewer} do
      livekit_stub!()
      %{burrow: burrow!(), space: channel!("Alpha", [viewer])}
    end

    test "the line is the blocked copy in text-error; Type instead posts like a spoken turn", %{
      conn: conn,
      space: space
    } do
      {:ok, view, _html} = live(conn, ~p"/voice")
      pick_context!(view, space)
      hook(view, "voice_mic_blocked")

      d = doc(view)

      assert text(d, "#listen-text") ==
               "Microphone is blocked. Allow it in your browser or app settings."

      assert has_element?(view, "#listen-text.text-error")
      refute has_element?(view, "#voice-type-form")

      view |> element("#voice-type-instead") |> render_click()
      assert has_element?(view, "#voice-type-form #voice-type-input")
      before = Chat.count_messages(space.id)

      view |> form("#voice-type-form", type: %{text: "typed note"}) |> render_submit()

      assert text(doc(view), ".bubble.me .meta") =~ "typed · "
      assert text(doc(view), ".bubble.me .meta") =~ " · posted to Alpha"
      assert Chat.count_messages(space.id) == before + 1
    end
  end

  describe "a partner change mid-session" do
    setup do
      livekit_stub!()

      %{
        burrow: burrow!(),
        pixel: agent!("pixel-#{System.unique_integer([:positive])}", "Pixel", color: "teal")
      }
    end

    test "releases the old agent's floor, then disconnects before a new session starts", %{
      conn: conn,
      viewer: viewer,
      burrow: burrow,
      pixel: pixel
    } do
      {:ok, view, _html} = live(conn, ~p"/voice")
      room = started!(view)
      hook(view, "voice_press")
      _ = signals()
      floor = "voice:" <> dm_id(viewer, burrow)
      assert {:ok, _held} = Platform.Meetings.AskFloor.holder(floor, burrow.id)

      view |> element("#partner") |> render_click()
      view |> element("#partner-opt-#{pixel.id}") |> render_click()

      assert [{^room, "mva.ask_floor", closed}] = signals()
      assert Jason.decode!(closed) == %{"event" => "closed", "agent_id" => burrow.id}
      assert Platform.Meetings.AskFloor.holder(floor, burrow.id) == :none
      assert_push_event(view, "voice_disconnect", %{})
      refute has_element?(view, "#mic.on")

      hook(view, "voice_start")
      assert_reply(view, %{ok: true, room: new_room})
      refute new_room == room
    end

    test "a toggled-on turn is released on the old agent too (stage 4)", %{
      conn: conn,
      viewer: viewer,
      burrow: burrow,
      pixel: pixel
    } do
      {:ok, view, _html} = live(conn, ~p"/voice")
      room = started!(view)
      hook(view, "voice_press")
      hook(view, "voice_toggled")
      _ = signals()

      view |> element("#partner") |> render_click()
      view |> element("#partner-opt-#{pixel.id}") |> render_click()

      assert [{^room, "mva.ask_floor", closed}] = signals()
      assert Jason.decode!(closed) == %{"event" => "closed", "agent_id" => burrow.id}

      assert Platform.Meetings.AskFloor.holder("voice:" <> dm_id(viewer, burrow), burrow.id) ==
               :none

      assert text(doc(view), "#listen-text") == "hold to talk · tap to toggle"
    end

    test "with no live turn a partner change sends no floor signal", %{conn: conn, pixel: pixel} do
      {:ok, view, _html} = live(conn, ~p"/voice")
      started!(view)
      _ = signals()

      view |> element("#partner") |> render_click()
      view |> element("#partner-opt-#{pixel.id}") |> render_click()

      assert signals() == []
      assert_push_event(view, "voice_disconnect", %{})
    end
  end
end
