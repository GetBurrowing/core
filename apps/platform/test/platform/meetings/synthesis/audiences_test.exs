defmodule Platform.Meetings.Synthesis.AudiencesTest do
  @moduledoc """
  Task 01a16974 stage 6: one provider call per audience.

  Invariant under test: every source in the prompt that produced a finding
  is readable by every recipient of that finding, at persist time and
  again at render time.
  """
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.{Chat, Meetings, Repo, Tasks}

  alias Platform.Meetings.{
    Completion,
    CompletionRun,
    MeetingBriefings,
    Participant,
    Room,
    SynthesisFinding,
    SynthesisFindings,
    Synthesis,
    Transcript
  }

  defmodule Provider do
    @moduledoc false
    # Reports every call's sources. Emits a finding citing ONLY the origin
    # meeting's summary, whose body repeats every "Pricing note" source in
    # its prompt: a model describing an uncited source it was shown. Mode
    # :private emits only when such a note was in the prompt; :public only
    # when none was.
    def chat(_credentials, [%{content: content}], _opts) do
      payload = Jason.decode!(content)
      send(Application.fetch_env!(:platform, :audiences_test_pid), {:call, payload["sources"]})

      notes =
        payload["sources"]
        |> Enum.filter(&String.starts_with?(&1["text"], "Pricing note"))
        |> Enum.map(& &1["text"])

      emit? =
        case Application.get_env(:platform, :audiences_test_mode, :private) do
          :private -> notes != []
          :public -> notes == []
        end

      origin = "meeting_briefing:" <> payload["meeting_id"]

      text =
        if emit? do
          body = Enum.join(["The release depends on the pricing call." | notes], " ")

          ~s(<meeting-finding kind="depends_on" confidence="high">#{body}<cite ref="#{origin}"/></meeting-finding>)
        else
          ""
        end

      {:ok, %{content: text}}
    end
  end

  setup do
    keys = [
      :meetings_summary,
      :meeting_synthesis_provider,
      :audiences_test_pid,
      :audiences_test_mode
    ]

    old = Map.new(keys, &{&1, Application.fetch_env(:platform, &1)})

    on_exit(fn ->
      Enum.each(old, fn
        {k, {:ok, v}} -> Application.put_env(:platform, k, v)
        {k, :error} -> Application.delete_env(:platform, k)
      end)
    end)

    Application.put_env(:platform, :meetings_summary, %{provider: :openai})
    Application.put_env(:platform, :meeting_synthesis_provider, Provider)
    Application.put_env(:platform, :audiences_test_pid, self())
    Application.delete_env(:platform, :audiences_test_mode)
    Platform.Orchestration.PromptTemplates.seed_defaults()

    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Audiences #{n}", org_id: acme_org_id()})
    %{project: project}
  end

  defp user!(name) do
    n = System.unique_integer([:positive])

    u =
      Repo.insert!(%Platform.Accounts.User{
        email: "aud-#{name}-#{n}@example.com",
        name: "#{name} #{n}",
        oidc_sub: "aud-#{name}-#{n}"
      })

    Repo.insert!(
      Platform.Tenancy.OrgMembership.changeset(%Platform.Tenancy.OrgMembership{}, %{
        user_id: u.id,
        org_id: acme_org_id(),
        role: "member"
      })
    )

    u
  end

  defp join!(space_id, u) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: u.id,
        display_name: u.name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  # The origin meeting, attended (room + chat) by `users`, with a filed run.
  defp origin!(project, users) do
    now = DateTime.utc_now()
    {:ok, m} = Meetings.create_meeting(%{project_id: project.id, name: "Release planning"})

    m =
      Repo.update!(
        Ecto.Changeset.change(m,
          status: "ended",
          started_at: DateTime.add(now, -600),
          ended_at: DateTime.add(now, -10)
        )
      )

    room =
      Repo.insert!(
        Room.changeset(%Room{}, %{space_id: m.chat_space_id, livekit_room_name: "aud-#{m.id}"})
      )

    for u <- users do
      Repo.insert!(
        Participant.changeset(%Participant{}, %{
          room_id: room.id,
          user_id: u.id,
          display_name: u.name,
          joined_at: DateTime.add(now, -500)
        })
      )

      join!(m.chat_space_id, u)
    end

    t =
      Repo.insert!(%Transcript{
        space_id: m.chat_space_id,
        meeting_id: m.id,
        room_id: m.livekit_room_name,
        started_at: DateTime.add(now, -500),
        status: "complete",
        summary: "Release on Friday",
        segments: [%{"id" => Ecto.UUID.generate(), "text" => "Release Friday", "start_time" => 1}]
      })

    Repo.update!(Ecto.Changeset.change(t, summary_input_hash: Transcript.summary_fingerprint(t)))
    {:ok, snap, _} = Completion.snapshot(m)

    r = %CompletionRun{
      meeting_id: m.id,
      transcript_id: t.id,
      capture_finished_at: now,
      status: "filed",
      snapshot: snap
    }

    hash = Completion.snapshot_hash(r, snap)

    r =
      Repo.insert!(%{
        r
        | snapshot_hash: hash,
          synthesis: %{"snapshot_hash" => hash, "status" => "pending"}
      })

    {:ok, _, _} = MeetingBriefings.build(m)
    {m, r}
  end

  # Another ended meeting whose chat space only `reader` can read, holding
  # one message "Pricing note <i>".
  defp private_note!(project, reader, i) do
    now = DateTime.utc_now()
    {:ok, m} = Meetings.create_meeting(%{project_id: project.id, name: "Pricing council #{i}"})

    m =
      Repo.update!(Ecto.Changeset.change(m, status: "ended", ended_at: DateTime.add(now, -3600)))

    p = join!(m.chat_space_id, reader)

    msg =
      Repo.insert!(%Chat.Message{
        space_id: m.chat_space_id,
        participant_id: p.id,
        content: "Pricing note #{i}: keep Stripe"
      })

    %{meeting: m, participant: p, message: msg, text: msg.content}
  end

  defp calls(acc \\ []) do
    receive do
      {:call, sources} -> calls([sources | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp texts(sources), do: Enum.map(sources, & &1["text"])
  defp notes(sources), do: Enum.filter(texts(sources), &String.starts_with?(&1, "Pricing note"))

  describe "provider call count" do
    test "one audience: one call", %{project: project} do
      u = user!("solo")
      {a, r} = origin!(project, [u])

      assert {:ok, _} = Synthesis.run(a.id, r.id, r.snapshot_hash)
      assert [_] = calls()
    end

    test "two audiences: two calls, each given only what its members can read", %{
      project: project
    } do
      [u1, u2] = [user!("one"), user!("two")]
      note = private_note!(project, u1, 1)
      {a, r} = origin!(project, [u1, u2])

      assert {:ok, [finding]} = Synthesis.run(a.id, r.id, r.snapshot_hash)

      assert [c1, c2] = calls()
      # Exactly one call saw the private note; the other did not.
      assert Enum.sort([notes(c1), notes(c2)]) == [[], [note.text]]
      # Apart from the note, the two prompts are the same sources.
      assert Enum.sort(texts(c1) -- [note.text]) == Enum.sort(texts(c2) -- [note.text])

      # The finding came from u1's call: u2 can read its citation, but not
      # the note its body repeats, so u2 is not a recipient.
      assert finding.body =~ note.text
      assert finding.recipient_user_ids == [u1.id]
      assert ("message:" <> note.message.id) in finding.prompt_refs
      assert MeetingBriefings.finding_visible?(finding, u1.id)
      refute MeetingBriefings.finding_visible?(finding, u2.id)

      view = MeetingBriefings.view(MeetingBriefings.get_for_attendee(a.id, u2.id), scope(u2))
      refute inspect(view, limit: :infinity, printable_limit: :infinity) =~ "Pricing note"
    end

    test "more audiences than the cap: the overflow shares one call over the common set", %{
      project: project
    } do
      users = for i <- 1..5, do: user!("u#{i}")
      private = for {u, i} <- Enum.with_index(users, 1), do: private_note!(project, u, i)
      {a, r} = origin!(project, users)
      Application.put_env(:platform, :audiences_test_mode, :public)

      assert Synthesis.max_provider_calls() == 4
      assert {:ok, [finding]} = Synthesis.run(a.id, r.id, r.snapshot_hash)

      seen = calls()
      assert length(seen) == Synthesis.max_provider_calls()

      {direct, [common]} = Enum.split_with(seen, &(notes(&1) != []))
      assert length(direct) == Synthesis.max_provider_calls() - 1
      assert Enum.all?(direct, &(length(notes(&1)) == 1))

      # The overflow call is exactly the sources every one of its members
      # can read: each direct prompt minus its own private note.
      for d <- direct, do: assert(Enum.sort(texts(d) -- notes(d)) == Enum.sort(texts(common)))

      # Its finding is bounded to the two overflow members, although every
      # attendee can read the citation.
      directly_served =
        for d <- direct, p <- private, p.text in notes(d), do: p.participant.participant_id

      overflow_members = Enum.map(users, & &1.id) -- directly_served
      assert length(overflow_members) == 2
      assert Enum.sort(finding.recipient_user_ids) == Enum.sort(overflow_members)
    end
  end

  defp src(id, readers),
    do: %{ref: {:task, id}, text: id, meeting_ids: [], reader_ids: readers}

  describe "audiences/3" do
    test "an empty common set for the overflow makes no call for it" do
      meeting = %Meetings.Meeting{id: Ecto.UUID.generate(), started_at: nil}
      users = for _ <- 1..6, do: Ecto.UUID.generate()
      sources = Enum.map(users, &src(Ecto.UUID.generate(), [&1]))
      context = %{candidate_recipient_ids: users, sources: sources}

      calls = Synthesis.audiences(meeting, context, 60)
      assert length(calls) == Synthesis.max_provider_calls() - 1
      assert Enum.all?(calls, &match?(%{members: [_], sources: [_]}, &1))
    end

    test "groups by the exact readable set, members share a call, the unreadable get none" do
      meeting = %Meetings.Meeting{id: Ecto.UUID.generate(), started_at: nil}
      [a, b, c, nobody] = for _ <- 1..4, do: Ecto.UUID.generate()
      [s1, s2] = for _ <- 1..2, do: Ecto.UUID.generate()

      context = %{
        candidate_recipient_ids: [a, b, c, nobody],
        sources: [src(s1, [a, b, c]), src(s2, [a, b])]
      }

      calls = Synthesis.audiences(meeting, context, 60)
      assert length(calls) == 2
      ab = Enum.find(calls, &(&1.members == Enum.sort([a, b])))
      assert ab.prompt_refs == Enum.sort(["task:" <> s1, "task:" <> s2])

      assert %{members: [^c], prompt_refs: ["task:" <> ^s1]} =
               Enum.find(calls, &(c in &1.members))

      refute Enum.any?(calls, &(nobody in &1.members))
    end
  end

  test "access to an uncited prompt source revoked after the run hides the finding", %{
    project: project
  } do
    [u1, u2] = [user!("one"), user!("two")]
    note = private_note!(project, u1, 1)
    {a, r} = origin!(project, [u1, u2])

    assert {:ok, [finding]} = Synthesis.run(a.id, r.id, r.snapshot_hash)
    assert MeetingBriefings.finding_visible?(finding, u1.id)

    {:ok, _} = Chat.remove_participant(note.participant)

    # The citation (the origin summary) is still readable; the prompt's
    # private note is not.
    assert Enum.all?(
             finding.citations,
             &Platform.Meetings.Synthesis.Visibility.citation_readable_by?(u1.id, &1)
           )

    refute MeetingBriefings.finding_visible?(Repo.get!(SynthesisFinding, finding.id), u1.id)
  end

  test "a merge adds an incoming recipient only if they can read the kept body's prompt", %{
    project: project
  } do
    [u1, u2] = [user!("one"), user!("two")]
    note = private_note!(project, u1, 1)
    {a, _r} = origin!(project, [u1, u2])
    note_ref = "message:" <> note.message.id

    attrs = %{
      org_id: acme_org_id(),
      origin_meeting_id: a.id,
      meeting_ids: [a.id],
      kind: "depends_on",
      confidence: "high",
      body: "Body that repeats " <> note.text,
      citations: [%{"ref" => "meeting_briefing:" <> a.id, "source_kind" => "meeting_briefing"}],
      recipient_user_ids: [u1.id],
      prompt_refs: [note_ref, "meeting_briefing:" <> a.id]
    }

    assert {:ok, first, :created} = SynthesisFindings.upsert(attrs)

    assert {:ok, merged, :merged} =
             SynthesisFindings.upsert(%{
               attrs
               | body: "A harmless body",
                 recipient_user_ids: [u2.id],
                 prompt_refs: ["meeting_briefing:" <> a.id]
             })

    assert merged.id == first.id
    assert merged.body == first.body
    assert merged.prompt_refs == first.prompt_refs
    assert merged.recipient_user_ids == [u1.id]
  end

  defp scope(u), do: Platform.Access.Scope.for_user(Repo.get!(Platform.Accounts.User, u.id))
end
