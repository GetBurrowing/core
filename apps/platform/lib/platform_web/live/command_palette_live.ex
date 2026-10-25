defmodule PlatformWeb.CommandPaletteLive do
  @moduledoc """
  The desktop command palette (Burrow redesign 23, stage 2; master-desktop.html
  `#cmdk`). A LiveComponent mounted ONCE in `shell.html.heex`, next to the
  meeting bar, so every shell page carries it with id `"command-palette"`.

  Server-rendered from `PlatformWeb.CommandPalette.Sources` (what the viewer
  may jump to) and `PlatformWeb.CommandPalette.Rank` (in what order). Sources
  is read on `palette_open` only, never on mount: a closed palette costs no
  query.

  ## Events (all `phx-target={@myself}`)

    * `palette_open`: load Sources, reset the query, open.
    * `palette_close`, `palette_toggle`.
    * `palette_query`: the form's `phx-change` (debounced 50ms); re-ranks.
    * `palette_go` `%{"q" => q, "index" => i}`: re-ranks `q` server-side and
      `push_navigate`s to result `i`, or to the first result when `i` is out
      of range; with no result it does nothing. The form's submit sends the
      query as `palette[q]`, which is read the same way.

  Rows are `<.link navigate>` for the mouse. The keyboard is the
  `CommandPalette` hook on the root (assets/js/hooks/command_palette.js,
  stage 4): ⌘K / Ctrl+K toggles at >= 1024px, ArrowDown / ArrowUp move
  `aria-selected` (the server renders row 0 selected; the hook resets to 0
  whenever `data-query` on the listbox changes), Enter pushes `palette_go`
  with the selected index, Escape and a scrim click close.

  ## Boundaries

  The component sends nothing to its parent LiveView and subscribes to
  nothing, so the shell LiveViews' catch-all `handle_info/2` clauses never
  see it. A jump into another `live_session` (e.g. `/chat` to
  `/canvases/:id`) is a `push_navigate` the client turns into a full page
  load; within one session it is a live remount.

  ## Required assigns (from the shell)

  `access_scope`, `current_user_record`, `root_user`, `mask_names?`.
  """

  use PlatformWeb, :live_component

  alias PlatformWeb.CommandPalette.{Rank, Sources}

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:open?, false)
     |> assign(:items, [])
     |> assign_query("")}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     assign(socket,
       access_scope: assigns[:access_scope],
       current_user_record: assigns[:current_user_record],
       root_user: assigns[:root_user] == true,
       mask_names?: assigns[:mask_names?] == true
     )}
  end

  @impl true
  def handle_event("palette_open", _params, socket), do: {:noreply, open(socket)}

  def handle_event("palette_close", _params, socket), do: {:noreply, close(socket)}

  def handle_event("palette_toggle", _params, socket) do
    {:noreply, if(socket.assigns.open?, do: close(socket), else: open(socket))}
  end

  def handle_event("palette_query", params, socket) do
    {:noreply, assign_query(socket, query_param(params))}
  end

  def handle_event("palette_go", params, socket) do
    results = Rank.rank(socket.assigns.items, query_param(params))

    case pick(results, params["index"]) do
      %{path: path} -> {:noreply, socket |> close() |> push_navigate(to: path)}
      nil -> {:noreply, socket}
    end
  end

  defp open(socket) do
    socket
    |> assign(:items, Sources.load(viewer(socket.assigns)))
    |> assign(:open?, true)
    |> assign_query("")
  end

  defp close(socket),
    do: socket |> assign(:open?, false) |> assign(:items, []) |> assign_query("")

  defp viewer(assigns) do
    %{
      access_scope: assigns.access_scope,
      user_id: assigns.current_user_record && assigns.current_user_record.id,
      root_user: assigns.root_user,
      mask_names?: assigns.mask_names?
    }
  end

  defp assign_query(socket, q) do
    socket
    |> assign(:query, q)
    |> assign(:form, to_form(%{"q" => q}, as: :palette))
    |> assign(:results, Rank.rank(socket.assigns[:items] || [], q))
  end

  # A pushed event carries `"q"`; the form's submit and change carry `palette[q]`.
  defp query_param(%{"q" => q}) when is_binary(q), do: q
  defp query_param(%{"palette" => %{"q" => q}}) when is_binary(q), do: q
  defp query_param(_params), do: ""

  defp pick([], _index), do: nil

  defp pick(results, index) do
    case parse_index(index) do
      i when is_integer(i) and i >= 0 and i < length(results) -> Enum.at(results, i)
      _ -> hd(results)
    end
  end

  defp parse_index(i) when is_integer(i), do: i

  defp parse_index(i) when is_binary(i) do
    case Integer.parse(i) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_index(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="command-palette"
      phx-hook="CommandPalette"
      role="dialog"
      aria-modal="true"
      aria-label="Command palette"
      data-open={to_string(@open?)}
      class={[
        "hidden",
        @open? && "fixed inset-0 z-[80] items-start justify-center bg-scrim pt-[12vh] lg:flex"
      ]}
    >
      <div
        :if={@open?}
        id="command-palette-box"
        class="w-[560px] max-w-[92vw] overflow-hidden rounded-box border border-edge bg-base-100 shadow-[var(--shadow-modal)]"
      >
        <.form
          for={@form}
          id="command-palette-form"
          phx-change="palette_query"
          phx-submit="palette_go"
          phx-target={@myself}
        >
          <.input
            field={@form[:q]}
            id="command-palette-input"
            type="text"
            placeholder="Jump to a module, space, person, file…"
            aria-label="Command palette"
            autocomplete="off"
            phx-debounce="50"
            class="h-12 w-full border-0 border-b border-edge bg-transparent px-4 text-base text-base-content outline-none placeholder:text-subtle"
          />
          <input type="hidden" name="index" value="0" />
        </.form>
        <div
          id="command-palette-results"
          role="listbox"
          data-query={@query}
          class="relative max-h-[50vh] overflow-y-auto p-1.5"
        >
          <.link
            :for={{item, n} <- Enum.with_index(@results)}
            navigate={item.path}
            role="option"
            id={"command-palette-row-#{n}"}
            data-index={n}
            aria-selected={to_string(n == 0)}
            class="flex h-[38px] w-full items-center gap-2.5 rounded-field px-2.5 text-left text-sm text-base-content lg:hover:bg-base-300 aria-selected:bg-base-300"
          >
            <span class="w-[22px] shrink-0 text-center" aria-hidden="true">
              <%= case item.kind do %>
                <% "space" -> %>
                  #
                <% "direct" -> %>
                  @
                <% _ -> %>
                  <.icon name={item.icon} class="size-4" />
              <% end %>
            </span>
            <span class="min-w-0 truncate">{item.label}</span>
            <small class="ml-auto shrink-0 text-xs text-subtle">{item.kind}</small>
          </.link>
          <div :if={@results == []} class="p-6 text-center text-sm text-subtle">No match.</div>
        </div>
      </div>
    </div>
    """
  end
end
