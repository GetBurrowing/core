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

    test "live renders as connecting until this window has a frame" do
      html = render_state(status("live"))
      assert shown_panels(html) == ["connecting"]
      # The Click to play overlay is in the markup for the hook to reveal.
      assert html =~ "Click to play"
      assert html =~ "Keys and controller go to the game until you press Esc."
      refute end_hidden?(html)
    end

    test "the capture ring is the only primary in the node, and starts hidden" do
      html = render_state(status("live"))
      [ring] = html |> doc() |> Floki.find("[data-gs-ring]")
      [class] = Floki.attribute(ring, "class")
      assert class =~ "ring-2"
      assert class =~ "ring-primary"
      assert Floki.attribute(ring, "hidden") != []
      assert length(Regex.scan(~r/\bprimary\b/, html)) == 1
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
end
