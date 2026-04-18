defmodule Platform.Chat.CanvasDocumentTest do
  use ExUnit.Case, async: true

  alias Platform.Chat.CanvasDocument

  describe "new/0" do
    test "creates a blank document with a stack root" do
      doc = CanvasDocument.new()
      assert doc["version"] == 1
      assert doc["revision"] == 1
      assert is_map(doc["root"])
      assert doc["root"]["type"] == "stack"
      assert doc["root"]["id"] == "root"
      assert doc["bindings"] == %{}
      assert doc["meta"] == %{}
      assert doc["theme"] == %{}
    end
  end

  describe "validate/1" do
    test "validates a valid document" do
      doc = CanvasDocument.new()
      assert {:ok, ^doc} = CanvasDocument.validate(doc)
    end

    test "rejects a non-map" do
      assert {:error, ["document must be a map"]} = CanvasDocument.validate(nil)
      assert {:error, ["document must be a map"]} = CanvasDocument.validate("string")
    end

    test "rejects missing version" do
      doc = CanvasDocument.new() |> Map.delete("version")
      assert {:error, errors} = CanvasDocument.validate(doc)
      assert Enum.any?(errors, &String.contains?(&1, "version"))
    end

    test "rejects zero revision" do
      doc = CanvasDocument.new() |> Map.put("revision", 0)
      assert {:error, errors} = CanvasDocument.validate(doc)
      assert Enum.any?(errors, &String.contains?(&1, "revision"))
    end

    test "rejects root without id" do
      doc =
        CanvasDocument.new()
        |> put_in(["root", "id"], "")

      assert {:error, errors} = CanvasDocument.validate(doc)
      assert Enum.any?(errors, &String.contains?(&1, "id"))
    end

    test "rejects root with unknown kind" do
      doc =
        CanvasDocument.new()
        |> put_in(["root", "type"], "unknown_kind")

      assert {:error, errors} = CanvasDocument.validate(doc)
      assert Enum.any?(errors, &String.contains?(&1, "unknown_kind"))
    end

    test "validates a document with text children" do
      doc =
        CanvasDocument.new()
        |> put_in(["root", "children"], [
          %{
            "id" => "child-1",
            "type" => "text",
            "props" => %{"value" => "Hello"},
            "children" => []
          }
        ])

      assert {:ok, _} = CanvasDocument.validate(doc)
    end

    test "rejects children with missing id" do
      doc =
        CanvasDocument.new()
        |> put_in(["root", "children"], [
          %{"type" => "text", "props" => %{"value" => ""}}
        ])

      assert {:error, errors} = CanvasDocument.validate(doc)
      assert Enum.any?(errors, &String.contains?(&1, "id"))
    end

    test "rejects illegal child kind under checklist" do
      doc =
        CanvasDocument.new()
        |> put_in(["root", "type"], "checklist")
        |> put_in(["root", "children"], [
          %{"id" => "bad", "type" => "text", "props" => %{"value" => "no"}, "children" => []}
        ])

      assert {:error, errors} = CanvasDocument.validate(doc)
      assert Enum.any?(errors, &String.contains?(&1, "not allowed"))
    end
  end

  describe "get_node/2" do
    test "finds the root node" do
      doc = CanvasDocument.new()
      root = CanvasDocument.get_node(doc, "root")
      assert root["id"] == "root"
    end

    test "finds a nested child node" do
      doc =
        CanvasDocument.new()
        |> put_in(["root", "children"], [
          %{
            "id" => "child-1",
            "type" => "text",
            "props" => %{"value" => "Hello"},
            "children" => []
          }
        ])

      node = CanvasDocument.get_node(doc, "child-1")
      assert node["id"] == "child-1"
      assert node["props"]["value"] == "Hello"
    end

    test "returns nil for missing node" do
      doc = CanvasDocument.new()
      assert is_nil(CanvasDocument.get_node(doc, "nonexistent"))
    end

    test "returns nil for invalid document" do
      assert is_nil(CanvasDocument.get_node(%{}, "root"))
    end
  end

  describe "revision/1" do
    test "returns revision from document" do
      doc = CanvasDocument.new()
      assert CanvasDocument.revision(doc) == 1
    end

    test "returns 0 for document without revision" do
      assert CanvasDocument.revision(%{}) == 0
    end
  end

  describe "root_kind/1" do
    test "returns the root node kind" do
      doc = CanvasDocument.new()
      assert CanvasDocument.root_kind(doc) == "stack"
    end

    test "returns nil for malformed document" do
      assert CanvasDocument.root_kind(%{}) == nil
    end
  end

  describe "canonical?/1" do
    test "detects a valid canonical document" do
      assert CanvasDocument.canonical?(CanvasDocument.new())
    end

    test "rejects a document whose root kind isn't registered" do
      doc = CanvasDocument.new() |> put_in(["root", "type"], "unknown")
      refute CanvasDocument.canonical?(doc)
    end

    test "rejects a non-document map" do
      refute CanvasDocument.canonical?(%{"nodes" => []})
    end
  end
end
