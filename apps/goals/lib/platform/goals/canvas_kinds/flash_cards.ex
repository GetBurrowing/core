defmodule Platform.Goals.CanvasKinds.FlashCards do
  @moduledoc "The flash_cards canvas kind: only an ask identity travels in props; the addressed viewer's deck is read at render time."
  use Platform.Chat.Canvas.Kind

  @impl true
  def describe, do: "An addressed goal practice deck. Props contain only ask_id, never card text."
  @impl true
  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["ask_id"],
      "properties" => %{"ask_id" => %{"type" => "string"}}
    }
  end

  @impl true
  def validate_props(props) when is_map(props) do
    if Map.keys(props) == ["ask_id"] && match?({:ok, _}, Ecto.UUID.cast(props["ask_id"])),
      do: :ok,
      else: {:error, "flash_cards takes only ask_id, which must be a UUID"}
  end

  def validate_props(_), do: {:error, "flash_cards takes only ask_id, which must be a UUID"}
  def inline_opens_canvas?, do: false

  attr(:node, :map, required: true)
  attr(:dom_id_scope, :string, default: nil)
  attr(:canvas_id, :string, default: nil)
  attr(:viewer, :any, default: nil)
  @impl true
  def render(assigns) do
    props = assigns.node["props"] || %{}
    scope = assigns[:dom_id_scope] || assigns[:canvas_id] || "x"

    viewer =
      case assigns[:viewer] do
        %Platform.Accounts.User{} = user ->
          user

        {:user, raw_id} ->
          case Ecto.UUID.cast(raw_id) do
            {:ok, id} -> Platform.Accounts.get_user(id)
            _ -> nil
          end

        _ ->
          nil
      end

    assigns =
      assigns
      |> assign(:ask_id, props["ask_id"])
      |> assign(:component_id, "goals-flash-#{scope}-#{assigns.node["id"] || "deck"}")
      |> assign(:viewer, viewer)

    ~H"""
    <.live_component
      module={PlatformWeb.GoalsFlashCardsComponent}
      id={@component_id}
      ask_id={@ask_id}
      viewer={@viewer}
    />
    """
  end
end
