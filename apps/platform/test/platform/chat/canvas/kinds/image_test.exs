defmodule Platform.Chat.Canvas.Kinds.ImageTest do
  use ExUnit.Case, async: true

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
        assert reason =~ "attachment.upload_inline"
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
end
