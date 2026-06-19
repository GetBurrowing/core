defmodule Platform.Files.Extractor.CSV do
  @moduledoc """
  CSV text extractor.

  Embedding models do much better on prose-shaped input than on raw CSV.
  We re-serialize the file as a flow where each row reads as
  `header: value` pairs (one row per paragraph). The header row drives
  the labels; columns the header doesn't cover fall back to `col_N`.

  Parsing uses `NimbleCSV.RFC4180` — double-quoted fields with embedded
  commas, newlines, and escaped double-quotes (`""` → `"`) round-trip.
  Malformed bytes (unterminated quoted field, stray quote) bubble up as
  `{:error, :malformed_csv}` rather than raising.
  """

  alias Platform.Files.Extractor

  NimbleCSV.define(__MODULE__.Parser, separator: ",", escape: "\"")

  @spec extract(binary()) :: {:ok, Extractor.ok_result()} | {:error, term()}
  def extract(bytes) when is_binary(bytes) do
    case parse(bytes) do
      {:ok, rows} -> {:ok, %{text: format(rows), pages: nil}}
      {:error, _} = err -> err
    end
  end

  @doc false
  @spec parse(binary()) :: {:ok, [[String.t()]]} | {:error, :malformed_csv}
  def parse(""), do: {:ok, []}

  def parse(bytes) when is_binary(bytes) do
    rows =
      bytes
      |> __MODULE__.Parser.parse_string(skip_headers: false)

    {:ok, rows}
  rescue
    NimbleCSV.ParseError -> {:error, :malformed_csv}
  end

  defp format([]), do: ""

  defp format([header | rows]) do
    rows
    |> Enum.map(&format_row(header, &1))
    |> Enum.intersperse("\n\n")
    |> IO.iodata_to_binary()
  end

  defp format_row(header, row) do
    cols = Enum.max([length(header), length(row)])

    0..(cols - 1)
    |> Enum.map(fn i ->
      label = Enum.at(header, i) || "col_#{i + 1}"
      value = Enum.at(row, i, "")
      [label, ": ", value]
    end)
    |> Enum.intersperse("\n")
  end
end
