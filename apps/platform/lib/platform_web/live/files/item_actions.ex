defmodule PlatformWeb.Files.ItemActions do
  @moduledoc "Rung-17 browser affordances; all eligibility is rechecked on commands."
  use Phoenix.Component
  import PlatformWeb.CoreComponents, only: [icon: 1, input: 1]
  alias Platform.Files.BrowserActions
  alias PlatformWeb.Files.BrowserView
  alias PlatformWeb.Components.Sheet

  def allowed?(viewer, target, action) do
    case BrowserActions.eligible(viewer, target) do
      {:ok, actions} -> action in actions
      _ -> false
    end
  end

  attr :browser, :map, required: true
  attr :labels, :map, required: true

  def scope_chip(assigns) do
    ~H"""
    <div :if={match?({:space, _}, @browser.node)} class="px-4 pb-2">
      <.link
        patch={BrowserView.browser_path(%{"tab" => "browse"}, %{})}
        data-role="files-scope-chip"
        class="inline-flex min-h-8 max-w-full items-center gap-2 rounded-full border border-base-300 px-3 text-[13px] text-base-content focus-visible-ring"
      >
        <span class="truncate">
          In {Map.get(@labels.spaces, elem(@browser.node, 1).id, @labels.unknown_space)}
        </span>
        <span aria-hidden="true">×</span><span class="sr-only">Remove space scope</span>
      </.link>
    </div>
    """
  end

  def highlight(%{node: {:space, _}, params: %{"highlight" => id}, items: items}) do
    if Enum.any?(items, &(&1.kind == :canvas && &1.id == id)), do: id
  end

  def highlight(_), do: nil

  attr :canvas, :map, required: true
  attr :viewer, :map, required: true
  attr :revision, :integer, default: 0

  def canvas_star(assigns) do
    actions =
      case BrowserActions.eligible(assigns.viewer, {:canvas, assigns.canvas.id}) do
        {:ok, actions} -> actions
        _ -> []
      end

    assigns = assign(assigns, actions: actions, starred?: :unstar in actions)

    ~H"""
    <button
      :if={@actions != []}
      type="button"
      phx-click="canvas_personal_star"
      phx-value-starred={to_string(!@starred?)}
      aria-label={if @starred?, do: "Unstar", else: "Star"}
      aria-pressed={to_string(@starred?)}
      data-role="canvas-personal-star"
      class="btn btn-ghost btn-xs order-3 text-base-content focus-visible-ring"
    >
      <.icon name={if @starred?, do: "hero-star-solid", else: "hero-star"} class="size-4" />
    </button>
    """
  end

  attr :item, :map, required: true
  attr :viewer, :map, required: true

  attr :revision, :integer, default: 0

  def affordances(assigns) do
    actions =
      case BrowserActions.eligible(assigns.viewer, {assigns.item.kind, assigns.item.id}) do
        {:ok, actions} -> actions
        _ -> []
      end

    assigns = assign(assigns, actions: actions, starred?: :unstar in actions)

    ~H"""
    <div
      :if={@actions != []}
      class="browser-item-actions absolute right-1 top-1 z-10 hidden items-center rounded-field bg-base-100 lg:flex"
    >
      <button
        type="button"
        phx-click="browser_command"
        phx-value-kind={@item.kind}
        phx-value-id={@item.id}
        phx-value-action={if @starred?, do: "unstar", else: "star"}
        aria-label={if @starred?, do: "Unstar", else: "Star"}
        aria-pressed={to_string(@starred?)}
        data-role="browser-star"
        class="inline-flex size-8 items-center justify-center text-base-content focus-visible-ring"
      >
        <.icon name={if @starred?, do: "hero-star-solid", else: "hero-star"} class="size-4" />
      </button>
      <button
        type="button"
        phx-click="browser_open_actions"
        phx-value-kind={@item.kind}
        phx-value-id={@item.id}
        aria-label="Item actions"
        aria-haspopup="dialog"
        data-role="browser-ellipsis"
        class="inline-flex size-8 items-center justify-center text-base-content focus-visible-ring"
      >
        <.icon name="hero-ellipsis-horizontal" class="size-5" />
      </button>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :class, :string, default: nil

  def title_field(assigns) do
    assigns = assign(assigns, :form, to_form(%{"title" => assigns.item.title}, as: nil))

    ~H"""
    <.form
      for={@form}
      id={"browser-rename-" <> @item.id}
      phx-submit="browser_rename"
      phx-window-keydown="browser_cancel_rename"
      phx-key="Escape"
      class={@class}
    >
      <.input
        field={@form[:title]}
        aria-label="Item title"
        phx-mounted={Phoenix.LiveView.JS.focus()}
        maxlength="255"
        required
        class="input input-sm w-full border-base-300 bg-base-100 text-[15px] text-base-content"
      />
      <button class="sr-only" type="submit">Save title</button>
    </.form>
    """
  end

  attr :state, :any, default: nil
  attr :labels, :map, required: true

  def panels(assigns) do
    ~H"""
    <Sheet.sheet
      id="browser-action-sheet"
      open={@state != nil}
      placement={:bottom}
      on_close="browser_close_actions"
      handle_close
      swipe_dismiss
      class="lg:hidden"
    >
      <:title>{panel_title(@state)}</:title>
      <.body :if={@state} state={@state} labels={@labels} suffix="phone" />
    </Sheet.sheet>
    <div
      :if={@state}
      id="browser-action-popover"
      role="dialog"
      aria-label={panel_title(@state)}
      phx-mounted={Phoenix.LiveView.JS.focus_first()}
      phx-click-away="browser_close_actions"
      phx-window-keydown="browser_close_actions"
      phx-key="Escape"
      class="fixed right-6 top-28 z-50 hidden max-h-[75vh] w-80 overflow-y-auto rounded-box border border-base-300 bg-base-100 p-2 shadow-lg lg:block"
    >
      <.body state={@state} labels={@labels} suffix="desktop" />
    </div>
    """
  end

  attr :state, :map, required: true
  attr :labels, :map, required: true
  attr :suffix, :string, required: true

  defp body(assigns) do
    ~H"""
    <div data-role="browser-action-body" data-mode={@state.mode}>
      <p class="px-4 py-2 text-[15px] font-semibold text-base-content">{@state.item.title}</p>
      <%= case @state.mode do %>
        <% :menu -> %>
          <button
            :for={action <- @state.actions}
            type="button"
            phx-click="browser_command"
            phx-value-kind={elem(@state.target, 0)}
            phx-value-id={elem(@state.target, 1)}
            phx-value-action={action}
            data-role="browser-action"
            data-action={action}
            class={[row_class(), action == :delete && "text-error"]}
          >
            {word(action)}
          </button>
        <% :move -> %>
          <p class="px-4 py-2 text-[13px] text-subtle">Choose a space</p>
          <button
            :for={space <- @state.destinations}
            type="button"
            phx-click="browser_move"
            phx-value-space_id={space.id}
            data-role="browser-move-space"
            data-space-id={space.id}
            aria-current={if space.id == @state.item.space_id, do: "location", else: "false"}
            class={[
              row_class(),
              "relative",
              space.id == @state.item.space_id &&
                "before:absolute before:inset-y-2 before:left-0 before:w-[3px] before:rounded-full before:bg-base-content"
            ]}
          >
            {Map.get(@labels.spaces, space.id, @labels.unknown_space)}
          </button>
          <p :if={@state.destinations == []} class="px-4 py-2 text-sm text-subtle">
            No writable spaces available.
          </p>
        <% :delete -> %>
          <p data-role="browser-delete-confirm-copy" class="px-4 py-2 text-[15px] text-base-content">
            Delete ‘{@state.item.title}’? People with the link will lose access.
          </p>
          <button
            type="button"
            phx-click="browser_confirm_delete"
            data-role="browser-confirm-delete"
            class={[row_class(), "text-error"]}
          >
            Delete
          </button>
      <% end %>
      <button type="button" phx-click="browser_close_actions" class={row_class()}>Cancel</button>
    </div>
    """
  end

  attr :toast, :any, default: nil

  def undo(assigns) do
    ~H"""
    <div
      :if={@toast}
      id="browser-undo-toast"
      role="status"
      aria-live="polite"
      class="fixed inset-x-4 bottom-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px)+1rem)] z-50 mx-auto flex w-fit max-w-[calc(100vw-2rem)] items-center gap-3 rounded-box border border-base-300 bg-base-100 px-4 py-2 text-base-content shadow-lg"
    >
      <span class="truncate">{@toast.name} deleted</span><button
        type="button"
        phx-click="browser_undo"
        data-role="browser-undo"
        class="btn btn-ghost min-h-11"
      >Undo</button>
    </div>
    """
  end

  defp row_class,
    do:
      "flex min-h-11 w-full items-center px-4 py-2 text-left text-[15px] text-base-content active:bg-base-200 focus-visible-ring"

  defp word(:star), do: "Star"
  defp word(:unstar), do: "Unstar"
  defp word(:rename), do: "Rename"
  defp word(:move), do: "Move"
  defp word(:delete), do: "Delete"
  defp panel_title(nil), do: "Item actions"
  defp panel_title(%{mode: :move}), do: "Move"
  defp panel_title(%{mode: :delete}), do: "Delete"
  defp panel_title(_), do: "Item actions"
end
