defmodule PlatformWeb.AgentPortrait do
  @moduledoc """
  An agent's face (task 01a1b6ad stage 1): one of the character builder's
  eight generated glyph portraits as inline SVG, or the agent's uploaded
  image, which always wins.

  The SVG markup is the comp's `POR` (burrow-agents.js), verbatim. Each
  shape carries a class (`.bg`, `.a`, `.c`, `.d`, `.k`, `.w`, `.s`,
  `.sa`) that app.css paints from `var(--ag)`, so a portrait wears whatever
  slot its container points `--ag` at. Pass `color` to set that slot here
  with `data-agent-slot`; leave it nil to inherit the container's.

  An uploaded image is `agents.avatar_url` (written by
  `PlatformWeb.ControlCenter.AgentAvatarUpload`); when it is set the SVG
  is not rendered at all.
  """
  use Phoenix.Component

  alias Platform.Agents.{Agent, Archetypes, ColorPalette}

  @svg %{
    "orbit" =>
      "<circle class=\"bg\" cx=\"50\" cy=\"50\" r=\"50\"/><ellipse class=\"sa\" cx=\"50\" cy=\"54\" rx=\"40\" ry=\"12\" transform=\"rotate(-18 50 54)\" opacity=\".55\"/><circle class=\"a\" cx=\"50\" cy=\"52\" r=\"24\"/><circle class=\"c\" cx=\"42\" cy=\"44\" r=\"7\" opacity=\".55\"/><g class=\"eye\"><circle class=\"k\" cx=\"42\" cy=\"53\" r=\"3.6\"/><circle class=\"k\" cx=\"58\" cy=\"53\" r=\"3.6\"/></g><path class=\"s\" d=\"M44 62q6 4 12 0\"/><path class=\"sa\" d=\"M14 62q36 22 74-16\" opacity=\".9\"/><circle class=\"a\" cx=\"82\" cy=\"30\" r=\"4\"/>",
    "visor" =>
      "<circle class=\"bg\" cx=\"50\" cy=\"50\" r=\"50\"/><path class=\"sa\" d=\"M50 22V12\"/><circle class=\"a\" cx=\"50\" cy=\"10\" r=\"4\"/><rect class=\"a\" x=\"25\" y=\"22\" width=\"50\" height=\"50\" rx=\"15\"/><rect class=\"k\" x=\"30\" y=\"38\" width=\"40\" height=\"14\" rx=\"7\"/><g class=\"eye\"><rect class=\"a\" x=\"36\" y=\"42\" width=\"9\" height=\"6\" rx=\"3\"/><rect class=\"a\" x=\"55\" y=\"42\" width=\"9\" height=\"6\" rx=\"3\"/></g><rect class=\"d\" x=\"38\" y=\"60\" width=\"24\" height=\"4\" rx=\"2\"/><rect class=\"c\" x=\"18\" y=\"40\" width=\"7\" height=\"14\" rx=\"3\"/><rect class=\"c\" x=\"75\" y=\"40\" width=\"7\" height=\"14\" rx=\"3\"/><rect class=\"a\" x=\"32\" y=\"74\" width=\"36\" height=\"20\" rx=\"8\"/>",
    "owl" =>
      "<circle class=\"bg\" cx=\"50\" cy=\"50\" r=\"50\"/><path class=\"a\" d=\"M24 30l10 10h32l10-10v40a26 24 0 0 1-52 0z\"/><circle class=\"w\" cx=\"39\" cy=\"50\" r=\"11\"/><circle class=\"w\" cx=\"61\" cy=\"50\" r=\"11\"/><g class=\"eye\"><circle class=\"k\" cx=\"39\" cy=\"51\" r=\"5.5\"/><circle class=\"k\" cx=\"61\" cy=\"51\" r=\"5.5\"/></g><path class=\"d\" d=\"M46 60l4 7 4-7z\"/><path class=\"c\" d=\"M36 72q14 8 28 0q-14 14-28 0z\"/>",
    "quill" =>
      "<circle class=\"bg\" cx=\"50\" cy=\"50\" r=\"50\"/><circle class=\"a\" cx=\"48\" cy=\"54\" r=\"25\"/><circle class=\"s\" cx=\"39\" cy=\"52\" r=\"7\"/><circle class=\"s\" cx=\"58\" cy=\"52\" r=\"7\"/><path class=\"s\" d=\"M46 52h5\"/><g class=\"eye\"><circle class=\"k\" cx=\"39\" cy=\"52\" r=\"2.2\"/><circle class=\"k\" cx=\"58\" cy=\"52\" r=\"2.2\"/></g><path class=\"s\" d=\"M42 66q6 3 12 0\"/><path class=\"c\" d=\"M70 14c10 6 12 22 2 34l-6 4c-2-12-1-26 4-38z\"/><path class=\"sa\" d=\"M66 52l8-30\"/>",
    "spark" =>
      "<circle class=\"bg\" cx=\"50\" cy=\"50\" r=\"50\"/><path class=\"a\" d=\"M50 12l9 22 23-4-15 18 15 18-23-4-9 22-9-22-23 4 15-18-15-18 23 4z\"/><circle class=\"c\" cx=\"50\" cy=\"50\" r=\"15\"/><g class=\"eye\"><circle class=\"k\" cx=\"45\" cy=\"48\" r=\"2.8\"/><circle class=\"k\" cx=\"55\" cy=\"48\" r=\"2.8\"/></g><path class=\"s\" d=\"M45 55q5 4 10 0\" style=\"stroke-width:2.6\"/>",
    "ghost" =>
      "<circle class=\"bg\" cx=\"50\" cy=\"50\" r=\"50\"/><path class=\"a\" d=\"M26 82V48a24 24 0 0 1 48 0v34l-8-6-8 6-8-6-8 6-8-6z\"/><g class=\"eye\"><ellipse class=\"k\" cx=\"41\" cy=\"50\" rx=\"4\" ry=\"6\"/><ellipse class=\"k\" cx=\"59\" cy=\"50\" rx=\"4\" ry=\"6\"/></g><circle class=\"c\" cx=\"35\" cy=\"60\" r=\"4\" opacity=\".8\"/><circle class=\"c\" cx=\"65\" cy=\"60\" r=\"4\" opacity=\".8\"/><path class=\"s\" d=\"M46 62q4 3 8 0\"/>",
    "fox" =>
      "<circle class=\"bg\" cx=\"50\" cy=\"50\" r=\"50\"/><path class=\"a\" d=\"M22 20l18 18h20l18-18-2 34c0 18-12 30-26 30S24 72 24 54z\"/><path class=\"d\" d=\"M28 28l9 10M72 28l-9 10\" style=\"stroke:var(--ground);stroke-width:3;opacity:.4\"/><path class=\"c\" d=\"M34 60q16-8 32 0q-4 18-16 20q-12-2-16-20z\"/><g class=\"eye\"><path class=\"k\" d=\"M36 50q5-5 10 0q-5 3-10 0z\"/><path class=\"k\" d=\"M54 50q5-5 10 0q-5 3-10 0z\"/></g><circle class=\"k\" cx=\"50\" cy=\"66\" r=\"3.2\"/>",
    "cube" =>
      "<circle class=\"bg\" cx=\"50\" cy=\"50\" r=\"50\"/><path class=\"c\" d=\"M50 16l30 16-30 16-30-16z\"/><path class=\"a\" d=\"M20 32l30 16v36L20 68z\"/><path class=\"d\" d=\"M80 32L50 48v36l30-16z\"/><g class=\"eye\"><circle class=\"k\" cx=\"31\" cy=\"54\" r=\"3.2\"/><circle class=\"k\" cx=\"41\" cy=\"59\" r=\"3.2\"/></g><path class=\"s\" d=\"M31 66q5 5 10 5\" style=\"stroke-width:2.6\"/><circle class=\"w\" cx=\"64\" cy=\"58\" r=\"2.4\" opacity=\".7\"/><circle class=\"w\" cx=\"70\" cy=\"54\" r=\"2.4\" opacity=\".7\"/>"
  }

  @default "orbit"

  @doc "The SVG body of portrait `id`; an unknown id is orbit's, as in the comp."
  def svg(id), do: Map.get(@svg, id, @svg[@default])

  @doc "The portrait ids the component draws."
  def ids, do: Map.keys(@svg)

  attr(:agent, Agent, default: nil, doc: "reads portrait, colour and avatar_url from the agent")
  attr(:portrait, :string, default: nil)
  attr(:color, :string, default: nil, doc: "a ColorPalette slot id; nil inherits --ag")
  attr(:avatar_url, :string, default: nil)
  attr(:name, :string, default: nil)
  attr(:size, :integer, default: 48)
  attr(:class, :any, default: nil)
  attr(:rest, :global)

  def agent_portrait(assigns) do
    agent = assigns.agent
    character = (agent && (agent.metadata || %{})["character"]) || %{}

    portrait = assigns.portrait || character["portrait"] || default_for(character)
    color = assigns.color || (agent && agent.color)
    avatar_url = blank_to_nil(assigns.avatar_url || (agent && agent.avatar_url))

    assigns
    |> assign(:portrait, if(Map.has_key?(@svg, portrait), do: portrait, else: @default))
    |> assign(:slot, color && ColorPalette.slot_for(color))
    |> assign(:avatar_url, avatar_url)
    |> assign(:name, assigns.name || (agent && agent.name))
    |> render_portrait()
  end

  defp render_portrait(assigns) do
    ~H"""
    <span
      class={["ba-por", @class]}
      style={"width:#{@size}px;height:#{@size}px"}
      data-agent-slot={@slot}
      data-portrait={@portrait}
      data-portrait-mode={if @avatar_url, do: "image", else: "svg"}
      {@rest}
    >
      <img :if={@avatar_url} src={@avatar_url} alt={@name || ""} />
      <svg :if={!@avatar_url} viewBox="0 0 100 100" aria-hidden="true">
        {Phoenix.HTML.raw(svg(@portrait))}
      </svg>
    </span>
    """
  end

  defp default_for(%{"archetype" => id}) when is_binary(id), do: Archetypes.fetch(id).portrait
  defp default_for(_), do: @default

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(s) when is_binary(s) do
    if String.trim(s) == "", do: nil, else: s
  end
end
