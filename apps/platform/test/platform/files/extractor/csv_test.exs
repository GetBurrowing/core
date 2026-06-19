defmodule Platform.Files.Extractor.CSVTest do
  use ExUnit.Case, async: true

  alias Platform.Files.Extractor.CSV

  test "rewrites rows as header: value paragraphs" do
    csv = "name,age,city\nAlice,30,Portland\nBob,42,\"Eugene, OR\"\n"

    assert {:ok, %{text: text, pages: nil}} = CSV.extract(csv)

    assert text =~ "name: Alice"
    assert text =~ "age: 30"
    assert text =~ "city: Portland"
    # quoted-field-with-comma round-trip
    assert text =~ "city: Eugene, OR"
    # paragraph separator between rows
    assert text =~ "\n\n"
  end

  test "handles escaped double-quotes" do
    csv = ~s(name,quote\nAlice,"She said ""hi"""\n)

    assert {:ok, %{text: text, pages: nil}} = CSV.extract(csv)

    assert text =~ ~s(quote: She said "hi")
  end

  test "empty body returns empty text" do
    assert {:ok, %{text: "", pages: nil}} = CSV.extract("")
  end

  test "header-only file returns empty text (no data rows)" do
    assert {:ok, %{text: "", pages: nil}} = CSV.extract("name,age\n")
  end

  test "returns :malformed_csv on unterminated quoted field" do
    assert {:error, :malformed_csv} = CSV.extract(~s(name,age\n"Alice,30\n))
  end

  test "columns the header doesn't cover fall back to col_N" do
    # header has 2 cols, row has 3 — third should be labeled col_3
    csv = "a,b\n1,2,3\n"

    assert {:ok, %{text: text, pages: nil}} = CSV.extract(csv)

    assert text =~ "a: 1"
    assert text =~ "b: 2"
    assert text =~ "col_3: 3"
  end
end
