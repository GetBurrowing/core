defmodule PlatformWeb.ControlCenter.AgentGraph do
  @moduledoc """
  The Connections graph of the living agent page (task 01a1b6ad stage 4):
  the comp's `graphSVG()` (burrow-agents.js) rendered on the server.

  The layout maths are the comp's: nodes sorted in `KIND` order sit on an
  ellipse around the agent, pulled in by their weight (w 3 closest), each
  joined to the centre by a quadratic edge whose width is the weight, with a
  dashed "flow" over edges of weight 2 and 3. Labels truncate at 16 chars
  and are clamped inside the width. The comp draws a 340x400 graph on the
  phone and a 680x440 one (with a sub label under each node) on the
  desktop, chosen by its `mob` flag; the server renders both and app.css
  shows one per the 768px media query.

  Nodes come from `PlatformWeb.ControlCenter.AgentPageData` (`:graph`):
  `%{id, k, l, sub, w}` plus whatever the kind needs for its card.
  """
  use Phoenix.Component

  alias PlatformWeb.ControlCenter.AgentPageData

  @order ~w(channel project repo tool person agent)

  @doc "The comp's glyph for a node kind."
  def glyph(k) do
    case Enum.find(AgentPageData.kinds(), &(elem(&1, 0) == k)) do
      {_, glyph, _} -> glyph
      nil -> "•"
    end
  end

  @doc "The comp's label for a node kind."
  def kind_label(k) do
    case Enum.find(AgentPageData.kinds(), &(elem(&1, 0) == k)) do
      {_, _, label} -> label
      nil -> k
    end
  end

  @doc "Nodes in the comp's draw order (`KIND` order, stable)."
  def sorted(nodes), do: Enum.sort_by(nodes, &Enum.find_index(@order, fn k -> k == &1.k end))

  @doc """
  The comp's `hash()`: h = 7, then h = (h * 31 + code) as an unsigned
  32-bit integer, over the string's UTF-16 code units.
  """
  def hash(s) when is_binary(s) do
    s
    |> :unicode.characters_to_binary(:utf8, :utf16)
    |> :binary.bin_to_list()
    |> Enum.chunk_every(2)
    |> Enum.map(fn [hi, lo] -> hi * 256 + lo end)
    |> Enum.reduce(7, fn c, h -> rem(h * 31 + c, 4_294_967_296) end)
  end

  @doc """
  The comp's layout for `nodes` at one size: `%{w, h, cx, cy, r0, nodes}`
  where each node carries `x`, `y`, `r`, `lx` (the clamped label x),
  `below?`, `d` (the edge path), `label` (truncated) and `i`.
  """
  def layout(nodes, mob?) do
    {w, h} = if mob?, do: {340, 400}, else: {680, 440}
    cx = w / 2
    cy = h / 2
    {rx, ry} = if mob?, do: {136, 160}, else: {250, 170}
    sorted = sorted(nodes)
    count = max(length(sorted), 1)

    placed =
      sorted
      |> Enum.with_index()
      |> Enum.map(fn {n, i} ->
        ang = -:math.pi() / 2 + i / count * :math.pi() * 2

        f =
          cond do
            n.w >= 3 -> if mob?, do: 0.5, else: 0.62
            n.w == 2 -> if mob?, do: 0.76, else: 0.82
            true -> 1.0
          end

        x = cx + :math.cos(ang) * rx * f
        y = cy + :math.sin(ang) * ry * f

        r =
          cond do
            mob? and n.w >= 3 -> 15
            mob? and n.w == 2 -> 13
            mob? -> 11
            n.w >= 3 -> 20
            n.w == 2 -> 17
            true -> 14
          end

        d =
          "M#{f2(cx)} #{f2(cy)} Q#{f2((cx + x) / 2 + (y - cy) * 0.12)} #{f2((cy + y) / 2 - (x - cx) * 0.12)} #{f2(x)} #{f2(y)}"

        Map.merge(n, %{
          i: i,
          x: x,
          y: y,
          r: r,
          lx: clamp_label_x(x, n.l, w),
          below?: y >= cy - 4,
          d: d,
          label: truncate(n.l),
          sub1: n.sub |> to_string() |> String.split(" · ") |> hd(),
          flow_delay: -rem(hash(n.id), 26) / 10,
          float_delay: -(i * 0.7)
        })
      end)

    %{w: w, h: h, cx: cx, cy: cy, r0: if(mob?, do: 22, else: 30), nodes: placed}
  end

  defp clamp_label_x(x, label, w) do
    hw = min(16, String.length(label)) * 3.3 + 4
    max(hw, min(w - hw, x))
  end

  defp truncate(l) when is_binary(l) do
    if String.length(l) > 16, do: String.slice(l, 0, 15) <> "…", else: l
  end

  defp truncate(l), do: to_string(l)

  @doc "A coordinate as the comp prints it, trimmed to two decimals."
  def f2(n) when is_integer(n), do: Integer.to_string(n)

  def f2(n) when is_float(n) do
    r = Float.round(n, 2)
    if r == Float.round(r, 0), do: Integer.to_string(trunc(r)), else: Float.to_string(r)
  end

  attr :nodes, :list, required: true
  attr :name, :string, required: true
  attr :filter, :string, default: "all"
  attr :sel, :string, default: nil
  attr :mob, :boolean, default: false

  @doc "One `graphSVG()` at one size. `sel` is the selected node id."
  def graph(assigns) do
    assigns = assign(assigns, :g, layout(assigns.nodes, assigns.mob))

    ~H"""
    <svg
      viewBox={"0 0 #{@g.w} #{@g.h}"}
      role="img"
      aria-label={"#{@name} connections"}
      class={if @mob, do: "m", else: "d"}
    >
      <%= for n <- @g.nodes do %>
        <path
          class={["edge", !vis?(n, @filter) && "dim", n.id == @sel && "hot"]}
          data-e={n.id}
          d={n.d}
          stroke-width={f2(n.w * 1.4)}
        />
        <path
          :if={n.w >= 2}
          class={["flow", !vis?(n, @filter) && "dim"]}
          data-e={n.id}
          d={n.d}
          stroke-width={n.w}
          style={"animation-delay:#{f2(n.flow_delay)}s"}
        />
      <% end %>
      <g class="center">
        <circle class="halo" cx={f2(@g.cx)} cy={f2(@g.cy)} r={@g.r0} />
        <circle cx={f2(@g.cx)} cy={f2(@g.cy)} r={@g.r0} />
        <text
          x={f2(@g.cx)}
          y={f2(@g.cy)}
          text-anchor="middle"
          dominant-baseline="central"
          style="fill:var(--color-base-200);font-weight:800;font-size:20px;font-family:var(--font-sans)"
        >
          {String.first(@name)}
        </text>
      </g>
      <g
        :for={n <- @g.nodes}
        class={["node", "k-#{n.k}", !vis?(n, @filter) && "dim", n.id == @sel && "sel"]}
        data-node={n.id}
        tabindex="0"
        role="button"
        aria-label={n.l}
        phx-click="page_node"
        phx-value-node={n.id}
        phx-keydown="page_node"
      >
        <g class="float" style={"animation-delay:#{f2(n.float_delay)}s"}>
          <circle class="bgc" cx={f2(n.x)} cy={f2(n.y)} r={n.r} />
          <text class="gl" x={f2(n.x)} y={f2(n.y)}>{glyph(n.k)}</text>
          <text x={f2(n.lx)} y={f2(if n.below?, do: n.y + n.r + 13, else: n.y - n.r - 14)}>
            {n.label}
          </text>
          <text
            :if={!@mob}
            class="sm"
            x={f2(n.x)}
            y={f2(if n.below?, do: n.y + n.r + 25, else: n.y - n.r - 3)}
          >
            {n.sub1}
          </text>
        </g>
        <circle cx={f2(n.x)} cy={f2(n.y)} r={n.r + 12} fill="transparent" />
      </g>
    </svg>
    """
  end

  defp vis?(_n, "all"), do: true
  defp vis?(n, filter), do: n.k == filter
end
