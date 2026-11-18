defmodule Platform.Chat.Canvas.Kinds.ProductionRail do
  @moduledoc """
  The episode header and production rail (task 01a1eaf6 stage 2).

  Renders the episode title once, in display weight, the records line
  ("Records Thu 7pm · room ready", the time in mono), and ONE line of the
  seven production stages as small state dots: `success` ready, `info` in
  progress, `warning` needs you, an outline not started. Only the current
  stage takes the agent accent slot (`agent_slot`, a
  `Platform.Agents.ColorPalette` id; unknown or absent is the default slot).

  Props are exactly the `production_rail` node `Platform.Showrunner.Episode.to_document/1`
  writes, and `validate_props/1` delegates to `Episode.validate_rail_props/1`.
  """

  use Platform.Chat.Canvas.Kind

  alias Platform.Agents.ColorPalette
  alias Platform.Showrunner.Episode

  @labels %{
    "pitch" => "Pitch",
    "research" => "Research",
    "run_sheet" => "Run sheet",
    "logistics" => "Logistics",
    "record" => "Record",
    "post" => "Post",
    "retro" => "Retro"
  }

  @state_labels %{
    "ready" => "ready",
    "in_progress" => "in progress",
    "needs_you" => "needs you",
    "not_started" => "not started"
  }

  def children, do: :none

  def schema do
    stage_names = Enum.map(Episode.stages(), &Atom.to_string/1)
    state_names = Enum.map(Episode.stage_states(), &Atom.to_string/1)

    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["number", "title", "stage", "stages"],
      "properties" => %{
        "number" => %{"type" => "integer", "minimum" => 1},
        "title" => %{"type" => "string"},
        "records_at" => %{"type" => ["string", "null"]},
        "room_status" => %{"type" => ["string", "null"]},
        "stage" => %{"type" => "string", "enum" => stage_names},
        "stages" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "required" => ["stage", "state"],
            "properties" => %{
              "stage" => %{"type" => "string", "enum" => stage_names},
              "state" => %{"type" => "string", "enum" => state_names}
            }
          }
        },
        "agent_slot" => %{"type" => "string", "enum" => ColorPalette.ids()},
        "class_overrides" => %{"type" => "string"}
      }
    }
  end

  def defaults do
    %{
      "number" => 1,
      "title" => "Episode title",
      "stage" => "pitch",
      "stages" =>
        Enum.map(Episode.stages(), fn
          :pitch -> %{"stage" => "pitch", "state" => "in_progress"}
          stage -> %{"stage" => Atom.to_string(stage), "state" => "not_started"}
        end)
    }
  end

  def validate_props(props) do
    case Episode.validate_rail_props(props) do
      :ok -> :ok
      {:error, reason} -> {:error, "(production_rail) " <> Episode.error_message(reason)}
    end
  end

  @doc "The display label of a stage name, e.g. \"run_sheet\" is \"Run sheet\"."
  @spec label(String.t()) :: String.t()
  def label(stage), do: Map.get(@labels, stage, stage)

  attr :node, :map, required: true
  attr :dom_id_scope, :string, default: nil
  attr :canvas_id, :string, default: nil
  attr :event_target, :any, default: nil
  attr :viewer, :any, default: nil

  def render(assigns) do
    props = assigns.node["props"] || %{}
    current = props["stage"]
    stages = rail_stages(props["stages"])

    assigns =
      assigns
      |> assign(:props, props)
      |> assign(:slot, ColorPalette.slot_for(props["agent_slot"]))
      |> assign(:title, title_line(props))
      |> assign(:records_at, records_at(props["records_at"]))
      |> assign(:records_id, dom_id(assigns, "records-at"))
      |> assign(:current, current)
      |> assign(:stages, Enum.with_index(stages))
      |> assign(:last, length(stages) - 1)

    ~H"""
    <section
      data-role="episode-header"
      data-agent-slot={@slot}
      class={["flex flex-col gap-2", @props["class_overrides"]]}
    >
      <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <h2 data-role="episode-title" class="text-xl font-semibold leading-tight text-base-content">
          {@title}
        </h2>
        <p
          :if={@records_at || @props["room_status"]}
          data-role="records-line"
          class="text-sm text-subtle"
        >
          <span :if={@records_at}>
            Records
            <time
              id={@records_id}
              data-role="records-at"
              phx-hook=".RecordsAt"
              datetime={DateTime.to_iso8601(@records_at)}
              class="font-mono"
            >
              {fallback_time(@records_at)}
            </time>
          </span>
          <span :if={@records_at && @props["room_status"]} aria-hidden="true">·</span>
          <span :if={@props["room_status"]} data-role="room-status">{@props["room_status"]}</span>
        </p>
      </div>
      <ol
        data-role="production-rail"
        aria-label="Production rail"
        class="flex items-center gap-x-2 overflow-x-auto whitespace-nowrap text-xs"
      >
        <li
          :for={{stage, index} <- @stages}
          data-role="rail-stage"
          data-stage={stage["stage"]}
          data-state={stage["state"]}
          data-current={to_string(stage["stage"] == @current)}
          aria-current={if stage["stage"] == @current, do: "step"}
          class="flex shrink-0 items-center gap-1.5"
        >
          <span
            data-role="rail-dot"
            aria-hidden="true"
            class={[
              "size-2 shrink-0 rounded-full",
              dot_class(stage["state"]),
              stage["stage"] == @current &&
                "ring-2 ring-[var(--ag)] ring-offset-1 ring-offset-base-100"
            ]}
          />
          <span class={
            if stage["stage"] == @current,
              do: "font-semibold text-[var(--ag-text)]",
              else: "text-base-content"
          }>
            {label(stage["stage"])}
          </span>
          <span class="sr-only">({state_label(stage["state"])})</span>
          <span :if={index < @last} aria-hidden="true" class="pl-0.5 text-subtle">→</span>
        </li>
      </ol>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".RecordsAt">
        // "Thu 7pm" in the viewer's own zone; the server renders UTC until then.
        const format = (el) => {
          const date = new Date(el.getAttribute("datetime"))
          if (Number.isNaN(date.getTime())) return
          const day = new Intl.DateTimeFormat(undefined, {weekday: "short"}).format(date)
          const h = date.getHours()
          const m = date.getMinutes()
          const hour = h % 12 === 0 ? 12 : h % 12
          const mins = m === 0 ? "" : ":" + String(m).padStart(2, "0")
          el.textContent = `${day} ${hour}${mins}${h < 12 ? "am" : "pm"}`
        }
        export default {
          mounted() { format(this.el) },
          updated() { format(this.el) }
        }
      </script>
    </section>
    """
  end

  # Every dot is its state colour. The live stage alone adds the agent accent,
  # as a ring on its dot and on its label (see render/1).
  defp dot_class("ready"), do: "bg-success"
  defp dot_class("in_progress"), do: "bg-info"
  defp dot_class("needs_you"), do: "bg-warning"
  defp dot_class(_), do: "border border-subtle"

  defp state_label(state), do: Map.get(@state_labels, state, to_string(state))

  defp rail_stages(stages) when is_list(stages), do: Enum.filter(stages, &is_map/1)
  defp rail_stages(_), do: []

  defp title_line(%{"number" => n, "title" => title}) when is_integer(n),
    do: "Ep #{n} · #{title}"

  defp title_line(props), do: to_string(props["title"])

  defp records_at(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} -> at
      _ -> nil
    end
  end

  defp records_at(_), do: nil

  defp fallback_time(%DateTime{} = at), do: Calendar.strftime(at, "%a %H:%M UTC")

  defp dom_id(assigns, suffix) do
    ["canvas", assigns.dom_id_scope, assigns.node["id"], suffix]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("-")
  end
end
