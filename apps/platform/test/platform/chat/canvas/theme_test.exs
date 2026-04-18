defmodule Platform.Chat.Canvas.ThemeTest do
  use ExUnit.Case, async: true

  alias Platform.Chat.Canvas.Theme

  describe "resolve/2" do
    test "maps tone tokens to Tailwind classes" do
      assert Theme.resolve(%{"tone" => "warning"}, :tone) == ["bg-warning/10", "text-warning"]
      assert Theme.resolve(%{"tone" => "critical"}, :tone) == ["bg-error/10", "text-error"]
    end

    test "unknown tone values produce no classes" do
      assert Theme.resolve(%{"tone" => "bogus"}, :tone) == []
    end

    test "missing token produces no classes" do
      assert Theme.resolve(%{}, :tone) == []
    end

    test "density maps to gap + padding" do
      assert Theme.resolve(%{"density" => "compact"}, :density) == ["gap-1", "p-2"]
    end

    test "emphasis elevated produces shadow" do
      assert Theme.resolve(%{"emphasis" => "elevated"}, :emphasis) == ["shadow-md"]
    end
  end

  describe "resolve_all/2" do
    test "combines multiple tokens in order" do
      theme = %{"tone" => "info", "density" => "comfortable"}
      classes = Theme.resolve_all(theme, [:tone, :density])

      assert classes == ["bg-info/10", "text-info", "gap-2", "p-3"]
    end
  end

  describe "from_document/1" do
    test "extracts theme from canonical document" do
      doc = %{"theme" => %{"tone" => "info"}}
      assert Theme.from_document(doc) == %{"tone" => "info"}
    end

    test "falls back to empty map" do
      assert Theme.from_document(%{}) == %{}
      assert Theme.from_document(nil) == %{}
    end
  end
end
