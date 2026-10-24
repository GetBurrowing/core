defmodule Platform.Chat.LinkCards do
  @moduledoc """
  Resolves `Platform.Chat.LinkTargets` targets into the cards one viewer sees
  under a message (redesign rung 13, stage 1).

  Access is checked per viewer, with the same functions the destination
  pages use:

    * canvas - `Platform.Chat.CanvasAccess.fetch_for_viewer/3` (`audit: false`,
      with the viewer's RBAC scope so a `canvas.read` deny refuses). A canvas
      that has a prototype row becomes a prototype card.
    * prototype - `Platform.Prototypes.readable_by?/2`, the exact check the
      `/proto` routes run.

  Anything refused OR missing is a `:locked` card carrying only its type:
  no title, space, version or thumbnail (rule 4 of the direction canvas).
  Nothing here fetches from the network; a link card is host + path.

  Attachment links are not cards: `Platform.Chat.AttachmentLinks` authorizes
  them into the attachment player.

  `annotate/2` resolves a whole page of messages at once: one canvas
  prototype lookup, one prototype query and one space-name query per page,
  with each distinct canvas and prototype checked once.
  """

  import Ecto.Query

  alias Platform.Chat.{CanvasAccess, LinkTargets, Space}
  alias Platform.Prototypes
  alias Platform.Prototypes.Prototype
  alias Platform.Repo

  @type card :: map()

  @doc """
  Put `:link_cards` on each message for `viewer_user_id`. A message with no
  card targets gets `[]`. A nil viewer leaves messages untouched, so they
  render plain links.
  """
  @spec annotate([map()], binary() | nil) :: [map()]
  def annotate(messages, viewer_user_id) when is_binary(viewer_user_id) do
    targets_by_msg = Enum.map(messages, &{&1, card_targets(&1)})
    all = targets_by_msg |> Enum.flat_map(&elem(&1, 1))
    lookup = build_lookup(all, viewer_user_id)

    Enum.map(targets_by_msg, fn {msg, targets} ->
      Map.put(msg, :link_cards, Enum.map(targets, &card_for(&1, lookup)))
    end)
  end

  def annotate(messages, _viewer_user_id), do: messages

  @doc "Cards for `targets`, in order, as `viewer_user_id` sees them."
  @spec resolve([LinkTargets.target()], binary() | nil) :: [card()]
  def resolve(targets, viewer_user_id) do
    targets = Enum.filter(targets, &card_kind?/1)

    if is_binary(viewer_user_id) do
      lookup = build_lookup(targets, viewer_user_id)
      Enum.map(targets, &card_for(&1, lookup))
    else
      Enum.map(targets, &card_for(&1, %{canvases: %{}, prototypes: %{}}))
    end
  end

  @doc """
  The URLs whose bare line a card replaces, for
  `ContentRenderer.render_message/2`'s `:cards` option.
  """
  @spec bare_urls([card()] | nil) :: [String.t()]
  def bare_urls(cards) when is_list(cards),
    do: for(%{bare_line?: true, url: url} <- cards, do: url)

  def bare_urls(_cards), do: []

  # ── internals ────────────────────────────────────────────────────────

  defp card_targets(msg) do
    case Map.get(msg, :content) do
      content when is_binary(content) and content != "" ->
        if Map.get(msg, :content_type, "text") == "canvas",
          do: [],
          else: content |> LinkTargets.from_content() |> Enum.filter(&card_kind?/1)

      _ ->
        []
    end
  end

  defp card_kind?(%{kind: kind}), do: kind in [:canvas, :prototype, :image, :video, :link]

  defp build_lookup(targets, user_id) do
    user = %{id: user_id}
    canvas_ids = for %{kind: :canvas, id: id} <- targets, uniq: true, do: id
    proto_ids = for %{kind: :prototype, id: id} <- targets, uniq: true, do: id

    canvases =
      case canvas_ids do
        [] -> %{}
        ids -> readable_canvases(ids, user_id)
      end

    canvas_protos =
      case Map.keys(canvases) do
        [] ->
          %{}

        ids ->
          user
          |> Prototypes.list_readable(canvas_ids: ids)
          |> Map.new(&{&1.canvas_id, &1})
      end

    prototypes =
      case proto_ids do
        [] ->
          %{}

        ids ->
          user
          |> Prototypes.list_readable(ids: ids)
          |> Map.new(&{&1.id, &1})
      end

    space_names = space_names(Map.values(canvases))

    canvases =
      Map.new(canvases, fn {id, canvas} ->
        {id, %{canvas: canvas, space_name: Map.get(space_names, canvas.space_id)}}
      end)

    %{canvases: canvases, canvas_protos: canvas_protos, prototypes: prototypes}
  end

  defp readable_canvases(ids, user_id) do
    scope = Platform.Access.Scope.for_user(%{id: user_id})

    ids
    |> Enum.flat_map(fn id ->
      case CanvasAccess.fetch_for_viewer(id, {:user, user_id}, audit: false, access_scope: scope) do
        # A soft-deleted canvas still resolves for grant holders (so its
        # page can say "removed"); a card for it would open nothing.
        {:ok, %{deleted_at: nil} = canvas, _level} -> [{id, canvas}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp space_names([]), do: %{}

  defp space_names(canvases) do
    ids = canvases |> Enum.map(& &1.space_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    from(s in Space, where: s.id in ^ids, select: {s.id, s.name})
    |> Repo.all()
    |> Map.new()
  end

  defp card_for(%{kind: :canvas, id: id} = t, lookup) do
    case {Map.get(lookup.canvases, id), Map.get(Map.get(lookup, :canvas_protos, %{}), id)} do
      {nil, _} ->
        locked(t, :canvas)

      {_entry, %Prototype{} = proto} ->
        prototype_card(t, proto, proto.latest_version)

      {%{canvas: canvas, space_name: space_name}, nil} ->
        %{
          kind: :canvas,
          url: t.url,
          bare_line?: t.bare_line?,
          canvas_id: canvas.id,
          space_id: canvas.space_id,
          title: canvas.title || "Untitled canvas",
          space_name: space_name
        }
    end
  end

  defp card_for(%{kind: :prototype, id: id, version: version} = t, lookup) do
    case Map.get(lookup.prototypes, id) do
      nil -> locked(t, :prototype)
      proto when version == :latest -> prototype_card(t, proto, proto.latest_version)
      proto -> prototype_card(t, proto, version)
    end
  end

  defp card_for(%{kind: :link, url: url} = t, _lookup) do
    uri = URI.parse(url)
    host = String.downcase(uri.host || "")

    path =
      case {uri.path, uri.query} do
        {p, nil} when p in [nil, "", "/"] -> ""
        {p, nil} -> String.trim_trailing(p, "/")
        {p, q} -> (p || "") <> "?" <> q
      end

    %{kind: :link, url: url, bare_line?: t.bare_line?, host: host, path: path}
  end

  defp card_for(%{kind: :image, url: url} = t, _lookup),
    do: %{kind: :image, url: url, bare_line?: t.bare_line?, filename: filename(url)}

  defp card_for(%{kind: :video, url: url} = t, _lookup),
    do: %{kind: :video, url: url, bare_line?: t.bare_line?, filename: filename(url)}

  defp prototype_card(t, %Prototype{} = proto, version) do
    open_url =
      case version do
        n when is_integer(n) and n > 0 -> Prototypes.url(proto.id, n)
        _ -> "/proto/#{proto.id}/latest/"
      end

    %{
      kind: :prototype,
      url: t.url,
      bare_line?: t.bare_line?,
      prototype_id: proto.id,
      name: proto.name,
      version: version,
      open_url: open_url
    }
  end

  # Only the type: no title, space, version or thumbnail. `url` is the link
  # the sender typed (already in the message text) and is used only to drop
  # the bare line; the card never renders it.
  defp locked(t, type), do: %{kind: :locked, type: type, url: t.url, bare_line?: t.bare_line?}

  defp filename(url) do
    case URI.parse(url) do
      %URI{path: path} when is_binary(path) ->
        last = path |> String.split("/") |> List.last()

        try do
          URI.decode(last)
        rescue
          ArgumentError -> last
        end

      _ ->
        url
    end
  end
end
