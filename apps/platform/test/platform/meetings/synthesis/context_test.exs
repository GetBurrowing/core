defmodule Platform.Meetings.Synthesis.ContextTest do
  use Platform.DataCase, async: false
  import Platform.TenancyFixtures
  alias Platform.{Chat, Meetings, Repo, Tasks}
  alias Platform.Access.Grants
  alias Platform.Meetings.{MeetingBriefing, Participant, Room}
  alias Platform.Meetings.Synthesis.{Context, Visibility}

  defp user!(external \\ false) do
    n = System.unique_integer([:positive])

    u =
      Repo.insert!(%Platform.Accounts.User{
        email: "synthesis-#{n}@example.com",
        name: "Reader",
        oidc_sub: "synthesis-#{n}"
      })

    Repo.insert!(
      Platform.Tenancy.OrgMembership.changeset(%Platform.Tenancy.OrgMembership{}, %{
        user_id: u.id,
        org_id: acme_org_id(),
        role: "member",
        external: external
      })
    )

    u
  end

  defp join!(space_id, u) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        joined_at: DateTime.utc_now(),
        participant_id: u.id,
        display_name: u.name
      })

    p
  end

  defp meeting!(users) do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Synthesis #{n}", org_id: acme_org_id()})

    {:ok, meeting} =
      Meetings.create_meeting(%{project_id: project.id, name: "Checkout release #{n}"})

    now = DateTime.utc_now()

    meeting =
      Repo.update!(
        Ecto.Changeset.change(meeting,
          status: "ended",
          started_at: DateTime.add(now, -3600),
          ended_at: DateTime.add(now, -60)
        )
      )

    room =
      Repo.insert!(
        Room.changeset(%Room{}, %{
          space_id: meeting.chat_space_id,
          livekit_room_name: "space-#{meeting.chat_space_id}"
        })
      )

    for u <- users do
      join!(meeting.chat_space_id, u)

      Repo.insert!(
        Participant.changeset(%Participant{}, %{
          room_id: room.id,
          user_id: u.id,
          display_name: u.name,
          joined_at: DateTime.add(now, -3000)
        })
      )
    end

    candidate =
      Repo.insert!(%Platform.Meetings.MeetingCandidate{
        meeting_id: meeting.id,
        org_id: acme_org_id(),
        disposition: :accepted,
        classified_intent: "open_question",
        evidence_quote: "Which checkout region?"
      })

    Repo.insert!(
      MeetingBriefing.changeset(%MeetingBriefing{}, %{
        meeting_id: meeting.id,
        attendee_user_ids: Enum.map(users, & &1.id),
        summary: "Checkout release is Friday",
        items: %{
          "_content" => %{
            "open_questions" => [%{"id" => candidate.id, "text" => "Which checkout region?"}]
          }
        }
      })
    )

    {meeting, project}
  end

  setup do
    allowed = user!()
    denied = user!()
    {meeting, project} = meeting!([allowed])
    %{allowed: allowed, denied: denied, meeting: meeting, project: project}
  end

  test "private chat needs participation and respects an explicit chat deny", c do
    p =
      Repo.get_by!(Chat.Participant,
        space_id: c.meeting.chat_space_id,
        participant_id: c.allowed.id
      )

    # Post a persisted message without invoking model dispatch.
    msg =
      Repo.insert!(%Chat.Message{
        space_id: c.meeting.chat_space_id,
        participant_id: p.id,
        content: "Checkout window is Friday"
      })

    assert Visibility.readable_by?(c.allowed.id, {:message, msg.id})
    refute Visibility.readable_by?(c.denied.id, {:message, msg.id})

    {:ok, _} =
      Grants.deny(%{
        principal: c.allowed,
        permission: "chat.read",
        resource: {:space, c.meeting.chat_space_id}
      })

    refute Visibility.readable_by?(c.allowed.id, {:message, msg.id})
  end

  test "canvas read follows the canvas grant and canvas deny", c do
    p =
      Repo.get_by!(Chat.Participant,
        space_id: c.meeting.chat_space_id,
        participant_id: c.allowed.id
      )

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => c.meeting.chat_space_id,
        "created_by" => p.id,
        "title" => "Checkout plan"
      })

    assert Visibility.readable_by?(c.allowed.id, {:canvas, canvas.id})
    refute Visibility.readable_by?(c.denied.id, {:canvas, canvas.id})
    join!(c.meeting.chat_space_id, c.denied)
    assert Visibility.readable_by?(c.denied.id, {:canvas, canvas.id})

    {:ok, _} =
      Grants.deny(%{
        principal: c.denied,
        permission: "canvas.read",
        resource: {:canvas, canvas.id}
      })

    refute Visibility.readable_by?(c.denied.id, {:canvas, canvas.id})
  end

  test "a project task deny excludes its holder while another member can read", c do
    {:ok, task} = Tasks.create_task(%{project_id: c.project.id, title: "Checkout deploy"})
    assert Visibility.readable_by?(c.denied.id, {:task, task.id})
    {:ok, _} = Grants.deny(%{principal: c.denied, permission: "tasks.read", resource: c.project})
    refute Visibility.readable_by?(c.denied.id, {:task, task.id})
    assert Visibility.readable_by?(c.allowed.id, {:task, task.id})
  end

  test "another briefing requires attendance even for a participant", c do
    join!(c.meeting.chat_space_id, c.denied)
    assert Visibility.readable_by?(c.allowed.id, {:meeting_briefing, c.meeting.id})
    refute Visibility.readable_by?(c.denied.id, {:meeting_briefing, c.meeting.id})
  end

  test "gather discards sources no candidate can read and applies candid floor", c do
    {:ok, task} =
      Tasks.create_task(%{project_id: c.project.id, title: "Hidden checkout decision"})

    {:ok, _} = Grants.deny(%{principal: c.allowed, permission: "tasks.read", resource: c.project})
    result = Context.gather(c.meeting, lookback_days: 7)
    refute Map.has_key?(result, :meetings)
    assert Enum.any?(result.sources, &(&1.ref == {:meeting_briefing, c.meeting.id}))
    refute Enum.any?(result.sources, &(&1.ref == {:task, task.id}))

    source = %{
      ref: {:meeting_briefing, c.meeting.id},
      text: "My salary is changing",
      meeting_ids: [c.meeting.id],
      transcript_derived?: true
    }

    assert Context.filter_sources([source], [c.allowed.id]) == []
    assert Context.filter_sources([%{source | transcript_derived?: false}], [c.allowed.id]) == []

    assert [_] =
             Context.filter_sources([%{source | text: "Checkout ships Friday"}], [c.allowed.id])
  end

  test "recipients intersect every citation and exclude guest attendees", c do
    guest = user!(true)
    {other, project} = meeting!([c.allowed, c.denied, guest])
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Checkout followup"})
    {:ok, _} = Grants.deny(%{principal: c.denied, permission: "tasks.read", resource: project})

    sources =
      Context.filter_sources(
        [
          %{
            ref: {:meeting_briefing, other.id},
            text: "Checkout is Friday",
            meeting_ids: [other.id],
            transcript_derived?: true
          },
          %{
            ref: {:task, task.id},
            text: "Checkout followup",
            meeting_ids: [other.id],
            transcript_derived?: false
          }
        ],
        [c.allowed.id, c.denied.id, guest.id]
      )

    assert length(sources) == 2
    assert Context.recipients_for(sources) == [c.allowed.id]
    assert Context.recipients_for([], [other]) == []
    result = Context.gather(other, lookback_days: 7)
    assert c.allowed.id in result.candidate_recipient_ids
    refute guest.id in result.candidate_recipient_ids
    refute Visibility.readable_by?(guest.id, {:meeting_briefing, other.id})
  end

  test "memory uses path denies and linked mail needs both mail and chat access", c do
    page =
      Repo.insert!(
        Platform.Org.WikiPage.changeset(%Platform.Org.WikiPage{}, %{
          file_key: "org/page/checkout.md",
          content: "Checkout release plan",
          org_id: acme_org_id()
        })
      )

    journal =
      Repo.insert!(
        Platform.Org.WikiJournalEntry.changeset(%Platform.Org.WikiJournalEntry{}, %{
          date: Date.utc_today(),
          content: "Checkout release update",
          org_id: acme_org_id()
        })
      )

    assert Visibility.readable_by?(c.allowed.id, {:memory_page, page.id})
    assert Visibility.readable_by?(c.allowed.id, {:memory_journal, journal.id})

    space_journal =
      Repo.insert!(
        Platform.Org.WikiJournalEntry.changeset(%Platform.Org.WikiJournalEntry{}, %{
          date: Date.utc_today(),
          content: "Private checkout release",
          org_id: acme_org_id(),
          metadata: %{"namespace" => "space/" <> c.meeting.chat_space_id}
        })
      )

    assert Visibility.readable_by?(c.allowed.id, {:memory_journal, space_journal.id})
    refute Visibility.readable_by?(c.denied.id, {:memory_journal, space_journal.id})

    {:ok, _} =
      Grants.deny(%{
        principal: c.denied,
        permission: "memory.read",
        resource: {:memory, page.file_key}
      })

    refute Visibility.readable_by?(c.denied.id, {:memory_page, page.id})
    assert Visibility.readable_by?(c.denied.id, {:memory_journal, journal.id})

    {:ok, _} =
      Grants.deny(%{
        principal: c.denied,
        permission: "memory",
        resource: {:module, acme_org_id()}
      })

    refute Visibility.readable_by?(c.denied.id, {:memory_journal, journal.id})

    p =
      Repo.get_by!(Chat.Participant,
        space_id: c.meeting.chat_space_id,
        participant_id: c.allowed.id
      )

    message =
      Repo.insert!(%Chat.Message{
        space_id: c.meeting.chat_space_id,
        participant_id: p.id,
        content: "Checkout mail"
      })

    account =
      Repo.insert!(%Platform.Mail.Account{
        org_id: acme_org_id(),
        name: "Checkout",
        smtp_host: "smtp.example.com",
        smtp_port: 587,
        smtp_tls: "starttls"
      })

    mail =
      Repo.insert!(%Platform.Mail.InboundMessage{
        org_id: acme_org_id(),
        account_id: account.id,
        folder: "INBOX",
        uidvalidity: 1,
        uid: 1,
        message_id_key: "synthesis-mail",
        raw: "Subject: Checkout\r\n\r\nRelease Friday",
        received_at: DateTime.utc_now(),
        subject: "Checkout",
        text_body: "Release Friday",
        chat_message_id: message.id
      })

    assert Visibility.readable_by?(c.allowed.id, {:mail, mail.id})
    refute Visibility.readable_by?(c.denied.id, {:mail, mail.id})
    result = Context.gather(c.meeting, lookback_days: 7)
    assert Enum.any?(result.sources, &(&1.ref == {:memory_page, page.id}))
    assert Enum.any?(result.sources, &(&1.ref == {:memory_journal, journal.id}))
    assert Enum.any?(result.sources, &(&1.ref == {:mail, mail.id}))

    {:ok, _} =
      Grants.deny(%{
        principal: c.allowed,
        permission: "mail",
        resource: {:module, acme_org_id()}
      })

    refute Visibility.readable_by?(c.allowed.id, {:mail, mail.id})
  end

  test "briefing item titles also require access to their referenced resource", c do
    {:ok, task} = Tasks.create_task(%{project_id: c.project.id, title: "Hidden checkout task"})
    briefing = Repo.get_by!(MeetingBriefing, meeting_id: c.meeting.id)

    items =
      Map.put(briefing.items, "filed", %{
        "ref" => "task:" <> task.id,
        "title" => "Hidden checkout task"
      })

    Repo.update!(Ecto.Changeset.change(briefing, items: items))

    assert Enum.any?(
             Context.gather(c.meeting, lookback_days: 7).sources,
             &(&1.text == task.title)
           )

    {:ok, _} = Grants.deny(%{principal: c.allowed, permission: "tasks.read", resource: c.project})

    refute Enum.any?(
             Context.gather(c.meeting, lookback_days: 7).sources,
             &(&1.text == task.title)
           )
  end

  test "accepted outcomes have their own citation identity and attendee gate", c do
    context = Context.gather(c.meeting, lookback_days: 7)
    question = Enum.find(context.sources, &(&1.text == "Which checkout region?"))
    assert {:meeting_candidate, id} = question.ref
    assert id != c.meeting.id
    assert Visibility.readable_by?(c.allowed.id, question)
    refute Visibility.readable_by?(c.denied.id, question)
    assert Enum.any?(context.sources, &(&1.ref == {:meeting_briefing, c.meeting.id}))
  end

  test "unknown and malformed references fail closed", c do
    refute Visibility.readable_by?(c.allowed.id, {:message, "bad"})
    refute Visibility.readable_by?("bad", {:task, c.project.id})
    refute Visibility.readable_by?(c.allowed.id, {:unknown, c.project.id})
  end
end
