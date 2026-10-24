defmodule Platform.Chat.Space do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(channel dm group execution system meeting guest_meeting)

  # The agent attention policies a member may pick for a channel or group
  # (ADR 0013; task 01a1557a-8f80 stage 1). NULL in the column means the kind
  # default, `Platform.Chat.AttentionRouter.resolve_attention_mode/2`.
  @agent_attention_policies ~w(on_mention directed collaborative)

  schema "chat_spaces" do
    field(:workspace_id, :binary_id)
    field(:name, :string)
    field(:slug, :string)
    field(:description, :string)
    field(:kind, :string, default: "channel")
    field(:topic, :string)
    field(:metadata, :map, default: %{})
    field(:org_id, :binary_id)
    field(:primary_agent_id, :binary_id)

    # The space's master switch for agents (task 01a1557a-8f80 stage 1).
    # `false`: no un-mentioned message reaches any agent here; @mentions
    # still route. Per-agent `chat_participants.silenced` is untouched by it.
    field(:agents_awake, :boolean, default: true)
    field(:agent_attention_policy, :string)
    field(:is_direct, :boolean, default: false)
    field(:created_by, :binary_id)
    field(:archived_at, :utc_datetime_usec)
    field(:deletion_scheduled_at, :utc_datetime_usec)
    field(:archived_cascade_org_id, :binary_id)

    # A single sentence of intent for this space, and the agent accountable
    # for it (task 01a0b491 stage 1). Both are nil on every space but the
    # agents space, and nil is the readable "none declared" state the stage-4
    # render is conditional on — so neither carries a `topic`-style default.
    field(:goal, :string)
    field(:leader_agent_id, :binary_id)

    # Virtual: the newest non-deleted message's `inserted_at`, falling back to
    # the space's own `inserted_at` when nothing has been said yet. Populated
    # only by `Platform.Chat.list_user_conversations/2`, which already computes
    # this expression to order the rail. Nil on every other read path, and
    # `Platform.Chat.ClosedDms.filter/2` treats nil as visible for exactly that
    # reason. Deliberately absent from `changeset/2`: it is derived, so it must
    # never arrive from user input.
    field(:last_activity_at, :utc_datetime_usec, virtual: true)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(space, attrs) do
    space
    |> cast(attrs, [
      :workspace_id,
      :name,
      :slug,
      :description,
      :kind,
      :topic,
      :metadata,
      :org_id,
      :primary_agent_id,
      :is_direct,
      :created_by,
      :archived_at,
      :deletion_scheduled_at,
      :archived_cascade_org_id,
      :goal,
      :leader_agent_id
    ])
    |> validate_required([:kind])
    |> validate_length(:goal, max: 500)
    |> validate_inclusion(:kind, @kinds)
    |> validate_channel_fields()
    |> validate_is_direct()
    |> unique_constraint(:slug, name: :chat_spaces_unique_slug)
    |> unique_constraint(:slug, name: :chat_spaces_unique_org_slug)
    |> unique_constraint(:slug, name: :chat_spaces_meeting_slug)
    |> unique_constraint(:slug, name: :chat_spaces_null_scope_channel_slug)
    |> foreign_key_constraint(:primary_agent_id)
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:leader_agent_id)
  end

  @doc "The stored values `agent_attention_policy` accepts."
  @spec agent_attention_policies() :: [String.t()]
  def agent_attention_policies, do: @agent_attention_policies

  @doc """
  The ONLY changeset that writes `agents_awake` and `agent_attention_policy`.

  They are deliberately absent from `changeset/2`, which space creation and
  settings forms feed with request params: these two are written only by
  `Platform.Chat.set_agents_awake/3` and
  `Platform.Chat.set_agent_attention_policy/3`, behind
  `Platform.Chat.SpaceAccess.authorize_writer/2`.
  """
  def agent_attention_changeset(space, attrs) do
    space
    |> cast(attrs, [:agents_awake, :agent_attention_policy])
    |> validate_required([:agents_awake])
    |> validate_inclusion(:agent_attention_policy, @agent_attention_policies)
    |> check_constraint(:agent_attention_policy,
      name: :chat_spaces_agent_attention_policy_check
    )
  end

  defp validate_channel_fields(changeset) do
    case get_field(changeset, :kind) do
      "channel" ->
        changeset
        |> validate_required([:name, :slug])

      "execution" ->
        # Execution spaces auto-generate name; no slug required
        changeset

      _ ->
        changeset
    end
  end

  defp validate_is_direct(changeset) do
    is_direct = get_field(changeset, :is_direct)
    kind = get_field(changeset, :kind)

    if is_direct && kind != "dm" do
      add_error(changeset, :is_direct, "can only be true when kind is dm")
    else
      changeset
    end
  end
end
