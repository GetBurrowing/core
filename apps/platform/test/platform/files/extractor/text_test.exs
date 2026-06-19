defmodule Platform.Files.Extractor.TextTest do
  use ExUnit.Case, async: true

  alias Platform.Files.Extractor.Text

  test "passes bytes through unchanged" do
    assert {:ok, %{text: "hello\nworld", pages: nil}} = Text.extract("hello\nworld")
  end

  test "handles empty bytes" do
    assert {:ok, %{text: "", pages: nil}} = Text.extract("")
  end

  test "handles unicode bytes verbatim" do
    assert {:ok, %{text: "héllo 🌎", pages: nil}} = Text.extract("héllo 🌎")
  end
end
