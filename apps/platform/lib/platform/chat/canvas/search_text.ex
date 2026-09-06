defmodule Platform.Chat.Canvas.SearchText do
  @moduledoc """
  Plain-text projection of a canvas document, for search indexing.

  `document` is a node tree whose text sits at a *different* prop key per node
  kind — `props.content` on `markdown`, `props.value` on `text`/`heading`/
  `badge`, `props.source` on `code`, `props.columns` + `props.rows` on `table`,
  `props.title` on `card` and `checklist`, `props.label` + `props.note` on
  `checklist_item`. Any extractor that enumerates those keys itself (a second
  traversal here, or a `jsonb_path_query_array(document, '$..content')` in SQL)
  silently drops every kind registered after it was written: a guard that quietly
  stops guarding.

  So this module does not traverse anything. It delegates to
  `Platform.Chat.Canvas.MarkdownExporter`, which dispatches off
  `Platform.Chat.Canvas.Kinds` and is the single source of truth for how a node
  kind turns into text.

  ## Known and accepted boundary

  The exporter's `@skipped_kinds` are `form`, `action_row`, `embed`, `image` and
  `mermaid`. Their text is therefore **not indexed**: `image.alt` / `image.caption`,
  `form` titles and field labels, `action_row` button labels, `mermaid.source`
  and `embed.srcdoc` do not appear in the output. That gap is inherited
  deliberately from the one extractor rather than forked into a second, divergent
  one. `test/platform/chat/canvas/search_text_test.exs` pins the full
  16-kind registry classification, so the boundary is a written decision that has
  to be revisited on purpose — not a silent hole.
  """

  alias Platform.Chat.Canvas
  alias Platform.Chat.Canvas.MarkdownExporter

  @doc """
  Extract searchable plain text from a canvas, a canonical document map, or nil.

  Always returns a `String.t()` — never a tuple, never nil. Returns `""` when
  there is nothing to extract or the input is not a recognisable document.
  """
  @spec extract(Canvas.t() | map() | nil) :: String.t()
  def extract(nil), do: ""

  def extract(canvas_or_doc) do
    case MarkdownExporter.export_markdown(canvas_or_doc) do
      {:ok, text} -> text
      {:error, _reason} -> ""
    end
  end
end
