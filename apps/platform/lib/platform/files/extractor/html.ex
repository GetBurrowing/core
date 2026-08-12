defmodule Platform.Files.Extractor.HTML do
  @moduledoc """
  Structure-preserving text extraction for `text/html`.

  Mirrors `Platform.Files.Extractor.Text`'s `extract/1` contract: bytes in,
  `{:ok, %{text: ..., pages: nil}}` out. `:pages` is always nil — an HTML
  document is one flow.

  ## Why this is not `Extractor.Text`

  Routing `text/html` at the pass-through extractor "works" in the sense that
  the ingest row flips to `succeeded` — and then the search index fills with
  `<div class="flex">`, inline scripts, CSS and nav chrome. Search degrades
  with no error, no failed status and nothing to grep for. **A file that
  reports success and indexes junk is harder to find than one that reports
  failure**, which is why the naive route is worse than the bug it fixes.

  ## Why Floki and not LazyHTML

  The test suite parses HTML with LazyHTML, so "this repo uses LazyHTML" is
  true — *about tests*. `lazy_html` is declared `only: :test` and is a NIF
  (`elixir_make` plus a `c_src` tree), so calling it from here would mean
  promoting the first compiled C into the production release. Floki is pure
  Elixir and has no dependencies of its own; its html5ever and fast_html
  backends are separate packages this project does not pull in.

  ## What survives extraction

  Priority order, highest first:

    1. `script` and `style` element CONTENTS never appear in the output.
    2. Structure is preserved as markdown-ish text — `h1`/`h2`/`h3` become
       `#`/`##`/`###`, `a[href]` becomes `[text](href)`, `li` becomes `- `.
       This is the point: a retrieved chunk is findable because its heading
       came with it. Flattening to bare prose loses that.
    3. Everything else degrades to text with whitespace collapsed.
  """

  alias Platform.Files.Extractor

  # Elements whose text content is markup machinery, not document content.
  # `noscript` and `template` hold markup that was never rendered; including
  # them would index alternatives the reader never saw.
  @dropped ~w(script style noscript template)

  # Elements that start a new line in the output. Without this every block
  # runs together and the heading structure above stops being legible.
  @block ~w(
    address article aside blockquote br details div dl dd dt fieldset
    figcaption figure footer form h1 h2 h3 h4 h5 h6 header hr li main nav
    ol p pre section table tbody td tfoot th thead tr ul
  )

  @spec extract(binary()) :: {:ok, Extractor.ok_result()} | {:error, term()}
  def extract(bytes) when is_binary(bytes) do
    case Floki.parse_document(bytes) do
      {:ok, document} ->
        {:ok, %{text: document |> walk() |> IO.iodata_to_binary() |> normalize(), pages: nil}}

      {:error, reason} ->
        {:error, {:html_parse_failed, reason}}
    end
  end

  # ── tree walk ─────────────────────────────────────────────────────────

  defp walk(nodes) when is_list(nodes), do: Enum.map(nodes, &walk/1)

  defp walk(text) when is_binary(text), do: text

  # Comments and doctypes carry no document text.
  defp walk({:comment, _}), do: []
  defp walk({:doctype, _, _, _}), do: []
  defp walk({:pi, _, _}), do: []

  defp walk({tag, _attrs, _children}) when tag in @dropped, do: []

  defp walk({"h" <> level, _attrs, children}) when level in ["1", "2", "3"] do
    hashes = String.duplicate("#", String.to_integer(level))
    ["\n\n", hashes, " ", walk(children), "\n\n"]
  end

  defp walk({"a", attrs, children}) do
    inner = children |> walk() |> IO.iodata_to_binary() |> collapse_spaces() |> String.trim()

    case {href(attrs), inner} do
      # A link with no text is a link to nothing a reader can act on.
      {_, ""} -> []
      {nil, text} -> text
      {url, text} -> ["[", text, "](", url, ")"]
    end
  end

  defp walk({"li", _attrs, children}), do: ["\n- ", walk(children)]

  defp walk({tag, _attrs, children}) when tag in @block do
    ["\n", walk(children), "\n"]
  end

  defp walk({_tag, _attrs, children}), do: walk(children)

  defp href(attrs) do
    Enum.find_value(attrs, fn
      {"href", value} when is_binary(value) -> String.trim(value)
      _ -> nil
    end)
  end

  # ── whitespace ────────────────────────────────────────────────────────

  # Collapse horizontal whitespace only. Newlines are structure at this
  # point — they were emitted deliberately by the walk, not inherited from
  # the source formatting.
  defp collapse_spaces(text), do: String.replace(text, ~r/[ \t\x{00A0}]+/u, " ")

  defp normalize(text) do
    text
    |> collapse_spaces()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.join("\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end
end
