defmodule Platform.Chat.Canvas.KindsGameStreamTest do
  @moduledoc """
  The `game_stream` canvas kind is registered exactly while
  `GAME_STREAM_ENABLED` is set (task 01a0db5f stage 2).

  NOT async: every case toggles `:platform, :game_stream_enabled`, which is
  global application env that any concurrently running case would read.

  ## The literal-list GUARD

  With the flag unset, `Kinds.names()` must equal main's sixteen names,
  typed out below — not derived from `@modules`, `Kinds.all/0` or anything
  else in the application, because a derived list would move with the
  defect it is meant to catch. The guard is shown to fire: the same
  comparison with the flag ON must fail, which is asserted in its own case
  so a guard that could never fail is itself a failure.
  """

  # DataCase (stage 4): a render with no live session asks
  # `Platform.GameStream.host_available?/0`, which reads the runtimes table.
  use Platform.DataCase, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Platform.Chat.Canvas.Kinds
  alias Platform.Chat.Canvas.Kinds.GameStream, as: GameStreamKind
  alias Platform.Chat.Canvas.Renderer
  alias Platform.Chat.CanvasDocument

  # main's registry at 23ff27a0, in `@modules` order. Typed, not derived.
  @main_kind_names ~w(stack row card text markdown heading badge image code mermaid embed
                      form action_row checklist checklist_item table)

  @sha "0123456789abcdef0123456789abcdef01234567"

  setup do
    previous = Application.get_env(:platform, :game_stream_enabled)
    Application.delete_env(:platform, :game_stream_enabled)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:platform, :game_stream_enabled),
        else: Application.put_env(:platform, :game_stream_enabled, previous)
    end)

    :ok
  end

  defp enable!, do: Application.put_env(:platform, :game_stream_enabled, true)

  defp document(node) do
    %{
      "version" => 1,
      "revision" => 1,
      "root" => node,
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }
  end

  defp gs_node(props \\ %{}), do: %{"id" => "gs", "type" => "game_stream", "props" => props}

  describe "GUARD: with GAME_STREAM_ENABLED unset the registry is main's" do
    test "Kinds.names() is exactly main's 16 names, in order" do
      assert length(@main_kind_names) == 16
      assert Kinds.names() == @main_kind_names
    end

    test "the guard FIRES: with the flag on, the same comparison fails" do
      enable!()
      refute Kinds.names() == @main_kind_names
      assert Kinds.names() == @main_kind_names ++ ["game_stream"]
    end
  end

  describe "flag unset" do
    test "game_stream is absent from every registry reader" do
      refute "game_stream" in Kinds.names()
      refute Map.has_key?(Kinds.by_name(), "game_stream")
      refute GameStreamKind in Kinds.all()
      refute Enum.any?(Kinds.summaries(), &(&1.kind == "game_stream"))
      refute Map.has_key?(Kinds.tool_schemas(), "game_stream")
      assert Kinds.get("game_stream") == nil
      refute Kinds.kind?("game_stream")
    end

    test "CanvasDocument rejects a game_stream node as an unknown kind" do
      assert {:error, reasons} = CanvasDocument.validate(document(gs_node()))
      assert Enum.any?(reasons, &(&1 =~ ~s(unknown kind "game_stream")))
    end

    test "an existing game_stream node renders through the renderer's fallback" do
      html = render_component(&Renderer.render_node/1, node: gs_node(%{"review_sha" => @sha}))
      assert html =~ "[unknown node type: game_stream]"
      refute html =~ @sha
    end
  end

  describe "flag set" do
    setup do
      enable!()
      :ok
    end

    test "registered in every reader, with a description and no children" do
      assert "game_stream" in Kinds.names()
      assert Kinds.get("game_stream") == GameStreamKind
      assert Kinds.behaviour_ok?(GameStreamKind)
      assert Map.has_key?(Kinds.tool_schemas(), "game_stream")

      summary = Enum.find(Kinds.summaries(), &(&1.kind == "game_stream"))
      assert summary.description =~ "review build"
      assert summary.accepts_children == "none"
    end

    test "a valid node validates; validate_props rejects bad values" do
      props = %{
        "session_id" => "s",
        "task_id" => "t",
        "review_sha" => @sha,
        "branch" => "task/x",
        "title" => "Review build",
        "latency_warn_ms" => 50
      }

      assert {:ok, _} = CanvasDocument.validate(document(gs_node(props)))
      assert :ok = GameStreamKind.validate_props(props)

      assert {:error, [msg]} = GameStreamKind.validate_props(%{"review_sha" => "abc123"})
      assert msg =~ "40-character"

      assert {:error, [_]} =
               GameStreamKind.validate_props(%{"review_sha" => String.upcase(@sha)})

      assert {:error, [_]} = GameStreamKind.validate_props(%{"latency_warn_ms" => 0})
      assert {:error, [_]} = GameStreamKind.validate_props(%{"title" => 7})

      assert {:error, reasons} =
               CanvasDocument.validate(document(gs_node(%{"review_sha" => "x"})))

      assert Enum.any?(reasons, &(&1 =~ "review_sha"))
    end

    test "children are refused" do
      bad = Map.put(gs_node(), "children", [%{"id" => "c", "type" => "text", "props" => %{}}])
      assert {:error, reasons} = CanvasDocument.validate(document(bad))
      assert Enum.any?(reasons, &(&1 =~ "does not accept children"))
    end

    test "the render shows the full sha in its title and never truncates it" do
      html = render_component(&Renderer.render_node/1, node: gs_node(%{"review_sha" => @sha}))
      assert html =~ @sha
      assert html =~ "bg-black"
      refute html =~ "unknown node type"

      [sha] = html |> Floki.parse_fragment!() |> Floki.find("[data-gs-sha]")
      assert Floki.attribute(sha, "title") == [@sha]
      [class] = Floki.attribute(sha, "class")
      assert class =~ "shrink-0"
      refute class =~ "truncate"
    end
  end

  @session "01a0dc00-0000-7000-8000-000000000001"

  defp render_state(status, props \\ %{}) do
    node =
      gs_node(
        Map.merge(
          %{
            "session_id" => @session,
            "task_id" => "t",
            "review_sha" => @sha,
            "branch" => "task/01a0db5f-4f1a-7001-87a3-e777ad1cab82",
            "title" => "Voltron: dash tuning"
          },
          props
        )
      )

    render_component(&GameStreamKind.render/1,
      node: node,
      dom_id_scope: "canvas-x-expanded",
      canvas_id: "canvas-x",
      status: status
    )
  end

  defp doc(html), do: Floki.parse_fragment!(html)

  # The panels that are NOT hidden. Exactly one frame state shows at a time.
  defp shown_panels(html) do
    html
    |> doc()
    |> Floki.find("[data-gs-panel]")
    |> Enum.reject(&(Floki.attribute(&1, "hidden") != []))
    |> Enum.flat_map(&Floki.attribute(&1, "data-gs-panel"))
  end

  defp end_hidden?(html),
    do: html |> doc() |> Floki.find("[data-gs-end]") |> Floki.attribute("hidden") != []

  defp status(state, extra \\ %{}),
    do: {:ok, Map.merge(%{state: state, detail: nil, elapsed_ms: 0}, extra)}

  # ── Stage 4: the full render, one case per state ──────────────────────────

  describe "render per state (stage 4)" do
    setup do
      enable!()
      :ok
    end

    test "every panel the hook can show is in the markup" do
      html = render_state(status("building"))

      rendered =
        html
        |> doc()
        |> Floki.find("[data-gs-panel]")
        |> Enum.flat_map(&Floki.attribute(&1, "data-gs-panel"))

      assert Enum.sort(rendered) == Enum.sort(GameStreamKind.panels())
    end

    test "no play host: the design's line, no spinner, no End" do
      html = render_state({:error, :not_found})
      assert shown_panels(html) == ["unavailable"]
      assert html =~ "Stream unavailable. No play host is connected."
      refute html =~ "animate-spin"
      refute html =~ "loading"
      assert end_hidden?(html)
    end

    test "a node with no session and no host is unavailable" do
      html = render_state(:lookup, %{"session_id" => nil})
      assert shown_panels(html) == ["unavailable"]
    end

    test "building: the short sha on the play host, with elapsed time, and End" do
      html = render_state(status("building", %{elapsed_ms: 83_000}))
      assert shown_panels(html) == ["building"]
      assert html =~ ~r/Building\s*<span[^>]*>\s*0123456\s*<\/span>\s*on the play host…/
      assert html =~ "1:23"
      refute end_hidden?(html)
    end

    test "connecting" do
      html = render_state(status("connecting"))
      assert shown_panels(html) == ["connecting"]
      assert html =~ "Connecting…"
      refute end_hidden?(html)
    end

    test "connecting carries a hidden Still connecting line in text-warning with a Reload button (01a0dbd6)" do
      html = render_state(status("connecting"))
      [panel] = html |> doc() |> Floki.find(~s([data-gs-panel="connecting"]))

      [line] = Floki.find(panel, "[data-gs-connecting-line]")
      assert Floki.text(line) =~ "Connecting…"

      [stuck] = Floki.find(panel, "[data-gs-stuck]")
      # The hook reveals it after 10 s with no frame on the current peer.
      assert Floki.attribute(stuck, "hidden") != []

      [warning] = Floki.find(stuck, "p")
      assert String.trim(Floki.text(warning)) == "Still connecting"
      assert warning |> Floki.attribute("class") |> hd() =~ ~r/\btext-warning\b/

      [reload] = Floki.find(stuck, "button[data-gs-reload]")
      assert String.trim(Floki.text(reload)) == "Reload"
      assert Floki.attribute(reload, "type") == ["button"]
      classes = reload |> Floki.attribute("class") |> hd() |> String.split() |> Enum.sort()
      assert classes == ["btn", "btn-sm"]
    end

    test "the Still connecting line exists only in the connecting panel" do
      html = render_state(status("live"))
      assert html |> doc() |> Floki.find("[data-gs-stuck]") |> length() == 1

      in_connecting =
        html |> doc() |> Floki.find(~s([data-gs-panel="connecting"] [data-gs-stuck]))

      assert length(in_connecting) == 1
    end

    test "live renders as connecting until this window has a frame" do
      html = render_state(status("live"))
      assert shown_panels(html) == ["connecting"]
      # The Click to play overlay is in the markup for the hook to reveal.
      assert html =~ "Click to play"
      assert html =~ "Keys and controller go to the game until you press Esc."
      refute end_hidden?(html)
    end

    test "audio uses a dedicated element and starts in an honest waiting state" do
      html = render_state(status("live"))
      parsed = doc(html)

      [video] = Floki.find(parsed, "video[data-gs-video]")
      assert Floki.attribute(video, "muted") != []

      [audio] = Floki.find(parsed, "audio[data-gs-audio]")
      assert Floki.attribute(audio, "autoplay") != []
      assert Floki.attribute(audio, "playsinline") != []

      [state] = Floki.find(parsed, "[data-gs-audio-state]")
      assert Floki.attribute(state, "data-gs-audio-state") == ["waiting"]
      assert String.trim(Floki.text(state)) == "Waiting for audio"
      assert Floki.attribute(state, "aria-live") == ["polite"]

      [mute] = Floki.find(parsed, "button[data-gs-mute]")
      assert Floki.attribute(mute, "disabled") != []
      assert Floki.attribute(mute, "aria-pressed") == ["false"]
      assert String.trim(Floki.text(mute)) == "Mute"
    end

    test "the capture ring is the only primary in a v1 node, and starts hidden" do
      html = render_state(status("live"))
      [ring] = html |> doc() |> Floki.find("[data-gs-ring]")
      [class] = Floki.attribute(ring, "class")
      assert class =~ "ring-2"
      assert class =~ "ring-primary"
      assert Floki.attribute(ring, "hidden") != []
      # The ring, plus YOUR roster chip's class, which the strip carries for
      # the hook even while it is hidden (01a0dbd6 stage 4): nothing else.
      assert Regex.scan(~r/[\w:-]*\bprimary\b[\w-]*/, html) |> List.flatten() |> Enum.sort() ==
               ["bg-primary", "ring-primary", "text-primary-content"]
    end

    test "ended: the reason and Start again, End gone" do
      html = render_state(status("ended", %{ended_reason: "Session ended after 10 minutes idle"}))
      assert shown_panels(html) == ["ended"]
      assert html =~ "Session ended after 10 minutes idle"
      assert html =~ "Start again"
      assert end_hidden?(html)
      # Last frame dimmed: the panel sits over the video on a translucent black.
      [panel] = html |> doc() |> Floki.find(~s([data-gs-panel="ended"]))
      assert hd(Floki.attribute(panel, "class")) =~ "bg-black/60"
    end

    test "failed: a plain-words error line in text-error, and Start again" do
      html = render_state(status("failed", %{ended_reason: "The build failed on the play host"}))
      assert shown_panels(html) == ["failed"]
      [panel] = html |> doc() |> Floki.find(~s([data-gs-panel="failed"]))
      [line] = Floki.find(panel, "[data-gs-reason]")
      assert Floki.text(line) =~ "The build failed on the play host"
      assert hd(Floki.attribute(line, "class")) =~ "text-error"
      assert Floki.text(panel) =~ "Start again"
      assert end_hidden?(html)
    end

    test "the takeover panel says Continued in another window" do
      html = render_state(status("live"))
      [panel] = html |> doc() |> Floki.find(~s([data-gs-panel="takeover"]))
      assert Floki.text(panel) =~ "Continued in another window"
    end

    # Task 01a0ee4f stage 2: the copy a twin in the same page took the stream
    # from. Its Play here is the twin button (a same-page reclaim), never the
    # takeover panel's window-level data-gs-play-here. The line names where
    # the stream went, from where this copy is: the inline chat copy points at
    # the canvas panel, the panel / overlay copy points back at the chat.
    test "the elsewhere panel carries the twin Play here, not the take-over one" do
      html = render_state(status("live"))
      [panel] = html |> doc() |> Floki.find(~s([data-gs-panel="elsewhere"]))
      assert Floki.attribute(panel, "hidden") != []
      [button] = Floki.find(panel, "button")
      assert Floki.attribute(button, "data-gs-play-here-twin") != []
      assert Floki.attribute(button, "data-gs-play-here") == []
      assert Floki.text(button) =~ "Play here"
      assert Floki.find(panel, "[data-gs-play-here]") == []
      [takeover] = html |> doc() |> Floki.find(~s([data-gs-panel="takeover"]))
      assert Floki.find(takeover, "[data-gs-play-here-twin]") == []
      assert Floki.text(takeover) =~ "Continued in another window"
    end

    test "the inline copy says Playing in the canvas panel; the panel copy says Playing in the chat" do
      line = fn scope ->
        render_component(&GameStreamKind.render/1,
          node: gs_node(%{"session_id" => @session, "review_sha" => @sha}),
          dom_id_scope: scope,
          canvas_id: "canvas-x",
          status: status("live")
        )
        |> doc()
        |> Floki.find(~s([data-gs-panel="elsewhere"] [data-gs-elsewhere-line]))
        |> Floki.text()
        |> String.trim()
      end

      assert line.("canvas-x-chat-message-inline") == "Playing in the canvas panel"
      assert line.("canvas-x-chat-message-expanded") == "Playing in the chat"
      assert line.("canvas-x-expanded") == "Playing in the chat"
      assert line.(nil) == "Playing in the canvas panel"
    end

    test "the stats readout is always rendered, in mono xs, with no toggle" do
      html = render_state(status("building"))
      [stats] = html |> doc() |> Floki.find("[data-gs-stats]")
      [class] = Floki.attribute(stats, "class")
      assert class =~ "font-mono"
      assert class =~ "text-xs"
      assert Floki.attribute(stats, "hidden") == []
      refute html =~ ~r/type="range"|<progress|controls/
    end

    test "the wrapper is the GameStream hook, ignore-updated, id scoped and session-keyed" do
      html = render_state(status("building"), %{"latency_warn_ms" => 40})
      [root] = html |> doc() |> Floki.find("[phx-hook=GameStream]")
      assert Floki.attribute(root, "phx-update") == ["ignore"]
      assert Floki.attribute(root, "id") == ["game-stream-gs-canvas-x-expanded-#{@session}"]
      assert Floki.attribute(root, "data-session-id") == [@session]
      assert Floki.attribute(root, "data-canvas-id") == ["canvas-x"]
      assert Floki.attribute(root, "data-node-id") == ["gs"]
      assert Floki.attribute(root, "data-latency-warn-ms") == ["40"]
    end

    test "two scopes give two ids, so panel and mobile overlay can both render" do
      node = gs_node(%{"session_id" => @session})

      a =
        render_component(&GameStreamKind.render/1,
          node: node,
          dom_id_scope: "a",
          status: status("building")
        )

      b =
        render_component(&GameStreamKind.render/1,
          node: node,
          dom_id_scope: "b",
          status: status("building")
        )

      id = &(&1 |> doc() |> Floki.find("[phx-hook=GameStream]") |> Floki.attribute("id"))
      refute id.(a) == id.(b)
    end

    test "the video well is black and the video is muted, autoplay, playsinline" do
      html = render_state(status("live"))
      [well] = html |> doc() |> Floki.find("[data-gs-well]")
      assert hd(Floki.attribute(well, "class")) =~ "bg-black"
      [video] = Floki.find(well, "video")
      for attr <- ~w(muted autoplay playsinline), do: assert(Floki.attribute(video, attr) != [])
    end
  end

  # ── Task 01a0dbd6 stage 4: the multiplayer roster, one case per state ─────

  @harper %{peer_id: "p-harper", name: "Harper", user_id: "u1"}
  @rowan %{peer_id: "p-rowan", name: "Rowan", user_id: "u2"}

  defp roster(slots, extra \\ %{}) do
    Map.merge(
      %{slots: slots, spectators: 0, names: [], max_players: 4, multi: true},
      extra
    )
  end

  defp render_multi(roster, opts \\ []) do
    node =
      gs_node(%{
        "session_id" => @session,
        "task_id" => "t",
        "review_sha" => @sha,
        "title" => "Voltron: dash tuning"
      })

    render_component(&GameStreamKind.render/1,
      node: node,
      dom_id_scope: "canvas-x-expanded",
      canvas_id: "canvas-x",
      status: Keyword.get(opts, :status, status("live")),
      roster: roster,
      peer_id: Keyword.get(opts, :peer_id)
    )
  end

  defp one(html, selector) do
    [el] = html |> doc() |> Floki.find(selector)
    el
  end

  defp hidden?(el), do: Floki.attribute(el, "hidden") != []
  defp text(el), do: el |> Floki.text(sep: " ") |> String.split() |> Enum.join(" ")
  defp classes(el), do: el |> Floki.attribute("class") |> hd() |> String.split()

  defp chip_states(html, box) do
    html
    |> doc()
    |> Floki.find("#{box} [data-gs-chip]")
    |> Enum.map(
      &{hd(Floki.attribute(&1, "data-gs-chip")), hd(Floki.attribute(&1, "data-gs-chip-state"))}
    )
  end

  describe "multiplayer render (01a0dbd6 stage 4)" do
    setup do
      enable!()
      :ok
    end

    test "watching: opening renders as a spectator with 'Watching' and 'Join as player N'" do
      html = render_multi(roster(%{0 => @harper}, %{spectators: 1, names: ["Ann"]}))

      watch = one(html, "[data-gs-watch]")
      refute hidden?(watch)
      assert text(one(html, "[data-gs-watch-line]")) == "Watching"

      join = one(html, "[data-gs-join]")
      refute hidden?(join)
      assert text(join) == "Join as player 2"
      assert Floki.attribute(join, "data-gs-join-slot") == ["1"]

      # A spectator has nothing to leave, and End is in the overflow.
      assert hidden?(one(html, "[data-gs-leave]"))
      assert end_hidden?(html)
      refute hidden?(one(html, "[data-gs-overflow]"))
    end

    test "slots full: the design's line and no Join" do
      html = render_multi(roster(%{0 => @harper, 1 => @rowan}, %{max_players: 2}))

      assert text(one(html, "[data-gs-watch-line]")) ==
               "All 2 player slots are taken. You are watching."

      assert hidden?(one(html, "[data-gs-join]"))

      html4 =
        render_multi(roster(%{0 => @harper, 1 => @rowan, 2 => @harper, 3 => @rowan}))

      assert text(one(html4, "[data-gs-watch-line]")) ==
               "All 4 player slots are taken. You are watching."
    end

    test "the roster strip: P1-P4 chips in mono xs, names truncating, the you chip in primary" do
      html =
        render_multi(roster(%{0 => @harper, 1 => @rowan}, %{spectators: 2, names: ["Ann", "Bo"]}),
          peer_id: "p-rowan"
        )

      assert chip_states(html, "[data-gs-chips]") ==
               [{"0", "other"}, {"1", "you"}, {"2", "open"}, {"3", "open"}]

      [p1, p2, p3, _p4] = html |> doc() |> Floki.find("[data-gs-chips] [data-gs-chip]")

      assert text(p1) == "P1 Harper"
      assert text(p2) == "P2 You"
      assert text(p3) == "P3 open"

      for c <- ["bg-base-300", "text-base-content"], do: assert(c in classes(p1))
      for c <- ["bg-primary", "text-primary-content"], do: assert(c in classes(p2))

      for c <- ["border", "border-dashed", "border-base-content/40"],
          do: assert(c in classes(p3))

      # No per-player hue: no status colour anywhere in a chip.
      for chip <- [p1, p2, p3], c <- classes(chip) do
        refute c =~ ~r/(error|warning|success|info|accent|secondary)/
      end

      # Occupied chips are not buttons you can press; an open one is.
      assert Floki.attribute(p1, "aria-disabled") == ["true"]
      assert Floki.attribute(p3, "aria-disabled") == []

      [label] = Floki.find(p1, "[data-gs-chip-label]")
      assert "font-mono" in classes(label) and "text-xs" in classes(label)
      assert "shrink-0" in classes(label)
      [name] = Floki.find(p1, "[data-gs-chip-name]")
      assert "truncate" in classes(name) and "text-xs" in classes(name)

      # Activity dots on held slots only, in base-content.
      [dot] = Floki.find(p1, "[data-gs-chip-dot]")
      assert "bg-base-content" in classes(dot)
      refute hidden?(dot)
      [open_dot] = Floki.find(p3, "[data-gs-chip-dot]")
      assert hidden?(open_dot)

      watching = one(html, "[data-gs-watching]")
      assert text(watching) == "2 watching"
      assert Floki.attribute(watching, "title") == ["Ann, Bo"]
    end

    test "player (you P2): Leave replaces End, no watching row" do
      html = render_multi(roster(%{0 => @harper, 1 => @rowan}), peer_id: "p-rowan")

      leave = one(html, "[data-gs-leave]")
      refute hidden?(leave)
      assert text(leave) == "Leave"
      assert end_hidden?(html)
      assert hidden?(one(html, "[data-gs-watch]"))
    end

    test "two pads in one browser: both slots are yours" do
      html = render_multi(roster(%{0 => @rowan, 1 => @rowan}), peer_id: "p-rowan")

      assert chip_states(html, "[data-gs-chips]") ==
               [{"0", "you"}, {"1", "you"}, {"2", "open"}, {"3", "open"}]

      assert text(one(html, "[data-gs-roster-line-text]")) ==
               "You are P1 and P2 · 0 others playing · 0 watching"
    end

    test "overflow: Take over per slot someone else holds, and End session for N people" do
      html =
        render_multi(roster(%{0 => @harper, 1 => @rowan}, %{spectators: 1}), peer_id: "p-rowan")

      overflow = one(html, "[data-gs-overflow]")
      refute hidden?(overflow)
      [toggle] = Floki.find(overflow, "[data-gs-overflow-toggle]")
      assert Floki.attribute(toggle, "aria-haspopup") == ["menu"]
      [icon] = Floki.find(toggle, "span")
      assert "hero-ellipsis-horizontal" in classes(icon)

      menu = one(html, "[data-gs-overflow-menu]")
      assert hidden?(menu)

      items = Floki.find(menu, "[data-gs-take-items] [data-gs-take-over]")
      assert Enum.map(items, &text/1) == ["Take over P1 from Harper"]
      assert Enum.flat_map(items, &Floki.attribute(&1, "data-gs-take-over")) == ["0"]

      # The one-line confirm is in the markup, hidden until an item is picked.
      confirm = one(html, "[data-gs-confirm]")
      assert hidden?(confirm)
      assert text(one(html, "[data-gs-confirm-yes]")) == "Take over"
      assert text(one(html, "[data-gs-confirm-no]")) == "Cancel"

      assert text(one(html, "[data-gs-end-session]")) ==
               "End session Ends the session for 3 people"

      solo = render_multi(roster(%{0 => @rowan}), peer_id: "p-rowan")
      assert text(one(solo, "[data-gs-end-line]")) == "Ends the session for 1 person"
      assert solo |> doc() |> Floki.find("[data-gs-take-items] [data-gs-take-over]") == []
    end

    test "375px: the strip is a single line that opens the full roster in a sheet" do
      html =
        render_multi(
          roster(%{0 => @harper, 1 => @rowan, 2 => %{peer_id: "p3", name: "Cy", user_id: nil}}, %{
            spectators: 2,
            names: ["Ann", "Bo"]
          }),
          peer_id: "p-rowan"
        )

      line = one(html, "[data-gs-roster-line]")
      assert "@md:hidden" in classes(line)

      assert text(one(html, "[data-gs-roster-line-text]")) ==
               "You are P2 · 2 others playing · 2 watching"

      strip = one(html, "[data-gs-roster-strip]")
      assert "hidden" in classes(strip) and "@md:flex" in classes(strip)

      sheet = one(html, "dialog[data-gs-sheet]")
      assert "modal" in classes(sheet) and "modal-bottom" in classes(sheet)
      assert Floki.find(sheet, ".modal-box") != []

      assert chip_states(html, "[data-gs-sheet-chips]") ==
               [{"0", "other"}, {"1", "you"}, {"2", "other"}, {"3", "open"}]

      assert text(one(html, "[data-gs-sheet-watching]")) == "2 watching: Ann, Bo"

      spectator = render_multi(roster(%{0 => @harper}, %{spectators: 1}))

      assert text(one(spectator, "[data-gs-roster-line-text]")) ==
               "You are watching · 1 playing · 1 watching"
    end

    test "the hook's templates and the chip classes are written once, here" do
      html = render_multi(roster(%{}))
      strip = one(html, "[data-gs-roster]")
      classes = GameStreamKind.chip_classes()
      assert Floki.attribute(strip, "data-gs-chip-you") == [classes.you]
      assert Floki.attribute(strip, "data-gs-chip-other") == [classes.other]
      assert Floki.attribute(strip, "data-gs-chip-open") == [classes.open]
      assert classes.you == "bg-primary text-primary-content"
      assert classes.other == "bg-base-300 text-base-content"

      for t <- ~w(data-gs-chip-template data-gs-take-template data-gs-pad-template) do
        assert html =~ "<template #{t}>"
      end

      # No hex anywhere in the node: semantic tokens only.
      refute html =~ ~r/#[0-9a-fA-F]{3,8}\b/
    end

    test "the pad rows and the watching row are rendered for the hook to fill" do
      html = render_multi(roster(%{0 => @rowan}), peer_id: "p-rowan")
      assert hidden?(one(html, "[data-gs-pads]"))
    end

    test "not running: no Leave, no overflow, no watching row" do
      html =
        render_multi(roster(%{0 => @rowan}),
          peer_id: "p-rowan",
          status: status("ended", %{ended_reason: "Session ended"})
        )

      assert hidden?(one(html, "[data-gs-leave]"))
      assert hidden?(one(html, "[data-gs-overflow]"))
      assert hidden?(one(html, "[data-gs-watch]"))
      assert end_hidden?(html)
    end

    test "a v1 host (no multi) renders none of it and keeps End" do
      html = render_multi(roster(%{0 => @rowan}, %{multi: false, max_players: 1}))
      assert hidden?(one(html, "[data-gs-roster]"))
      assert hidden?(one(html, "[data-gs-watch]"))
      assert hidden?(one(html, "[data-gs-leave]"))
      assert hidden?(one(html, "[data-gs-overflow]"))
      refute end_hidden?(html)
    end

    test "no roster at all (no session) is the v1 render" do
      html = render_state(status("live"))
      assert hidden?(one(html, "[data-gs-roster]"))
      refute end_hidden?(html)
    end
  end
end
