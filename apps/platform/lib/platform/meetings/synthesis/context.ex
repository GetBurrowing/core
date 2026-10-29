defmodule Platform.Meetings.Synthesis.Context do
  @moduledoc "Deterministic, recipient-scoped context for a concluded meeting. No model calls."
  import Ecto.Query
  alias Platform.{Meetings, Repo}
  alias Platform.Meetings.{IntentPrivacy, Meeting, MeetingBriefing}
  alias Platform.Meetings.Synthesis.Visibility
  alias Platform.Tasks.{Project, Task}
  alias Platform.Chat.Message
  alias Platform.Org.{WikiPage, WikiJournalEntry}

  @doc "Gather within an explicit experiment lookback. Sources with no readers are discarded."
  def gather(%Meeting{status: "ended"} = meeting, opts) do
    days = Keyword.fetch!(opts, :lookback_days)

    if not (is_integer(days) and days > 0),
      do: raise(ArgumentError, "lookback_days must be positive")

    now = Keyword.get(opts, :now, DateTime.utc_now())
    since = DateTime.add(now, -days, :day)
    project = Repo.one!(from(p in Project, where: p.id == ^meeting.project_id))

    meetings =
      Repo.all(
        from(m in Meeting,
          join: p in Project,
          on: p.id == m.project_id,
          where:
            p.org_id == ^project.org_id and m.status == "ended" and
              m.ended_at >= ^since and m.ended_at <= ^now,
          order_by: [asc: m.ended_at, asc: m.id]
        )
      )

    meetings = Enum.uniq_by([meeting | meetings], & &1.id)

    recipients =
      meetings |> Enum.flat_map(&Meetings.human_attendee_ids/1) |> Enum.uniq() |> Enum.sort()

    meeting_ids = Enum.map(meetings, & &1.id)
    space_ids = Enum.map(meetings, & &1.chat_space_id)

    briefings =
      Repo.all(from(b in MeetingBriefing, where: b.meeting_id in ^meeting_ids, order_by: b.id))

    meeting_tasks = Repo.all(Meetings.meeting_tasks_query(meeting))

    open_tasks =
      Repo.all(
        from(t in Task,
          join: p in Project,
          on: t.project_id == p.id,
          where:
            p.org_id == ^project.org_id and t.status not in ["done", "cancelled"] and
              is_nil(t.deleted_at),
          order_by: t.id
        )
      )

    messages =
      Repo.all(
        from(m in Message,
          where:
            m.space_id in ^space_ids and m.inserted_at >= ^since and
              m.inserted_at <= ^now and is_nil(m.deleted_at) and not m.log_only,
          order_by: [asc: m.inserted_at, asc: m.id]
        )
      )

    message_ids = Enum.map(messages, & &1.id)

    mail =
      Repo.all(
        from(m in Platform.Mail.InboundMessage,
          where: m.org_id == ^project.org_id and m.chat_message_id in ^message_ids,
          order_by: m.id
        )
      )

    pages = Repo.all(from(p in WikiPage, where: p.org_id == ^project.org_id, order_by: p.id))

    journals =
      Repo.all(
        from(j in WikiJournalEntry,
          where: j.org_id == ^project.org_id and j.inserted_at >= ^since,
          order_by: j.id
        )
      )

    sources =
      Enum.flat_map(briefings, &briefing_sources/1) ++
        Enum.map(Enum.uniq_by(meeting_tasks ++ open_tasks, & &1.id), fn t ->
          source(
            :task,
            t.id,
            Enum.join([t.title, t.description], "\n"),
            if(Enum.any?(meeting_tasks, &(&1.id == t.id)), do: [meeting.id], else: []),
            true
          )
        end) ++
        Enum.map(messages, &source(:message, &1.id, &1.content, [], true)) ++
        Enum.map(
          mail,
          &source(:mail, &1.id, Enum.join([&1.subject, &1.text_body], "\n"), [], false)
        ) ++
        (pages
         |> Enum.filter(&relevant?(&1.content, meeting.name))
         |> Enum.map(&source(:memory_page, &1.id, &1.content, [], false))) ++
        (journals
         |> Enum.filter(&relevant?(&1.content, meeting.name))
         |> Enum.map(&source(:memory_journal, &1.id, &1.content, [], false)))

    %{
      meeting_id: meeting.id,
      candidate_recipient_ids: recipients,
      sources: filter_sources(sources, recipients),
      meetings: meetings
    }
  end

  def gather(%Meeting{}, _opts), do: {:error, :not_concluded}

  @doc "Apply the privacy floor and materialize current readers before prompt construction."
  def filter_sources(sources, recipient_ids) do
    sources
    |> Enum.reject(fn s ->
      not is_binary(s.text) or String.trim(s.text) == "" or
        (s.transcript_derived? and IntentPrivacy.candid_register(s.text) != :ok)
    end)
    |> Enum.map(fn s ->
      Map.put(s, :reader_ids, Enum.filter(recipient_ids, &Visibility.readable_by?(&1, s)))
    end)
    |> Enum.reject(&(&1.reader_ids == []))
  end

  @doc "Intersect cited readers with human attendees of the named meetings. Empty citations yield nobody."
  def recipients_for(citations, meetings) when is_list(citations) and is_list(meetings) do
    humans = meetings |> Enum.flat_map(&Meetings.human_attendee_ids/1) |> MapSet.new()

    case citations do
      [] ->
        []

      _ ->
        Enum.reduce(citations, humans, fn s, acc ->
          readers =
            Map.get(s, :reader_ids, [])
            |> Enum.filter(&Visibility.readable_by?(&1, s))
            |> MapSet.new()

          MapSet.intersection(acc, readers)
        end)
        |> MapSet.to_list()
        |> Enum.sort()
    end
  end

  @doc "Use meetings named by citations when the caller has no additional finding meeting names."
  def recipients_for(citations) do
    ids =
      citations
      |> Enum.flat_map(&Map.get(&1, :meeting_ids, []))
      |> Enum.uniq()
      |> Enum.filter(&Platform.UUID.valid?/1)

    recipients_for(citations, Repo.all(from(m in Meeting, where: m.id in ^ids)))
  end

  defp briefing_sources(b) do
    summary = source(:meeting_briefing, b.meeting_id, b.summary, [b.meeting_id], true)
    content = Map.get(b.items || %{}, "_content", %{})

    entries =
      Map.get(content, "open_questions", []) ++ Map.get(content, "unfiled_action_items", [])

    filed =
      b.items
      |> Kernel.||(%{})
      |> Map.delete("_content")
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {_key, item} ->
        case String.split(item["ref"] || "", ":", parts: 2) do
          [kind, id] when kind in ["task", "canvas"] ->
            ref_kind = if kind == "task", do: :task, else: :canvas

            [
              source(:meeting_briefing, b.meeting_id, item["title"], [b.meeting_id], true)
              |> Map.put(:required_refs, [{ref_kind, id}])
            ]

          _ ->
            []
        end
      end)

    filed ++
      [
        summary
        | Enum.map(
            entries,
            &source(:meeting_briefing, b.meeting_id, &1["text"], [b.meeting_id], true)
          )
      ]
  end

  defp source(kind, id, text, meetings, derived),
    do: %{ref: {kind, id}, text: text, meeting_ids: meetings, transcript_derived?: derived}

  defp relevant?(text, title) do
    terms =
      title
      |> String.downcase()
      |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
      |> Enum.filter(&(String.length(&1) >= 3))

    haystack = String.downcase(text || "")
    Enum.any?(terms, &String.contains?(haystack, &1))
  end
end
