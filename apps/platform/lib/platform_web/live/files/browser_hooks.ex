defmodule PlatformWeb.Files.BrowserHooks do
  @moduledoc "Live browser commands and private star invalidation (rung 17)."
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView
  alias Platform.{Chat, Files}
  alias Platform.Files.{Browser, BrowserActions, Stars}
  alias PlatformWeb.FilesLive

  def attach(socket) do
    if connected?(socket), do: Stars.subscribe(socket.assigns.viewer)

    socket
    |> assign(
      browser_revision: 0,
      browser_action: nil,
      browser_editing: nil,
      browser_undo: nil,
      browser_topics: MapSet.new()
    )
    |> subscriptions()
    |> attach_hook(:browser_commands, :handle_event, &event/3)
    |> attach_hook(:browser_changes, :handle_info, &info/2)
    |> attach_hook(:browser_starred, :handle_params, &params/3)
  end

  defp params(%{"tab" => "starred"} = params, _uri, socket),
    do: {:halt, starred(socket, params)}

  defp params(_params, _uri, socket),
    do: {:cont, assign(socket, browser_action: nil, browser_editing: nil)}

  defp starred(socket, params) do
    type =
      Map.get(
        %{
          "canvas" => :canvas,
          "file" => :file,
          "doc" => :doc,
          "image" => :image,
          "game" => :game
        },
        params["type"]
      )

    type = if type == :game && !socket.assigns.games?, do: nil, else: type
    %{items: items, capped?: capped?} = Stars.list_items(socket.assigns.viewer)
    socket = FilesLive.apply_browser_params(socket, %{})

    browser = %{
      socket.assigns.browser
      | mode: :starred,
        node: nil,
        items: Browser.filter(items, type),
        type: type,
        capped?: capped?,
        params: Map.take(params, ["tab", "type"])
    }

    assign(socket,
      browser: browser,
      page_title: "Starred",
      browser_action: nil,
      browser_editing: nil
    )
  end

  def refresh(socket) do
    viewer =
      case BrowserActions.viewer(socket.assigns.viewer) do
        {:ok, viewer} -> viewer
        _ -> %{user: nil, access_scope: nil}
      end

    params = socket.assigns.browser.params

    socket =
      socket
      |> assign(
        viewer: viewer,
        tree: Browser.tree(viewer),
        selected_project_id: nil,
        browser_revision: socket.assigns.browser_revision + 1,
        browser_action: nil,
        browser_editing: nil
      )
      |> subscriptions()

    if params["tab"] == "starred",
      do: starred(socket, params),
      else: FilesLive.apply_browser_params(socket, params)
  end

  defp subscriptions(socket) do
    if connected?(socket) do
      tree = socket.assigns.tree
      spaces = Enum.flat_map(tree.orgs, & &1.spaces) ++ tree.other.spaces
      projects = Enum.flat_map(tree.orgs, & &1.projects) ++ tree.other.projects

      topics =
        MapSet.new(
          Enum.map(spaces, &Chat.PubSub.space_topic(&1.id)) ++
            Enum.map(projects, &Files.project_topic(&1.id))
        )

      old = socket.assigns.browser_topics
      Enum.each(MapSet.difference(old, topics), &Phoenix.PubSub.unsubscribe(Platform.PubSub, &1))
      Enum.each(MapSet.difference(topics, old), &Phoenix.PubSub.subscribe(Platform.PubSub, &1))
      assign(socket, :browser_topics, topics)
    else
      socket
    end
  end

  def request_file_delete(socket, id) do
    {:halt, socket} =
      event("browser_command", %{"kind" => "file", "id" => id, "action" => "delete"}, socket)

    socket
  end

  defp event("browser_open_actions", params, socket) do
    with {:ok, target} <- target(params),
         {:ok, item} <- Browser.fetch_item(socket.assigns.viewer, target),
         {:ok, actions} <- BrowserActions.eligible(socket.assigns.viewer, target) do
      {:halt,
       assign(socket,
         browser_action: %{mode: :menu, target: target, item: item, actions: actions},
         browser_editing: nil
       )}
    else
      _ -> {:halt, deny(socket)}
    end
  end

  defp event("browser_close_actions", _params, socket),
    do: {:halt, assign(socket, :browser_action, nil)}

  defp event("browser_command", %{"action" => action} = params, socket) do
    with {:ok, target} <- target(params),
         {:ok, item} <- Browser.fetch_item(socket.assigns.viewer, target),
         {:ok, actions} <- BrowserActions.eligible(socket.assigns.viewer, target) do
      command(action, target, item, actions, socket)
    else
      _ -> {:halt, deny(socket)}
    end
  end

  defp event("browser_move", %{"space_id" => space_id}, socket) do
    case socket.assigns.browser_action do
      %{mode: :move, target: target} -> mutate(socket, target, :move, %{space_id: space_id})
      _ -> {:halt, socket}
    end
  end

  defp event("browser_confirm_delete", _params, socket) do
    case socket.assigns.browser_action do
      %{mode: :delete, target: {:file, id}} ->
        with {:ok, file} <- Browser.fetch_source(socket.assigns.viewer, {:file, id}) do
          {:noreply, socket} =
            FilesLive.confirm_file_delete(socket, socket.assigns.viewer.user, file)

          {:halt, socket |> assign(browser_action: nil, browser_editing: nil) |> refresh()}
        else
          _ -> {:halt, deny(socket)}
        end

      %{mode: :delete, target: target, item: item} ->
        case BrowserActions.execute(socket.assigns.viewer, target, :delete) do
          {:ok, _} ->
            token = make_ref()
            Process.send_after(self(), {:clear_browser_undo, token}, 8_000)

            {:halt,
             socket
             |> assign(browser_action: nil, browser_editing: nil)
             |> refresh()
             |> assign(:browser_undo, %{target: target, name: item.title, token: token})}

          _ ->
            {:halt, deny(socket)}
        end

      _ ->
        {:halt, socket}
    end
  end

  defp event("browser_undo", _params, socket) do
    case socket.assigns.browser_undo do
      %{target: target} -> mutate(assign(socket, :browser_undo, nil), target, :undo, %{})
      _ -> {:halt, socket}
    end
  end

  defp event("browser_rename", %{"title" => title}, socket) do
    case socket.assigns.browser_editing do
      nil -> {:halt, socket}
      target -> mutate(socket, target, :rename, %{title: title})
    end
  end

  defp event("browser_cancel_rename", _params, socket),
    do: {:halt, assign(socket, :browser_editing, nil)}

  defp event(event, _params, socket)
       when event in ["browser_command", "browser_move", "browser_rename"],
       do: {:halt, deny(socket)}

  defp event(_event, _params, socket), do: {:cont, socket}

  defp command(action, target, item, actions, socket) do
    case Enum.find(actions, &(Atom.to_string(&1) == action)) do
      star when star in [:star, :unstar] ->
        mutate(socket, target, star, %{})

      :rename ->
        {:halt, assign(socket, browser_action: nil, browser_editing: target)}

      :move ->
        case BrowserActions.move_destinations(socket.assigns.viewer, target) do
          {:ok, destinations} ->
            {:halt,
             assign(socket, :browser_action, %{
               mode: :move,
               target: target,
               item: item,
               destinations: destinations
             })}

          _ ->
            {:halt, deny(socket)}
        end

      :delete ->
        {:halt, assign(socket, :browser_action, %{mode: :delete, target: target, item: item})}

      _ ->
        {:halt, deny(socket)}
    end
  end

  defp mutate(socket, target, action, attrs) do
    case BrowserActions.execute(socket.assigns.viewer, target, action, attrs) do
      result when result == :ok or elem(result, 0) == :ok ->
        {:halt, socket |> assign(browser_action: nil, browser_editing: nil) |> refresh()}

      {:error, :invalid_title} ->
        {:halt, put_flash(socket, :error, "Enter a title between 1 and 255 characters.")}

      _ ->
        {:halt, deny(socket)}
    end
  end

  defp deny(socket),
    do:
      socket
      |> assign(browser_action: nil, browser_editing: nil)
      |> refresh()
      |> put_flash(:error, "This item is no longer available for that action.")

  defp target(%{"kind" => kind, "id" => id}) when is_binary(id) do
    case Map.fetch(%{"canvas" => :canvas, "file" => :file, "space_file" => :space_file}, kind) do
      {:ok, kind} -> {:ok, {kind, id}}
      _ -> :error
    end
  end

  defp target(_), do: :error

  defp info({:file_restored, id}, socket) do
    socket =
      case socket.assigns.undo_toast do
        %{file: %{id: ^id}, timer: timer} ->
          Process.cancel_timer(timer)
          assign(socket, :undo_toast, nil)

        _ ->
          socket
      end

    {:halt, refresh(socket)}
  end

  defp info({:clear_browser_undo, token}, socket) do
    toast = socket.assigns.browser_undo

    {:halt,
     if(toast && toast.token == token, do: assign(socket, :browser_undo, nil), else: socket)}
  end

  defp info({event, _}, socket)
       when event in [
              :stars_changed,
              :canvas_updated,
              :canvas_created,
              :canvas_deleted,
              :canvas_restored,
              :canvas_arrived,
              :file_updated,
              :file_deleted,
              :file_restored,
              :file_ingested,
              :participant_left,
              :participant_joined
            ],
       do: {:halt, refresh(socket)}

  defp info({:file_ingest_failed, _, _}, socket), do: {:halt, refresh(socket)}
  defp info(_event, socket), do: {:cont, socket}
end
