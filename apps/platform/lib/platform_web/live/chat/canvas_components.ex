defmodule PlatformWeb.Chat.CanvasComponents do
  @moduledoc """
  Function components for rendering built-in live chat canvases.

  Built-in canvas types are server-rendered and persist their state through
  `Platform.Chat.update_canvas_state/2`, so all connected clients see the same
  canvas content after PubSub updates.
  """

  use PlatformWeb, :html

  alias Platform.Chat.Canvas

  attr :canvas, Canvas, required: true

  def canvas(assigns) do
    ~H"""
    <section
      id={"canvas-card-#{@canvas.id}"}
      class="mt-2 overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-sm"
    >
      <header class="flex items-center justify-between border-b border-base-300 bg-base-200 px-4 py-2">
        <div>
          <p class="text-sm font-semibold text-base-content">
            {@canvas.title || humanize_type(@canvas.canvas_type)}
          </p>
          <p class="text-[11px] uppercase tracking-widest text-base-content/50">
            {humanize_type(@canvas.canvas_type)} canvas
          </p>
        </div>

        <span class="rounded-full bg-base-300 px-2 py-0.5 text-[11px] text-base-content/60">
          {humanize_type(@canvas.canvas_type)}
        </span>
      </header>

      <div class="p-4">
        <%= case @canvas.canvas_type do %>
          <% "table" -> %>
            <.table_canvas canvas={@canvas} />
          <% "form" -> %>
            <.form_canvas canvas={@canvas} />
          <% "code" -> %>
            <.code_canvas canvas={@canvas} />
          <% "diagram" -> %>
            <.diagram_canvas canvas={@canvas} />
          <% "dashboard" -> %>
            <.dashboard_canvas canvas={@canvas} />
          <% _ -> %>
            <.custom_canvas canvas={@canvas} />
        <% end %>
      </div>
    </section>
    """
  end

  attr :canvas, Canvas, required: true

  defp table_canvas(assigns) do
    columns = string_list(state_value(assigns.canvas, "columns", []))
    rows = sort_rows(list_value(assigns.canvas, "rows", []), assigns.canvas.state)

    assigns =
      assigns
      |> assign(:columns, columns)
      |> assign(:rows, rows)
      |> assign(:sort_by, string_value(assigns.canvas, "sort_by"))
      |> assign(:sort_dir, string_value(assigns.canvas, "sort_dir") || "asc")

    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-zebra table-sm w-full">
        <thead>
          <tr>
            <th :for={column <- @columns}>
              <button
                type="button"
                phx-click="canvas_sort"
                phx-value-id={@canvas.id}
                phx-value-column={column}
                class="inline-flex items-center gap-1 font-semibold text-base-content hover:text-primary"
              >
                <span>{column}</span>
                <span :if={@sort_by == column} class="text-[10px] text-primary">
                  {if @sort_dir == "desc", do: "↓", else: "↑"}
                </span>
              </button>
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows}>
            <td :for={column <- @columns} class="align-top">
              {row_value(row, column)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :canvas, Canvas, required: true

  defp form_canvas(assigns) do
    fields = list_value(assigns.canvas, "fields", [])
    values = map_value(assigns.canvas, "values", %{})
    submitted_at = string_value(assigns.canvas, "submitted_at")

    assigns =
      assigns
      |> assign(:fields, fields)
      |> assign(:values, values)
      |> assign(:submitted_at, submitted_at)
      |> assign(:submit_label, string_value(assigns.canvas, "submit_label") || "Save")

    ~H"""
    <div class="space-y-4">
      <.form for={to_form(@values, as: :values)} phx-submit="save_canvas_form" class="space-y-3">
        <input type="hidden" name="canvas_id" value={@canvas.id} />

        <div :for={field <- @fields} class="space-y-1.5">
          <label class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
            {field_value(field, "label") || field_value(field, "name")}
          </label>

          <textarea
            :if={field_value(field, "type") == "textarea"}
            name={"values[#{field_value(field, "name")}]"}
            rows="3"
            placeholder={field_value(field, "placeholder")}
            class="textarea textarea-bordered w-full"
          ><%= Map.get(@values, field_value(field, "name"), "") %></textarea>

          <input
            :if={field_value(field, "type") != "textarea"}
            type={field_value(field, "type") || "text"}
            name={"values[#{field_value(field, "name")}]"}
            value={Map.get(@values, field_value(field, "name"), "")}
            placeholder={field_value(field, "placeholder")}
            class="input input-bordered w-full"
          />
        </div>

        <div class="flex items-center justify-between">
          <span :if={@submitted_at} class="text-xs text-success">
            Saved {format_timestamp(@submitted_at)}
          </span>
          <span :if={!@submitted_at} class="text-xs text-base-content/40">
            Shared live form canvas
          </span>

          <button type="submit" class="btn btn-neutral btn-sm">{@submit_label}</button>
        </div>
      </.form>
    </div>
    """
  end

  attr :canvas, Canvas, required: true

  defp code_canvas(assigns) do
    language = string_value(assigns.canvas, "language") || "elixir"
    content = string_value(assigns.canvas, "content") || ""

    assigns =
      assigns
      |> assign(:language, language)
      |> assign(:content, content)

    ~H"""
    <div class="space-y-3">
      <.form
        for={to_form(%{"language" => @language, "content" => @content}, as: :code_canvas)}
        phx-submit="save_canvas_code"
        class="space-y-3"
      >
        <input type="hidden" name="canvas_id" value={@canvas.id} />

        <div class="flex items-center gap-2">
          <label class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
            Language
          </label>
          <input
            type="text"
            name="code_canvas[language]"
            value={@language}
            class="input input-bordered input-sm w-40"
          />
        </div>

        <textarea
          name="code_canvas[content]"
          rows="10"
          class="textarea textarea-bordered w-full font-mono text-xs"
        ><%= @content %></textarea>

        <div class="flex items-center justify-between gap-2">
          <span class="text-xs text-base-content/40">Persisted shared code canvas</span>
          <button type="submit" class="btn btn-neutral btn-sm">Save code</button>
        </div>
      </.form>
    </div>
    """
  end

  attr :canvas, Canvas, required: true

  defp diagram_canvas(assigns) do
    source = string_value(assigns.canvas, "source") || ""

    assigns =
      assigns
      |> assign(:diagram_title, string_value(assigns.canvas, "diagram_title") || "Diagram")
      |> assign(:source, source)

    ~H"""
    <div class="space-y-3">
      <.form
        for={to_form(%{"diagram_title" => @diagram_title, "source" => @source}, as: :diagram_canvas)}
        phx-submit="save_canvas_diagram"
        class="space-y-3"
      >
        <input type="hidden" name="canvas_id" value={@canvas.id} />

        <input
          type="text"
          name="diagram_canvas[diagram_title]"
          value={@diagram_title}
          placeholder="Diagram title"
          class="input input-bordered w-full"
        />

        <textarea
          name="diagram_canvas[source]"
          rows="8"
          class="textarea textarea-bordered w-full font-mono text-xs"
          placeholder="graph TD&#10;  User-->Chat&#10;  Chat-->Agent"
        ><%= @source %></textarea>

        <div class="flex items-center justify-between gap-2">
          <span class="text-xs text-base-content/40">Mermaid source stored in canvas state</span>
          <button type="submit" class="btn btn-neutral btn-sm">Save diagram</button>
        </div>
      </.form>

      <div class="rounded-xl border border-base-300 bg-base-200 p-3">
        <p class="mb-2 text-xs font-semibold uppercase tracking-widest text-base-content/50">
          Mermaid preview source
        </p>
        <pre class="whitespace-pre-wrap text-xs leading-5 text-base-content/80">{@source}</pre>
      </div>
    </div>
    """
  end

  attr :canvas, Canvas, required: true

  defp dashboard_canvas(assigns) do
    metrics = list_value(assigns.canvas, "metrics", [])
    refreshed_at = string_value(assigns.canvas, "refreshed_at")

    assigns =
      assigns
      |> assign(:metrics, metrics)
      |> assign(:refreshed_at, refreshed_at)

    ~H"""
    <div class="space-y-3">
      <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
        <div
          :for={metric <- @metrics}
          class="rounded-xl border border-base-300 bg-base-200 p-3"
        >
          <p class="text-xs uppercase tracking-widest text-base-content/50">
            {field_value(metric, "label")}
          </p>
          <p class="mt-2 text-2xl font-semibold text-base-content">
            {field_value(metric, "value")}
          </p>
          <p :if={field_value(metric, "trend")} class="mt-1 text-xs text-base-content/50">
            {field_value(metric, "trend")}
          </p>
        </div>
      </div>

      <div class="flex items-center justify-between gap-2">
        <span class="text-xs text-base-content/40">
          Refreshed {format_timestamp(@refreshed_at)}
        </span>
        <button
          type="button"
          phx-click="refresh_canvas_dashboard"
          phx-value-id={@canvas.id}
          class="btn btn-neutral btn-sm"
        >
          Refresh snapshot
        </button>
      </div>
    </div>
    """
  end

  attr :canvas, Canvas, required: true

  defp custom_canvas(assigns) do
    component_module = assigns.canvas.component_module || "(none provided)"
    state_preview = inspect(assigns.canvas.state || %{}, pretty: true, limit: :infinity)

    assigns =
      assigns
      |> assign(:component_module, component_module)
      |> assign(:state_preview, state_preview)

    ~H"""
    <div class="space-y-3">
      <div class="rounded-xl border border-dashed border-base-300 bg-base-200 p-3">
        <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
          Custom component module
        </p>
        <p class="mt-1 font-mono text-xs text-base-content/80">{@component_module}</p>
      </div>

      <div class="rounded-xl border border-base-300 bg-base-200 p-3">
        <p class="mb-2 text-xs font-semibold uppercase tracking-widest text-base-content/50">
          Initial state
        </p>
        <pre class="whitespace-pre-wrap text-xs leading-5 text-base-content/80">{@state_preview}</pre>
      </div>
    </div>
    """
  end

  defp state_value(%Canvas{state: state}, key, default), do: map_fetch(state, key, default)

  defp string_value(canvas, key), do: state_value(canvas, key, nil) |> normalize_string()

  defp list_value(canvas, key, default) do
    case state_value(canvas, key, default) do
      value when is_list(value) -> value
      _ -> default
    end
  end

  defp map_value(canvas, key, default) do
    case state_value(canvas, key, default) do
      value when is_map(value) -> value
      _ -> default
    end
  end

  defp map_fetch(map, key, default) when is_map(map) and is_binary(key) do
    atom_value =
      try do
        Map.get(map, String.to_existing_atom(key))
      rescue
        ArgumentError -> nil
      end

    Map.get(map, key, atom_value || default)
  end

  defp map_fetch(map, key, default) when is_map(map) do
    Map.get(map, key, default)
  end

  defp map_fetch(_map, _key, default), do: default

  defp string_list(list) do
    Enum.map(list, fn value -> to_string(value) end)
  end

  defp row_value(row, column) when is_map(row) do
    map_fetch(row, column, "—")
  end

  defp row_value(_row, _column), do: "—"

  defp sort_rows(rows, state) do
    sort_by = map_fetch(state || %{}, "sort_by", nil)
    sort_dir = map_fetch(state || %{}, "sort_dir", "asc")

    if is_binary(sort_by) and sort_by != "" do
      sorter = fn row -> row_value(row, sort_by) |> to_string() |> String.downcase() end
      ordered = Enum.sort_by(rows, sorter)
      if sort_dir == "desc", do: Enum.reverse(ordered), else: ordered
    else
      rows
    end
  end

  defp field_value(field, key), do: map_fetch(field, key, nil)

  defp humanize_type(type) when is_binary(type) do
    type
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp humanize_type(_type), do: "Canvas"

  defp normalize_string(nil), do: nil
  defp normalize_string(value) when is_binary(value), do: value
  defp normalize_string(value), do: to_string(value)

  defp format_timestamp(nil), do: "just now"

  defp format_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> Calendar.strftime(dt, "%I:%M %p")
      _ -> value
    end
  end

  defp format_timestamp(%DateTime{} = dt), do: Calendar.strftime(dt, "%I:%M %p")
  defp format_timestamp(_value), do: "just now"
end
