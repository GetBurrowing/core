defmodule Platform.Chat.Canvas.Templates do
  @moduledoc """
  Named canonical canvas documents agents can copy + adjust.

  Returned by the `canvas_template` agent tool and used as prescriptive
  examples in validation error payloads. Each template is a complete,
  valid `CanvasDocument` — pass it straight to `canvas_create` and it
  works. Adjust node props and children to taste.
  """

  alias Platform.Showrunner.Episode

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
    },
    %{
      name: "episode_board",
      description:
        "A weekly episode board: title and records line on the production rail, " <>
          "Needs you, the run sheet (with show mode), and collapsed brief, guests and " <>
          "last week's retro. The rail, needs_you and run_sheet nodes are " <>
          "Platform.Showrunner.Episode.to_document/1's."
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

  # The episode board (task 01a1eaf6 stage 2). The three episode nodes and
  # `meta.showrunner` come from `Episode.to_document/1` itself, so the template
  # cannot drift from what the showrunner writes; the collapsed sections are
  # existing `markdown` nodes with a `<details>` block each.
  defp build("episode_board") do
    doc = Episode.to_document(sample_episode())

    collapsed = %{
      "id" => "episode-collapsed",
      "type" => "stack",
      "props" => %{"gap" => 8},
      "children" => [
        details(
          "episode-brief",
          "Research brief · 3 sources",
          "<p>Where the savings from automation go, and why they stall before they reach a household budget.</p>"
        ),
        details(
          "episode-guests",
          "Guests",
          "<p>No guests this week.</p>"
        ),
        details(
          "episode-retro",
          "Last week's retro",
          "<p>Kept 4 of 5 segments. The cold open ran long; trim it to 4:30.</p>"
        )
      ]
    }

    update_in(doc, ["root", "children"], &(&1 ++ [collapsed]))
  end

  defp details(id, summary, body_html) do
    %{
      "id" => id,
      "type" => "markdown",
      "props" => %{
        "content" => "<details>\n<summary>#{summary}</summary>\n#{body_html}\n</details>"
      },
      "children" => []
    }
  end

  defp sample_episode do
    {:ok, episode} =
      Episode.new(%{
        number: 14,
        title: "The AI savings cliff",
        records_at: ~U[2026-11-19 19:00:00Z],
        room_status: "room ready"
      })

    {:ok, episode} = Episode.advance(episode, :research)
    {:ok, episode} = Episode.advance(episode, :run_sheet)

    {:ok, episode} =
      Episode.put_run_sheet(episode, [
        %{
          id: "cold-open",
          starts_at_s: 0,
          ends_at_s: 270,
          name: "Cold open",
          talking_points: %{"Host A" => "The town analogy", "Host B" => "The $2 per worker hook"},
          callback_episode: 9
        },
        %{
          id: "the-town",
          starts_at_s: 270,
          ends_at_s: 900,
          name: "The town",
          talking_points: %{"Host A" => "Walk the savings through one street"},
          stat_cards: [
            %{
              text: "38% of tasks automatable",
              source_url: "https://example.org/automation-report"
            }
          ]
        },
        %{
          id: "the-cliff",
          starts_at_s: 900,
          ends_at_s: 1800,
          name: "The cliff",
          talking_points: %{"Chris" => "Why the savings stop at the payroll line"}
        }
      ])

    {:ok, episode} =
      Episode.add_needs_you(episode, %{
        id: "cold-open-pick",
        question: "Cold open: the town analogy or the $2 per worker hook?",
        options: ["Pick the town", "Pick the hook"]
      })

    episode
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
