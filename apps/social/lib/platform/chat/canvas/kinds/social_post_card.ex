defmodule Platform.Social.CanvasKinds.SocialPostCard do
  @moduledoc """
  The `social_post_card` canvas kind (task 01a140a9-31b0, Social 3/7): a
  post's approval card. The module is `SocialPostCard`, not `PostCard`,
  because `use Platform.Chat.Canvas.Kind` derives the kind name from the
  last module segment.

  ## Seam decision

  No new core seam: ADR 0055's `canvas_kinds` is read per call by
  `Platform.Chat.Canvas.Kinds.all/0`, so `Platform.Social.Extension.canvas_kinds/0`
  registers this kind. The one core edit for the card is generic: the
  inline chat-message canvas path now threads the renderer's `viewer`
  (`PlatformWeb.Components.ChatInlineCanvas`), as the expanded panel
  already did, so a kind can render per viewer in the message row too.

  The interactive part is `PlatformWeb.SocialCardComponent`, a LiveComponent
  rendered here (the `prototype` kind's pattern), because a kind's render
  only sees the renderer's assigns: the per-card open/closed state of the
  edit and reject forms has to live with the card. It does not use
  `canvas_action_click`, which `CanvasHooks` handles and halts first.

  ## Props

  ONLY `card_id` and `rev`; `validate_props/1` refuses anything else, so an
  agent cannot smuggle text into the card. Everything shown is rendered at
  view time by `Platform.Social.Approvals.card_view/2` for the renderer's
  `viewer`.
  """
  use Platform.Chat.Canvas.Kind

  @impl true
  def describe,
    do:
      "A Social post's approval card. Placed by Social only; its props are a card id and a revision, never post text."

  @impl true
  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["card_id"],
      "properties" => %{
        "card_id" => %{"type" => "string"},
        "rev" => %{"type" => "integer"}
      }
    }
  end

  @impl true
  def validate_props(props) when is_map(props) do
    case Map.keys(props) -- ["card_id", "rev"] do
      [] ->
        if is_binary(props["card_id"]) and match?({:ok, _}, Ecto.UUID.cast(props["card_id"])),
          do: :ok,
          else: {:error, "card_id must be a UUID"}

      extra ->
        {:error, "social_post_card takes only card_id and rev, not #{Enum.join(extra, ", ")}"}
    end
  end

  @doc false
  # The card is interactive: a click on it must not open the canvas panel
  # (`PlatformWeb.Chat.CanvasRenderer.opens_on_click?/1`).
  def inline_opens_canvas?, do: false

  attr :node, :map, required: true
  attr :dom_id_scope, :string, default: nil
  attr :canvas_id, :string, default: nil
  attr :viewer, :any, default: nil

  @impl true
  def render(assigns) do
    props = assigns.node["props"] || %{}
    scope = assigns[:dom_id_scope] || assigns[:canvas_id] || "x"

    assigns =
      assigns
      |> assign(:card_id, props["card_id"])
      |> assign(:rev, props["rev"])
      |> assign(:component_id, "social-card-#{scope}")
      |> assign_new(:canvas_id, fn -> nil end)
      |> assign_new(:viewer, fn -> nil end)

    ~H"""
    <.live_component
      module={PlatformWeb.SocialCardComponent}
      id={@component_id}
      card_id={@card_id}
      rev={@rev}
      canvas_id={@canvas_id}
      viewer={@viewer}
    />
    """
  end
end
