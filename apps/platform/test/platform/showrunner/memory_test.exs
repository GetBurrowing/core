defmodule Platform.Showrunner.MemoryTest do
  @moduledoc "Task 01a1eaf6 stage 1: the showrunner's memory path conventions."

  use ExUnit.Case, async: true

  alias Platform.Memory.Insights
  alias Platform.Showrunner.Memory

  @space "test-show-space"

  test "journal_path is the space journal for the day, in the shape Insights recognises" do
    path = Memory.journal_path(@space, ~D[2026-11-17])

    assert path == "space/#{@space}/journal/2026-11-17.md"
    assert Insights.journal_path?(path)
  end

  test "journal_path takes a DateTime's UTC date" do
    assert Memory.journal_path(@space, ~U[2026-11-17 23:59:59Z]) ==
             "space/#{@space}/journal/2026-11-17.md"
  end

  test "the four curated show pages, in order" do
    assert Memory.pages() == [:episodes, :guests, :running_bits, :clip_performance]

    assert Memory.page_paths(@space) == [
             "space/#{@space}/page/show/episodes.md",
             "space/#{@space}/page/show/guests.md",
             "space/#{@space}/page/show/running-bits.md",
             "space/#{@space}/page/show/clip-performance.md"
           ]

    assert Memory.page_path(@space, :running_bits) == "space/#{@space}/page/show/running-bits.md"
  end

  test "no page path exists outside the four, and none for a blank space" do
    assert_raise FunctionClauseError, fn -> Memory.page_path(@space, :notes) end
    assert_raise FunctionClauseError, fn -> Memory.page_path("", :episodes) end
    assert_raise FunctionClauseError, fn -> Memory.journal_path("", ~D[2026-11-17]) end
  end

  test "journal entries carry the [show] tag" do
    assert Memory.tag() == "[show]"
    assert Memory.journal_entry("  Booked Ada for ep 12. ") == "[show] Booked Ada for ep 12."
  end
end
