defmodule Platform.Repo.Migrations.CanvasFirstClassRefactor do
  @moduledoc """
  ADR 0036: canvases become first-class space-scoped objects.

  - Add `document` (jsonb), `deleted_at`, `cloned_from` to `chat_canvases`.
  - Convert every legacy `state` + `canvas_type` row to a canonical document.
  - Add `canvas_id` to `chat_messages` and backfill from the inverse of
    `chat_canvases.message_id`.
  - Drop legacy columns: `message_id`, `canvas_type`, `component_module`, `state`.
  - Tighten NOT NULL on `space_id` and `created_by`.

  Rows that cannot be converted get a placeholder document and `deleted_at = now()`
  — per ADR directive we drop what cannot round-trip.
  """

  use Ecto.Migration
  import Ecto.Query, warn: false

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    alter table(:chat_canvases) do
      add(:document, :map, default: %{})
      add(:deleted_at, :utc_datetime_usec)
      add(:cloned_from, references(:chat_canvases, type: :binary_id, on_delete: :nilify_all))
    end

    alter table(:chat_messages) do
      add(:canvas_id, references(:chat_canvases, type: :binary_id, on_delete: :nilify_all))
    end

    flush()

    create_if_not_exists(index(:chat_messages, [:canvas_id]))
    create_if_not_exists(index(:chat_canvases, [:cloned_from]))
    create_if_not_exists(index(:chat_canvases, [:deleted_at]))

    flush()

    migrate_data()

    flush()

    alter table(:chat_canvases) do
      modify(:space_id, :binary_id, null: false)
      modify(:created_by, :binary_id, null: false)
      remove(:message_id)
      remove(:canvas_type)
      remove(:component_module)
      remove(:state)
    end
  end

  def down do
    alter table(:chat_canvases) do
      add(:message_id, :binary_id)
      add(:canvas_type, :string)
      add(:component_module, :string)
      add(:state, :map, default: %{})
      modify(:space_id, :binary_id, null: true)
      modify(:created_by, :binary_id, null: true)
    end

    alter table(:chat_messages) do
      remove(:canvas_id)
    end

    alter table(:chat_canvases) do
      remove(:document)
      remove(:deleted_at)
      remove(:cloned_from)
    end
  end

  # ── Data migration ─────────────────────────────────────────────────────────

  defp migrate_data do
    canvases =
      Platform.Repo.query!(~s(SELECT id, canvas_type, state, message_id FROM chat_canvases))

    Enum.each(canvases.rows, fn [id, canvas_type, state, message_id] ->
      id = normalize_id(id)
      state = state || %{}

      {document, deleted} = convert(canvas_type, state)

      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      deleted_at = if deleted, do: now, else: nil

      # Pass the map directly — Postgrex's configured jsonb extension handles
      # encoding. Pre-encoding to JSON string + ::jsonb cast round-trips
      # through a JSON string literal and yields a double-encoded document.
      Platform.Repo.query!(
        ~s(UPDATE chat_canvases SET document = $1, deleted_at = $2 WHERE id = $3),
        [document, deleted_at, id]
      )

      if message_id do
        Platform.Repo.query!(
          ~s(UPDATE chat_messages SET canvas_id = $1 WHERE id = $2),
          [id, normalize_id(message_id)]
        )
      end
    end)
  end

  defp normalize_id(uuid) when is_binary(uuid), do: uuid
  defp normalize_id(other), do: other

  defp convert(type, state) when is_map(state) do
    cond do
      has_url?(state) ->
        # URL canvases — no iframe kind in core set yet; convert to a markdown
        # node with the URL. Phase 7 replaces this with the `iframe` kind.
        url = state["url"]

        doc =
          single_child_doc(%{
            "id" => "url-note",
            "type" => "markdown",
            "props" => %{
              "content" => "Legacy URL canvas: #{url}\n\nOpen: #{url}"
            }
          })

        {doc, false}

      has_a2ui?(state) ->
        parsed = parse_a2ui(state["a2ui_content"])
        children = Enum.map(parsed, &normalize_a2ui_node/1)

        root_stack = %{
          "id" => "root",
          "type" => "stack",
          "props" => %{"gap" => 12},
          "children" => children
        }

        {%{
           "version" => 1,
           "revision" => 1,
           "root" => root_stack,
           "theme" => %{},
           "bindings" => %{},
           "meta" => %{"legacy_source" => "a2ui"}
         }, false}

      true ->
        case type do
          "table" -> {convert_table(state), false}
          "form" -> {convert_form(state), false}
          "code" -> {convert_code(state), false}
          "diagram" -> {convert_diagram(state), false}
          "dashboard" -> {convert_dashboard(state), false}
          "custom" -> {convert_custom(state), false}
          _ -> {placeholder_doc("canvas could not be migrated"), true}
        end
    end
  end

  defp convert(_type, _state), do: {placeholder_doc("canvas could not be migrated"), true}

  defp has_url?(%{"url" => u}) when is_binary(u) and u != "", do: true
  defp has_url?(_), do: false

  defp has_a2ui?(%{"a2ui_content" => c}) when is_binary(c) and c != "", do: true
  defp has_a2ui?(_), do: false

  defp parse_a2ui(content) when is_binary(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, node} when is_map(node) -> [node]
        _ -> []
      end
    end)
  end

  defp parse_a2ui(_), do: []

  defp normalize_a2ui_node(%{"type" => type} = node) when is_map(node) do
    allowed = ~w(stack row card text markdown heading badge image code mermaid table)

    mapped_type =
      cond do
        type in allowed -> type
        type == "container" -> "stack"
        type == "paragraph" -> "text"
        type == "h1" -> "heading"
        type == "h2" -> "heading"
        true -> "markdown"
      end

    props = Map.get(node, "props", %{})

    props =
      if mapped_type == "markdown" and type != "markdown" do
        Map.put(props, "content", Jason.encode!(node))
      else
        props
      end

    %{
      "id" => Map.get(node, "id") || random_id(),
      "type" => mapped_type,
      "props" => props,
      "children" => Enum.map(Map.get(node, "children", []), &normalize_a2ui_node/1)
    }
  end

  defp normalize_a2ui_node(other) do
    %{
      "id" => random_id(),
      "type" => "markdown",
      "props" => %{"content" => inspect(other)},
      "children" => []
    }
  end

  defp random_id, do: Ecto.UUID.generate()

  defp single_child_doc(child) do
    %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{"gap" => 12},
        "children" => [child]
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }
  end

  defp placeholder_doc(reason) do
    single_child_doc(%{
      "id" => "placeholder",
      "type" => "text",
      "props" => %{"value" => reason},
      "children" => []
    })
    |> put_in(["meta", "migration_failure"], reason)
  end

  defp convert_table(state) do
    columns = Map.get(state, "columns", []) |> List.wrap()
    rows = Map.get(state, "rows", []) |> List.wrap()

    single_child_doc(%{
      "id" => "table-main",
      "type" => "table",
      "props" => %{
        "columns" => Enum.map(columns, &to_string/1),
        "rows" => rows
      },
      "children" => []
    })
  end

  defp convert_form(state) do
    fields =
      Map.get(state, "fields", [])
      |> List.wrap()
      |> Enum.map(fn
        %{"name" => name} = field ->
          %{
            "name" => to_string(name),
            "label" => to_string(Map.get(field, "label", name)),
            "type" => to_string(Map.get(field, "type", "text")),
            "required" => Map.get(field, "required", false)
          }

        other ->
          %{"name" => inspect(other), "type" => "text"}
      end)

    single_child_doc(%{
      "id" => "form-main",
      "type" => "form",
      "props" => %{
        "title" => Map.get(state, "title"),
        "fields" => fields
      },
      "children" => []
    })
  end

  defp convert_code(state) do
    language = Map.get(state, "language", "text")
    source = Map.get(state, "source") || Map.get(state, "content") || ""

    single_child_doc(%{
      "id" => "code-main",
      "type" => "code",
      "props" => %{"language" => to_string(language), "source" => to_string(source)},
      "children" => []
    })
  end

  defp convert_diagram(state) do
    source = Map.get(state, "source") || Map.get(state, "diagram") || ""

    single_child_doc(%{
      "id" => "diagram-main",
      "type" => "mermaid",
      "props" => %{"source" => to_string(source)},
      "children" => []
    })
  end

  defp convert_dashboard(state) do
    metrics = Map.get(state, "metrics", []) |> List.wrap()

    cards =
      metrics
      |> Enum.with_index()
      |> Enum.map(fn {metric, idx} ->
        label = Map.get(metric, "label", "Metric #{idx + 1}")
        value = to_string(Map.get(metric, "value", "—"))

        %{
          "id" => "metric-card-#{idx}",
          "type" => "card",
          "props" => %{"title" => to_string(label)},
          "children" => [
            %{
              "id" => "metric-#{idx}-value",
              "type" => "text",
              "props" => %{"value" => value, "size" => "2xl", "weight" => "bold"},
              "children" => []
            }
          ]
        }
      end)

    row = %{
      "id" => "metrics-row",
      "type" => "row",
      "props" => %{"gap" => 12},
      "children" => cards
    }

    %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{"gap" => 12},
        "children" => [row]
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }
  end

  defp convert_custom(state) do
    single_child_doc(%{
      "id" => "custom-dump",
      "type" => "markdown",
      "props" => %{"content" => Jason.encode!(state, pretty: true)},
      "children" => []
    })
  end
end
