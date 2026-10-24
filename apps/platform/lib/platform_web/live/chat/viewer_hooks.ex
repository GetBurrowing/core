defmodule PlatformWeb.ChatLive.ViewerHooks do
  @moduledoc """
  The in-app viewer's events (redesign rung 13 stage 2). Replaces the image
  lightbox outright.

  The client names WHAT to open, never a URL: a message id plus either an
  attachment id or a link-card index. The item is resolved here from what
  this viewer may already read: the message's attachments in
  `:attachments_map` (already authorized, linked attachments included), or the message's link cards resolved for this
  viewer by `Platform.Chat.LinkCards` (canvas and prototype access checked
  per viewer). A prototype is re-checked with `Platform.Prototypes.readable_by?/2`
  before its frame is served. A locked card opens nothing.

  ## Assigns owned

    * `:viewer` - nil when closed, else a map: `mode` (`"image" | "video" |
      "file" | "prototype" | "link"`), `filename`, `meta`, `src`,
      `download_url` (nil where there is no file), `share_path`, `pdf?`,
      `url`/`host` (link mode), `items`/`index` (image paging) and
      `content_type`.

  ## Events

    * `"viewer_open"` - `message_id` + `attachment_id`, or `message_id` +
      `card` (index into the message's link cards)
    * `"viewer_open_link"` - `href` of a same-host `/proto` anchor in
      message text (classified, never used as the frame src)
    * `"viewer_page"` - `delta` (+1 / -1) through the message's images
    * `"viewer_close"`
    * `"viewer_link_copied"` - the hook copied the share link (no native
      share sheet), so say so
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3]

  alias Platform.Chat
  alias Platform.Chat.LinkCards
  alias Platform.Chat.LinkTargets
  alias Platform.Chat.UploadLimits
  alias Platform.Prototypes

  @doc "Seed `:viewer` and attach the event hook."
  def attach(socket) do
    socket
    |> assign(:viewer, nil)
    |> attach_hook(:viewer_events, :handle_event, &handle_event/3)
  end

  defp handle_event("viewer_open", %{"message_id" => mid, "attachment_id" => aid}, socket)
       when is_binary(mid) and is_binary(aid) do
    attachments = message_attachments(socket, mid)

    case Enum.find(attachments, &(&1.id == aid)) do
      nil ->
        {:halt, socket}

      attachment ->
        {:halt, assign(socket, :viewer, for_attachment(attachment, attachments, socket, mid))}
    end
  end

  defp handle_event("viewer_open", %{"message_id" => mid, "card" => idx}, socket)
       when is_binary(mid) do
    with {index, ""} <- Integer.parse(to_string(idx)),
         %{} = card <- Enum.at(message_cards(socket, mid), index),
         %{} = viewer <- for_card(card, socket, mid) do
      {:halt, assign(socket, :viewer, viewer)}
    else
      _ -> {:halt, socket}
    end
  end

  defp handle_event("viewer_open", _params, socket), do: {:halt, socket}

  # A same-host `/proto/...` anchor in message text (`data-in-app-link`),
  # intercepted by the ChatViewer hook. The href is only classified: the
  # frame src is rebuilt from the prototype id and version, and served only
  # after `readable_by?/2`.
  defp handle_event("viewer_open_link", %{"href" => href}, socket) when is_binary(href) do
    with {:prototype, id, version} <- LinkTargets.classify(href),
         %{} = viewer <-
           for_card(
             %{
               kind: :prototype,
               prototype_id: id,
               version: version,
               open_url: proto_path(id, version)
             },
             socket,
             nil
           ) do
      {:halt, assign(socket, :viewer, viewer)}
    else
      _ -> {:halt, socket}
    end
  end

  defp handle_event("viewer_page", %{"delta" => delta}, socket) do
    case {socket.assigns[:viewer], Integer.parse(to_string(delta))} do
      {%{mode: "image", items: [_, _ | _] = items, index: index} = viewer, {d, ""}} ->
        new_index = Integer.mod(index + d, length(items))
        {:halt, assign(socket, :viewer, image_viewer(items, new_index, viewer))}

      _ ->
        {:halt, socket}
    end
  end

  defp handle_event("viewer_close", _params, socket),
    do: {:halt, assign(socket, :viewer, nil)}

  defp handle_event("viewer_link_copied", _params, socket),
    do: {:halt, put_flash(socket, :info, "Link copied")}

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # ── Resolution ───────────────────────────────────────────────────────

  defp message_attachments(socket, mid) do
    Map.get(socket.assigns[:attachments_map] || %{}, mid) || []
  end

  # The link cards this viewer sees on `mid`, resolved now (the stream item's
  # copy is not kept server-side). Only a message in the open space.
  defp message_cards(socket, mid) do
    with %{id: space_id} <- socket.assigns[:active_space],
         user_id when is_binary(user_id) <- user_id(socket),
         %{space_id: ^space_id, deleted_at: nil} = msg <- Chat.get_message(mid) do
      [msg] |> LinkCards.annotate(user_id) |> hd() |> Map.get(:link_cards) || []
    else
      _ -> []
    end
  end

  defp user_id(socket) do
    case socket.assigns do
      %{current_user_record: %{id: id}} when is_binary(id) -> id
      %{current_user: %{id: id}} when is_binary(id) -> id
      %{user_id: id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp for_attachment(attachment, attachments, socket, mid) do
    cond do
      image?(attachment) ->
        items = image_items(attachments, message_cards(socket, mid))
        index = Enum.find_index(items, &(&1.key == {:attachment, attachment.id})) || 0
        image_viewer(items, index, %{})

      video?(attachment) ->
        attachment
        |> attachment_item()
        |> Map.merge(%{mode: "video"})

      true ->
        attachment
        |> attachment_item()
        |> Map.merge(%{mode: "file"})
    end
  end

  defp for_card(%{kind: :image, url: url}, socket, mid) do
    items = image_items(message_attachments(socket, mid), message_cards(socket, mid))
    index = Enum.find_index(items, &(&1.key == {:url, url})) || 0
    image_viewer(items, index, %{})
  end

  defp for_card(%{kind: :video, url: url, filename: filename}, _socket, _mid) do
    %{
      mode: "video",
      filename: filename,
      meta: type_label(filename, nil),
      src: url,
      download_url: url,
      share_path: url,
      content_type: nil,
      pdf?: false
    }
  end

  defp for_card(%{kind: :prototype, prototype_id: pid, open_url: open_url} = card, socket, _mid) do
    with %{} = proto <- Prototypes.get_prototype(pid),
         true <- Prototypes.readable_by?(%{id: user_id(socket)}, proto) do
      %{
        mode: "prototype",
        filename: proto.name,
        meta:
          PlatformWeb.Components.ChatLinkCard.prototype_meta(
            if(card.version == :latest, do: proto.latest_version, else: card.version)
          ),
        src: open_url,
        download_url: nil,
        share_path: open_url,
        content_type: nil,
        pdf?: false
      }
    else
      _ -> nil
    end
  end

  defp for_card(%{kind: :link, url: url, host: host, path: path}, _socket, _mid) do
    %{
      mode: "link",
      filename: host <> path,
      meta: host,
      src: nil,
      url: url,
      host: host,
      download_url: nil,
      share_path: url,
      content_type: nil,
      pdf?: false
    }
  end

  defp for_card(_card, _socket, _mid), do: nil

  defp proto_path(id, n) when is_integer(n) and n > 0, do: Prototypes.url(id, n)
  defp proto_path(id, _latest), do: "/proto/#{id}/latest/"

  # Every image on the message, attachments first then inline image URLs,
  # so the viewer pages through all of them ("2 of 4").
  defp image_items(attachments, cards) do
    from_attachments =
      for a <- attachments, image?(a) do
        a |> attachment_item() |> Map.put(:key, {:attachment, a.id})
      end

    from_urls =
      for %{kind: :image, url: url, filename: filename} <- cards do
        %{
          key: {:url, url},
          filename: filename,
          meta: type_label(filename, nil),
          src: url,
          download_url: url,
          share_path: url,
          content_type: nil,
          pdf?: false
        }
      end

    from_attachments ++ from_urls
  end

  defp image_viewer(items, index, _prev) do
    item = Enum.at(items, index)

    item
    |> Map.drop([:key])
    |> Map.merge(%{mode: "image", items: items, index: index})
  end

  defp attachment_item(attachment) do
    url = "/chat/attachments/#{attachment.id}"

    %{
      filename: attachment.filename,
      meta: attachment_meta(attachment),
      src: url,
      download_url: url,
      share_path: url,
      content_type: attachment.content_type,
      pdf?: pdf?(attachment),
      byte_size: attachment.byte_size
    }
  end

  defp attachment_meta(attachment) do
    case attachment.byte_size do
      n when is_integer(n) and n >= 0 ->
        type_label(attachment.filename, attachment.content_type) <>
          " · " <> UploadLimits.format_bytes(n)

      _ ->
        type_label(attachment.filename, attachment.content_type)
    end
  end

  @doc false
  def type_label(filename, content_type) do
    ext = filename |> to_string() |> Path.extname() |> String.trim_leading(".")

    cond do
      ext != "" and String.length(ext) <= 5 ->
        String.upcase(ext)

      is_binary(content_type) and content_type != "" ->
        content_type |> String.split("/") |> List.last() |> String.upcase()

      true ->
        "File"
    end
  end

  defp image?(a), do: String.starts_with?(a.content_type || "", "image/")
  defp video?(a), do: String.starts_with?(a.content_type || "", "video/")

  # Only the stored content type decides whether the viewer frames a file.
  # Never the filename: the attachment route serves some types inline, so a
  # `text/html` file named `x.pdf` framed same-origin would run as a page of
  # the app. Anything else gets the file panel.
  defp pdf?(a), do: a.content_type == "application/pdf"
end
