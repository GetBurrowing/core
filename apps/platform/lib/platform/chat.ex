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
      Platform.Chat.create_canvas_with_message(space.id, p.id, %{title: "Sprint board"})
      Platform.Chat.list_reactions_for_messages([msg1.id, msg2.id])
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Platform.Agents.Agent

  alias Platform.Chat.{
    Attachment,
    Canvas,
    Message,
    Participant,
    Pin,
    Reaction,
    Space,
    SpaceAgent,
    Thread
  }

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
    {include_execution, opts} = Keyword.pop(opts, :include_execution, false)

    base =
      if archived do
        from(s in Space, where: not is_nil(s.archived_at), order_by: [asc: s.inserted_at])
      else
        from(s in Space, where: is_nil(s.archived_at), order_by: [asc: s.inserted_at])
      end

    # Exclude execution spaces by default
    base =
      if include_execution do
        base
      else
        where(base, [s], s.kind != "execution")
      end

    opts
    |> Enum.reduce(base, fn
      # `workspace_id: nil` means "match spaces with NULL workspace_id" (the
      # single-tenant / default-org case), not "skip the filter". Ecto refuses
      # to compare against nil so we must branch to `is_nil/1`.
      {:workspace_id, nil}, q -> where(q, [s], is_nil(s.workspace_id))
      {:workspace_id, wid}, q -> where(q, [s], s.workspace_id == ^wid)
      {:kind, kind}, q -> where(q, [s], s.kind == ^kind)
      _other, q -> q
    end)
    |> Repo.all()
  end

  @doc "List spaces an agent is a member of via the `chat_participants` roster."
  @spec list_spaces_for_agent(binary(), keyword()) :: [Space.t()]
  def list_spaces_for_agent(agent_id, opts \\ []) when is_binary(agent_id) do
    kind = Keyword.get(opts, :kind)

    base =
      from(s in Space,
        join: p in Participant,
        on: p.space_id == s.id,
        where:
          p.participant_type == "agent" and
            p.participant_id == ^agent_id and
            is_nil(p.left_at) and
            is_nil(s.archived_at),
        order_by: [asc: s.inserted_at]
      )

    base = if kind, do: where(base, [s], s.kind == ^kind), else: base
    Repo.all(base)
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

  # ── Conversations (DM / Group / Channel creation) ─────────────────────────

  @doc """
  Find an existing DM between initiator and target, or create one.

  `target_type` is "user" or "agent", `target_id` is the UUID.
  Returns `{:ok, space}`.
  """
  @spec find_or_create_dm(binary(), String.t(), binary(), keyword()) ::
          {:ok, Space.t()} | {:error, term()}
  def find_or_create_dm(user_id, target_type, target_id, _opts \\ []) do
    # Look for an existing DM space where both participants are active
    existing =
      from(s in Space,
        join: p1 in Participant,
        on: p1.space_id == s.id,
        join: p2 in Participant,
        on: p2.space_id == s.id,
        where:
          s.kind == "dm" and s.is_direct == true and is_nil(s.archived_at) and
            p1.participant_type == "user" and p1.participant_id == ^user_id and
            is_nil(p1.left_at) and
            p2.participant_type == ^target_type and p2.participant_id == ^target_id and
            is_nil(p2.left_at),
        limit: 1,
        select: s
      )
      |> Repo.one()

    case existing do
      %Space{} = space ->
        {:ok, space}

      nil ->
        create_dm_space(user_id, target_type, target_id)
    end
  end

  defp create_dm_space(user_id, target_type, target_id) do
    Multi.new()
    |> Multi.insert(
      :space,
      Space.changeset(%Space{}, %{
        kind: "dm",
        is_direct: true,
        created_by: user_id
      })
    )
    |> Multi.run(:initiator, fn _repo, %{space: space} ->
      add_participant(space.id, %{
        participant_type: "user",
        participant_id: user_id,
        display_name: user_display_name(user_id),
        joined_at: DateTime.utc_now()
      })
    end)
    |> Multi.run(:target, fn _repo, %{space: space} ->
      if target_type == "agent" do
        case Repo.get(Agent, target_id) do
          %Agent{} = agent ->
            ensure_agent_participant(space.id, agent)

          nil ->
            {:error, :agent_not_found}
        end
      else
        add_participant(space.id, %{
          participant_type: "user",
          participant_id: target_id,
          display_name: user_display_name(target_id),
          joined_at: DateTime.utc_now()
        })
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{space: space}} -> {:ok, space}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  @doc """
  Create a group conversation with multiple participants.

  `participant_specs` is a list of `%{type: "user"|"agent", id: uuid}`.
  If only 1 other participant, redirects to find_or_create_dm.
  """
  @spec create_group_conversation(binary(), [map()], keyword()) ::
          {:ok, Space.t()} | {:error, term()}
  def create_group_conversation(user_id, participant_specs, _opts \\ []) do
    # If only one other participant, create a DM instead
    if length(participant_specs) == 1 do
      [spec] = participant_specs
      type = Map.get(spec, :type) || Map.get(spec, "type")
      id = Map.get(spec, :id) || Map.get(spec, "id")
      find_or_create_dm(user_id, type, id)
    else
      multi =
        Multi.new()
        |> Multi.insert(
          :space,
          Space.changeset(%Space{}, %{
            kind: "group",
            is_direct: false,
            created_by: user_id
          })
        )
        |> Multi.run(:creator, fn _repo, %{space: space} ->
          add_participant(space.id, %{
            participant_type: "user",
            participant_id: user_id,
            display_name: user_display_name(user_id),
            joined_at: DateTime.utc_now()
          })
        end)

      multi =
        participant_specs
        |> Enum.with_index()
        |> Enum.reduce(multi, fn {spec, idx}, multi ->
          type = Map.get(spec, :type) || Map.get(spec, "type")
          id = Map.get(spec, :id) || Map.get(spec, "id")

          Multi.run(multi, {:participant, idx}, fn _repo, %{space: space} ->
            if type == "agent" do
              case Repo.get(Agent, id) do
                %Agent{} = agent -> ensure_agent_participant(space.id, agent)
                nil -> {:error, :agent_not_found}
              end
            else
              add_participant(space.id, %{
                participant_type: "user",
                participant_id: id,
                display_name: user_display_name(id),
                joined_at: DateTime.utc_now()
              })
            end
          end)
        end)

      case Repo.transaction(multi) do
        {:ok, %{space: space}} -> {:ok, space}
        {:error, _step, reason, _} -> {:error, reason}
      end
    end
  end

  @doc "Create a channel space. Requires name and slug."
  @spec create_channel(map()) :: {:ok, Space.t()} | {:error, Ecto.Changeset.t()}
  def create_channel(attrs) do
    attrs = Map.put(attrs, :kind, "channel")
    create_space(attrs)
  end

  @doc """
  Promote a group conversation to a channel.

  Only works on kind=group spaces. Sets name and slug from attrs.
  """
  @spec promote_to_channel(Space.t(), map()) ::
          {:ok, Space.t()} | {:error, :not_promotable | Ecto.Changeset.t()}
  def promote_to_channel(%Space{kind: "group", is_direct: false} = space, attrs) do
    space
    |> Space.changeset(Map.merge(attrs, %{kind: "channel"}))
    |> Repo.update()
  end

  def promote_to_channel(%Space{kind: "dm"}, _attrs), do: {:error, :not_promotable}
  def promote_to_channel(%Space{is_direct: true}, _attrs), do: {:error, :not_promotable}
  def promote_to_channel(%Space{kind: "channel"}, _attrs), do: {:error, :not_promotable}
  def promote_to_channel(_, _), do: {:error, :not_promotable}

  @doc """
  List all non-archived spaces where the user is an active participant,
  ordered by most recent message (or inserted_at).
  """
  @spec list_user_conversations(binary()) :: [Space.t()]
  def list_user_conversations(user_id) do
    from(s in Space,
      join: p in Participant,
      on: p.space_id == s.id,
      left_join: m in Message,
      on: m.space_id == s.id and is_nil(m.deleted_at),
      where:
        p.participant_type == "user" and p.participant_id == ^user_id and
          is_nil(p.left_at) and is_nil(s.archived_at),
      group_by: s.id,
      order_by: [desc: fragment("COALESCE(MAX(?), ?)", m.inserted_at, s.inserted_at)],
      select: s
    )
    |> Repo.all()
  end

  @doc """
  Compute a display name for a space relative to the current user.

  - Channel: space.name
  - DM: the other participant's display_name
  - Group: comma-separated names (excluding current user), truncated
  """
  @spec display_name_for_space(Space.t(), [Participant.t()], binary()) :: String.t()
  def display_name_for_space(%Space{kind: "channel"} = space, _participants, _current_user_id) do
    space.name || "Unnamed Channel"
  end

  def display_name_for_space(%Space{kind: "dm"}, participants, current_user_id) do
    other =
      Enum.find(participants, fn p ->
        p.participant_id != current_user_id and is_nil(p.left_at)
      end)

    case other do
      %Participant{display_name: name} when is_binary(name) and name != "" -> name
      _ -> "DM"
    end
  end

  def display_name_for_space(%Space{kind: "group"}, participants, current_user_id) do
    names =
      participants
      |> Enum.filter(fn p -> p.participant_id != current_user_id and is_nil(p.left_at) end)
      |> Enum.map(fn p -> p.display_name || "User" end)

    case names do
      [] ->
        "Group"

      list ->
        joined = Enum.join(list, ", ")
        if String.length(joined) > 40, do: String.slice(joined, 0, 37) <> "...", else: joined
    end
  end

  @doc "List active agents for the conversation picker."
  @spec list_agents_for_picker() :: [Agent.t()]
  def list_agents_for_picker do
    from(a in Agent,
      where: a.status == "active",
      order_by: [asc: a.name]
    )
    |> Repo.all()
  end

  defp user_display_name(user_id) do
    case Platform.Accounts.get_user(user_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      %{email: email} when is_binary(email) -> email
      _ -> "User"
    end
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

  @doc """
  Build a map of `participant.id → accent_color_string` for agent participants in a space.

  Used to supply per-agent color identity to chat rendering. Agents without a color
  fall back to the default blue accent via `ColorPalette.accent_for/1`.
  """
  @spec agent_color_map_for_participants([Participant.t()]) :: %{binary() => binary()}
  def agent_color_map_for_participants(participants) do
    alias Platform.Agents.ColorPalette

    # Build map: agent_id → participant.id (for agent participants only)
    agent_participant_ids =
      participants
      |> Enum.filter(&(&1.participant_type == "agent"))
      |> Map.new(fn p -> {p.participant_id, p.id} end)

    cond do
      map_size(agent_participant_ids) == 0 ->
        %{}

      :color not in Agent.__schema__(:fields) ->
        %{}

      true ->
        agent_ids = Map.keys(agent_participant_ids)

        from(a in Agent, where: a.id in ^agent_ids, select: {a.id, a.color})
        |> Repo.all()
        |> Map.new(fn {agent_id, color} ->
          participant_id = Map.fetch!(agent_participant_ids, agent_id)
          {participant_id, ColorPalette.accent_for(color)}
        end)
    end
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

  @doc """
  Ensure an agent is an active participant in the space.
  """
  @spec ensure_agent_participant(binary(), Agent.t() | binary(), keyword()) ::
          {:ok, Participant.t()} | {:error, term()}
  def ensure_agent_participant(space_id, agent_or_id, opts \\ [])

  def ensure_agent_participant(space_id, %Agent{} = agent, opts) do
    display_name = Keyword.get(opts, :display_name, agent.name)
    attention_mode = Keyword.get(opts, :attention_mode, "mention")
    joined_at = Keyword.get(opts, :joined_at, DateTime.utc_now())

    case Repo.get_by(Participant,
           space_id: space_id,
           participant_type: "agent",
           participant_id: agent.id
         ) do
      nil ->
        add_participant(space_id, %{
          participant_type: "agent",
          participant_id: agent.id,
          display_name: display_name,
          attention_mode: attention_mode,
          joined_at: joined_at
        })

      %Participant{left_at: nil} = participant ->
        {:ok, participant}

      %Participant{} = participant ->
        update_participant(participant, %{
          left_at: nil,
          display_name: display_name,
          attention_mode: attention_mode,
          joined_at: joined_at
        })
    end
  end

  def ensure_agent_participant(space_id, agent_id, opts) when is_binary(agent_id) do
    case Repo.get(Agent, agent_id) do
      %Agent{} = agent -> ensure_agent_participant(space_id, agent, opts)
      nil -> {:error, :not_found}
    end
  end

  # ── Messages ────────────────────────────────────────────────────────────────

  @doc """
  Post a new message to a space.

  Required attrs: `:space_id`, `:participant_id`, `:content_type`.
  Optional: `:thread_id`, `:content`, `:structured_content`, `:metadata`.
  """
  @spec post_message(map(), keyword()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def post_message(attrs, opts \\ []) do
    result =
      %Message{}
      |> Message.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, msg} ->
        publish_message_posted(msg, opts)

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
  @spec post_message_with_attachments(map(), [map()], keyword()) ::
          {:ok, Message.t(), [Attachment.t()]} | {:error, term()}
  def post_message_with_attachments(attrs, attachment_attrs_list, opts \\ [])
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

        publish_message_posted(message, opts)
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
    * `:top_level_only` — when `true`, include only messages where `thread_id` is `NULL`
  """
  @spec list_messages(binary(), keyword()) :: [Message.t()]
  def list_messages(space_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    before_id = Keyword.get(opts, :before_id)
    thread_id = Keyword.get(opts, :thread_id)
    top_level_only = Keyword.get(opts, :top_level_only, false)

    base =
      from(m in Message,
        where: m.space_id == ^space_id and is_nil(m.deleted_at),
        order_by: [desc: m.inserted_at],
        limit: ^limit
      )

    base =
      cond do
        thread_id -> where(base, [m], m.thread_id == ^thread_id)
        top_level_only -> where(base, [m], is_nil(m.thread_id))
        true -> base
      end

    base = if before_id, do: where(base, [m], m.id < ^before_id), else: base

    Repo.all(base)
  end

  @doc """
  For a list of message IDs, returns thread preview data for any that have threads with replies.

  Returns `%{message_id => %{thread_id: id, reply_count: count, last_reply_at: datetime}}`.
  """
  @spec thread_previews_for_messages([binary()]) :: map()
  def thread_previews_for_messages([]), do: %{}

  def thread_previews_for_messages(message_ids) do
    from(t in Thread,
      where: t.parent_message_id in ^message_ids,
      left_join: m in Message,
      on: m.thread_id == t.id and is_nil(m.deleted_at),
      group_by: [t.id, t.parent_message_id],
      having: count(m.id) > 0,
      select:
        {t.parent_message_id,
         %{thread_id: t.id, reply_count: count(m.id), last_reply_at: max(m.inserted_at)}}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Full-text search messages in a space using PostgreSQL text search.

  Returns up to `limit` results ordered by search rank (highest first) with a
  lightweight highlighted excerpt in the virtual `search_headline` field.
  Blank queries return an empty list.
  """
  @spec search_messages(binary(), String.t(), keyword()) :: [Message.t()]
  def search_messages(space_id, query, opts \\ [])
  def search_messages(_space_id, query, _opts) when not is_binary(query) or query == "", do: []

  def search_messages(space_id, query, opts) do
    limit = Keyword.get(opts, :limit, 20)
    trimmed_query = String.trim(query)

    if trimmed_query == "" do
      []
    else
      from(m in Message,
        where:
          m.space_id == ^space_id and
            is_nil(m.deleted_at) and
            fragment("search_vector @@ websearch_to_tsquery('english', ?)", ^trimmed_query),
        select_merge: %{
          search_rank:
            fragment(
              "ts_rank_cd(search_vector, websearch_to_tsquery('english', ?))",
              ^trimmed_query
            ),
          search_headline:
            fragment(
              "ts_headline('english', coalesce(?, ''), websearch_to_tsquery('english', ?), 'StartSel=<mark>, StopSel=</mark>, MaxWords=18, MinWords=5')",
              m.content,
              ^trimmed_query
            )
        },
        order_by: [
          desc:
            fragment(
              "ts_rank_cd(search_vector, websearch_to_tsquery('english', ?))",
              ^trimmed_query
            ),
          desc: m.inserted_at
        ],
        limit: ^limit
      )
      |> Repo.all()
    end
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

  @doc "Returns the number of replies in a thread."
  @spec count_thread_replies(binary()) :: non_neg_integer()
  def count_thread_replies(thread_id) do
    from(m in Message, where: m.thread_id == ^thread_id and is_nil(m.deleted_at), select: count())
    |> Repo.one()
  end

  @doc "Batch version: returns `%{thread_id => reply_count}` for the given thread IDs."
  @spec list_thread_reply_counts([binary()]) :: %{binary() => non_neg_integer()}
  def list_thread_reply_counts([]), do: %{}

  def list_thread_reply_counts(thread_ids) do
    from(m in Message,
      where: m.thread_id in ^thread_ids and is_nil(m.deleted_at),
      group_by: m.thread_id,
      select: {m.thread_id, count()}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  For a list of message IDs, returns thread preview data for any that have threads with replies.

  Returns `%{message_id => %{thread_id: id, reply_count: count, last_reply_at: datetime}}`.
  """
  @spec thread_previews_for_messages([binary()]) :: map()
  def thread_previews_for_messages([]), do: %{}

  def thread_previews_for_messages(message_ids) do
    from(t in Thread,
      where: t.parent_message_id in ^message_ids,
      left_join: m in Message,
      on: m.thread_id == t.id and is_nil(m.deleted_at),
      group_by: [t.id, t.parent_message_id],
      having: count(m.id) > 0,
      select:
        {t.parent_message_id,
         %{thread_id: t.id, reply_count: count(m.id), last_reply_at: max(m.inserted_at)}}
    )
    |> Repo.all()
    |> Map.new()
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
  #
  # First-class space-scoped canvases (ADR 0036). A canvas owns a canonical
  # document. Messages may reference a canvas via `chat_messages.canvas_id`.

  @doc """
  Create a canvas with a validated canonical document.

  Accepts either a raw map of attrs or the tuple form `{space_id, created_by, document}`.
  Required fields: `:space_id`, `:created_by`. Optional: `:title`, `:document`,
  `:metadata`, `:cloned_from`. If `:document` is omitted, a blank canonical
  document is seeded via `CanvasDocument.new/0`.
  """
  @spec create_canvas(map()) :: {:ok, Canvas.t()} | {:error, Ecto.Changeset.t()}
  def create_canvas(attrs) do
    attrs = stringify_canvas_payload(attrs)

    result =
      %Canvas{}
      |> Canvas.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, canvas} -> publish_canvas_created(canvas)
      _ -> :ok
    end

    result
  end

  @doc """
  Create a canvas and its companion chat message atomically.

  The message's `canvas_id` FK is set directly — no back-patch step. Messages
  reference canvases; canvases do not reference messages.
  """
  @spec create_canvas_with_message(binary(), binary(), map()) ::
          {:ok, Canvas.t(), Message.t()} | {:error, term()}
  def create_canvas_with_message(space_id, participant_id, attrs \\ %{}) do
    attrs = stringify_canvas_payload(attrs)

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
        message_attrs = %{
          space_id: space_id,
          participant_id: participant_id,
          canvas_id: canvas.id,
          content_type: "canvas",
          content: Map.get(attrs, "message_content") || default_canvas_message(attrs),
          structured_content: %{
            "canvas_id" => canvas.id,
            "title" => Map.get(attrs, "title")
          }
        }

        %Message{}
        |> Message.changeset(message_attrs)
        |> repo.insert()
      end)

    case Repo.transaction(multi) do
      {:ok, %{canvas: canvas, message: message}} ->
        publish_canvas_created(canvas)
        publish_message_posted(message)
        {:ok, canvas, message}

      {:error, _operation, reason, _changes_so_far} ->
        {:error, reason}
    end
  end

  @doc "Fetch a canvas. Returns `nil` if not found or soft-deleted."
  @spec get_canvas(binary()) :: Canvas.t() | nil
  def get_canvas(id) do
    case Repo.get(Canvas, id) do
      %Canvas{deleted_at: nil} = canvas -> canvas
      _ -> nil
    end
  end

  @doc "Update canvas metadata/title. Document changes go through `patch_canvas/2`."
  @spec update_canvas(Canvas.t(), map()) ::
          {:ok, Canvas.t()} | {:error, Ecto.Changeset.t()}
  def update_canvas(%Canvas{} = canvas, attrs) do
    attrs = stringify_canvas_payload(attrs)

    result =
      canvas
      |> Canvas.changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated} -> publish_canvas_updated(updated)
      _ -> :ok
    end

    result
  end

  @doc "List canvases in a space (excluding soft-deleted), oldest first."
  @spec list_canvases(binary()) :: [Canvas.t()]
  def list_canvases(space_id) do
    from(c in Canvas,
      where: c.space_id == ^space_id and is_nil(c.deleted_at),
      order_by: [asc: c.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Apply `CanvasPatch` operations to a canvas document.

  Routes through `Platform.Chat.Canvas.Server` for rebase-or-reject concurrency
  (ADR 0036, Phase 3). Callers that have a specific `base_revision` should use
  `Canvas.Server.apply_patches/3` directly; this helper assumes head writes
  and refetches the canvas for the return value.
  """
  @spec patch_canvas(Canvas.t(), [Platform.Chat.CanvasPatch.operation()]) ::
          {:ok, Canvas.t()} | {:conflict, map()} | {:error, term()}
  def patch_canvas(%Canvas{} = canvas, operations) when is_list(operations) do
    alias Platform.Chat.Canvas.Server, as: CanvasServer

    case CanvasServer.describe(canvas.id) do
      {:ok, %{revision: current_revision}} ->
        case CanvasServer.apply_patches(canvas.id, operations, current_revision) do
          {:ok, _new_revision} ->
            # Refetch to return the fresh struct; the server has already
            # triggered an async persist.
            {:ok, get_canvas(canvas.id) || canvas}

          {:conflict, payload} ->
            {:conflict, payload}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Clone a canvas into another space (ADR 0036, Phase 6).

  Produces a new canvas with:

    * a new canvas id
    * freshly-generated node ids (canvas-local uniqueness)
    * document structure copied verbatim
    * revision reset to 1
    * `created_by` = `actor_id`
    * `cloned_from` = the source canvas id

  Space-scoped `$bind` references whose target resource does not exist in the
  target space are cleared; universal bindings are preserved. Messages in the
  source space remain valid — the source is untouched.

  Permissions note: this function does NOT check participant membership.
  Callers (tool handlers, HTTP controllers, LiveView) must assert that the
  actor has read on the source space and write on the target space before
  invoking.
  """
  @spec clone_canvas(binary(), binary(), binary()) ::
          {:ok, Canvas.t()} | {:error, term()}
  def clone_canvas(source_canvas_id, target_space_id, actor_id)
      when is_binary(source_canvas_id) and is_binary(target_space_id) and is_binary(actor_id) do
    case get_canvas(source_canvas_id) do
      nil ->
        {:error, :source_not_found}

      %Canvas{document: document, title: title} = source ->
        {cloned_document, _mapping} = regenerate_node_ids(document)

        attrs = %{
          "space_id" => target_space_id,
          "created_by" => actor_id,
          "cloned_from" => source.id,
          "title" => title,
          "document" => Map.put(cloned_document, "revision", 1)
        }

        case create_canvas(attrs) do
          {:ok, cloned} ->
            :telemetry.execute(
              [:platform, :chat, :canvas_cloned],
              %{system_time: System.system_time()},
              %{
                source_id: source.id,
                clone_id: cloned.id,
                source_space_id: source.space_id,
                target_space_id: target_space_id
              }
            )

            {:ok, cloned}

          {:error, _} = err ->
            err
        end
    end
  end

  defp regenerate_node_ids(document) when is_map(document) do
    case Map.get(document, "root") do
      root when is_map(root) ->
        {new_root, mapping} = regenerate_subtree(root, %{})
        {Map.put(document, "root", new_root), mapping}

      _ ->
        {document, %{}}
    end
  end

  defp regenerate_subtree(%{"id" => old_id} = node, mapping) do
    new_id =
      if old_id == "root", do: "root", else: Ecto.UUID.generate()

    mapping = Map.put(mapping, old_id, new_id)

    children =
      case Map.get(node, "children") do
        list when is_list(list) ->
          Enum.map_reduce(list, mapping, fn child, m ->
            regenerate_subtree(child, m)
          end)

        _ ->
          {[], mapping}
      end

    {children_list, child_mapping} = children

    new_node =
      node
      |> Map.put("id", new_id)
      |> then(fn n ->
        if Map.has_key?(n, "children"), do: Map.put(n, "children", children_list), else: n
      end)

    {new_node, child_mapping}
  end

  defp regenerate_subtree(other, mapping), do: {other, mapping}

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
        document_kind: Platform.Chat.CanvasDocument.root_kind(canvas.document),
        title: canvas.title
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
        document_kind: Platform.Chat.CanvasDocument.root_kind(canvas.document),
        title: canvas.title
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

  # ── Space Agent Roster ──────────────────────────────────────────────────────

  @doc """
  Set the principal agent for a space.

  Atomically removes any existing principal and sets the new one.
  If the agent already exists in the roster, promotes it; otherwise inserts.
  """
  @spec set_principal_agent(binary(), binary()) ::
          {:ok, SpaceAgent.t()} | {:error, term()}
  def set_principal_agent(space_id, agent_id) do
    Multi.new()
    |> Multi.run(:demote_existing, fn repo, _changes ->
      case repo.get_by(SpaceAgent, space_id: space_id, role: "principal") do
        nil ->
          {:ok, nil}

        %SpaceAgent{agent_id: ^agent_id} = existing ->
          # Already principal — no-op for demotion
          {:ok, existing}

        %SpaceAgent{} = existing ->
          existing
          |> SpaceAgent.changeset(%{role: "member"})
          |> repo.update()
      end
    end)
    |> Multi.run(:promote, fn repo, %{demote_existing: demoted} ->
      case demoted do
        %SpaceAgent{agent_id: ^agent_id} ->
          # Already principal
          {:ok, demoted}

        _ ->
          case repo.get_by(SpaceAgent, space_id: space_id, agent_id: agent_id) do
            nil ->
              %SpaceAgent{}
              |> SpaceAgent.changeset(%{
                space_id: space_id,
                agent_id: agent_id,
                role: "principal"
              })
              |> repo.insert()

            %SpaceAgent{} = existing ->
              existing
              |> SpaceAgent.changeset(%{role: "principal"})
              |> repo.update()
          end
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{promote: space_agent}} ->
        :telemetry.execute(
          [:platform, :chat, :agent_roster_changed],
          %{system_time: System.system_time()},
          %{space_id: space_id, agent_id: agent_id, action: :set_principal}
        )

        Phoenix.PubSub.broadcast(
          Platform.PubSub,
          "space_agents:#{space_id}",
          {:roster_changed, space_id}
        )

        {:ok, space_agent}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  @doc """
  Add an agent to a space's roster.

  ## Options

    * `:role` — `"member"` (default) or `"principal"`
  """
  @spec add_space_agent(binary(), binary(), keyword()) ::
          {:ok, SpaceAgent.t()} | {:error, term()}
  def add_space_agent(space_id, agent_id, opts \\ []) do
    role = Keyword.get(opts, :role, "member")

    result =
      %SpaceAgent{}
      |> SpaceAgent.changeset(%{space_id: space_id, agent_id: agent_id, role: role})
      |> Repo.insert()

    case result do
      {:ok, sa} ->
        :telemetry.execute(
          [:platform, :chat, :agent_roster_changed],
          %{system_time: System.system_time()},
          %{space_id: space_id, agent_id: agent_id, action: :added}
        )

        Phoenix.PubSub.broadcast(
          Platform.PubSub,
          "space_agents:#{space_id}",
          {:roster_changed, space_id}
        )

        {:ok, sa}

      error ->
        error
    end
  end

  @doc "Remove an agent from a space entirely (hard delete)."
  @spec remove_space_agent(binary(), binary()) :: :ok | {:error, :not_found}
  def remove_space_agent(space_id, agent_id) do
    case Repo.get_by(SpaceAgent, space_id: space_id, agent_id: agent_id) do
      nil ->
        {:error, :not_found}

      %SpaceAgent{} = sa ->
        Repo.delete!(sa)

        :telemetry.execute(
          [:platform, :chat, :agent_roster_changed],
          %{system_time: System.system_time()},
          %{space_id: space_id, agent_id: agent_id, action: :removed}
        )

        Phoenix.PubSub.broadcast(
          Platform.PubSub,
          "space_agents:#{space_id}",
          {:roster_changed, space_id}
        )

        :ok
    end
  end

  @doc """
  Ensure an agent exists in a space's roster.

  This is idempotent:
  - `role: "principal"` promotes the agent to principal via `set_principal_agent/2`
  - `role: "member"` inserts a member row if missing, otherwise returns the
    existing roster entry without demoting a principal
  """
  @spec ensure_space_agent(binary(), binary(), keyword()) ::
          {:ok, SpaceAgent.t()} | {:error, term()}
  def ensure_space_agent(space_id, agent_id, opts \\ []) do
    role = Keyword.get(opts, :role, "member")

    case role do
      "principal" ->
        set_principal_agent(space_id, agent_id)

      _ ->
        case Repo.get_by(SpaceAgent, space_id: space_id, agent_id: agent_id) do
          %SpaceAgent{} = existing -> {:ok, existing}
          nil -> add_space_agent(space_id, agent_id, role: "member")
        end
    end
  end

  # ADR 0027: dismiss_space_agent/3 and reinvite_space_agent/2 removed.
  # The 'dismissed' role no longer exists — use remove_space_agent/2 instead.

  @doc "List all agents in a space's roster, with preloaded agent data."
  @spec list_space_agents(binary()) :: [SpaceAgent.t()]
  def list_space_agents(space_id) do
    from(sa in SpaceAgent,
      where: sa.space_id == ^space_id,
      preload: [:agent],
      order_by: [asc: sa.inserted_at]
    )
    |> Repo.all()
  end

  @doc "Get the principal agent for a space. Returns `nil` if none set."
  @spec get_principal_agent(binary()) :: SpaceAgent.t() | nil
  def get_principal_agent(space_id) do
    from(sa in SpaceAgent,
      where: sa.space_id == ^space_id and sa.role == "principal",
      preload: [:agent],
      limit: 1
    )
    |> Repo.one()
  end

  @doc "Get a specific space agent entry."
  @spec get_space_agent(binary(), binary()) :: SpaceAgent.t() | nil
  def get_space_agent(space_id, agent_id) do
    Repo.get_by(SpaceAgent, space_id: space_id, agent_id: agent_id)
  end

  @doc "List all agents in a space's roster (all roles are active now — ADR 0027)."
  @spec list_active_space_agents(binary()) :: [SpaceAgent.t()]
  def list_active_space_agents(space_id) do
    from(sa in SpaceAgent,
      where: sa.space_id == ^space_id,
      preload: [:agent],
      order_by: [asc: sa.inserted_at]
    )
    |> Repo.all()
  end

  # ── Unread counts ──────────────────────────────────────────────────────────

  @doc "Persist the last-read cursor for a participant."
  @spec mark_space_read(binary(), binary()) :: :ok
  def mark_space_read(participant_id, message_id) do
    from(p in Participant, where: p.id == ^participant_id)
    |> Repo.update_all(set: [last_read_message_id: message_id])

    :ok
  end

  @doc """
  Return `%{space_id => unread_count}` for every space the user participates in.

  Uses UUIDv7 ordering (`id > last_read_message_id`) to count newer messages.
  """
  @spec unread_counts_for_user(binary()) :: %{binary() => non_neg_integer()}
  def unread_counts_for_user(user_id) do
    from(p in Participant,
      where:
        p.participant_id == ^user_id and is_nil(p.left_at) and
          p.participant_type == "user",
      select: {p.space_id, p.last_read_message_id, p.id}
    )
    |> Repo.all()
    |> Enum.map(fn {space_id, last_read_id, participant_pk} ->
      {space_id, count_unread(space_id, last_read_id, participant_pk)}
    end)
    |> Enum.filter(fn {_, count} -> count > 0 end)
    |> Map.new()
  end

  # participant_pk is the internal chat_participants.id (PK), which is what
  # chat_messages.participant_id references via foreign key.
  defp count_unread(space_id, nil, participant_pk) do
    from(m in Message,
      where:
        m.space_id == ^space_id and is_nil(m.thread_id) and is_nil(m.deleted_at) and
          m.participant_id != ^participant_pk,
      select: count(m.id)
    )
    |> Repo.one()
    |> min(10)
  end

  defp count_unread(space_id, last_read_id, participant_pk) do
    from(m in Message,
      where:
        m.space_id == ^space_id and m.id > ^last_read_id and is_nil(m.thread_id) and
          is_nil(m.deleted_at) and m.participant_id != ^participant_pk,
      select: count(m.id)
    )
    |> Repo.one()
  end

  defp publish_message_posted(msg, opts \\ []) do
    :telemetry.execute(
      [:platform, :chat, :message_posted],
      %{system_time: System.system_time()},
      %{
        space_id: msg.space_id,
        message_id: msg.id,
        participant_id: msg.participant_id
      }
    )

    case Keyword.get(opts, :from_pid) do
      pid when is_pid(pid) -> ChatPubSub.broadcast_from(msg.space_id, pid, {:new_message, msg})
      _ -> ChatPubSub.broadcast(msg.space_id, {:new_message, msg})
    end
  end
end
