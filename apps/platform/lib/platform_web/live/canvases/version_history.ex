defmodule PlatformWeb.Canvases.VersionHistory do
  @moduledoc "Standalone history keeps the historical preview independent of the live head (task 01a1557a)."
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView
  alias Platform.Chat.CanvasAccess
  alias Platform.Chat.Canvas.{Restore, Server, Versions}
  alias Platform.Files.BrowserActions

  def attach(socket) do
    socket
    |> assign(:history_open, false)
    |> assign(:history_rows, [])
    |> assign(:history_preview, nil)
    |> assign(:history_confirm, nil)
    |> assign(:history_can_restore, false)
    |> assign(:history_error, nil)
    |> attach_hook(:standalone_history_events, :handle_event, &event/3)
    |> attach_hook(:standalone_history_updates, :handle_info, &info/2)
  end

  def refresh(socket) do
    with %{id: id} <- socket.assigns[:canvas],
         {:ok, viewer} <- BrowserActions.viewer(actor(socket)),
         {:ok, canvas, _} <-
           CanvasAccess.fetch_for_viewer(id, viewer.user,
             audit: false,
             access_scope: viewer.access_scope
           ),
         true <- is_nil(canvas.deleted_at),
         {:ok, head} <- Server.describe(id) do
      canvas = %{canvas | document: head.document}

      socket
      |> assign(:canvas, canvas)
      |> assign(:revision, head.revision)
      |> assign(:page_title, canvas.title || "Canvas")
      |> assign(:history_can_restore, match?({:ok, _, _}, Restore.authorize(actor(socket), id)))
      |> assign(:history_rows, if(socket.assigns.history_open, do: rows(canvas, head), else: []))
    else
      _ -> socket |> clear() |> assign(:canvas, nil) |> assign(:load_error, :not_found)
    end
  end

  def clear(socket) do
    socket
    |> assign(:history_open, false)
    |> assign(:history_rows, [])
    |> assign(:history_preview, nil)
    |> assign(:history_confirm, nil)
    |> assign(:history_can_restore, false)
  end

  def rows(canvas, head) do
    versions = Versions.list_for_canvas(canvas.id, limit: 100)
    stored_head = Enum.find(versions, &(&1.revision == head.revision))

    current = %{
      revision: head.revision,
      current?: true,
      written_at: (stored_head && stored_head.written_at) || canvas.updated_at,
      written_by:
        (stored_head && stored_head.written_by) || Versions.attribution_from_canvas(canvas),
      restored_from: source_revision(stored_head)
    }

    [
      current
      | Enum.filter(versions, &(&1.revision < head.revision))
        |> Enum.map(fn v ->
          %{
            revision: v.revision,
            current?: false,
            written_at: v.written_at,
            written_by: v.written_by,
            restored_from: source_revision(v)
          }
        end)
    ]
    |> Enum.map(fn row ->
      source = row.restored_from && Versions.get(canvas.id, row.restored_from)
      Map.put(row, :source_at, source && source.written_at)
    end)
  end

  defp source_revision(nil), do: nil

  defp source_revision(v) do
    case Platform.Chat.Canvas.Version.ops(v) do
      [["restore_from_revision", revision]] -> revision
      _ -> nil
    end
  end

  defp event("canvas_history_open", _, socket) do
    {:halt, socket |> assign(:history_open, true) |> assign(:history_error, nil) |> refresh()}
  end

  defp event("canvas_history_close", _, socket),
    do: {:halt, socket |> assign(:history_open, false) |> assign(:history_confirm, nil)}

  defp event("canvas_history_current", _, socket),
    do:
      {:halt,
       socket
       |> assign(:history_preview, nil)
       |> assign(:history_confirm, nil)
       |> assign(:history_error, nil)
       |> refresh()}

  defp event("canvas_history_select", %{"revision" => raw}, socket)
       when is_binary(raw) and byte_size(raw) <= 20 do
    socket = refresh(socket)

    with {revision, ""} <- Integer.parse(to_string(raw)),
         %{id: id} = canvas <- socket.assigns[:canvas],
         true <- socket.assigns.history_open,
         true <- revision > 0 and revision < socket.assigns.revision,
         %{} = version <- Versions.get(id, revision) do
      preview = %{
        canvas: %{canvas | document: inert_document(version.document, version.written_at)},
        revision: revision,
        at: version.written_at
      }

      {:halt,
       socket
       |> assign(:history_preview, preview)
       |> assign(:history_open, false)
       |> assign(:history_confirm, nil)
       |> assign(:history_error, nil)}
    else
      _ -> {:halt, assign(socket, :history_error, "That version is no longer available.")}
    end
  end

  defp event("canvas_history_restore_prompt", _, socket) do
    socket = refresh(socket)

    case {socket.assigns.history_preview, socket.assigns.history_can_restore} do
      {%{revision: source}, true} ->
        {:halt,
         assign(socket, :history_confirm, %{source: source, expected: socket.assigns.revision})}

      _ ->
        {:halt, socket}
    end
  end

  defp event("canvas_history_restore_cancel", _, socket),
    do: {:halt, assign(socket, :history_confirm, nil)}

  defp event("canvas_history_restore_confirm", _, socket) do
    case {socket.assigns[:canvas], socket.assigns.history_confirm} do
      {%{id: id}, %{source: source, expected: expected}} ->
        case Restore.restore(actor(socket), id, source, expected) do
          {:ok, _revision} ->
            {:halt,
             socket
             |> assign(:history_preview, nil)
             |> assign(:history_open, true)
             |> assign(:history_confirm, nil)
             |> assign(:history_error, nil)
             |> refresh()}

          error ->
            {:halt,
             socket
             |> assign(:history_confirm, nil)
             |> assign(:history_error, restore_error(error))
             |> refresh()}
        end

      _ ->
        {:halt, socket}
    end
  end

  defp event("canvas_history_" <> _, _, socket), do: {:halt, socket}
  # Block forged edit/form events too. The preview contains no live extension
  # nodes; the native inert subtree prevents client controls from emitting.
  defp event(event, _, %{assigns: %{history_preview: preview}} = socket)
       when not is_nil(preview) and
              event in ["canvas_action_click", "canvas_form_submit", "canvas_patch"],
       do: {:halt, socket}

  defp event(_, _, socket), do: {:cont, socket}

  defp info({:canvas_patched, id, _, _}, socket), do: update(id, socket)
  defp info({:canvas_updated, %{id: id}}, socket), do: update(id, socket)

  defp info({:canvas_deleted, %{id: id}}, socket) do
    if socket.assigns[:canvas] && socket.assigns.canvas.id == id,
      do: {:cont, clear(socket)},
      else: {:cont, socket}
  end

  defp info(_, socket), do: {:cont, socket}

  defp update(id, socket) do
    if socket.assigns[:canvas] && socket.assigns.canvas.id == id,
      do: {:cont, refresh(socket)},
      else: {:cont, socket}
  end

  defp actor(socket), do: %{id: socket.assigns[:current_user_id]}

  defp restore_error({:conflict, _}),
    do: "The canvas changed. Review the current version before restoring."

  defp restore_error(_),
    do: "This version could not be restored. Check your access and try again."

  @doc """
  Keep canonical static rendering, replacing executable/extension nodes with
  inert text. Sealed prototype frames survive as read-only previews (task
  01a18834 stage 2): a scripted `embed` with a well-formed `prototype_ref`
  becomes a `prototype` node pinned to that ref's version, and a `prototype`
  node is pinned to the version that was latest at `written_at` (nil leaves
  a follow-latest node following latest). Both carry `"preview" => true`,
  which `Kinds.Prototype.validate_props/1` refuses on any write, so only
  this projection can produce it. The rewrite is in DATA rather than an attr
  threaded through every container kind: a container that forgot to forward
  the attr would silently re-attach the room bridge; this fails closed.
  """
  def inert_document(document, written_at \\ nil),
    do: Map.update!(document, "root", &inert_node(&1, written_at))

  @static ~w(stack row card text markdown heading badge image code mermaid table checklist checklist_item form action_row)

  defp inert_node(%{"type" => type} = node, at) when type in @static do
    Map.update(node, "children", [], &Enum.map(&1, fn child -> inert_node(child, at) end))
  end

  # A plain embed renders `sandbox=""` srcdoc: no scripts, no room bridge.
  defp inert_node(%{"type" => "embed", "props" => props} = node, _at)
       when is_map(props) and not is_map_key(props, "scripts"),
       do: node

  defp inert_node(%{"type" => "embed", "props" => %{"scripts" => scripts}} = node, _at)
       when scripts != true,
       do: node

  defp inert_node(
         %{
           "type" => "embed",
           "props" =>
             %{
               "scripts" => true,
               "prototype_ref" => %{"prototype_id" => prototype_id, "version" => version}
             } = props
         } = node,
         _at
       )
       when is_binary(prototype_id) and is_integer(version) and version > 0 do
    if Platform.UUID.valid?(prototype_id) do
      %{
        "id" => node["id"],
        "type" => "prototype",
        "props" =>
          props
          |> Map.take(["height", "width", "min_scale"])
          |> Map.merge(%{
            "prototype_id" => prototype_id,
            "version" => version,
            "preview" => true
          })
      }
    else
      unavailable(node)
    end
  end

  defp inert_node(%{"type" => "prototype", "props" => %{} = props} = node, at) do
    version =
      case {props["version"], at} do
        {nil, %DateTime{}} -> Platform.Prototypes.version_at(props["prototype_id"], at)
        {version, _} -> version
      end

    props =
      props
      |> Map.put("preview", true)
      |> then(&if(is_nil(version), do: &1, else: Map.put(&1, "version", version)))

    Map.put(node, "props", props)
  end

  defp inert_node(node, _at), do: unavailable(node)

  defp unavailable(node),
    do: %{
      "id" => node["id"],
      "type" => "text",
      "props" => %{"value" => "Interactive content is unavailable in version previews."}
    }
end
