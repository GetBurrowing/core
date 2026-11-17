defmodule Platform.Chat.Canvas.Kinds.EpisodeBoardTest do
  @moduledoc """
  Task 01a1eaf6 stage 2: the `production_rail`, `needs_you` and `run_sheet`
  kinds and the `episode_board` template. Props are
  `Platform.Showrunner.Episode.to_document/1`'s, so most fixtures here are
  written BY `to_document/1` rather than by hand.
  """

  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Platform.Chat.Canvas.{Kinds, MarkdownExporter, Renderer, Templates}
  alias Platform.Chat.Canvas.Kinds.{NeedsYou, ProductionRail, RunSheet}
  alias Platform.Chat.{CanvasDocument, CanvasPatch}
  alias Platform.Showrunner.Episode

  @rail_labels ["Pitch", "Research", "Run sheet", "Logistics", "Record", "Post", "Retro"]

  defp board, do: Templates.get("episode_board").document

  defp node_of(doc, type),
    do: Enum.find(doc["root"]["children"], &(&1["type"] == type))

  defp render_html(node) do
    assigns = %{node: node}

    rendered_to_string(~H"""
    <Renderer.render_node node={@node} dom_id_scope="t" canvas_id="c1" />
    """)
  end

  defp query(html, selector),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp texts(html, selector),
    do: html |> query(selector) |> Enum.map(&String.trim(LazyHTML.text(&1)))

  defp present?(html, selector), do: Enum.count(query(html, selector)) > 0

  describe "registry" do
    test "the three kinds are core kinds and conform to the behaviour" do
      for mod <- [ProductionRail, NeedsYou, RunSheet] do
        assert mod in Kinds.core_modules()
        assert Kinds.behaviour_ok?(mod)
      end

      assert ~w(production_rail needs_you run_sheet) -- Kinds.names() == []
    end
  end

  describe "props validation" do
    test "every node to_document/1 writes validates against its kind" do
      doc = board()
      assert {:ok, _} = CanvasDocument.validate(doc)

      for type <- ~w(production_rail needs_you run_sheet) do
        assert Kinds.validate_node(node_of(doc, type)) == :ok
      end
    end

    test "the rail refuses an unknown stage, a missing stage and a bad number" do
      props = node_of(board(), "production_rail")["props"]

      assert {:error, _} = ProductionRail.validate_props(Map.put(props, "stage", "edit"))

      assert {:error, _} =
               ProductionRail.validate_props(Map.update!(props, "stages", &Enum.drop(&1, 1)))

      assert {:error, _} = ProductionRail.validate_props(Map.put(props, "number", 0))
      assert ProductionRail.validate_props(props) == :ok
    end

    test "needs_you refuses an item without options" do
      bad = %{"items" => [%{"id" => "a", "question" => "Which?", "options" => []}]}
      assert {:error, _} = NeedsYou.validate_props(bad)
      assert NeedsYou.validate_props(%{"items" => []}) == :ok
    end

    test "run_sheet refuses a gap between segments and a total over 45:00" do
      gap = %{
        "segments" => [
          %{"id" => "a", "starts_at_s" => 0, "ends_at_s" => 60, "name" => "A"},
          %{"id" => "b", "starts_at_s" => 90, "ends_at_s" => 120, "name" => "B"}
        ]
      }

      assert {:error, reason} = RunSheet.validate_props(gap)
      assert reason =~ "must start at 60s"

      long = %{
        "segments" => [%{"id" => "a", "starts_at_s" => 0, "ends_at_s" => 2701, "name" => "A"}]
      }

      assert {:error, reason} = RunSheet.validate_props(long)
      assert reason =~ "over the 2700s limit"
    end

    test "an unsourced stat is rejected by patch validation" do
      doc = board()
      segments = node_of(doc, "run_sheet")["props"]["segments"]

      unsourced =
        List.update_at(segments, 1, fn segment ->
          Map.put(segment, "stat_cards", [%{"text" => "38% of tasks automatable"}])
        end)

      assert {:error, reason} =
               CanvasPatch.apply(doc, {:set_props, "run_sheet", %{"segments" => unsourced}})

      assert reason =~ "without a source_url"
      assert reason =~ "the-town"

      blank =
        List.update_at(segments, 1, fn segment ->
          Map.put(segment, "stat_cards", [%{"text" => "38%", "source_url" => "  "}])
        end)

      assert {:error, _} =
               CanvasPatch.apply(doc, {:set_props, "run_sheet", %{"segments" => blank}})

      # The same patch with the source back in place is accepted.
      assert {:ok, _} =
               CanvasPatch.apply(doc, {:set_props, "run_sheet", %{"segments" => segments}})
    end
  end

  describe "production_rail render" do
    test "renders exactly seven stages, in order, on one line" do
      html = render_html(node_of(board(), "production_rail"))

      assert texts(
               html,
               ~s|[data-role="production-rail"] [data-role="rail-stage"] > span:nth-child(2)|
             ) ==
               @rail_labels

      assert html |> query(~s|[data-role="rail-dot"]|) |> Enum.count() == 7
    end

    test "only the current stage carries the agent accent; dots are state colours" do
      html = render_html(node_of(board(), "production_rail"))

      assert texts(html, ~s|[data-current="true"]|) |> Enum.map(&String.slice(&1, 0, 9)) == [
               "Run sheet"
             ]

      assert html |> query(~s|.ring-\\[var\\(--ag\\)\\]|) |> Enum.count() == 1
      assert present?(html, ~s|[data-stage="pitch"][data-state="ready"] .bg-success|)
      assert present?(html, ~s|[data-stage="run_sheet"][data-state="needs_you"] .bg-warning|)
      refute html =~ "bg-primary"
      refute html =~ "btn-primary"
    end

    test "the title appears once, in display weight, over a mono records time" do
      html = render_html(node_of(board(), "production_rail"))

      assert texts(html, ~s|h2[data-role="episode-title"].font-semibold|) == [
               "Ep 14 · The AI savings cliff"
             ]

      assert present?(html, ~s|[data-role="records-line"] time.font-mono[phx-hook]|)
      assert texts(html, ~s|[data-role="room-status"]|) == ["room ready"]
    end
  end

  describe "needs_you render" do
    test "shows the count and quiet option buttons" do
      html = render_html(node_of(board(), "needs_you"))

      assert texts(html, ~s|[data-role="needs-you-count"]|) == ["Needs you (1)"]

      assert texts(html, ~s|button.btn-secondary.btn-outline[data-role="needs-you-option"]|) ==
               ["Pick the town", "Pick the hook"]

      assert present?(html, ~s|[phx-value-action="cold-open-pick:Pick the town"]|)
    end

    test "the empty state reads exactly \"Nothing needs you this week.\"" do
      node = %{"id" => "needs_you", "type" => "needs_you", "props" => %{"items" => []}}
      html = render_html(node)

      assert texts(html, ~s|[data-role="needs-you-empty"]|) == ["Nothing needs you this week."]
      refute present?(html, ~s|[data-role="needs-you-count"]|)
    end
  end

  describe "run_sheet render" do
    test "rows: mono shrink-0 timings, untruncated names, truncating talking points" do
      html = render_html(node_of(board(), "run_sheet"))

      assert texts(html, ~s|[data-role="segment-timing"].font-mono.shrink-0|) == [
               "00:00–04:30",
               "04:30–15:00",
               "15:00–30:00"
             ]

      for name <- query(html, ~s|[data-role="segment-name"]|) do
        refute LazyHTML.attribute(name, "class") |> hd() =~ "truncate"
      end

      assert html |> query(~s|[data-role="talking-point"].truncate|) |> Enum.count() == 4
      assert texts(html, ~s|[data-role="segment-callback"]|) == ["↩ callback Ep 9"]
    end

    test "stat cards carry their source inline" do
      html = render_html(node_of(board(), "run_sheet"))

      assert present?(
               html,
               ~s|[data-role="stat-card"] a[data-role="stat-source"][href="https://example.org/automation-report"]|
             )

      assert texts(html, ~s|[data-role="stat-source"]|) == ["src: example.org"]
    end

    test "show mode: a toggle, and the timer hook on an ignored element with its own id" do
      html = render_html(node_of(board(), "run_sheet"))

      assert present?(html, ~s|section#canvas-t-run_sheet-run-sheet[data-role="run-sheet"]|)
      assert present?(html, ~s|button[data-role="show-mode-toggle"][phx-click]|)

      assert present?(
               html,
               ~s|#canvas-t-run_sheet-run-sheet-timer[phx-update="ignore"][phx-hook$=".ShowTimer"]|
             )

      # Colocated, never inline: the script tag is extracted at compile time.
      refute html =~ "<script"
    end
  end

  describe "episode_board template" do
    test "is listed, validates and round-trips through Episode.from_document/1" do
      assert "episode_board" in Enum.map(Templates.list(), & &1.name)

      doc = board()
      assert {:ok, _} = CanvasDocument.validate(doc)
      assert {:ok, episode} = Episode.from_document(doc)
      assert episode.number == 14
      assert episode.stage == :run_sheet

      assert Episode.to_document(episode)["root"]["children"] ==
               Enum.take(doc["root"]["children"], 3)
    end

    test "holds the rail, needs_you, run_sheet and three collapsed sections" do
      doc = board()

      assert Enum.map(doc["root"]["children"], & &1["type"]) ==
               ~w(production_rail needs_you run_sheet stack)

      collapsed = List.last(doc["root"]["children"])["children"]
      assert Enum.map(collapsed, & &1["type"]) == ~w(markdown markdown markdown)

      for {node, summary} <-
            Enum.zip(collapsed, ["Research brief", "Guests", "Last week's retro"]) do
        html = render_html(node)
        assert present?(html, "details:not([open]) summary")
        assert html =~ summary
      end
    end

    test "exports to markdown with the plain copy" do
      assert {:ok, md} = MarkdownExporter.export_markdown(board())
      assert md =~ "## Ep 14 · The AI savings cliff"
      assert md =~ "**Needs you (1)**"
      assert md =~ "**Run sheet**"
      assert md =~ "`00:00–04:30` Cold open"
      assert md =~ "(source: https://example.org/automation-report)"
    end
  end
end
