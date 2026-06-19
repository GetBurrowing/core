defmodule Platform.Files.Extractor.CSV do
  @moduledoc """
  CSV text extractor.

  Embedding models do much better on prose-shaped input than on raw CSV.
  We re-serialize the file as a markdown-table-ish flow so each row reads
  as `header: value` pairs (one row per paragraph). The header row drives
  the labels; columns the header doesn't cover fall back to `col_N`.

  Parsing is done inline (no external dep) — we honor double-quoted
  fields with embedded commas, newlines, and escaped double-quotes
  (`""` → `"`). That's RFC 4180-ish, which is what spreadsheet exports
  produce.

  Malformed bytes (unterminated quoted field) return
  `{:error, :malformed_csv}` rather than raising.
  """

  alias Platform.Files.Extractor

  @spec extract(Platform.Files.File.t()) ::
          {:ok, Extractor.ok_result()} | {:error, term()}
  def extract(file) do
    with {:ok, path} <- Extractor.local_path(file),
         {:ok, body} <- File.read(path),
         {:ok, rows} <- parse(body) do
      {:ok, %{text: format(rows), pages: nil}}
    end
  end

  @doc false
  @spec parse(binary()) :: {:ok, [[String.t()]]} | {:error, :malformed_csv}
  def parse(body) when is_binary(body) do
    case parse_rows(body, [], [], [], :field) do
      {:ok, rows} -> {:ok, rows}
      :error -> {:error, :malformed_csv}
    end
  end

  # state machine:
  #   :field     — between/inside an unquoted field
  #   :quoted    — inside a quoted field
  #   :after_quote — just saw a closing quote; expect comma, newline, or another quote (escape)
  defp parse_rows(<<>>, field, row, acc, state) do
    case state do
      :quoted ->
        :error

      _ ->
        finished_row = Enum.reverse([IO.iodata_to_binary(Enum.reverse(field)) | row])

        rows =
          if finished_row == [""] and acc == [] do
            []
          else
            Enum.reverse([finished_row | acc])
          end

        {:ok, rows}
    end
  end

  defp parse_rows(<<?", rest::binary>>, [], [], acc, :field),
    do: parse_rows(rest, [], [], acc, :quoted)

  defp parse_rows(<<?", rest::binary>>, field, row, acc, :field) when field == [] and row != [] do
    # quote opens a new field after a comma (row not empty, field empty)
    parse_rows(rest, field, row, acc, :quoted)
  end

  defp parse_rows(<<?", rest::binary>>, field, row, acc, :field) do
    # bare quote in unquoted field — treat as literal character (lenient)
    parse_rows(rest, [<<?">> | field], row, acc, :field)
  end

  defp parse_rows(<<?", ?", rest::binary>>, field, row, acc, :quoted) do
    parse_rows(rest, [<<?">> | field], row, acc, :quoted)
  end

  defp parse_rows(<<?", rest::binary>>, field, row, acc, :quoted) do
    parse_rows(rest, field, row, acc, :after_quote)
  end

  defp parse_rows(<<?", rest::binary>>, field, row, acc, :after_quote) do
    # "" right after closing — treat as escaped quote (re-enter quoted)
    parse_rows(rest, [<<?">> | field], row, acc, :quoted)
  end

  defp parse_rows(<<?,, rest::binary>>, field, row, acc, state)
       when state in [:field, :after_quote] do
    parse_rows(rest, [], [IO.iodata_to_binary(Enum.reverse(field)) | row], acc, :field)
  end

  defp parse_rows(<<?,, rest::binary>>, field, row, acc, :quoted) do
    parse_rows(rest, [<<?,>> | field], row, acc, :quoted)
  end

  defp parse_rows(<<?\r, ?\n, rest::binary>>, field, row, acc, state)
       when state in [:field, :after_quote] do
    finished_row = Enum.reverse([IO.iodata_to_binary(Enum.reverse(field)) | row])
    parse_rows(rest, [], [], [finished_row | acc], :field)
  end

  defp parse_rows(<<?\n, rest::binary>>, field, row, acc, state)
       when state in [:field, :after_quote] do
    finished_row = Enum.reverse([IO.iodata_to_binary(Enum.reverse(field)) | row])
    parse_rows(rest, [], [], [finished_row | acc], :field)
  end

  defp parse_rows(<<?\r, rest::binary>>, field, row, acc, state)
       when state in [:field, :after_quote] do
    finished_row = Enum.reverse([IO.iodata_to_binary(Enum.reverse(field)) | row])
    parse_rows(rest, [], [], [finished_row | acc], :field)
  end

  defp parse_rows(<<c, rest::binary>>, field, row, acc, :quoted) do
    parse_rows(rest, [<<c>> | field], row, acc, :quoted)
  end

  defp parse_rows(<<c, rest::binary>>, field, row, acc, :field) do
    parse_rows(rest, [<<c>> | field], row, acc, :field)
  end

  defp parse_rows(<<_c, _rest::binary>>, _field, _row, _acc, :after_quote) do
    # garbage between closing quote and the next delimiter — bail
    :error
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
