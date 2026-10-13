defmodule Platform.Chat.Canvas.Kinds.Prototype do
  @moduledoc """
  A published, versioned prototype bundle framed in a canvas (ADR 0057; task
  01a1316b-4e46 stage 2). The bytes are published with `prototype_publish` (or
  the New canvas form) and served sealed from `/proto/<id>/<version>/` by
  `PlatformWeb.PrototypeController`.

  ## Props

    * `prototype_id` (string, required) — the prototype's UUID.
    * `version` (integer >= 1, optional) — pin a version. Absent follows the
      prototype's latest version.
    * `height` / `width` / `min_scale` — exactly `embed`'s defaults and ranges
      (height 400 in 100..2000, width 1080 in 320..2400, min_scale 0.0..1.0),
      read by the same `EmbedCanvasScale` auto-scale hook.

  ## Where the data comes from: a LiveComponent, not a preload

  The bar shows the version number, its timestamp, the version list and its
  publishers, and whether the shown version was removed by retention.
  `render/1` is a function component that re-runs on every canvas patch, so a
  query in it would be a query per patch per node. It renders
  `PlatformWeb.Components.Canvases.PrototypeFrame` instead, which loads once in
  `update/2` and only reloads when the node's `prototype_id`/`version` or the
  canvas changes. A batched preload in the render path was the alternative;
  it would have had to be threaded through every one of the dozen call sites
  that render a canvas document.

  ## The seal

  The iframe carries `sandbox="allow-scripts"` and nothing else (no
  allow-same-origin, allow-popups, allow-top-navigation or allow-forms). That
  attribute is the second layer: the sandbox CSP the serve route sends on
  every bundle file is the real one.

  ## Org scoping

  A canvas in a space of org X never frames a prototype of org Y: the
  component checks the canvas's space org against the prototype's org and
  renders a neutral "not available" panel on a mismatch, the same panel an
  unknown id gets (`Platform.Prototypes.frame_view/3`). The serve route's 404
  for non-members is the backstop.
  """

  use Platform.Chat.Canvas.Kind

  alias PlatformWeb.Components.Canvases.PrototypeFrame

  @default_height 400
  @min_height 100
  @max_height 2000
  @default_width 1080
  @min_width 320
  @max_width 2400

  @doc "Embed's default iframe height."
  def default_height, do: @default_height

  @doc "Embed's default declared width."
  def default_width, do: @default_width

  @impl Platform.Chat.Canvas.Kind
  def children, do: :none

  @doc """
  An interactive kind: the bar's buttons and the frame itself take clicks, so
  an inline preview must not turn every click into "open the canvas"
  (`PlatformWeb.Chat.CanvasRenderer` convention).
  """
  def inline_opens_canvas?, do: false

  @impl Platform.Chat.Canvas.Kind
  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["prototype_id"],
      "properties" => %{
        "prototype_id" => %{
          "type" => "string",
          "description" =>
            "UUID of a published prototype in this space's org (from prototype_publish)."
        },
        "version" => %{
          "type" => "integer",
          "minimum" => 1,
          "description" => "Pin this version. Omit to follow the latest version."
        },
        "height" => %{
          "type" => "integer",
          "minimum" => @min_height,
          "maximum" => @max_height,
          "description" => "Frame height in pixels (default 400)."
        },
        "width" => %{
          "type" => "integer",
          "minimum" => @min_width,
          "maximum" => @max_width,
          "description" =>
            "Declared design width in pixels (default 1080). " <>
              "Drives client-side auto-scale on narrower viewports."
        },
        "min_scale" => %{
          "type" => "number",
          "minimum" => 0.0,
          "maximum" => 1.0,
          "description" =>
            "Smallest allowed auto-scale ratio (0.0..1.0). " <>
              "Below this floor, fall back to horizontal scroll at natural size."
        }
      }
    }
  end

  @impl true
  def validate_props(props) when is_map(props) do
    with :ok <- validate_prototype_id(Map.get(props, "prototype_id")),
         :ok <- validate_version(Map.get(props, "version")),
         :ok <- validate_height(Map.get(props, "height")),
         :ok <- validate_width(Map.get(props, "width")) do
      validate_min_scale(Map.get(props, "min_scale"))
    end
  end

  defp validate_prototype_id(id) do
    if Platform.UUID.valid?(id),
      do: :ok,
      else: {:error, "prototype_id must be the UUID of a published prototype"}
  end

  defp validate_version(nil), do: :ok
  defp validate_version(v) when is_integer(v) and v >= 1, do: :ok
  defp validate_version(_), do: {:error, "version must be an integer >= 1"}

  defp validate_height(nil), do: :ok
  defp validate_height(h) when is_integer(h) and h in @min_height..@max_height, do: :ok
  defp validate_height(_), do: {:error, "height must be between 100 and 2000 pixels"}

  defp validate_width(nil), do: :ok
  defp validate_width(w) when is_integer(w) and w in @min_width..@max_width, do: :ok
  defp validate_width(_), do: {:error, "width must be an integer between 320 and 2400 pixels"}

  defp validate_min_scale(nil), do: :ok
  defp validate_min_scale(s) when is_number(s) and s >= 0.0 and s <= 1.0, do: :ok
  defp validate_min_scale(_), do: {:error, "min_scale must be a number between 0.0 and 1.0"}

  @doc "Clamp a `height` prop to embed's range, or embed's default."
  def height(%{"height" => h}) when is_integer(h) and h in @min_height..@max_height, do: h
  def height(_), do: @default_height

  @doc "Clamp a `width` prop to embed's range, or embed's default."
  def width(%{"width" => w}) when is_integer(w) and w in @min_width..@max_width, do: w
  def width(_), do: @default_width

  @doc "A valid `min_scale` prop, or nil."
  def min_scale(%{"min_scale" => s}) when is_number(s) and s >= 0.0 and s <= 1.0, do: s
  def min_scale(_), do: nil

  attr(:node, :map, required: true)
  attr(:dom_id_scope, :string, default: nil)
  attr(:canvas_id, :string, default: nil)
  attr(:viewer, :any, default: nil)

  @impl Platform.Chat.Canvas.Kind
  def render(assigns) do
    node_id = assigns.node["id"] || "prototype"

    frame_id =
      case assigns[:dom_id_scope] do
        scope when is_binary(scope) and scope != "" -> "prototype-#{node_id}-#{scope}"
        _ -> "prototype-#{node_id}"
      end

    assigns =
      assigns
      |> assign(:frame_id, frame_id)
      |> assign(:frame_module, PrototypeFrame)
      |> assign_new(:canvas_id, fn -> nil end)
      |> assign_new(:viewer, fn -> nil end)

    ~H"""
    <.live_component
      module={@frame_module}
      id={@frame_id}
      node={@node}
      canvas_id={@canvas_id}
      viewer={@viewer}
    />
    """
  end
end
