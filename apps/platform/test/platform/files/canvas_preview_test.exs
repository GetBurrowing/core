defmodule Platform.Files.CanvasPreviewTest do
  use Platform.DataCase, async: false
  alias Platform.Files.CanvasPreview

  test "projection preserves native content order but discards executable and interactive subtrees" do
    leaf = fn type, props -> %{"type" => type, "props" => props} end
    child = leaf.("text", %{"value" => "Secret executable subtree"})

    doc = %{
      "root" => %{
        "type" => "stack",
        "children" => [
          leaf.("heading", %{"value" => "Actual title"}),
          leaf.("markdown", %{
            "content" => "**Real** [link](https://example.test) <script>bad()</script>"
          }),
          leaf.("image", %{"src" => "/chat/attachments/#{Ecto.UUID.generate()}"}),
          leaf.("image", %{"src" => "javascript:alert(1)"}),
          %{"type" => "embed", "children" => [child]},
          %{"type" => "prototype", "children" => [child]},
          %{"type" => "form", "children" => [child]},
          %{"type" => "game_stream", "children" => [child]},
          leaf.("text", %{"value" => "<img onerror=alert(1)>"})
        ]
      }
    }

    [title, markdown, image, text] = CanvasPreview.project(doc)
    assert title == %{kind: :heading, value: "Actual title"}
    assert markdown.value =~ "Real link"
    # Rendered as escaped text, never HTML.
    assert is_binary(markdown.value)
    assert image.kind == :image
    assert text.value == "<img onerror=alert(1)>"
    assert CanvasPreview.project(nil) == []
  end

  test "projection bounds deep and wide documents and individual text" do
    leaf = %{"type" => "text", "props" => %{"value" => String.duplicate("x", 20_000)}}
    assert [%{value: text}] = CanvasPreview.project(%{"root" => leaf})
    assert String.length(text) == 1500

    assert length(
             CanvasPreview.project(%{
               "root" => %{"type" => "row", "children" => List.duplicate(leaf, 300)}
             })
           ) == 24

    deep = Enum.reduce(1..20, leaf, fn _, node -> %{"type" => "stack", "children" => [node]} end)
    assert CanvasPreview.project(%{"root" => deep}) == []
  end
end
