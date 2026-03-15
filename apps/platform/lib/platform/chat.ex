defmodule Platform.Chat do
  @moduledoc """
  Core context for all Chat domain operations.

  Covers spaces, participants, messages, threads, reactions, pins,
  canvases, and attachments. Telemetry events are emitted for key writes
  and bridged to the audit log via `Platform.Chat.TelemetryHandler`.

  ## Quick reference

      # Spaces
      Platform.Chat.create_space(%{name: "General", slug: "general", kind: "channel"})
      Platform.Chat.list_spaces(workspace_id: id, kind: "channel", archived: false)

      # Participants
      Platform.Chat.add_participant(space.id, %{participant_type: "user", participant_id: uid, joined_at: DateTime.utc_now()})
      Platform.Chat.list_participants(space.id)

      # Messages
      Platform.Chat.post_message(%{space_id: id, participant_id: pid, content_type: "text", content: "hello"})
      Platform.Chat.list_messages(space.id, limit: 50, before_id: cursor_id)
      Platform.Chat.search_messages(space.id, "elixir phoenix", limit: 20)

      # Threads
      Platform.Chat.create_thread(space.id, %{parent_message_id: msg.id, title: "Discussion"})
      Platform.Chat.get_thread_for_message(msg.id)

      # Reactions / Pins / Canvases / Attachments
      Platform.Chat.add_reaction(%{message_id: msg.id, participant_id: p.id, emoji: "👍"})
      Platform.Chat.pin_message(%{space_id: space.id, message_id: msg.id, pinned_by: p.id})
      Platform.Chat.create_canvas_with_message(space.id, p.id, %{canvas_type: "table"})
      Platform.Chat.list_reactions_for_messages([msg1.id, msg2.id])
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Platform.Chat.{Attachment, Canvas, Message, Participant, Pin, Reaction, Space, Thread}
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Repo

  # ── Spaces ─────────────────────────────────────────────────────────────────

  @doc """
  Create a new chat space (channel, dm, or group).

  Required attrs: `:name`, `:slug`, `:kind`.
  Optional: `:workspace_id`, `:description`, `:topic`, `:metadata`.
  """
  @spec create_space(map()) :: {:ok, Space.t()} | {:error, Ecto.Changeset.t()}
  def create_space(attrs) do
    result =
      %Space{}
      |> Space.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, space} ->
        :telemetry.execute(
          [:platform, :chat, :space_created],
          %{system_time: System.system_time()},
          %{space_id: space.id, slug: space.slug, kind: space.kind}
        )

      _ ->
        :ok
    end

    result
  end

  @doc "Fetch a space by primary key. Returns `nil` if not found."
  @spec get_space(binary()) :: Space.t() | nil
  def get_space(id), do: Repo.get(Space, id)

  @doc "Fetch a space by slug. Returns `nil` if not found."
  @spec get_space_by_slug(String.t()) :: Space.t() | nil
  def get_space_by_slug(slug) do
    Space
    |> where([s], s.slug == ^slug)
    |> order_by([s], asc: s.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  List spaces with optional filters.

  ## Options

    * `:workspace_id` — filter by workspace
    * `:kind`         — filter by kind ("channel", "dm", "group")
    * `:archived`     — `true` for archived only, `false` (default) for active only
  """
  @spec list_spaces(keyword()) :: [Space.t()]
  def list_spaces(opts \\ []) do
    {archived, opts} = Keyword.pop(opts, :archived, false)

    base =
      if archived do
        from(s in Space, where: not is_nil(s.archived_at), order_by: [asc: s.inserted_at])
      else
        from(s in Space, where: is_nil(s.archived_at), order_by: [asc: s.inserted_at])
      end

    opts
    |> Enum.reduce(base, fn
      {:workspace_id, wid}, q -> where(q, [s], s.workspace_id == ^wid)
      {:kind, kind}, q -> where(q, [s], s.kind == ^kind)
      _other, q -> q
    end)
    |> Repo.all()
  end

  @doc "Update a space's attributes."
  @spec update_space(Space.t(), map()) :: {:ok, Space.t()} | {:error, Ecto.Changeset.t()}
  def update_space(%Space{} = space, attrs) do
    space
    |> Space.changeset(attrs)
    |> Repo.update()
  end

  @doc "Soft-archive a space by setting `archived_at` to now."
  @spec archive_space(Space.t()) :: {:ok, Space.t()} | {:error, Ecto.Changeset.t()}
  def archive_space(%Space{} = space) do
    space
    |> Space.changeset(%{archived_at: DateTime.utc_now()})
    |> Repo.update()
  end

  # ── Participants ────────────────────────────────────────────────────────────

  @doc """
  Add a participant to a space.

  `space_id` is injected automatically; attrs must include:
  `:participant_type`, `:participant_id`, `:joined_at`.
  Optional: `:role`, `:display_name`, `:avatar_url`, `:attention_mode`.
  """
  @spec add_participant(binary(), map()) ::
          {:ok, Participant.t()} | {:error, Ecto.Changeset.t()}
  def add_participant(space_id, attrs) do
    attrs = Map.put(attrs, :space_id, space_id)

    result =
      %Participant{}
      |> Participant.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, p} ->
        :telemetry.execute(
          [:platform, :chat, :participant_added],
          %{system_time: System.system_time()},
          %{
            space_id: space_id,
            participant_id: p.id,
            participant_type: p.participant_type
          }
        )

        ChatPubSub.broadcast(space_id, {:participant_joined, p})

      _ ->
        :ok
    end

    result
  end

  @doc "Fetch a participant by primary key. Returns `nil` if not found."
  @spec get_participant(binary()) :: Participant.t() | nil
  def get_participant(id), do: Repo.get(Participant, id)

  @doc """
  List participants in a space.

  By default only active participants (left_at IS NULL) are returned.

  ## Options

    * `:participant_type` — filter by `"user"` or `"agent"`
    * `:include_left`     — include participants who have left (default: `false`)
  """
  @spec list_participants(binary(), keyword()) :: [Participant.t()]
  def list_participants(space_id, opts \\ []) do
    include_left = Keyword.get(opts, :include_left, false)
    participant_type = Keyword.get(opts, :participant_type)

    base =
      if include_left do
        from(p in Participant, where: p.space_id == ^space_id, order_by: [asc: p.joined_at])
      else
        from(p in Participant,
          where: p.space_id == ^space_id and is_nil(p.left_at),
          order_by: [asc: p.joined_at]
        )
      end

    base =
      if participant_type do
        where(base, [p], p.participant_type == ^participant_type)
      else
        base
      end

    Repo.all(base)
  end

  @doc "Update a participant's attributes (role, display_name, attention settings, etc.)."
  @spec update_participant(Participant.t(), map()) ::
          {:ok, Participant.t()} | {:error, Ecto.Changeset.t()}
  def update_participant(%Participant{} = participant, attrs) do
    participant
    |> Participant.changeset(attrs)
    |> Repo.update()
  end

  @doc "Soft-remove a participant by setting `left_at` to now."
  @spec remove_participant(Participant.t()) ::
          {:ok, Participant.t()} | {:error, Ecto.Changeset.t()}
  def remove_participant(%Participant{} = participant) do
    result =
      participant
      |> Participant.changeset(%{left_at: DateTime.utc_now()})
      |> Repo.update()

    case result do
      {:ok, p} ->
        :telemetry.execute(
          [:platform, :chat, :participant_removed],
          %{system_time: System.system_time()},
          %{space_id: p.space_id, participant_id: p.id}
        )

        ChatPubSub.broadcast(p.space_id, {:participant_left, p})

      _ ->
        :ok
    end

    result
  end

  # ── Messages ────────────────────────────────────────────────────────────────

  @doc """
  Post a new message to a space.

  Required attrs: `:space_id`, `:participant_id`, `:content_type`.
  Optional: `:thread_id`, `:content`, `:structured_content`, `:metadata`.
  """
  @spec post_message(map()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def post_message(attrs) do
    result =
      %Message{}
      |> Message.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, msg} ->
        publish_message_posted(msg)

      _ ->
        :ok
    end

    result
  end

  @doc """
  Post a new message and create any attachments in the same transaction.

  `attachment_attrs_list` should contain maps with `:filename`, `:content_type`,
  `:byte_size`, and `:storage_key`.
  """
  @spec post_message_with_attachments(map(), [map()]) ::
          {:ok, Message.t(), [Attachment.t()]} | {:error, term()}
  def post_message_with_attachments(attrs, attachment_attrs_list)
      when is_list(attachment_attrs_list) do
    multi =
      Multi.new()
      |> Multi.insert(:message, Message.changeset(%Message{}, attrs))

    multi =
      Enum.with_index(attachment_attrs_list)
      |> Enum.reduce(multi, fn {attachment_attrs, index}, multi ->
        Multi.run(multi, {:attachment, index}, fn repo, %{message: message} ->
          attachment_attrs
          |> Map.put(:message_id, message.id)
          |> then(&Attachment.changeset(%Attachment{}, &1))
          |> repo.insert()
        end)
      end)

    case Repo.transaction(multi) do
      {:ok, changes} ->
        message = changes.message

        attachments =
          changes
          |> Enum.filter(fn {key, _value} -> match?({:attachment, _}, key) end)
          |> Enum.sort_by(fn {{:attachment, index}, _value} -> index end)
          |> Enum.map(fn {_key, attachment} -> attachment end)

        publish_message_posted(message)
        {:ok, message, attachments}

      {:error, _operation, reason, _changes_so_far} ->
        {:error, reason}
    end
  end

  @doc "Fetch a message by primary key (integer). Returns `nil` if not found."
  @spec get_message(binary()) :: Message.t() | nil
  def get_message(id), do: Repo.get(Message, id)

  @doc """
  List non-deleted messages in a space, newest first.

  ## Options

    * `:limit`     — max number of messages (default: 50)
    * `:before_id` — keyset cursor — only messages with `id < before_id`
    * `:thread_id` — filter to a specific thread
  """
  @spec list_messages(binary(), keyword()) :: [Message.t()]
  def list_messages(space_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    before_id = Keyword.get(opts, :before_id)
    thread_id = Keyword.get(opts, :thread_id)

    base =
      from(m in Message,
        where: m.space_id == ^space_id and is_nil(m.deleted_at),
        order_by: [desc: m.id],
        limit: ^limit
      )

    base = if thread_id, do: where(base, [m], m.thread_id == ^thread_id), else: base
    base = if before_id, do: where(base, [m], m.id < ^before_id), else: base

    Repo.all(base)
  end

  @doc """
  Full-text search messages in a space using the generated `search_vector` column.

  Returns up to `limit` results ordered by recency (newest first).
  """
  @spec search_messages(binary(), String.t(), keyword()) :: [Message.t()]
  def search_messages(space_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    from(m in Message,
      where:
        m.space_id == ^space_id and
          is_nil(m.deleted_at) and
          fragment("search_vector @@ plainto_tsquery('english', ?)", ^query),
      order_by: [desc: m.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "Edit a message's content. Sets `edited_at` to now."
  @spec edit_message(Message.t(), String.t()) ::
          {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def edit_message(%Message{} = message, content) do
    result =
      message
      |> Message.changeset(%{content: content, edited_at: DateTime.utc_now()})
      |> Repo.update()

    case result do
      {:ok, msg} ->
        :telemetry.execute(
          [:platform, :chat, :message_edited],
          %{system_time: System.system_time()},
          %{message_id: msg.id, space_id: msg.space_id}
        )

        ChatPubSub.broadcast(msg.space_id, {:message_updated, msg})

      _ ->
        :ok
    end

    result
  end

  @doc "Soft-delete a message by setting `deleted_at` to now."
  @spec delete_message(Message.t()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def delete_message(%Message{} = message) do
    result =
      message
      |> Message.changeset(%{deleted_at: DateTime.utc_now()})
      |> Repo.update()

    case result do
      {:ok, msg} ->
        :telemetry.execute(
          [:platform, :chat, :message_deleted],
          %{system_time: System.system_time()},
          %{message_id: msg.id, space_id: msg.space_id}
        )

        ChatPubSub.broadcast(msg.space_id, {:message_deleted, msg})

      _ ->
        :ok
    end

    result
  end

  # ── Threads ─────────────────────────────────────────────────────────────────

  @doc """
  Create a new thread anchored to a space.

  `space_id` is injected automatically. Optional attrs:
  `:parent_message_id`, `:title`, `:metadata`.
  """
  @spec create_thread(binary(), map()) ::
          {:ok, Thread.t()} | {:error, Ecto.Changeset.t()}
  def create_thread(space_id, attrs \\ %{}) do
    attrs = Map.put(attrs, :space_id, space_id)

    %Thread{}
    |> Thread.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Fetch a thread by primary key. Returns `nil` if not found."
  @spec get_thread(binary()) :: Thread.t() | nil
  def get_thread(id), do: Repo.get(Thread, id)

  @doc """
  Find the thread anchored to a specific parent message.

  Returns `nil` if no thread has been started for this message yet.
  """
  @spec get_thread_for_message(binary()) :: Thread.t() | nil
  def get_thread_for_message(parent_message_id) do
    Repo.get_by(Thread, parent_message_id: parent_message_id)
  end

  @doc "List threads in a space, oldest first."
  @spec list_threads(binary()) :: [Thread.t()]
  def list_threads(space_id) do
    from(t in Thread, where: t.space_id == ^space_id, order_by: [asc: t.inserted_at])
    |> Repo.all()
  end

  @doc """
  Idempotent thread creation for a parent message.

  If a thread already exists anchored to `parent_message_id`, returns it.
  Otherwise creates a new thread in the space. Optional attrs: `:title`, `:metadata`.
  """
  @spec create_thread_for_message(binary(), binary(), map()) ::
          {:ok, Thread.t()} | {:error, Ecto.Changeset.t()}
  def create_thread_for_message(space_id, parent_message_id, attrs \\ %{}) do
    case Repo.get_by(Thread, parent_message_id: parent_message_id) do
      %Thread{} = existing ->
        {:ok, existing}

      nil ->
        attrs =
          attrs
          |> Map.put(:space_id, space_id)
          |> Map.put(:parent_message_id, parent_message_id)

        result =
          %Thread{}
          |> Thread.changeset(attrs)
          |> Repo.insert()

        case result do
          {:ok, thread} ->
            :telemetry.execute(
              [:platform, :chat, :thread_created],
              %{system_time: System.system_time()},
              %{space_id: space_id, thread_id: thread.id, parent_message_id: parent_message_id}
            )

          _ ->
            :ok
        end

        result
    end
  end

  @doc """
  Post a reply to an existing thread.

  Creates a message in `space_id` with `thread_id` set. Returns `{:error, :thread_not_found}`
  if the thread ID does not exist.
  """
  @spec reply_to_thread(binary(), binary(), map()) ::
          {:ok, Message.t()} | {:error, :thread_not_found | Ecto.Changeset.t()}
  def reply_to_thread(thread_id, participant_id, attrs) do
    case Repo.get(Thread, thread_id) do
      nil ->
        {:error, :thread_not_found}

      thread ->
        attrs =
          attrs
          |> Map.put(:space_id, thread.space_id)
          |> Map.put(:thread_id, thread_id)
          |> Map.put(:participant_id, participant_id)
          |> Map.put_new(:content_type, "text")

        post_message(attrs)
    end
  end

  # ── Reactions ───────────────────────────────────────────────────────────────

  @doc """
  Add a reaction to a message.

  Required attrs: `:message_id` (integer), `:participant_id`, `:emoji`.
  """
  @spec add_reaction(map()) :: {:ok, Reaction.t()} | {:error, Ecto.Changeset.t()}
  def add_reaction(attrs) do
    result =
      %Reaction{}
      |> Reaction.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, r} ->
        :telemetry.execute(
          [:platform, :chat, :reaction_added],
          %{system_time: System.system_time()},
          %{message_id: r.message_id, participant_id: r.participant_id, emoji: r.emoji}
        )

        case Repo.get(Message, r.message_id) do
          %Message{space_id: space_id} -> ChatPubSub.broadcast(space_id, {:reaction_added, r})
          nil -> :ok
        end

      _ ->
        :ok
    end

    result
  end

  @doc "Remove a reaction from a message. Returns `{:error, :not_found}` if absent."
  @spec remove_reaction(integer(), binary(), String.t()) ::
          {:ok, Reaction.t()} | {:error, :not_found | any()}
  def remove_reaction(message_id, participant_id, emoji) do
    case Repo.get_by(Reaction,
           message_id: message_id,
           participant_id: participant_id,
           emoji: emoji
         ) do
      nil ->
        {:error, :not_found}

      reaction ->
        with {:ok, deleted} <- Repo.delete(reaction) do
          :telemetry.execute(
            [:platform, :chat, :reaction_removed],
            %{system_time: System.system_time()},
            %{message_id: message_id, participant_id: participant_id, emoji: emoji}
          )

          case Repo.get(Message, message_id) do
            %Message{space_id: space_id} ->
              ChatPubSub.broadcast(
                space_id,
                {:reaction_removed,
                 %{message_id: message_id, participant_id: participant_id, emoji: emoji}}
              )

            nil ->
              :ok
          end

          {:ok, deleted}
        end
    end
  end

  @doc "List all reactions for a message, ordered by insertion time."
  @spec list_reactions(binary()) :: [Reaction.t()]
  def list_reactions(message_id) do
    from(r in Reaction,
      where: r.message_id == ^message_id,
      order_by: [asc: r.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  List reactions for a message grouped by emoji.

  Returns a list of maps with `:emoji`, `:count`, and `:participants`
  (list of participant_ids who reacted with that emoji), ordered by first
  appearance.

  Example:
      [%{emoji: "👍", count: 2, participants: ["uid-1", "uid-2"]}, ...]
  """
  @spec list_reactions_grouped(binary()) :: [
          %{emoji: String.t(), count: non_neg_integer(), participants: [binary()]}
        ]
  def list_reactions_grouped(message_id) do
    message_id
    |> list_reactions()
    |> Enum.group_by(& &1.emoji)
    |> Enum.map(fn {emoji, reactions} ->
      %{
        emoji: emoji,
        count: length(reactions),
        participants: Enum.map(reactions, & &1.participant_id)
      }
    end)
    |> Enum.sort_by(fn %{participants: ps} ->
      # stable ordering by first reactor's insertion (already sorted in list_reactions)
      List.first(ps)
    end)
  end

  @doc """
  Toggle a reaction on a message.

  If the participant has already reacted with this emoji, removes the reaction.
  Otherwise adds it. Returns `{:ok, :added, Reaction.t()}` or `{:ok, :removed, Reaction.t()}`.
  """
  @spec toggle_reaction(binary(), binary(), String.t()) ::
          {:ok, :added, Reaction.t()}
          | {:ok, :removed, Reaction.t()}
          | {:error, any()}
  def toggle_reaction(message_id, participant_id, emoji) do
    case Repo.get_by(Reaction,
           message_id: message_id,
           participant_id: participant_id,
           emoji: emoji
         ) do
      nil ->
        case add_reaction(%{message_id: message_id, participant_id: participant_id, emoji: emoji}) do
          {:ok, reaction} -> {:ok, :added, reaction}
          {:error, reason} -> {:error, reason}
        end

      _existing ->
        case remove_reaction(message_id, participant_id, emoji) do
          {:ok, reaction} -> {:ok, :removed, reaction}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Batch-load reactions for a list of message IDs in a single query.

  Returns `%{message_id => [Reaction.t()]}`. Message IDs with no reactions
  are omitted from the result map.
  """
  @spec list_reactions_for_messages([binary()]) :: %{binary() => [Reaction.t()]}
  def list_reactions_for_messages([]), do: %{}

  def list_reactions_for_messages(message_ids) do
    from(r in Reaction,
      where: r.message_id in ^message_ids,
      order_by: [asc: r.inserted_at]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.message_id)
  end

  # ── Pins ────────────────────────────────────────────────────────────────────

  @doc """
  Pin a message in a space.

  Required attrs: `:space_id`, `:message_id` (integer), `:pinned_by`.
  """
  @spec pin_message(map()) :: {:ok, Pin.t()} | {:error, Ecto.Changeset.t()}
  def pin_message(attrs) do
    result =
      %Pin{}
      |> Pin.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, pin} ->
        :telemetry.execute(
          [:platform, :chat, :pin_added],
          %{system_time: System.system_time()},
          %{space_id: pin.space_id, message_id: pin.message_id, pinned_by: pin.pinned_by}
        )

        ChatPubSub.broadcast(pin.space_id, {:pin_added, pin})

      _ ->
        :ok
    end

    result
  end

  @doc "Unpin a message from a space. Returns `{:error, :not_found}` if not pinned."
  @spec unpin_message(binary(), integer()) ::
          {:ok, Pin.t()} | {:error, :not_found | any()}
  def unpin_message(space_id, message_id) do
    case Repo.get_by(Pin, space_id: space_id, message_id: message_id) do
      nil ->
        {:error, :not_found}

      pin ->
        with {:ok, deleted} <- Repo.delete(pin) do
          :telemetry.execute(
            [:platform, :chat, :pin_removed],
            %{system_time: System.system_time()},
            %{space_id: space_id, message_id: message_id}
          )

          ChatPubSub.broadcast(
            space_id,
            {:pin_removed, %{space_id: space_id, message_id: message_id}}
          )

          {:ok, deleted}
        end
    end
  end

  @doc "List pinned messages in a space, oldest first."
  @spec list_pins(binary()) :: [Pin.t()]
  def list_pins(space_id) do
    from(p in Pin,
      where: p.space_id == ^space_id,
      order_by: [asc: p.inserted_at]
    )
    |> Repo.all()
  end

  # ── Canvases ─────────────────────────────────────────────────────────────────

  @doc """
  Create a canvas attached to a space (and optionally a message).

  Required attrs: `:space_id`, `:created_by`, `:canvas_type`.
  Optional: `:message_id`, `:title`, `:state`, `:component_module`, `:metadata`.
  """
  @spec create_canvas(map()) :: {:ok, Canvas.t()} | {:error, Ecto.Changeset.t()}
  def create_canvas(attrs) do
    attrs = stringify_canvas_payload(attrs)

    result =
      %Canvas{}
      |> Canvas.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, canvas} ->
        publish_canvas_created(canvas)

      _ ->
        :ok
    end

    result
  end

  @doc """
  Create a canvas and its companion chat message in one transaction.

  The resulting message uses `content_type: "canvas"` and stores a lightweight
  pointer in `structured_content` so the LiveView can reopen the canvas later.
  """
  @spec create_canvas_with_message(binary(), binary(), map()) ::
          {:ok, Canvas.t(), Message.t()} | {:error, term()}
  def create_canvas_with_message(space_id, participant_id, attrs \\ %{}) do
    attrs = stringify_canvas_payload(attrs)

    message_attrs = %{
      space_id: space_id,
      participant_id: participant_id,
      content_type: "canvas",
      content: Map.get(attrs, "message_content") || default_canvas_message(attrs),
      structured_content: %{
        "canvas_type" => Map.get(attrs, "canvas_type", "custom"),
        "title" => Map.get(attrs, "title")
      }
    }

    multi =
      Multi.new()
      |> Multi.run(:canvas, fn repo, _changes ->
        attrs
        |> Map.put("space_id", space_id)
        |> Map.put("created_by", participant_id)
        |> then(&Canvas.changeset(%Canvas{}, &1))
        |> repo.insert()
      end)
      |> Multi.run(:message, fn repo, %{canvas: canvas} ->
        attrs = put_in(message_attrs, [:structured_content, "canvas_id"], canvas.id)

        %Message{}
        |> Message.changeset(attrs)
        |> repo.insert()
      end)
      |> Multi.run(:canvas_link, fn repo, %{canvas: canvas, message: message} ->
        canvas
        |> Canvas.changeset(%{"message_id" => message.id})
        |> repo.update()
      end)

    case Repo.transaction(multi) do
      {:ok, %{canvas_link: canvas, message: message}} ->
        publish_canvas_created(canvas)
        publish_message_posted(message)
        {:ok, canvas, message}

      {:error, _operation, reason, _changes_so_far} ->
        {:error, reason}
    end
  end

  @doc "Fetch a canvas by primary key. Returns `nil` if not found."
  @spec get_canvas(binary()) :: Canvas.t() | nil
  def get_canvas(id), do: Repo.get(Canvas, id)

  @doc "Update a canvas's state or metadata."
  @spec update_canvas(Canvas.t(), map()) ::
          {:ok, Canvas.t()} | {:error, Ecto.Changeset.t()}
  def update_canvas(%Canvas{} = canvas, attrs) do
    attrs = stringify_canvas_payload(attrs)

    result =
      canvas
      |> Canvas.changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated} ->
        publish_canvas_updated(updated)

      _ ->
        :ok
    end

    result
  end

  @doc "Merge new keys into a canvas's persisted state map."
  @spec update_canvas_state(Canvas.t(), map()) ::
          {:ok, Canvas.t()} | {:error, Ecto.Changeset.t()}
  def update_canvas_state(%Canvas{} = canvas, state_updates) when is_map(state_updates) do
    merged_state =
      canvas.state
      |> Kernel.||(%{})
      |> Map.merge(stringify_canvas_payload(state_updates))

    update_canvas(canvas, %{state: merged_state})
  end

  @doc "List canvases in a space, oldest first."
  @spec list_canvases(binary()) :: [Canvas.t()]
  def list_canvases(space_id) do
    from(c in Canvas, where: c.space_id == ^space_id, order_by: [asc: c.inserted_at])
    |> Repo.all()
  end

  # ── Attachments ──────────────────────────────────────────────────────────────

  @doc """
  Record a new attachment for a message.

  Required attrs: `:message_id` (integer), `:filename`, `:content_type`,
  `:byte_size`, `:storage_key`.
  Optional: `:metadata`.
  """
  @spec create_attachment(map()) :: {:ok, Attachment.t()} | {:error, Ecto.Changeset.t()}
  def create_attachment(attrs) do
    %Attachment{}
    |> Attachment.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Fetch an attachment by primary key. Returns `nil` if not found."
  @spec get_attachment(binary()) :: Attachment.t() | nil
  def get_attachment(id), do: Repo.get(Attachment, id)

  @doc """
  Fetch an attachment only when its parent message still exists and is not soft-deleted.
  """
  @spec get_visible_attachment(binary()) :: Attachment.t() | nil
  def get_visible_attachment(id) do
    from(a in Attachment,
      join: m in Message,
      on: m.id == a.message_id,
      where: a.id == ^id and is_nil(m.deleted_at),
      select: a
    )
    |> Repo.one()
  end

  @doc "List attachments for a message, oldest first."
  @spec list_attachments(binary()) :: [Attachment.t()]
  def list_attachments(message_id) do
    from(a in Attachment,
      where: a.message_id == ^message_id,
      order_by: [asc: a.inserted_at]
    )
    |> Repo.all()
  end

  @doc "Batch-load attachments for a list of message IDs in a single query."
  @spec list_attachments_for_messages([binary()]) :: %{binary() => [Attachment.t()]}
  def list_attachments_for_messages([]), do: %{}

  def list_attachments_for_messages(message_ids) do
    from(a in Attachment,
      where: a.message_id in ^message_ids,
      order_by: [asc: a.inserted_at]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.message_id)
  end

  defp publish_canvas_created(canvas) do
    :telemetry.execute(
      [:platform, :chat, :canvas_created],
      %{system_time: System.system_time()},
      %{
        canvas_id: canvas.id,
        space_id: canvas.space_id,
        message_id: canvas.message_id,
        canvas_type: canvas.canvas_type
      }
    )

    ChatPubSub.broadcast(canvas.space_id, {:canvas_created, canvas})
    ChatPubSub.broadcast_canvas(canvas.id, {:canvas_updated, canvas})
  end

  defp publish_canvas_updated(canvas) do
    :telemetry.execute(
      [:platform, :chat, :canvas_updated],
      %{system_time: System.system_time()},
      %{
        canvas_id: canvas.id,
        space_id: canvas.space_id,
        message_id: canvas.message_id,
        canvas_type: canvas.canvas_type
      }
    )

    ChatPubSub.broadcast(canvas.space_id, {:canvas_updated, canvas})
    ChatPubSub.broadcast_canvas(canvas.id, {:canvas_updated, canvas})
  end

  defp default_canvas_message(attrs) do
    title = Map.get(attrs, "title") || "Untitled Canvas"
    "opened a live canvas: #{title}"
  end

  defp stringify_canvas_payload(value) when is_map(value) do
    Map.new(value, fn
      {key, nested} when is_atom(key) -> {Atom.to_string(key), stringify_canvas_payload(nested)}
      {key, nested} -> {key, stringify_canvas_payload(nested)}
    end)
  end

  defp stringify_canvas_payload(value) when is_list(value) do
    Enum.map(value, &stringify_canvas_payload/1)
  end

  defp stringify_canvas_payload(value), do: value

  defp publish_message_posted(msg) do
    :telemetry.execute(
      [:platform, :chat, :message_posted],
      %{system_time: System.system_time()},
      %{
        space_id: msg.space_id,
        message_id: msg.id,
        participant_id: msg.participant_id
      }
    )

    ChatPubSub.broadcast(msg.space_id, {:new_message, msg})
  end
end
