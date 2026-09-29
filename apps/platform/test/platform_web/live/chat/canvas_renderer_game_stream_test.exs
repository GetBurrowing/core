defmodule PlatformWeb.Chat.CanvasRendererGameStreamTest do
  @moduledoc """
  The inline canvas card's click-to-open wrapper, and the kind-level opt-out
  `game_stream` uses to leave it (task 01a0ee4f stage 1).

  NOT async: cases toggle `:platform, :game_stream_enabled` (global app env),
  which decides whether `game_stream` is a registered kind at all.

  The wrapper tags below are LITERALS, not derived from the renderer.
  `@opening_wrapper` and `@panel_wrapper` are the bytes origin/main
  (eb30c8593) emits for an inline and a panel card, trailing class space
  included, so a change to any attribute of a non-Play card fails here.
  `@closed_wrapper` is the Play card's inline wrapper after this change.
  """

  use ExUnit.Case, async: false

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Platform.Chat.Canvas
  alias Platform.Chat.Canvas.Kinds.GameStream, as: GameStreamKind
  alias PlatformWeb.Chat.CanvasRenderer

  @sha "0123456789abcdef0123456789abcdef01234567"

  @opening_wrapper ~s(<div id="canvas-doc-test-canvas-inline" class="overflow-x-auto cursor-pointer" phx-click="canvas_open" phx-value-canvas-id="test-canvas">)
  @closed_wrapper ~s(<div id="canvas-doc-test-canvas-inline" class="overflow-x-auto ">)
  @panel_wrapper ~s(<div id="canvas-doc-test-canvas-expanded" class="overflow-x-auto ">)

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

  defp canvas(root) do
    %Canvas{
      id: "test-canvas",
      space_id: "test-space",
      created_by: "test-user",
      title: "Test Canvas",
      document: %{
        "version" => 1,
        "revision" => 1,
        "root" => root,
        "theme" => %{},
        "bindings" => %{},
        "meta" => %{}
      },
      inserted_at: ~U[2026-01-01 00:00:00Z],
      updated_at: ~U[2026-01-01 00:00:00Z]
    }
  end

  defp stack(children),
    do: %{"id" => "root", "type" => "stack", "props" => %{}, "children" => children}

  # The shape `Platform.GameStream.Tools` posts: a stack root, one child.
  defp play_root do
    stack([
      %{
        "id" => "game-stream",
        "type" => "game_stream",
        "props" => %{"review_sha" => @sha, "title" => "Review build"}
      }
    ])
  end

  defp render(canvas, inline) do
    assigns = %{canvas: canvas, inline: inline}

    ~H"""
    <CanvasRenderer.canvas_document canvas={@canvas} inline={@inline} />
    """
    |> rendered_to_string()
  end

  defp wrapper_tag(html, suffix) do
    [tag] = Regex.run(~r/<div id="canvas-doc-test-canvas-#{suffix}"[^>]*>/, html)
    tag
  end

  describe "the game_stream kind opts out" do
    test "it says so through the convention function" do
      assert GameStreamKind.inline_opens_canvas?() == false
    end

    test "(a) an inline stack>game_stream card has no canvas_open and no cursor-pointer" do
      enable!()
      html = render(canvas(play_root()), true)

      # The node really rendered (not the unknown-kind fallback).
      assert html =~ ~s(phx-hook="GameStream")
      assert wrapper_tag(html, "inline") == @closed_wrapper
      refute html =~ ~s(phx-click="canvas_open")
      refute html =~ "phx-value-canvas-id"
    end

    test "a game_stream node deeper than the root's children still opts the card out" do
      enable!()

      root =
        stack([
          %{
            "id" => "card",
            "type" => "card",
            "props" => %{"title" => "Play"},
            "children" => [hd(play_root()["children"])]
          }
        ])

      assert render(canvas(root), true) |> wrapper_tag("inline") == @closed_wrapper
    end

    test "(c) the panel render of the Play document is unchanged" do
      enable!()
      html = render(canvas(play_root()), false)

      assert wrapper_tag(html, "expanded") == @panel_wrapper
      assert html =~ ~s(phx-hook="GameStream")
    end

    test "(d) with the kind disabled, the fallback-rendered card keeps canvas_open" do
      html = render(canvas(play_root()), true)

      assert html =~ "[unknown node type: game_stream]"
      assert wrapper_tag(html, "inline") == @opening_wrapper
    end
  end

  describe "open_target (#1157) composed with the Play opt-out" do
    # #1157 added `open_target`, emitted as phx-target next to the canvas_open
    # binding. The target follows the binding: a Play card carries neither, and
    # every other inline card keeps both.
    defp render_targeted(canvas, target) do
      assigns = %{canvas: canvas, target: target}

      ~H"""
      <CanvasRenderer.canvas_document canvas={@canvas} inline={true} open_target={@target} />
      """
      |> rendered_to_string()
    end

    test "a targeted Play card still has no canvas_open and no phx-target" do
      enable!()
      html = render_targeted(canvas(play_root()), "#steering")

      assert html =~ ~s(phx-hook="GameStream")
      assert wrapper_tag(html, "inline") == @closed_wrapper
      refute html =~ "phx-target"
    end

    test "a targeted markdown card keeps canvas_open and gains phx-target" do
      enable!()
      root = stack([%{"id" => "md", "type" => "markdown", "props" => %{"content" => "hi"}}])
      tag = render_targeted(canvas(root), "#steering") |> wrapper_tag("inline")

      assert tag =~ ~s(phx-click="canvas_open")
      assert tag =~ ~s(phx-target="#steering")
    end
  end

  describe "(b) every other kind opens exactly as on main" do
    setup do
      # With game_stream registered, so the walk runs against the full registry.
      enable!()
      :ok
    end

    test "markdown" do
      root =
        stack([%{"id" => "md", "type" => "markdown", "props" => %{"content" => "# Hi"}}])

      assert render(canvas(root), true) |> wrapper_tag("inline") == @opening_wrapper
    end

    test "table" do
      root =
        stack([
          %{
            "id" => "t",
            "type" => "table",
            "props" => %{"columns" => ["a"], "rows" => [%{"a" => "1"}]}
          }
        ])

      assert render(canvas(root), true) |> wrapper_tag("inline") == @opening_wrapper
    end

    test "embed" do
      root =
        stack([
          %{"id" => "embed", "type" => "embed", "props" => %{"srcdoc" => "<p>hi</p>"}}
        ])

      assert render(canvas(root), true) |> wrapper_tag("inline") == @opening_wrapper
    end

    test "a root that is itself a leaf kind" do
      root = %{"id" => "md", "type" => "markdown", "props" => %{"content" => "hi"}}
      assert render(canvas(root), true) |> wrapper_tag("inline") == @opening_wrapper
    end
  end
end
