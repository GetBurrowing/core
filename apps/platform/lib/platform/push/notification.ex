defmodule Platform.Push.Notification do
  @moduledoc """
  The ONE push notification model (task 01a10882 stage 2).

  Every producer builds a `%Notification{}` (or hands `Platform.Push` a legacy
  `%{title, body, url}` map, which `from_map/1` lifts to kind `"generic"`), and
  both transports serialise this same struct:

    * web push: `to_web_payload/1`, the JSON `priv/static/sw.js` reads;
    * APNs: `to_apns_payload/1`, the JSON body `Platform.Push.APNs` posts;
    * FCM: `to_fcm_payload/1`, the v1 `message` `Platform.Push.FCM` posts
      (task 01a10d8e). Data-only, so the Android app always builds the
      notification itself (MessagingStyle with `author_name` and
      `space_name`, RemoteInput reply, channels, grouping), whether it is in
      the foreground or not.

  Redaction (`Platform.Push.preview_for_user/2`) and the archived-user
  suppression run ONCE on the struct, BEFORE the transport split, so web push
  and APNs cannot disagree about content: there is no per-transport copy to
  drift. A field one transport needs is a field on this struct, never a second
  payload built beside it.

  ## Copy (design canvas 01a10887, "Suite iOS v1: native surfaces", rev 23)

  | kind                     | title                  | body          |
  |--------------------------|------------------------|---------------|
  | `chat_mention`           | `{Author} in {Space}`  | the message   |
  | `review_request_pending` | `Review requested`     | the task title|
  | `task_plan_review`       | `Plan ready to approve`| the task title|

  A message body is plain text: formatting stripped, `@[Name]` becomes
  `@Name`, an attachment-only message reads `Sent a photo` or
  `Sent a PDF: {filename}`, and anything longer than 200 characters is cut
  at a word boundary and ends with an ellipsis.

  ## Categories (iOS notification actions)

    * `chat_mention` -> `SUITE_MENTION` (Reply + Open), grouped by space;
    * `task_plan_review`, `review_request_pending` -> `SUITE_OPEN`, grouped
      together under thread `approvals` (canvas open question 3, decided: one
      Approvals group);
    * everything else -> no category; a tap opens the url.

  Alert pushes only; the VoIP ring itself is
  `Platform.Push.APNs.deliver_voip_to_user/2`. Task 01a10db7 added the ring
  follow-ups as alert kinds (`meeting_ring_waiting` with category
  `SUITE_RING_WAITING`, `meeting_ring_missed`), which carry `meeting_id` and
  `ring_id` so the app can show its in-app banner or open the meeting.
  """

  alias Platform.Inbox.Item

  @body_limit 200

  @mention_category "SUITE_MENTION"
  @open_category "SUITE_OPEN"
  @ring_waiting_category "SUITE_RING_WAITING"
  @approvals_thread "approvals"
  @approval_kinds ~w(task_plan_review review_request_pending)
  # Kinds the iOS Notification Service Extension rewrites (task 01a111bb).
  @mutable_kinds ~w(chat_message chat_mention)

  defstruct kind: "generic",
            title: nil,
            body: nil,
            url: nil,
            category: nil,
            thread_id: nil,
            collapse_id: nil,
            space_id: nil,
            message_id: nil,
            task_id: nil,
            inbox_item_id: nil,
            install_host: nil,
            author_name: nil,
            author_id: nil,
            author_type: nil,
            space_name: nil,
            meeting_id: nil,
            ring_id: nil

  @type t :: %__MODULE__{
          kind: String.t(),
          title: String.t() | nil,
          body: String.t() | nil,
          url: String.t() | nil,
          category: String.t() | nil,
          thread_id: String.t() | nil,
          collapse_id: String.t() | nil,
          space_id: String.t() | nil,
          message_id: String.t() | nil,
          task_id: String.t() | nil,
          inbox_item_id: String.t() | nil,
          install_host: String.t() | nil,
          author_name: String.t() | nil,
          author_id: String.t() | nil,
          author_type: String.t() | nil,
          space_name: String.t() | nil,
          meeting_id: String.t() | nil,
          ring_id: String.t() | nil
        }

  @doc "The iOS category for a kind, or nil (tap opens)."
  @spec category_for(String.t()) :: String.t() | nil
  def category_for("chat_mention"), do: @mention_category
  def category_for("meeting_ring_waiting"), do: @ring_waiting_category
  def category_for(kind) when kind in @approval_kinds, do: @open_category
  def category_for(_kind), do: nil

  @doc """
  Build a notification. `attrs` may carry any struct field; `category`,
  `thread_id` and `install_host` default from the kind and the install.
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs) do
    attrs = Map.new(attrs)
    %__MODULE__{} = n = struct(__MODULE__, attrs)
    kind = n.kind || "generic"

    %__MODULE__{
      n
      | kind: kind,
        category: Map.get(attrs, :category, category_for(kind)),
        thread_id: Map.get(attrs, :thread_id) || default_thread_id(kind, n),
        install_host: n.install_host || install_host()
    }
  end

  @doc """
  Lift a legacy `%{title, body, url}` map (or return a struct unchanged).
  A map without a `:kind` is kind `"generic"`: no category, tap opens.
  """
  @spec from_map(t() | map()) :: t()
  def from_map(%__MODULE__{} = n), do: n

  def from_map(%{} = map) do
    map
    |> Map.take([
      :kind,
      :title,
      :body,
      :url,
      :category,
      :thread_id,
      :collapse_id,
      :space_id,
      :message_id,
      :task_id,
      :inbox_item_id,
      :install_host,
      :author_name,
      :author_id,
      :author_type,
      :space_name,
      :meeting_id,
      :ring_id
    ])
    |> Map.put_new(:kind, "generic")
    |> new()
  end

  @doc """
  Build the notification for an inbox row. Approval kinds get the canvas copy
  (fixed title, task title in the body); any other kind keeps the row's own
  title, body and url. `collapse_id` is the inbox item id, so a re-delivery
  of the same row replaces rather than stacks on the device.
  """
  @spec from_inbox_item(Item.t()) :: t()
  def from_inbox_item(%Item{} = item) do
    task_id = if item.source_type in ~w(task task_review), do: item.source_id

    {title, body} = inbox_copy(item, task_id)

    new(%{
      kind: item.kind,
      title: title,
      body: body,
      url: item.url,
      task_id: task_id,
      inbox_item_id: item.id,
      collapse_id: item.id
    })
  end

  @doc """
  Build a chat notification. `reason` `:mention` is kind `chat_mention`,
  everything else `chat_message`. `attachments` (used only when the message
  has no text) are `%{content_type, filename}` maps.

  `space_path` is the `/chat/:space_slug` segment from
  `Platform.Chat.space_path_segment/1`, never a raw `space.slug`: a DM or
  group has no slug, and a slug-only url collapsed to `/chat`, which opened
  the reader's first channel instead of the conversation. With a
  `message_id` the url carries the `?message=` anchor `ChatLive` resolves.
  """
  @spec chat(map()) :: t()
  def chat(%{} = attrs) do
    kind = if attrs[:reason] == :mention, do: "chat_mention", else: "chat_message"

    new(%{
      kind: kind,
      title: chat_title(attrs[:author], attrs[:space_name], attrs[:reason]),
      body: body_text(attrs[:content], attrs[:attachments] || []),
      url: chat_url(attrs[:space_path], attrs[:message_id]),
      space_id: attrs[:space_id],
      message_id: attrs[:message_id],
      thread_id: attrs[:space_id],
      # Separate from the title so Android's MessagingStyle can show the
      # author and the conversation apart (task 01a10d8e).
      author_name: presence(attrs[:author]),
      # Who wrote it (task 01a111bb): the author participant's
      # `participant_id` and `participant_type` ("user" | "agent"), so the iOS
      # Notification Service Extension can build the sender `INPerson` for a
      # communication notification.
      author_id: presence(attrs[:author_id]),
      author_type: presence(attrs[:author_type]),
      # `conversation_name` is the recipient's label for the space (a DM or
      # unnamed group has a NULL `chat_spaces.name`; the web sidebar shows the
      # other participant). It falls back to the space's own name. The TITLE
      # keeps `space_name` so APNs and web push read exactly as before.
      space_name: presence(attrs[:conversation_name]) || presence(attrs[:space_name])
    })
  end

  @doc "Mention title: `{Author} in {Space}` (`@here` variant for a broadcast)."
  @spec chat_title(String.t() | nil, String.t() | nil, atom() | nil) :: String.t()
  def chat_title(author, space_name, :here),
    do: "#{presence(author) || "Someone"} @here in #{presence(space_name) || "Suite"}"

  def chat_title(author, space_name, _reason),
    do: "#{presence(author) || "Someone"} in #{presence(space_name) || "Suite"}"

  @doc """
  The redacted copy an external recipient gets on EVERY transport. Every
  identifying field (space, message, task, inbox ids and the grouping and
  category derived from them) is cleared, and so are `author_name`,
  `author_id`, `author_type` and `space_name`; only the kind and install
  survive. It builds a FRESH struct, so a field added later is dropped unless
  it is copied here on purpose.
  """
  @spec redact(t(), %{title: String.t(), body: String.t(), url: String.t()}) :: t()
  def redact(%__MODULE__{} = n, %{title: title, body: body, url: url}) do
    %__MODULE__{
      kind: n.kind,
      title: title,
      body: body,
      url: url,
      install_host: n.install_host
    }
  end

  @doc """
  The web push JSON map. `title`, `body` and `url` are the keys `sw.js` reads
  and are unchanged; everything else is additive.
  """
  @spec to_web_payload(t()) :: map()
  def to_web_payload(%__MODULE__{} = n) do
    %{
      title: n.title,
      body: n.body,
      url: n.url,
      kind: n.kind,
      category: n.category,
      thread_id: n.thread_id,
      space_id: n.space_id,
      message_id: n.message_id,
      task_id: n.task_id,
      inbox_item_id: n.inbox_item_id,
      meeting_id: n.meeting_id,
      ring_id: n.ring_id,
      install_host: n.install_host
    }
    |> drop_nils()
  end

  @doc """
  The APNs JSON body: the `aps` dictionary plus top-level routing keys.

  Chat kinds (`chat_message`, `chat_mention`) also set
  `"mutable-content" => 1` so the iOS Notification Service Extension runs on
  them and can make them communication notifications (task 01a111bb). No
  other kind sets it. `author_name` and `space_name` name the sender and the
  conversation for that extension; a redacted copy carries neither.
  """
  @spec to_apns_payload(t()) :: map()
  def to_apns_payload(%__MODULE__{} = n) do
    aps =
      %{
        # A nil body is omitted, never sent as `"body": null`.
        "alert" => drop_nils(%{"title" => n.title, "body" => n.body}),
        "sound" => "default",
        "category" => n.category,
        "thread-id" => n.thread_id,
        "mutable-content" => if(n.kind in @mutable_kinds, do: 1)
      }
      |> drop_nils()

    %{
      "aps" => aps,
      "url" => n.url,
      "kind" => n.kind,
      "space_id" => n.space_id,
      "message_id" => n.message_id,
      "task_id" => n.task_id,
      "inbox_item_id" => n.inbox_item_id,
      "meeting_id" => n.meeting_id,
      "ring_id" => n.ring_id,
      "install_host" => n.install_host,
      "author_id" => n.author_id,
      "author_type" => n.author_type,
      # The sender's display name and the conversation name, for the
      # INPerson and conversation the NSE builds (task 01a111bb stage 4).
      # Both are already in the title; redact/2 clears them.
      "author_name" => n.author_name,
      "space_name" => n.space_name
    }
    |> drop_nils()
  end

  @doc """
  The FCM HTTP v1 `message` map, without `token` (the transport adds it per
  device).

  DATA-ONLY: there is no `notification` block, so FCM never displays
  anything itself and the app builds every notification. `android.priority`
  is `high` so a data message wakes the app from Doze. `collapse_id` becomes
  `android.collapse_key` (cut to 64 characters). FCM rejects non-string data
  values, so every value is a string, and a nil or empty value is dropped.
  """
  @spec to_fcm_payload(t()) :: map()
  def to_fcm_payload(%__MODULE__{} = n) do
    data =
      %{
        "kind" => n.kind,
        "title" => n.title,
        "body" => n.body,
        "url" => n.url,
        "category" => n.category,
        "thread_id" => n.thread_id,
        "space_id" => n.space_id,
        "message_id" => n.message_id,
        "task_id" => n.task_id,
        "inbox_item_id" => n.inbox_item_id,
        "meeting_id" => n.meeting_id,
        "ring_id" => n.ring_id,
        "install_host" => n.install_host,
        "author_name" => n.author_name,
        "author_id" => n.author_id,
        "author_type" => n.author_type,
        "space_name" => n.space_name
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new(fn {k, v} -> {k, to_string(v)} end)

    android =
      case n.collapse_id do
        id when is_binary(id) and id != "" ->
          %{"priority" => "high", "collapse_key" => String.slice(id, 0, 64)}

        _ ->
          %{"priority" => "high"}
      end

    %{"data" => data, "android" => android}
  end

  @doc """
  Plain-text notification body for a chat message (canvas copy rules).
  """
  @spec body_text(String.t() | nil, [map()]) :: String.t()
  def body_text(content, attachments \\ []) do
    case content |> to_string() |> plain_text() do
      "" -> attachment_text(attachments)
      text -> truncate(text, @body_limit)
    end
  end

  @doc "Cut `text` to `limit` graphemes at a word boundary, ending with an ellipsis."
  @spec truncate(String.t(), pos_integer()) :: String.t()
  def truncate(text, limit) do
    if String.length(text) <= limit do
      text
    else
      head = String.slice(text, 0, limit)

      cut =
        case Regex.run(~r/\A(.*)\s\S*\z/su, head) do
          [_, before] when byte_size(before) > 0 -> before
          _ -> head
        end

      String.trim_trailing(cut, " ,;:.-") <> "…"
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp inbox_copy(%Item{kind: "task_plan_review"} = item, task_id),
    do: {"Plan ready to approve", task_title(task_id, item)}

  defp inbox_copy(%Item{kind: "review_request_pending"} = item, task_id),
    do: {"Review requested", task_title(task_id, item)}

  defp inbox_copy(%Item{} = item, _task_id), do: {item.title, item.body}

  # The task's own title. If the row cannot be read (deleted task, malformed
  # id), fall back to the part of the inbox title after its "Label: " prefix.
  defp task_title(task_id, %Item{title: item_title}) do
    title =
      if is_binary(task_id) do
        case Platform.Repo.get(Platform.Tasks.Task, task_id) do
          %{title: t} when is_binary(t) -> t
          _ -> nil
        end
      end

    title || strip_label(item_title)
  rescue
    _ -> strip_label(item_title)
  end

  defp strip_label(nil), do: ""

  defp strip_label(title) do
    case String.split(title, ": ", parts: 2) do
      [_label, rest] -> rest
      [only] -> only
    end
  end

  defp default_thread_id(kind, _n) when kind in @approval_kinds, do: @approvals_thread
  defp default_thread_id(_kind, %__MODULE__{space_id: space_id}), do: space_id

  defp chat_url(path, message_id) when is_binary(path) and path != "" do
    if is_binary(message_id) and message_id != "",
      do: "/chat/#{path}?message=#{URI.encode_www_form(message_id)}",
      else: "/chat/#{path}"
  end

  defp chat_url(_path, _message_id), do: "/chat"

  defp attachment_text([]), do: ""

  defp attachment_text([first | _]) do
    content_type = to_string(Map.get(first, :content_type) || Map.get(first, "content_type"))
    filename = to_string(Map.get(first, :filename) || Map.get(first, "filename"))

    cond do
      String.starts_with?(content_type, "image/") -> "Sent a photo"
      content_type == "application/pdf" -> "Sent a PDF: #{filename}"
      filename != "" -> "Sent a file: #{filename}"
      true -> "Sent a file"
    end
  end

  # Markdown to one line of plain text. Order matters: `@[Name]` is rewritten
  # before links so it is never read as a link label.
  defp plain_text(text) do
    text
    |> String.replace(~r/@\[([^\]]+)\]/u, "@\\1")
    |> String.replace(~r/```[a-zA-Z0-9_-]*\n?/u, "")
    |> String.replace(~r/!\[([^\]]*)\]\([^)]*\)/u, "\\1")
    |> String.replace(~r/\[([^\]]+)\]\([^)]*\)/u, "\\1")
    |> String.replace(~r/^\s{0,3}(\#{1,6}|>|[-*+]|\d+\.)\s+/mu, "")
    |> String.replace(~r/(\*\*|__|~~|`)/u, "")
    |> String.replace(~r/(?<![\w*])\*(?!\s)([^*\n]+?)(?<!\s)\*(?![\w*])/u, "\\1")
    |> String.replace(~r/(?<!\w)_(?!\s)([^_\n]+?)(?<!\s)_(?!\w)/u, "\\1")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  @doc """
  This install's host (from `Platform.OIDC.app_url/0`), or nil. The default
  for every notification's `install_host`, which the app uses to route a push
  to the right signed-in install; `Platform.Push.APNs.deliver_voip_to_user/2`
  stamps VoIP payloads with the same value.
  """
  @spec install_host() :: String.t() | nil
  def install_host do
    case Platform.OIDC.app_url() do
      url when is_binary(url) -> URI.parse(url).host
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value) when is_binary(value), do: value
  defp presence(_), do: nil

  defp drop_nils(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
end
