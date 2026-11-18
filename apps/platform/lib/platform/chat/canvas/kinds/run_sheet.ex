defmodule Platform.Chat.Canvas.Kinds.RunSheet do
  @moduledoc """
  The run sheet, the hero of an episode board (task 01a1eaf6 stage 2).

  One row per segment: the timing in mono (`00:00–04:30`, `shrink-0`), the
  segment name (never truncated), an optional "↩ callback Ep N" marker, the
  per-host talking points (these truncate first) and the stat cards, each
  carrying its source inline.

  Show mode lives on the same node: the "Show mode" toggle flips
  `data-show` on the section (a client-side `JS` command, so it survives
  patches), which enlarges the sheet to the full viewport and reveals a live
  segment timer readable from a phone. The timer is the colocated `.ShowTimer`
  hook on an element with its own DOM id and `phx-update="ignore"`.

  Props are exactly the `run_sheet` node `Platform.Showrunner.Episode.to_document/1`
  writes; `validate_props/1` delegates to `Episode.validate_run_sheet_props/1`,
  so a stat card without a `source_url` is refused at patch time.
  """

  use Platform.Chat.Canvas.Kind

  alias Phoenix.LiveView.JS
  alias Platform.Showrunner.Episode

  def children, do: :none

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["segments"],
      "properties" => %{
        "segments" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "required" => ["id", "starts_at_s", "ends_at_s", "name"],
            "properties" => %{
              "id" => %{"type" => "string"},
              "starts_at_s" => %{"type" => "integer", "minimum" => 0},
              "ends_at_s" => %{"type" => "integer", "minimum" => 1},
              "name" => %{"type" => "string"},
              "talking_points" => %{
                "type" => "object",
                "additionalProperties" => %{"type" => "string"}
              },
              "callback_episode" => %{"type" => ["integer", "null"], "minimum" => 1},
              "stat_cards" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "required" => ["text", "source_url"],
                  "properties" => %{
                    "text" => %{"type" => "string"},
                    "source_url" => %{"type" => "string", "minLength" => 1}
                  }
                }
              }
            }
          }
        },
        "total_s" => %{"type" => "integer", "minimum" => 0},
        "class_overrides" => %{"type" => "string"}
      }
    }
  end

  def defaults, do: %{"segments" => [], "total_s" => 0}

  def validate_props(props) do
    case Episode.validate_run_sheet_props(props) do
      :ok -> :ok
      {:error, reason} -> {:error, "(run_sheet) " <> Episode.error_message(reason)}
    end
  end

  @doc "Seconds as `MM:SS`, e.g. 270 is \"04:30\"."
  @spec clock(integer()) :: String.t()
  def clock(seconds) when is_integer(seconds) and seconds >= 0 do
    pad(div(seconds, 60)) <> ":" <> pad(rem(seconds, 60))
  end

  def clock(_), do: "--:--"

  attr :node, :map, required: true
  attr :dom_id_scope, :string, default: nil
  attr :canvas_id, :string, default: nil
  attr :event_target, :any, default: nil
  attr :viewer, :any, default: nil

  def render(assigns) do
    props = assigns.node["props"] || %{}
    segments = props["segments"] |> List.wrap() |> Enum.filter(&is_map/1)
    section_id = dom_id(assigns, "run-sheet")

    assigns =
      assigns
      |> assign(:props, props)
      |> assign(:segments, segments)
      |> assign(:section_id, section_id)
      |> assign(:timer_id, section_id <> "-timer")
      |> assign(:total, total(props, segments))
      |> assign(:timer_segments, timer_segments(segments))

    ~H"""
    <section
      id={@section_id}
      data-role="run-sheet"
      class={[
        "group flex flex-col gap-2 rounded-xl border border-edge bg-base-200 p-3",
        "data-[show=on]:fixed data-[show=on]:inset-0 data-[show=on]:z-50 data-[show=on]:overflow-y-auto",
        "data-[show=on]:rounded-none data-[show=on]:border-0 data-[show=on]:bg-base-100 data-[show=on]:p-4",
        @props["class_overrides"]
      ]}
    >
      <header class="flex items-center justify-between gap-2">
        <h3 class="text-sm font-semibold text-base-content group-data-[show=on]:text-lg">
          Run sheet
          <span data-role="run-sheet-total" class="ml-1 font-mono text-xs font-normal text-subtle">
            {clock(@total)}
          </span>
        </h3>
        <button
          type="button"
          data-role="show-mode-toggle"
          class="btn btn-sm btn-ghost"
          phx-click={JS.toggle_attribute({"data-show", "on"}, to: "##{@section_id}")}
        >
          <span class="group-data-[show=on]:hidden">Show mode</span>
          <span class="hidden group-data-[show=on]:inline">Exit show mode</span>
        </button>
      </header>

      <div
        id={@timer_id}
        data-role="show-timer"
        phx-hook=".ShowTimer"
        phx-update="ignore"
        data-segments={Jason.encode!(@timer_segments)}
        class="hidden flex-col items-center gap-1 rounded-xl border border-edge bg-base-200 p-4 group-data-[show=on]:flex"
      >
        <p data-timer-part="segment" class="text-center text-2xl font-semibold text-base-content">
          {first_name(@segments)}
        </p>
        <p
          data-timer-part="clock"
          class="font-mono text-6xl tabular-nums text-base-content"
          aria-live="off"
        >
          00:00
        </p>
        <p data-timer-part="remaining" class="font-mono text-sm text-subtle"></p>
        <div class="mt-2 flex gap-2">
          <button
            type="button"
            data-timer-action="toggle"
            class="btn btn-sm btn-outline btn-secondary"
          >
            Start
          </button>
          <button type="button" data-timer-action="next" class="btn btn-sm btn-ghost">
            Next segment
          </button>
          <button type="button" data-timer-action="reset" class="btn btn-sm btn-ghost">
            Reset
          </button>
        </div>
      </div>

      <ol class="flex flex-col">
        <li
          :for={segment <- @segments}
          data-role="run-sheet-segment"
          data-segment-id={segment["id"]}
          class="flex flex-col gap-1 border-t border-edge py-2 first:border-t-0"
        >
          <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
            <span
              data-role="segment-timing"
              class="font-mono shrink-0 text-xs text-subtle group-data-[show=on]:text-base"
            >
              {clock(segment["starts_at_s"])}–{clock(segment["ends_at_s"])}
            </span>
            <span
              data-role="segment-name"
              class="max-w-full break-words text-sm font-medium text-base-content group-data-[show=on]:text-2xl"
            >
              {segment["name"]}
            </span>
            <span
              :if={is_integer(segment["callback_episode"])}
              data-role="segment-callback"
              class="shrink-0 text-xs text-subtle group-data-[show=on]:text-base"
            >
              ↩ callback Ep {segment["callback_episode"]}
            </span>
          </div>
          <ul
            :if={talking_points(segment) != []}
            class="flex min-w-0 flex-col gap-x-4 sm:flex-row"
          >
            <li
              :for={{host, text} <- talking_points(segment)}
              data-role="talking-point"
              class="min-w-0 flex-1 truncate text-sm text-base-content group-data-[show=on]:text-lg"
            >
              <span class="font-medium">{host}:</span> {text}
            </li>
          </ul>
          <ul :if={stat_cards(segment) != []} class="flex flex-wrap gap-2">
            <li
              :for={card <- stat_cards(segment)}
              data-role="stat-card"
              class="inline-flex max-w-full flex-wrap items-baseline gap-x-2 rounded-lg border border-edge bg-base-100 px-2 py-1 text-xs text-base-content"
            >
              <span>{card["text"]}</span>
              <a
                :if={http_url?(card["source_url"])}
                data-role="stat-source"
                href={card["source_url"]}
                target="_blank"
                rel="noopener noreferrer"
                class="font-mono text-subtle underline"
              >
                {source_label(card["source_url"])}
              </a>
              <span
                :if={not http_url?(card["source_url"])}
                data-role="stat-source"
                class="font-mono text-subtle"
              >
                {card["source_url"]}
              </span>
            </li>
          </ul>
        </li>
      </ol>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ShowTimer">
        // Live segment timer for show mode. Client-only state: the timer is
        // a stopwatch on the host's phone, never written to the document.
        const pad = (n) => String(Math.floor(n)).padStart(2, "0")
        const clock = (s) => `${pad(s / 60)}:${pad(s % 60)}`

        export default {
          mounted() {
            this.runningSince = null
            this.banked = 0
            this.onClick = (e) => {
              const button = e.target.closest("[data-timer-action]")
              if (!button) return
              this.act(button.dataset.timerAction, button)
            }
            this.el.addEventListener("click", this.onClick)
            this.interval = setInterval(() => this.paint(), 250)
            this.paint()
          },
          destroyed() {
            clearInterval(this.interval)
            this.el.removeEventListener("click", this.onClick)
          },
          segments() {
            try { return JSON.parse(this.el.dataset.segments || "[]") } catch (_e) { return [] }
          },
          elapsed() {
            const live = this.runningSince === null ? 0 : (Date.now() - this.runningSince) / 1000
            return this.banked + live
          },
          act(action, button) {
            if (action === "toggle") {
              if (this.runningSince === null) {
                this.runningSince = Date.now()
                button.textContent = "Pause"
              } else {
                this.banked = this.elapsed()
                this.runningSince = null
                button.textContent = "Start"
              }
            } else if (action === "reset") {
              this.banked = 0
              this.runningSince = this.runningSince === null ? null : Date.now()
            } else if (action === "next") {
              const at = this.elapsed()
              const next = this.segments().find((s) => s.starts_at_s > at)
              if (next) {
                this.banked = next.starts_at_s
                this.runningSince = this.runningSince === null ? null : Date.now()
              }
            }
            this.paint()
          },
          paint() {
            const at = this.elapsed()
            const segments = this.segments()
            const current =
              segments.find((s) => at >= s.starts_at_s && at < s.ends_at_s) ||
              segments[segments.length - 1]
            const part = (name) => this.el.querySelector(`[data-timer-part="${name}"]`)
            if (!current) return
            part("segment").textContent = current.name
            part("clock").textContent = clock(Math.max(0, at - current.starts_at_s))
            const left = current.ends_at_s - at
            part("remaining").textContent =
              left >= 0
                ? `${clock(left)} left · ends ${clock(current.ends_at_s)}`
                : `over by ${clock(-left)}`
          }
        }
      </script>
    </section>
    """
  end

  defp timer_segments(segments) do
    Enum.map(segments, fn segment ->
      Map.take(segment, ["id", "name", "starts_at_s", "ends_at_s"])
    end)
  end

  defp first_name([first | _]), do: first["name"]
  defp first_name(_), do: ""

  defp total(%{"total_s" => total}, _segments) when is_integer(total), do: total

  defp total(_props, segments) do
    case List.last(segments) do
      %{"ends_at_s" => ends} when is_integer(ends) -> ends
      _ -> 0
    end
  end

  # Host order is the document's map order, which is not stable; sort by host
  # so a re-render never reshuffles the row.
  defp talking_points(%{"talking_points" => points}) when is_map(points),
    do: points |> Enum.filter(fn {_h, t} -> is_binary(t) end) |> Enum.sort()

  defp talking_points(_), do: []

  defp stat_cards(%{"stat_cards" => cards}) when is_list(cards), do: Enum.filter(cards, &is_map/1)
  defp stat_cards(_), do: []

  defp http_url?(url) when is_binary(url),
    do: String.starts_with?(url, "https://") or String.starts_with?(url, "http://")

  defp http_url?(_), do: false

  # The host is the inline source label: "src: bls.gov".
  defp source_label(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        "src: " <> String.replace_prefix(host, "www.", "")

      _ ->
        "src"
    end
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp dom_id(assigns, suffix) do
    ["canvas", assigns.dom_id_scope, assigns.node["id"], suffix]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("-")
  end
end
