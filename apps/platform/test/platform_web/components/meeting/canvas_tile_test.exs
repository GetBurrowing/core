defmodule PlatformWeb.Components.Meeting.CanvasTileTest do
  @moduledoc """
  Unit tests for the `<.canvas_tile>` component.

  The tile is the render-path answer to putting a canvas on the meeting stage
  (see the component moduledoc for why it is not a published media track), so
  these tests pin the DOM contract the design constrains: a document surface,
  previewed rather than rendered at reading size, a name plate where the
  timestamp never loses space to the title, and a one-shot highlight that
  never animates.

  ## On the sizing tests

  Rowan rejected the first build for two coupled reasons — the body was legible
  rather than a preview, and content dictated the tile's size. The second is
  the one that is easy to test vacuously: asserting "the tile has class X"
  passes just as happily against an implementation where a long document grows
  the box, because the class is on the element either way.

  So the sizing tests here do two things a class-presence check cannot:

    1. Render TWO fixtures — a one-line canvas and a deliberately enormous one
       — and assert their geometry is identical. A test with only the small
       fixture cannot fail on the bug it is meant to catch.
    2. Assert the STRUCTURE that makes that identity hold: the document is
       absolutely positioned inside an `overflow-hidden` box, so it is out of
       flow and contributes nothing to the tile's height. Point 1 without
       point 2 would still pass against a build where both fixtures happened
       to overflow equally.

  What no ExUnit test here can do is measure pixels — there is no layout
  engine. The measured evidence is the manual_approval screenshots.

  Structs are built in-memory with generated ids — no database, no real
  space or meeting identifiers.
  """

  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PlatformWeb.Components.Meeting.CanvasTile

  alias Platform.Chat.Canvas

  # A two-block document: enough content that the crop window has something to
  # crop, and two distinct strings to prove the body actually rendered.
  defp two_block_canvas(overrides \\ %{}) do
    document = %{
      "version" => 1,
      "revision" => 2,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "children" => [
          %{"id" => "b1", "type" => "text", "props" => %{"value" => "First block body"}},
          %{"id" => "b2", "type" => "text", "props" => %{"value" => "Second block body"}}
        ]
      }
    }

    struct!(
      Canvas,
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          space_id: Ecto.UUID.generate(),
          title: "Sprint notes",
          document: document,
          deleted_at: nil,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        },
        overrides
      )
    )
  end

  # A one-line canvas: the SMALL half of the two-fixture geometry pair.
  defp tiny_canvas do
    two_block_canvas(%{
      title: "One-liner",
      document: %{
        "version" => 1,
        "revision" => 1,
        "root" => %{
          "id" => "root",
          "type" => "stack",
          "children" => [
            %{"id" => "only", "type" => "text", "props" => %{"value" => "hi"}}
          ]
        }
      }
    })
  end

  # A deliberately enormous canvas: 120 blocks, each carrying a long line. The
  # LARGE half of the pair. If content could reach the tile's geometry at all,
  # this is the fixture that would move it — which is the whole reason it
  # exists. Sized well past any plausible tile height rather than "a bit
  # bigger", so the test does not depend on where the crop would have fallen.
  defp huge_canvas do
    children =
      for i <- 1..120 do
        %{
          "id" => "b#{i}",
          "type" => "text",
          "props" => %{"value" => "Block #{i} " <> String.duplicate("lorem ipsum dolor ", 20)}
        }
      end

    two_block_canvas(%{
      title: "Enormous",
      document: %{
        "version" => 1,
        "revision" => 9,
        "root" => %{"id" => "root", "type" => "stack", "children" => children}
      }
    })
  end

  defp render_tile(canvas, opts) do
    assigns = %{
      c: canvas,
      changed?: Keyword.get(opts, :changed?, false),
      layout: Keyword.get(opts, :layout, :strip),
      prefix: Keyword.get(opts, :id_prefix, "gallery-canvas-tile")
    }

    rendered_to_string(~H"""
    <.canvas_tile canvas={@c} id_prefix={@prefix} layout={@layout} changed?={@changed?} />
    """)
  end

  defp render_video_tile(layout) do
    assigns = %{layout: layout}

    rendered_to_string(~H"""
    <PlatformWeb.Components.Meeting.VideoTile.video_tile
      id_prefix="gallery-tile"
      participant={%{identity: "user:1", name: "Ada"}}
      video_track={false}
      audio_muted?={false}
      speaking?={false}
      avatar_url={nil}
      layout={@layout}
    />
    """)
  end

  # Classes on the ROOT element that can affect how big the element is inside
  # its parent. Display/direction utilities (`flex`, `flex-col`) are excluded
  # on purpose: they govern the tile's CHILDREN, not the tile's own footprint,
  # and the canvas tile legitimately differs from the video tile there.
  @sizing_prefixes ~w(aspect- h- w- max- min- shrink- grow- basis- size-)

  defp sizing_classes(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("class")
    |> List.first()
    |> Kernel.||("")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.filter(fn c -> Enum.any?(@sizing_prefixes, &String.starts_with?(c, &1)) end)
    |> Enum.sort()
  end

  defp node_count(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.count()
  end

  describe "canvas_tile/1 — document surface" do
    test "renders both document blocks inside a bg-base-100 content area" do
      html = render_tile(two_block_canvas(), [])

      assert html =~ "First block body"
      assert html =~ "Second block body"

      assert node_count(html, ~s([data-role="canvas-tile-content"].bg-base-100)) == 1
    end

    test "derives the dom id from id_prefix and uses a tile-distinct dom_id_base" do
      canvas = two_block_canvas()
      html = render_tile(canvas, [])

      assert node_count(html, ~s(##{"gallery-canvas-tile-" <> canvas.id})) == 1
      # Distinct from the canvas view's "meeting-stage" base, so the two
      # renderings of one canvas never mint colliding dom ids.
      assert html =~ "meeting-tile-gallery-canvas-tile"
      refute html =~ "meeting-stage"
    end

    test "the body is scaled down to a preview, and the scale is clipped to the tile" do
      html = render_tile(two_block_canvas(), [])

      # Reduced, not true type size. Rowan: "not necessarily to see at a fine
      # level what the content is, just that THERE IS content".
      assert node_count(html, ~s([data-role="canvas-tile-preview"])) == 1
      assert html =~ "scale-[0.3333]"
      assert html =~ "w-[300%]"
      assert node_count(html, ~s([data-role="canvas-tile-preview"].origin-top-left)) == 1

      # A transform paints outside the border box unless something clips it,
      # so the clip is part of the sizing contract, not decoration.
      assert node_count(html, ~s([data-role="canvas-tile-content"].overflow-hidden)) == 1
    end

    test "the name plate is NOT inside the scaled region — it stays legible" do
      html = render_tile(two_block_canvas(%{title: "Sprint notes"}), [])

      # The identifying affordance must survive the preview treatment. If the
      # title/timestamp ever land inside the preview they render at a third of
      # type size and the tile stops being clickable-with-intent.
      assert node_count(
               html,
               ~s([data-role="canvas-tile-preview"] [data-role="canvas-tile-title"])
             ) == 0

      assert node_count(
               html,
               ~s([data-role="canvas-tile-preview"] [data-role="canvas-tile-timestamp"])
             ) == 0

      assert node_count(html, ~s([data-role="canvas-tile-title"])) == 1
      assert node_count(html, ~s([data-role="canvas-tile-timestamp"])) == 1
    end
  end

  describe "canvas_tile/1 — geometry is independent of content" do
    # THE anti-vacuity pair. Neither fixture alone can fail on the bug: a
    # one-line canvas produces a correctly-sized tile even in the build Rowan
    # rejected, where content dictated the box.
    test "a 120-block canvas produces the same sizing classes as a one-line canvas" do
      small = render_tile(tiny_canvas(), layout: :gallery)
      large = render_tile(huge_canvas(), layout: :gallery)

      # Sanity: the fixtures really do differ in content, so this is not two
      # renders of the same thing agreeing with itself.
      assert large =~ "Block 120"
      refute small =~ "Block 120"

      assert sizing_classes(small, ~s([data-role="canvas-tile"])) ==
               sizing_classes(large, ~s([data-role="canvas-tile"]))

      assert sizing_classes(small, ~s([data-role="canvas-tile-content"])) ==
               sizing_classes(large, ~s([data-role="canvas-tile-content"]))
    end

    test "the document is out of flow in both fixtures, which is WHY the box cannot move" do
      # Class equality above is necessary but not sufficient — an in-flow
      # document keeps identical classes while still growing the rendered box.
      # The structural guarantee is absolute positioning inside a clipped,
      # min-h-0 box: an out-of-flow child contributes zero height to its
      # parent no matter how tall it is.
      for {label, canvas} <- [{"tiny", tiny_canvas()}, {"huge", huge_canvas()}] do
        html = render_tile(canvas, layout: :gallery)

        assert node_count(html, ~s([data-role="canvas-tile-preview"].absolute)) == 1,
               "#{label}: preview must be absolutely positioned so content cannot grow the tile"

        assert node_count(
                 html,
                 ~s([data-role="canvas-tile-content"].overflow-hidden.min-h-0 [data-role="canvas-tile-preview"])
               ) == 1,
               "#{label}: preview must sit inside the clipped, min-h-0 content box"
      end
    end

    test "the tile carries the class the unlayered clamp keys on, with no call-site help" do
      # A grid item's min-height defaults to `auto` — "never shrink below your
      # content" — which is precisely how a tall canvas used to shove a
      # neighbouring face tile out of line. The call sites clamp it, but a
      # future call site can forget, so the component must not depend on them:
      # the durable clamp is the unlayered `.meeting-canvas-tile` rule in
      # app.css (asserted below). This test pins the hook it needs — the class
      # must be on the tile even when the caller passes nothing at all.
      html = render_tile(huge_canvas(), layout: :gallery)

      assert node_count(html, ~s([data-role="canvas-tile"].meeting-canvas-tile)) == 1

      # And the component itself contributes no content-derived sizing: for
      # :gallery the cell container query is the sole authority, so the root
      # must carry no sizing utilities to compete with it.
      assert sizing_classes(html, ~s([data-role="canvas-tile"])) == []
    end
  end

  describe "canvas_tile/1 — same box as a face tile" do
    test "sizing classes match <.video_tile> for each layout" do
      for layout <- [:strip, :gallery] do
        canvas_sizing =
          sizing_classes(render_tile(tiny_canvas(), layout: layout), ~s(.meeting-canvas-tile))

        video_sizing = sizing_classes(render_video_tile(layout), ~s(.meeting-video-tile))

        assert canvas_sizing == video_sizing,
               "layout #{inspect(layout)}: canvas tile sized #{inspect(canvas_sizing)} but a face tile is #{inspect(video_sizing)}"
      end
    end

    test "app.css applies the gallery-cell container query to the canvas tile too" do
      # The :gallery layout deliberately emits NO sizing classes — the cell
      # container query owns it. That makes the CSS the actual sizing
      # authority, so a class-only test would be asserting the empty set.
      # Resolved from __DIR__, not the cwd: a cwd-relative read passes or fails
      # depending on where mix was invoked from, which is a flake, not a test.
      css = File.read!(Path.expand("../../../../assets/css/app.css", __DIR__))

      assert css =~ "[data-gallery-cell] > .meeting-canvas-tile"

      # Same rule blocks as the face tile: the base aspect/max clamp plus BOTH
      # container-query branches. Missing one branch mis-sizes the canvas tile
      # in exactly half of all cell shapes.
      canvas_rules =
        css
        |> String.split("[data-gallery-cell] > .meeting-canvas-tile")
        |> length()
        |> Kernel.-(1)

      video_rules =
        css
        |> String.split("[data-gallery-cell] > .meeting-video-tile")
        |> length()
        |> Kernel.-(1)

      assert canvas_rules == video_rules and canvas_rules == 3

      # The unlayered clamp. Unlayered beats Tailwind's @layer utilities, so a
      # call site cannot widen the tile with a utility class.
      assert css =~ ~r/\.meeting-canvas-tile\s*\{[^}]*min-height:\s*0/
      assert css =~ ~r/\.meeting-canvas-tile\s*\{[^}]*max-height:\s*100%/
    end
  end

  describe "canvas_tile/1 — name plate" do
    test "the title truncates and the timestamp refuses to wrap" do
      html = render_tile(two_block_canvas(%{title: "Sprint notes"}), [])

      assert html =~ "Sprint notes"

      assert node_count(html, ~s([data-role="canvas-tile-title"].truncate.min-w-0)) == 1
      assert node_count(html, ~s([data-role="canvas-tile-title"].text-xs)) == 1

      assert node_count(
               html,
               ~s([data-role="canvas-tile-timestamp"].whitespace-nowrap.shrink-0)
             ) == 1
    end
  end

  describe "canvas_tile/1 — just-changed highlight" do
    test "the primary highlight appears only when changed? is true" do
      unchanged = render_tile(two_block_canvas(), changed?: false)
      changed = render_tile(two_block_canvas(), changed?: true)

      assert node_count(unchanged, ~s([data-role="canvas-tile"].ring-primary)) == 0
      assert node_count(changed, ~s([data-role="canvas-tile"].ring-primary)) == 1
    end

    test "the highlight is still — no animate-* class, and not a warning/error tone" do
      changed = render_tile(two_block_canvas(), changed?: true)

      refute changed =~ "animate-"
      refute changed =~ "ring-warning"
      refute changed =~ "ring-error"
    end
  end
end
