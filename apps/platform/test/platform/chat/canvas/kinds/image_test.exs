defmodule Platform.Chat.Canvas.Kinds.ImageTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Platform.Chat.Canvas.Kinds.Image
  alias Platform.Chat.CanvasDocument

  @valid_src "/chat/attachments/a1b2c3d4-e5f6-7890-abcd-ef1234567890"

  describe "validate_props/1" do
    test "accepts a path-relative /chat/attachments/<uuid> src" do
      assert Image.validate_props(%{"src" => @valid_src}) == :ok
    end

    test "accepts uppercase hex in the uuid" do
      src = "/chat/attachments/A1B2C3D4-E5F6-7890-ABCD-EF1234567890"
      assert Image.validate_props(%{"src" => src}) == :ok
    end

    for {label, bad_src} <- [
          {"https scheme", "https://example.com/cat.png"},
          {"http scheme", "http://placekitten.com/600/300"},
          {"javascript URI", "javascript:alert(1)"},
          {"file URI", "file:///etc/passwd"},
          {"data URI", "data:image/png;base64,iVBORw0KG"},
          {"bare host", "example.com/logo.svg"},
          {"protocol-relative", "//cdn.example.com/foo.png"},
          {"path outside /chat/attachments", "/other/path/foo.png"},
          {"/chat/attachments/<not-a-uuid>", "/chat/attachments/not-a-uuid"},
          {"/chat/attachments/ with trailing path",
           "/chat/attachments/a1b2c3d4-e5f6-7890-abcd-ef1234567890/../etc"},
          {"empty string", ""}
        ] do
      test "rejects #{label}: #{bad_src}" do
        assert {:error, reason} = Image.validate_props(%{"src" => unquote(bad_src)})
        assert reason =~ "path-relative"
        assert reason =~ "attachment_upload_inline"
      end
    end

    test "rejects a non-string src" do
      assert {:error, reason} = Image.validate_props(%{"src" => 42})
      assert reason =~ "must be a string"
    end

    test "rejects when src is missing" do
      assert {:error, reason} = Image.validate_props(%{"alt" => "no src"})
      assert reason =~ "requires a \"src\""
    end
  end

  describe "canvas document validation" do
    test "a doc with an illegal image src returns a structured validation error" do
      doc = %{
        "version" => 1,
        "revision" => 1,
        "root" => %{
          "id" => "root",
          "type" => "stack",
          "props" => %{},
          "children" => [
            %{
              "id" => "img1",
              "type" => "image",
              "props" => %{"src" => "https://placekitten.com/400/400"}
            }
          ]
        },
        "theme" => %{},
        "bindings" => %{},
        "meta" => %{}
      }

      assert {:error, reasons} = CanvasDocument.validate(doc)
      assert Enum.any?(reasons, &(&1 =~ "path-relative"))
    end

    test "a doc with a legal image src validates" do
      doc = %{
        "version" => 1,
        "revision" => 1,
        "root" => %{
          "id" => "root",
          "type" => "stack",
          "props" => %{},
          "children" => [
            %{
              "id" => "img1",
              "type" => "image",
              "props" => %{"src" => @valid_src}
            }
          ]
        },
        "theme" => %{},
        "bindings" => %{},
        "meta" => %{}
      }

      assert {:ok, _} = CanvasDocument.validate(doc)
    end
  end

  describe "render/1" do
    defp render_node(props) do
      assigns = %{node: %{"id" => "img", "type" => "image", "props" => props}}

      ~H"""
      <Image.render node={@node} />
      """
      |> rendered_to_string()
      |> LazyHTML.from_fragment()
    end

    # Task 01a1b67d: a same-install raw attachment link was navigated in place
    # (a bare image document with no way back in the app shell). The anchor
    # must route to the in-app image layer instead.
    test "the full-size anchor carries data-image-viewer and keeps the href fallback" do
      doc = render_node(%{"src" => @valid_src, "alt" => "a screenshot"})

      assert [_] =
               doc
               |> LazyHTML.query("a[data-image-viewer][href='#{@valid_src}']")
               |> Enum.to_list()

      assert [_] =
               doc
               |> LazyHTML.query("a[data-image-viewer] > img[alt='a screenshot']")
               |> Enum.to_list()

      assert [] = doc |> LazyHTML.query("a[target]") |> Enum.to_list()
    end
  end
end
