defmodule Platform.Chat.CanvasDocumentTest do
  use ExUnit.Case, async: true

  alias Platform.Chat.CanvasDocument

  describe "new/1" do
    test "creates a blank document with default kind ui" do
      doc = CanvasDocument.new()
      assert doc["version"] == 1
      assert doc["kind"] == "ui"
      assert doc["revision"] == 1
      assert is_map(doc["root"])
      assert doc["root"]["type"] == "stack"
      assert doc["root"]["id"] == "root"
      assert doc["bindings"] == %{}
      assert doc["meta"] == %{}
    end

    test "creates a document with custom kind" do
      doc = CanvasDocument.new("ui")
      assert doc["kind"] == "ui"
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

    test "rejects invalid kind" do
      doc = CanvasDocument.new() |> Map.put("kind", "invalid")
      assert {:error, errors} = CanvasDocument.validate(doc)
      assert Enum.any?(errors, &String.contains?(&1, "kind"))
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

    test "rejects root with unknown type" do
      doc =
        CanvasDocument.new()
        |> put_in(["root", "type"], "unknown_type")

      assert {:error, errors} = CanvasDocument.validate(doc)
      assert Enum.any?(errors, &String.contains?(&1, "unknown_type"))
    end

    test "validates a document with children" do
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
          %{"type" => "text", "props" => %{}}
        ])

      assert {:error, errors} = CanvasDocument.validate(doc)
      assert Enum.any?(errors, &String.contains?(&1, "id"))
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

    test "finds a deeply nested node" do
      doc =
        CanvasDocument.new()
        |> put_in(["root", "children"], [
          %{
            "id" => "card-1",
            "type" => "card",
            "props" => %{},
            "children" => [
              %{
                "id" => "deep-text",
                "type" => "text",
                "props" => %{"value" => "deep"},
                "children" => []
              }
            ]
          }
        ])

      node = CanvasDocument.get_node(doc, "deep-text")
      assert node["id"] == "deep-text"
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

  describe "seed/2" do
    test "seeds a table document" do
      doc =
        CanvasDocument.seed("table", %{
          "columns" => ["Name", "Status"],
          "rows" => [%{"Name" => "Task 1", "Status" => "Done"}]
        })

      assert {:ok, _} = CanvasDocument.validate(doc)
      [table_node] = doc["root"]["children"]
      assert table_node["type"] == "table"
      assert table_node["props"]["columns"] == ["Name", "Status"]
      assert length(table_node["props"]["rows"]) == 1
    end

    test "seeds a code document" do
      doc =
        CanvasDocument.seed("code", %{
          "language" => "elixir",
          "source" => "IO.puts(\"hello\")"
        })

      assert {:ok, _} = CanvasDocument.validate(doc)
      [code_node] = doc["root"]["children"]
      assert code_node["type"] == "code"
      assert code_node["props"]["language"] == "elixir"
      assert code_node["props"]["source"] =~ "hello"
    end

    test "seeds a diagram document" do
      doc =
        CanvasDocument.seed("diagram", %{
          "source" => "graph TD\n  A --> B",
          "diagram_title" => "Flow"
        })

      assert {:ok, _} = CanvasDocument.validate(doc)
      children = doc["root"]["children"]
      assert length(children) == 2
      heading = Enum.find(children, &(&1["type"] == "heading"))
      assert heading["props"]["value"] == "Flow"
      mermaid = Enum.find(children, &(&1["type"] == "mermaid"))
      assert mermaid["props"]["source"] =~ "graph TD"
    end

    test "seeds a dashboard document" do
      doc =
        CanvasDocument.seed("dashboard", %{
          "metrics" => [
            %{"label" => "Open items", "value" => 5, "trend" => "↑"},
            %{"label" => "Closed", "value" => 12}
          ]
        })

      assert {:ok, _} = CanvasDocument.validate(doc)
      [row] = doc["root"]["children"]
      assert row["type"] == "row"
      assert length(row["children"]) == 2
    end

    test "seeds an unknown type as blank document with meta" do
      doc = CanvasDocument.seed("unknown_type", %{"foo" => "bar"})
      assert {:ok, _} = CanvasDocument.validate(doc)
      assert doc["meta"]["foo"] == "bar"
    end

    test "seeds with empty data" do
      doc = CanvasDocument.seed("table", %{})
      assert {:ok, _} = CanvasDocument.validate(doc)
    end
  end
end
