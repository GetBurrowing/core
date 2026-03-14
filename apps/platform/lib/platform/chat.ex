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

      # Reactions / Pins / Canvases / Attachments
      Platform.Chat.add_reaction(%{message_id: msg.id, participant_id: p.id, emoji: "👍"})
      Platform.Chat.pin_message(%{space_id: space.id, message_id: msg.id, pinned_by: p.id})
  """

  import Ecto.Query

  alias Platform.Chat.{Attachment, Canvas, Message, Participant, Pin, Reaction, Space, Thread}
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
  def get_space_by_slug(slug), do: Repo.get_by(Space, slug: slug)

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
        :telemetry.execute(
          [:platform, :chat, :message_posted],
          %{system_time: System.system_time()},
          %{
            space_id: msg.space_id,
            message_id: msg.id,
            participant_id: msg.participant_id
          }
        )

      _ ->
        :ok
    end

    result
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

  @doc "List threads in a space, oldest first."
  @spec list_threads(binary()) :: [Thread.t()]
  def list_threads(space_id) do
    from(t in Thread, where: t.space_id == ^space_id, order_by: [asc: t.inserted_at])
    |> Repo.all()
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

          {:ok, deleted}
        end
    end
  end

  @doc "List all reactions for a message, ordered by insertion time."
  @spec list_reactions(integer()) :: [Reaction.t()]
  def list_reactions(message_id) do
    from(r in Reaction,
      where: r.message_id == ^message_id,
      order_by: [asc: r.inserted_at]
    )
    |> Repo.all()
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
    %Canvas{}
    |> Canvas.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Fetch a canvas by primary key. Returns `nil` if not found."
  @spec get_canvas(binary()) :: Canvas.t() | nil
  def get_canvas(id), do: Repo.get(Canvas, id)

  @doc "Update a canvas's state or metadata."
  @spec update_canvas(Canvas.t(), map()) ::
          {:ok, Canvas.t()} | {:error, Ecto.Changeset.t()}
  def update_canvas(%Canvas{} = canvas, attrs) do
    canvas
    |> Canvas.changeset(attrs)
    |> Repo.update()
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

  @doc "List attachments for a message, oldest first."
  @spec list_attachments(integer()) :: [Attachment.t()]
  def list_attachments(message_id) do
    from(a in Attachment,
      where: a.message_id == ^message_id,
      order_by: [asc: a.inserted_at]
    )
    |> Repo.all()
  end
end
