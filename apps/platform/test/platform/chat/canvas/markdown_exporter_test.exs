defmodule Platform.Chat.Canvas.MarkdownExporterTest do
  use ExUnit.Case, async: true

  alias Platform.Chat.Canvas
  alias Platform.Chat.Canvas.Kinds
  alias Platform.Chat.Canvas.MarkdownExporter
  alias Platform.Chat.CanvasDocument

  describe "export_markdown/1 — input shapes" do
    test "accepts a canonical document map" do
      doc = %{"version" => 1, "revision" => 1, "root" => root_stack([])}
      assert {:ok, ""} = MarkdownExporter.export_markdown(doc)
    end

    test "accepts a %Canvas{} struct via its :document field" do
      doc = %{"version" => 1, "revision" => 1, "root" => root_stack([heading(1, "Hi")])}
      canvas = %Canvas{document: doc}
      assert {:ok, "# Hi"} = MarkdownExporter.export_markdown(canvas)
    end

    test "accepts a bare root-node map (defensive path for tests + adhoc usage)" do
      node = heading(2, "Bare")
      assert {:ok, "## Bare"} = MarkdownExporter.export_markdown(node)
    end

    test "rejects unrecognised input" do
      assert {:error, :invalid_document} = MarkdownExporter.export_markdown(nil)
      assert {:error, :invalid_document} = MarkdownExporter.export_markdown(%{"garbage" => true})
      assert {:error, :invalid_document} = MarkdownExporter.export_markdown(42)
    end
  end

  describe "structural containers" do
    test "empty stack root → empty string" do
      assert {:ok, ""} =
               MarkdownExporter.export_markdown(%{
                 "version" => 1,
                 "revision" => 1,
                 "root" => root_stack([])
               })
    end

    test "stack joins children with blank line" do
      doc = doc(root_stack([heading(1, "A"), heading(2, "B")]))
      assert {:ok, "# A\n\n## B"} = MarkdownExporter.export_markdown(doc)
    end

    test "row joins children with a space" do
      doc =
        doc(
          root_stack([
            %{
              "id" => "r",
              "type" => "row",
              "props" => %{},
              "children" => [badge("A"), badge("B")]
            }
          ])
        )

      assert {:ok, "_A_ _B_"} = MarkdownExporter.export_markdown(doc)
    end

    test "card with title renders as H3 followed by body" do
      card = %{
        "id" => "c1",
        "type" => "card",
        "props" => %{"title" => "Summary"},
        "children" => [markdown_node("Recommendation: use RDS.")]
      }

      assert {:ok, "### Summary\n\nRecommendation: use RDS."} =
               MarkdownExporter.export_markdown(doc(root_stack([card])))
    end

    test "card without title just recurses" do
      card = %{
        "id" => "c2",
        "type" => "card",
        "props" => %{},
        "children" => [markdown_node("Body only.")]
      }

      assert {:ok, "Body only."} = MarkdownExporter.export_markdown(doc(root_stack([card])))
    end

    test "empty card with title still emits the heading" do
      card = %{
        "id" => "c3",
        "type" => "card",
        "props" => %{"title" => "Empty"},
        "children" => []
      }

      assert {:ok, "### Empty"} = MarkdownExporter.export_markdown(doc(root_stack([card])))
    end
  end

  describe "text-ish leaves" do
    test "heading levels 1..4 emit the right number of hashes" do
      for lvl <- 1..4 do
        {:ok, out} = MarkdownExporter.export_markdown(heading(lvl, "H#{lvl}"))
        assert out == String.duplicate("#", lvl) <> " H#{lvl}"
      end
    end

    test "heading without level defaults to H2" do
      node = %{"id" => "h", "type" => "heading", "props" => %{"value" => "Default"}}
      assert {:ok, "## Default"} = MarkdownExporter.export_markdown(node)
    end

    test "text node renders as plain string when weight is normal/absent" do
      node = %{"id" => "t", "type" => "text", "props" => %{"value" => "Hello"}}
      assert {:ok, "Hello"} = MarkdownExporter.export_markdown(node)
    end

    test "text node bolds when weight is medium / semibold / bold" do
      for w <- ["medium", "semibold", "bold"] do
        node = %{"id" => "t", "type" => "text", "props" => %{"value" => "Loud", "weight" => w}}
        assert {:ok, "**Loud**"} = MarkdownExporter.export_markdown(node)
      end
    end

    test "markdown node is passed through verbatim" do
      node = markdown_node("- one\n- two\n\n> quote")
      assert {:ok, "- one\n- two\n\n> quote"} = MarkdownExporter.export_markdown(node)
    end

    test "badge renders as italic inline" do
      assert {:ok, "_status_"} = MarkdownExporter.export_markdown(badge("status"))
    end
  end

  describe "checklists" do
    test "checklist with mixed states emits [x] / [ ] lines" do
      cl = %{
        "id" => "cl",
        "type" => "checklist",
        "props" => %{"title" => "Steps"},
        "children" => [
          checklist_item("Design", :complete),
          checklist_item("Build", :active),
          checklist_item("Ship", :pending)
        ]
      }

      assert {:ok, out} = MarkdownExporter.export_markdown(cl)

      assert out == """
             **Steps**
             - [x] Design
             - [ ] Build
             - [ ] Ship\
             """
    end

    test "checklist honours boolean `checked` when `state` is absent" do
      cl = %{
        "id" => "cl",
        "type" => "checklist",
        "props" => %{},
        "children" => [
          %{
            "id" => "i1",
            "type" => "checklist_item",
            "props" => %{"label" => "Boxed", "checked" => true}
          },
          %{
            "id" => "i2",
            "type" => "checklist_item",
            "props" => %{"label" => "Open", "checked" => false}
          }
        ]
      }

      assert {:ok, "- [x] Boxed\n- [ ] Open"} = MarkdownExporter.export_markdown(cl)
    end

    test "checklist_item renders on its own with note trailing after an em dash" do
      node = %{
        "id" => "i",
        "type" => "checklist_item",
        "props" => %{"label" => "Ping", "note" => "with alembic", "state" => "complete"}
      }

      assert {:ok, "- [x] Ping — with alembic"} = MarkdownExporter.export_markdown(node)
    end

    test "empty checklist with title still emits the title" do
      cl = %{
        "id" => "cl",
        "type" => "checklist",
        "props" => %{"title" => "Empty"},
        "children" => []
      }

      assert {:ok, "**Empty**"} = MarkdownExporter.export_markdown(cl)
    end
  end

  describe "tables" do
    test "3x2 table emits pipe-table with separator row" do
      tbl = %{
        "id" => "tbl",
        "type" => "table",
        "props" => %{
          "columns" => ["Name", "Owner", "Status"],
          "rows" => [
            %{"Name" => "Alembic", "Owner" => "Alex", "Status" => "shipping"},
            %{"Name" => "Suite", "Owner" => "Dalton", "Status" => "wip"}
          ]
        }
      }

      assert {:ok, out} = MarkdownExporter.export_markdown(tbl)

      assert out == """
             | Name | Owner | Status |
             | --- | --- | --- |
             | Alembic | Alex | shipping |
             | Suite | Dalton | wip |\
             """
    end

    test "table with zero rows still emits header + separator" do
      tbl = %{
        "id" => "tbl",
        "type" => "table",
        "props" => %{"columns" => ["A", "B"], "rows" => []}
      }

      assert {:ok, "| A | B |\n| --- | --- |"} = MarkdownExporter.export_markdown(tbl)
    end

    test "table with zero columns is emitted as empty (no phantom header)" do
      tbl = %{"id" => "tbl", "type" => "table", "props" => %{"columns" => [], "rows" => []}}
      assert {:ok, ""} = MarkdownExporter.export_markdown(tbl)
    end

    test "table cells escape pipe characters and flatten newlines" do
      tbl = %{
        "id" => "tbl",
        "type" => "table",
        "props" => %{
          "columns" => ["k", "v"],
          "rows" => [%{"k" => "pipe|inside", "v" => "line1\nline2"}]
        }
      }

      assert {:ok, out} = MarkdownExporter.export_markdown(tbl)
      assert out =~ "pipe\\|inside"
      assert out =~ "line1 line2"
      refute out =~ "line1\nline2"
    end
  end

  describe "code" do
    test "code block is fenced with language" do
      node = %{
        "id" => "c",
        "type" => "code",
        "props" => %{"language" => "elixir", "source" => "IO.puts(\"hi\")"}
      }

      assert {:ok, "```elixir\nIO.puts(\"hi\")\n```"} = MarkdownExporter.export_markdown(node)
    end

    test "code block without language emits an empty language tag" do
      node = %{"id" => "c", "type" => "code", "props" => %{"source" => "raw"}}
      assert {:ok, "```\nraw\n```"} = MarkdownExporter.export_markdown(node)
    end
  end

  describe "skipped kinds" do
    test "form, action_row, embed, image, mermaid, prototype render as HTML-comment stubs" do
      for kind <- ~w(form action_row embed image mermaid prototype) do
        node = %{"id" => "n-#{kind}", "type" => kind, "props" => %{}}
        assert {:ok, out} = MarkdownExporter.export_markdown(node)
        assert out == "<!-- skipped: #{kind} id=n-#{kind} -->"
      end
    end

    test "skipped-kinds set matches Kinds registry - handled_kinds partition" do
      # Guards against future kinds landing without exporter coverage: every
      # registered kind must be either handled explicitly or in the skipped set.
      handled =
        ~w(stack row card heading text markdown badge checklist checklist_item table code)

      skipped = ~w(form action_row embed image mermaid prototype)

      assert Enum.sort(handled ++ skipped) == Enum.sort(Kinds.names())
    end
  end

  describe "unknown kind" do
    test "renders as HTML-comment marker without crashing" do
      node = %{"id" => "u", "type" => "quux", "props" => %{}}
      assert {:ok, "<!-- unknown-kind: quux -->"} = MarkdownExporter.export_markdown(node)
    end
  end

  describe "nesting" do
    test "stack > card > markdown traverses depth-first with \\n\\n separators" do
      inner_card = %{
        "id" => "c",
        "type" => "card",
        "props" => %{"title" => "Details"},
        "children" => [markdown_node("Line one.")]
      }

      doc = doc(root_stack([heading(1, "Top"), inner_card, markdown_node("Trailing.")]))

      assert {:ok, out} = MarkdownExporter.export_markdown(doc)

      assert out == """
             # Top

             ### Details

             Line one.

             Trailing.\
             """
    end
  end

  describe "Globex-shaped fixture (regression pin)" do
    test "5-kind canvas round-trips to a deterministic Markdown string" do
      doc = %{
        "version" => 1,
        "revision" => 1,
        "root" => %{
          "id" => "root",
          "type" => "stack",
          "props" => %{"gap" => 12},
          "children" => [
            heading(1, "Globex Infra Proposal"),
            %{
              "id" => "recommendation-card",
              "type" => "card",
              "props" => %{"title" => "Recommendation"},
              "children" => [markdown_node("Recommendation: use RDS.")]
            },
            %{
              "id" => "next-steps",
              "type" => "checklist",
              "props" => %{"title" => "Next steps"},
              "children" => [
                checklist_item("Provision RDS", :complete),
                checklist_item("Migrate data", :pending)
              ]
            },
            %{
              "id" => "sizing",
              "type" => "table",
              "props" => %{
                "columns" => ["Env", "Class"],
                "rows" => [
                  %{"Env" => "prod", "Class" => "db.r6g.large"},
                  %{"Env" => "stage", "Class" => "db.t4g.medium"}
                ]
              }
            },
            %{
              "id" => "sample",
              "type" => "code",
              "props" => %{"language" => "sql", "source" => "SELECT 1;"}
            }
          ]
        }
      }

      # Sanity-check the fixture matches the canvas schema so a shape drift
      # (e.g. a required prop rename) trips the fixture before it silently
      # produces wrong Markdown.
      assert {:ok, _} = CanvasDocument.validate(doc)

      assert {:ok, out} = MarkdownExporter.export_markdown(doc)

      assert out == """
             # Globex Infra Proposal

             ### Recommendation

             Recommendation: use RDS.

             **Next steps**
             - [x] Provision RDS
             - [ ] Migrate data

             | Env | Class |
             | --- | --- |
             | prod | db.r6g.large |
             | stage | db.t4g.medium |

             ```sql
             SELECT 1;
             ```\
             """
    end
  end

  describe "Platform.Chat.Canvas delegate" do
    test "Canvas.export_markdown/1 delegates to the exporter" do
      canvas = %Canvas{document: doc(root_stack([heading(1, "Delegated")]))}
      assert {:ok, "# Delegated"} = Canvas.export_markdown(canvas)
    end
  end

  # ── Fixture helpers ─────────────────────────────────────────────────

  defp doc(root), do: %{"version" => 1, "revision" => 1, "root" => root}

  defp root_stack(children) do
    %{"id" => "root", "type" => "stack", "props" => %{"gap" => 12}, "children" => children}
  end

  defp heading(level, value) do
    %{
      "id" => "h-#{level}",
      "type" => "heading",
      "props" => %{"level" => level, "value" => value}
    }
  end

  defp markdown_node(body) do
    %{"id" => "m-#{:erlang.phash2(body)}", "type" => "markdown", "props" => %{"content" => body}}
  end

  defp badge(value) do
    %{"id" => "b-#{value}", "type" => "badge", "props" => %{"value" => value}}
  end

  defp checklist_item(label, state) do
    %{
      "id" => "i-#{label}",
      "type" => "checklist_item",
      "props" => %{"label" => label, "state" => to_string(state)}
    }
  end
end
