defmodule Platform.Chat.Canvas.Templates do
  @moduledoc """
  Named canonical canvas documents agents can copy + adjust.

  Returned by the `canvas.template` agent tool and used as prescriptive
  examples in validation error payloads. Each template is a complete,
  valid `CanvasDocument` — pass it straight to `canvas.create` and it
  works. Adjust node props and children to taste.
  """

  @type template :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:document) => map()
        }

  @templates [
    %{
      name: "empty",
      description: "A blank canvas with just a root stack. Use as a starting scaffold."
    },
    %{
      name: "text",
      description: "Single markdown/text block. Simplest possible canvas."
    },
    %{
      name: "heading_and_text",
      description: "A heading with a paragraph under it — the most common canvas shape."
    },
    %{
      name: "checklist",
      description: "A titled checklist with three items."
    },
    %{
      name: "table",
      description: "A simple two-column table."
    },
    %{
      name: "form",
      description: "A single-field form that emits a `submitted` event."
    },
    %{
      name: "code",
      description: "A syntax-highlighted code block."
    },
    %{
      name: "dashboard",
      description: "A row of KPI cards."
    }
  ]

  @doc "List all template names + descriptions (without the full document)."
  @spec list() :: [%{name: String.t(), description: String.t()}]
  def list, do: Enum.map(@templates, &Map.take(&1, [:name, :description]))

  @doc "Return the template document for `name`, or nil if unknown."
  @spec get(String.t()) :: template() | nil
  def get(name) when is_binary(name) do
    case Enum.find(@templates, fn t -> t.name == name end) do
      nil -> nil
      meta -> Map.put(meta, :document, build(meta.name))
    end
  end

  def get(_), do: nil

  @doc "Minimal valid document — used as the always-safe fallback example."
  @spec minimal_example() :: map()
  def minimal_example, do: build("heading_and_text")

  # ── Builders (kept trivial and static so they're easy to eyeball) ──────

  defp build("empty"), do: wrap([])

  defp build("text") do
    wrap([
      %{
        "id" => "body",
        "type" => "markdown",
        "props" => %{"content" => "Hello from a canvas."},
        "children" => []
      }
    ])
  end

  defp build("heading_and_text") do
    wrap([
      %{
        "id" => "title",
        "type" => "heading",
        "props" => %{"value" => "Welcome", "level" => 2},
        "children" => []
      },
      %{
        "id" => "body",
        "type" => "markdown",
        "props" => %{"content" => "Replace this with the content you want to show."},
        "children" => []
      }
    ])
  end

  defp build("checklist") do
    wrap([
      %{
        "id" => "checklist",
        "type" => "checklist",
        "props" => %{"title" => "Todo"},
        "children" => [
          %{
            "id" => "item-1",
            "type" => "checklist_item",
            "props" => %{"label" => "First task", "state" => "pending"},
            "children" => []
          },
          %{
            "id" => "item-2",
            "type" => "checklist_item",
            "props" => %{"label" => "Second task", "state" => "pending"},
            "children" => []
          },
          %{
            "id" => "item-3",
            "type" => "checklist_item",
            "props" => %{"label" => "Third task", "state" => "pending"},
            "children" => []
          }
        ]
      }
    ])
  end

  defp build("table") do
    wrap([
      %{
        "id" => "table",
        "type" => "table",
        "props" => %{
          "columns" => ["Name", "Status"],
          "rows" => [
            %{"Name" => "Alpha", "Status" => "active"},
            %{"Name" => "Beta", "Status" => "pending"}
          ]
        },
        "children" => []
      }
    ])
  end

  defp build("form") do
    wrap([
      %{
        "id" => "form",
        "type" => "form",
        "props" => %{
          "title" => "Share feedback",
          "submit_label" => "Send",
          "fields" => [
            %{
              "name" => "notes",
              "label" => "Notes",
              "type" => "textarea",
              "required" => true
            }
          ]
        },
        "children" => []
      }
    ])
  end

  defp build("code") do
    wrap([
      %{
        "id" => "snippet",
        "type" => "code",
        "props" => %{
          "language" => "elixir",
          "source" => "IO.puts(\"hello, canvas\")"
        },
        "children" => []
      }
    ])
  end

  defp build("dashboard") do
    wrap([
      %{
        "id" => "metrics",
        "type" => "row",
        "props" => %{"gap" => 12},
        "children" => [
          metric_card("uptime", "Uptime", "99.9%"),
          metric_card("latency", "p95 latency", "128ms"),
          metric_card("errors", "Errors/min", "0.2")
        ]
      }
    ])
  end

  defp metric_card(id, label, value) do
    %{
      "id" => "card-#{id}",
      "type" => "card",
      "props" => %{"title" => label},
      "children" => [
        %{
          "id" => "value-#{id}",
          "type" => "text",
          "props" => %{"value" => value, "size" => "2xl", "weight" => "bold"},
          "children" => []
        }
      ]
    }
  end

  defp wrap(children) when is_list(children) do
    %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{"gap" => 12},
        "children" => children
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }
  end
end
