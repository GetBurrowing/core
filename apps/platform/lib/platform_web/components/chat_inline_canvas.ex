defmodule PlatformWeb.Components.ChatInlineCanvas do
  @moduledoc """
  The inline canvas inside a chat message row, mounted lazily (task 01a13884
  stage 4).

  Every canvas message in the 50-message window used to render its whole
  `canvas_document` on entry: embed iframes, prototype frames and their
  scripts, all in the switch's main-thread budget, whether or not they were
  anywhere near the viewport. Now a canvas renders as a placeholder until the
  `LazyInlineCanvas` hook sees it within 600px of the scroll viewport and
  pushes `inline_canvas_mount`; `PlatformWeb.ChatLive.MessagesHooks` then adds
  the message id to `:mounted_inline_canvas_ids` and re-inserts the row, and
  this component renders the real document in place of the placeholder.

  ## The wrapper is stable, the child swaps

  `#inline-canvas-<message id>` carries the hook in BOTH states, so the hook
  survives the swap: it sees the placeholder become the document as a resize
  of one element, which is what lets it hold the reader's position when a
  canvas above the viewport mounts and changes height (see
  `assets/js/hooks/lazy_inline_canvas.js`).

  ## Placeholder

  `bg-base-200`, `border-edge`, the canvas kind icon and its title, and
  nothing else: no shimmer, no spinner. It reserves a height so the mount
  moves as little as possible: `reserved_height/1` from the document (the
  embed / prototype declared heights), which the hook replaces with the
  canvas's last measured height when browser storage has one for this
  width, else 240px. The icon and title sit at the TOP of the box, not its
  centre: a declared 720px frame scales to a fraction of that on a 375px
  phone, so the reserved box can be taller than the viewport there.
  The border is `border-edge`, not `border-base-300`: base-300 is a fill
  token since task 01a0740b, and `border_token_direction_test.exs` refuses
  it as a border colour.

  ## Mount-all

  `mounted_ids` is a MapSet of message ids, or `:all`. `:all` renders every
  canvas directly, exactly as before this stage; it is the default so a
  caller that does not thread the assign keeps the old behaviour. Soft-deleted
  canvases always render directly: their document is a one-line notice.
  """

  use Phoenix.Component

  import PlatformWeb.Chat.CanvasRenderer, only: [canvas_document: 1]

  alias Platform.Chat.Canvas.Kinds.Prototype

  @fallback_height 240

  # Allowance for a non-frame child (heading, text) beside a frame in the
  # same document. Only used when the document declares at least one frame.
  @child_allowance 40

  # Kinds whose declared `height` prop is the rendered frame height.
  @frame_kinds ~w(embed prototype)

  # The kind the placeholder names is the heaviest kind in the document, in
  # this order; a document of headings and text names its root kind.
  @kind_rank ~w(prototype embed mermaid image table code form checklist markdown)

  attr(:msg, :map, required: true)
  attr(:canvas, :any, required: true)
  attr(:title, :string, required: true)
  attr(:mounted_ids, :any, default: :all)

  # The viewing actor (`{:user, id}`), passed through to the renderer like the
  # expanded panel's `viewer` (partials.ex), for kinds that render per viewer.
  # nil keeps the old behaviour.
  attr(:viewer, :any, default: nil)

  def inline_canvas(assigns) do
    assigns =
      assign(assigns, :mounted?, mounted?(assigns.mounted_ids, assigns.msg, assigns.canvas))

    ~H"""
    <div
      id={"inline-canvas-#{@msg.id}"}
      phx-hook="LazyInlineCanvas"
      data-message-id={@msg.id}
      data-canvas-id={@canvas.id}
      data-mounted={to_string(@mounted?)}
      class="min-w-0 overflow-hidden"
    >
      <.canvas_document
        :if={@mounted?}
        canvas={@canvas}
        inline={true}
        dom_id_base="chat-message-inline"
        viewer={@viewer}
      />
      <div
        :if={!@mounted?}
        data-role="inline-canvas-placeholder"
        data-reserved-height={reserved_height(@canvas)}
        style={"height: #{reserved_height(@canvas)}px;"}
        class="flex items-start justify-center gap-2 rounded-xl border border-edge bg-base-200 px-4 pt-6 text-sm text-base-content"
      >
        <span class={[kind_icon(@canvas), "size-4 shrink-0"]} aria-hidden="true"></span>
        <span class="truncate">{@title}</span>
      </div>
    </div>
    """
  end

  @doc "Whether the row renders its canvas document rather than the placeholder."
  @spec mounted?(MapSet.t() | :all, map(), map()) :: boolean()
  def mounted?(:all, _msg, _canvas), do: true
  def mounted?(_ids, _msg, %{deleted_at: deleted_at}) when not is_nil(deleted_at), do: true
  def mounted?(%MapSet{} = ids, %{id: id}, _canvas), do: MapSet.member?(ids, id)
  def mounted?(_ids, _msg, _canvas), do: true

  @doc """
  The placeholder's server-side height in pixels: the sum of the declared
  heights of the document's embed and prototype frames plus a small
  allowance per other top-level child, or 240 when it declares none.
  """
  @spec reserved_height(map()) :: pos_integer()
  def reserved_height(%{document: %{"root" => root}}) when is_map(root) do
    case frame_heights(root) do
      [] ->
        @fallback_height

      heights ->
        others =
          root
          |> Map.get("children", [])
          |> List.wrap()
          |> Enum.count(&(not frame_node?(&1)))

        Enum.sum(heights) + others * @child_allowance
    end
  end

  def reserved_height(_canvas), do: @fallback_height

  defp frame_heights(%{"type" => type} = node) when type in @frame_kinds,
    do: [Prototype.height(Map.get(node, "props") || %{})]

  defp frame_heights(%{"children" => children}) when is_list(children),
    do: Enum.flat_map(children, &frame_heights/1)

  defp frame_heights(_node), do: []

  defp frame_node?(node), do: frame_heights(node) != []

  @doc "The hero icon class naming the canvas's heaviest kind."
  @spec kind_icon(map()) :: String.t()
  def kind_icon(%{document: %{"root" => root}}) when is_map(root) do
    types = node_types(root)

    @kind_rank
    |> Enum.find(&MapSet.member?(types, &1))
    |> icon_for()
  end

  def kind_icon(_canvas), do: icon_for(nil)

  defp node_types(%{"type" => type} = node) do
    node
    |> Map.get("children", [])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(MapSet.new([type]), &MapSet.union(&2, node_types(&1)))
  end

  defp node_types(_node), do: MapSet.new()

  defp icon_for("prototype"), do: "hero-device-phone-mobile"
  defp icon_for("embed"), do: "hero-window"
  defp icon_for("mermaid"), do: "hero-share"
  defp icon_for("image"), do: "hero-photo"
  defp icon_for("table"), do: "hero-table-cells"
  defp icon_for("code"), do: "hero-code-bracket"
  defp icon_for("form"), do: "hero-pencil-square"
  defp icon_for("checklist"), do: "hero-check-circle"
  defp icon_for("markdown"), do: "hero-document-text"
  defp icon_for(_), do: "hero-rectangle-group"
end
