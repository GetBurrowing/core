defmodule Platform.Chat.GroupMentions do
  @moduledoc "Server-owned, immutable send-time group audience. Never grants participation."
  import Ecto.Query
  alias Platform.Repo

  alias Platform.Chat.{
    GroupMentionToken,
    MentionGroups,
    MentionGroup,
    MentionGroupMember,
    Message,
    MessageGroupRecipient,
    MessageGroupSnapshot,
    MessageMentionGroup,
    Participant,
    Space
  }

  @doc "Capture once in the caller's message-creation transaction, before publishing."
  def capture!(%Message{} = message) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "group capture requires a transaction")

    # The message lock serializes even empty resolutions and repeated calls.
    # Resolve persisted content/author, never caller-supplied virtual fields.
    stored = Repo.one!(from(m in Message, where: m.id == ^message.id, lock: "FOR UPDATE"))

    unless Repo.get(MessageGroupSnapshot, stored.id) do
      Repo.insert!(%MessageGroupSnapshot{message_id: stored.id})
      capture_rows!(stored)
    end

    load(message)
  end

  def load(%Message{id: id} = message) do
    if Platform.UUID.valid?(id) do
      groups =
        Repo.all(from(g in MessageMentionGroup, where: g.message_id == ^id, order_by: g.id))

      if groups == [] do
        %{message | group_mentions: [], group_mention_recipients: []}
      else
        recipients =
          Repo.all(from(r in MessageGroupRecipient, where: r.message_id == ^id, order_by: r.id))

        participant_ids = Enum.map(recipients, & &1.participant_id)

        participants =
          Repo.all(from(p in Participant, where: p.id in ^participant_ids))
          |> Map.new(&{&1.id, &1})

        space = Repo.get(Space, message.space_id)

        recipients =
          Enum.filter(recipients, fn row ->
            case Map.get(participants, row.participant_id) do
              %Participant{} = p ->
                matches?(p, row) and MentionGroups.eligible_participant?(p, space) and
                  history_visible?(p, message)

              _ ->
                false
            end
          end)

        %{message | group_mentions: groups, group_mention_recipients: recipients}
      end
    else
      %{message | group_mentions: [], group_mention_recipients: []}
    end
  end

  def recipient?(%Participant{} = participant, %Message{} = message) do
    message = if is_nil(message.group_mention_recipients), do: load(message), else: message

    Enum.any?(message.group_mention_recipients, fn
      %MessageGroupRecipient{message_id: id} = row when id == message.id ->
        matches?(participant, row)

      _ ->
        false
    end) and MentionGroups.eligible_participant?(participant, Repo.get(Space, message.space_id)) and
      history_visible?(participant, message)
  end

  def recipient?(_, _), do: false

  def in_context_message_ids(%Participant{} = participant, space_id) do
    space = if Platform.UUID.valid?(space_id), do: Repo.get(Space, space_id)

    if MentionGroups.eligible_participant?(participant, space) do
      rows =
        Repo.all(
          from(r in MessageGroupRecipient,
            join: m in Message,
            on: m.id == r.message_id,
            where:
              m.space_id == ^space_id and is_nil(m.deleted_at) and
                r.participant_id == ^participant.id and
                r.principal_type == ^participant.participant_type and
                r.principal_id == ^participant.participant_id,
            select: {m.id, m.inserted_at}
          )
        )

      rows
      |> Enum.filter(fn {_id, inserted_at} ->
        history_visible?(participant, %{inserted_at: inserted_at})
      end)
      |> MapSet.new(&elem(&1, 0))
    else
      MapSet.new()
    end
  end

  def in_context_message_ids(_, _), do: MapSet.new()

  defp capture_rows!(message) do
    space = Repo.get(Space, message.space_id)
    author = Repo.get(Participant, message.participant_id)
    tokens = GroupMentionToken.parse(message.content)

    if tokens != [] and usable_author?(author, space) and not suppressed?(message, space) do
      ids = Enum.map(tokens, & &1.id)
      # Admin membership writers lock the same parent row before replacing
      # members. Ordered locks also serialize multi-group captures coherently.
      groups =
        Repo.all(
          from(g in MentionGroup,
            where: g.id in ^ids and g.org_id == ^space.org_id and is_nil(g.deleted_at),
            order_by: g.id,
            lock: "FOR UPDATE"
          )
        )

      group_ids = Enum.map(groups, & &1.id)
      members = Repo.all(from(m in MentionGroupMember, where: m.group_id in ^group_ids))
      participants = Repo.all(from(p in Participant, where: p.space_id == ^space.id))

      eligible =
        participants
        |> Enum.reject(&(&1.id == author.id))
        |> Enum.filter(
          &(MentionGroups.eligible_participant?(&1, space) and history_visible?(&1, message))
        )
        |> Map.new(&{{&1.participant_type, &1.participant_id}, &1})

      names = Map.new(tokens, &{&1.id, &1.name})

      Enum.each(groups, fn group ->
        Repo.insert!(%MessageMentionGroup{
          message_id: message.id,
          group_id: group.id,
          name: names[group.id]
        })
      end)

      members
      |> Enum.reduce(%{}, fn member, acc ->
        target = MentionGroupMember.to_view(member)
        key = {target.type, target.id}

        if Map.has_key?(eligible, key),
          do: Map.update(acc, key, [member.group_id], &[member.group_id | &1]),
          else: acc
      end)
      |> Enum.each(fn {{type, id} = key, origins} ->
        Repo.insert!(%MessageGroupRecipient{
          message_id: message.id,
          principal_type: type,
          principal_id: id,
          participant_id: eligible[key].id,
          group_ids: Enum.sort(Enum.uniq(origins))
        })
      end)
    end
  end

  defp usable_author?(%Participant{participant_type: "agent"} = author, space),
    do: MentionGroups.eligible_participant?(author, space)

  defp usable_author?(
         %Participant{participant_type: "user", participant_id: id} = author,
         %Space{} = space
       ) do
    MentionGroups.eligible_participant?(author, space) and
      Platform.Tenancy.internal_member?(%{id: id}, space.org_id) and
      not Platform.Tenancy.external_user?(%{id: id})
  end

  defp usable_author?(_, _), do: false

  defp suppressed?(message, space) do
    metadata = message.metadata || %{}

    message.log_only or metadata["skip_mention_scan"] == true or
      metadata["source"] in ["email_inbound", "federation_inbound"] or
      (space.kind == "dm" and metadata["source"] == "voice" and
         is_binary(metadata["voice_session_id"]))
  end

  defp matches?(participant, row),
    do:
      participant.id == row.participant_id and participant.participant_type == row.principal_type and
        participant.participant_id == row.principal_id

  defp history_visible?(%Participant{history_visible_from: nil}, _), do: true

  defp history_visible?(%Participant{history_visible_from: %DateTime{} = from}, %{
         inserted_at: %DateTime{} = inserted
       }),
       do: DateTime.compare(inserted, from) != :lt

  defp history_visible?(_, _), do: false
end
