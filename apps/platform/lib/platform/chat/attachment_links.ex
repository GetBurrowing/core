defmodule Platform.Chat.AttachmentLinks do
  @moduledoc """
  Resolves `/chat/attachments/<uuid>` links in message text to the
  attachments a given viewer may read, so chat can render a linked video or
  image with the same player a real attachment gets.

  Two link shapes count:

    * an absolute URL whose host and port equal `PlatformWeb.Endpoint`'s
      configured URL (a link to THIS install), and
    * a path-relative `/chat/attachments/<uuid>` (what the upload tools
      return).

  Any other host, and anything that is not a valid UUID, is ignored.

  Authorization is exactly `Platform.Chat.get_visible_attachment_for_principal/2`,
  the check the download route uses: the deleted-message gate, space
  membership (external principals refused on space-less rows), then the RBAC
  `attachment_access_check/2`. `resolve_for_viewer/2` batches the queries and
  builds the access scope once; its decision per row equals the single-row
  function (tested on allowed and denied rows).

  A link the viewer cannot read resolves to nothing, so the message renders
  the plain link exactly as before: never a locked player.
  """

  import Ecto.Query

  alias Platform.Chat
  alias Platform.Chat.{Attachment, Message, Participant}
  alias Platform.Repo

  @link_regex ~r/(?:(?<scheme>https?):\/\/(?<authority>[^\s\/?#<>()\[\]"'`]+)|(?<![^\s(<\["'>]))\/chat\/attachments\/(?<id>[0-9a-fA-F-]{36})(?![0-9A-Za-z_-])/

  @media_prefixes ["video/", "image/"]

  @type principal :: {:user, binary()} | {:runtime, Platform.Agents.AgentRuntime.t()}

  @doc """
  The attachment ids linked from `content`, in order of first appearance,
  lowercased and unique. Only links to this install (or path-relative links)
  with a valid UUID are returned.
  """
  @spec ids_in(String.t() | nil) :: [binary()]
  def ids_in(content) when is_binary(content) do
    if String.contains?(content, "/chat/attachments/") do
      @link_regex
      |> Regex.scan(content, capture: ["scheme", "authority", "id"])
      |> Enum.flat_map(fn [scheme, authority, id] ->
        if local_link?(scheme, authority), do: cast_id(id), else: []
      end)
      |> Enum.uniq()
    else
      []
    end
  end

  def ids_in(_content), do: []

  @doc """
  `%{message_id => [Attachment]}` of the video/image attachments linked from
  each message's content that `principal` may read. Messages with no
  readable linked media are absent from the map.
  """
  @spec resolve_for_viewer([map()], principal() | nil) :: %{binary() => [Attachment.t()]}
  def resolve_for_viewer(messages, principal) when is_list(messages) do
    links =
      messages
      |> Enum.map(fn msg -> {msg.id, ids_in(Map.get(msg, :content))} end)
      |> Enum.reject(fn {_id, ids} -> ids == [] end)

    case {links, principal} do
      {[], _} ->
        %{}

      {_, nil} ->
        %{}

      _ ->
        visible =
          links
          |> Enum.flat_map(&elem(&1, 1))
          |> Enum.uniq()
          |> visible_media(principal)

        links
        |> Enum.map(fn {msg_id, ids} ->
          {msg_id, ids |> Enum.map(&Map.get(visible, &1)) |> Enum.reject(&is_nil/1)}
        end)
        |> Enum.reject(fn {_id, atts} -> atts == [] end)
        |> Map.new()
    end
  end

  @doc """
  Merge resolved linked attachments into an attachments map: real
  attachments first, linked ones after, unique by attachment id.
  """
  @spec merge(%{binary() => [Attachment.t()]}, %{binary() => [Attachment.t()]}) ::
          %{binary() => [Attachment.t()]}
  def merge(attachments_map, linked) do
    Map.merge(attachments_map, linked, fn _msg_id, real, extra ->
      Enum.uniq_by(real ++ extra, & &1.id)
    end)
  end

  @doc """
  Remove lines of `content` that consist only of a link to one of `ids`
  (a bare URL, `<URL>`, or `[text](URL)`). The player replaces such a line;
  a link mid-sentence stays as written.
  """
  @spec strip_standalone(String.t() | nil, [binary()]) :: String.t() | nil
  def strip_standalone(content, []), do: content

  def strip_standalone(content, ids) when is_binary(content) do
    wanted = MapSet.new(ids, &String.downcase/1)

    content
    |> String.split("\n")
    |> Enum.reject(&standalone_link_line?(&1, wanted))
    |> Enum.join("\n")
    |> String.trim()
  end

  def strip_standalone(content, _ids), do: content

  # ── internals ────────────────────────────────────────────────────────

  defp standalone_link_line?(line, wanted) do
    trimmed = String.trim(line)

    with [id] <- ids_in(trimmed),
         true <- MapSet.member?(wanted, id),
         [url] <- Regex.run(@link_regex, trimmed, capture: :first) do
      trimmed in [url, "<" <> url <> ">"] or
        Regex.match?(~r/\A\[[^\]\n]*\]\(#{Regex.escape(url)}\)\z/, trimmed)
    else
      _ -> false
    end
  end

  defp cast_id(id) do
    case Platform.UUID.cast(id) do
      {:ok, uuid} -> [String.downcase(uuid)]
      :error -> []
    end
  end

  defp local_link?("", ""), do: true

  defp local_link?(scheme, authority) do
    # Plain host[:port] only. URI.parse is lenient ("host:4002.evil.com"
    # parses as host+port), so anything else is another host.
    if Regex.match?(~r/\A[A-Za-z0-9.-]+(:[0-9]{1,5})?\z/, authority) do
      %URI{host: host, port: port} = URI.parse(scheme <> "://" <> authority)
      endpoint = PlatformWeb.Endpoint.struct_url()

      is_binary(host) and String.downcase(host) == String.downcase(endpoint.host || "") and
        port == endpoint.port
    else
      false
    end
  end

  # Batch form of `Chat.get_visible_attachment_for_principal/2`, restricted
  # to video/* and image/* rows. Returns %{id => Attachment}.
  defp visible_media(ids, {:user, user_id} = principal) when is_binary(user_id) do
    rows =
      from(a in Attachment,
        left_join: m in Message,
        on: m.id == a.message_id,
        where: a.id in ^ids and (is_nil(a.message_id) or is_nil(m.deleted_at)),
        select: a
      )
      |> Repo.all()
      |> Enum.filter(&media?/1)

    space_ids = rows |> Enum.map(& &1.space_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    member_spaces =
      if space_ids == [] do
        MapSet.new()
      else
        from(p in Participant,
          where:
            p.space_id in ^space_ids and p.participant_type == "user" and
              p.participant_id == ^user_id,
          select: p.space_id,
          distinct: true
        )
        |> Repo.all()
        |> MapSet.new()
      end

    external? = Enum.any?(rows, &is_nil(&1.space_id)) and Chat.external_principal?(principal)

    admitted =
      Enum.filter(rows, fn
        %Attachment{space_id: nil} -> not external?
        %Attachment{space_id: space_id} -> MapSet.member?(member_spaces, space_id)
      end)

    if admitted == [] do
      %{}
    else
      scope = Platform.Access.Scope.for_user(%{id: user_id})

      admitted
      |> Enum.filter(&(Chat.attachment_access_check(&1, scope) == :ok))
      |> Map.new(&{&1.id, &1})
    end
  end

  # Other principals: the single-row function itself, per id.
  defp visible_media(ids, principal) do
    ids
    |> Enum.map(&Chat.get_visible_attachment_for_principal(&1, principal))
    |> Enum.filter(&(&1 && media?(&1)))
    |> Map.new(&{&1.id, &1})
  end

  defp media?(%Attachment{content_type: ct}) when is_binary(ct) do
    ct = String.downcase(ct)
    Enum.any?(@media_prefixes, &String.starts_with?(ct, &1))
  end

  defp media?(_), do: false
end
