defmodule Platform.Meetings.Synthesis.DeliveryTest do
  @moduledoc """
  Task 01a16974-e3db-7000-97e9-8ec9611189bc stage 4: findings delivered into
  every named meeting's briefing, filtered per viewer, and resolved by
  align / confirm / dismiss / revert.

  Meeting A is attended by R and J, meeting B by C and K. Everyone is a
  participant in both meetings' chat spaces, so a message posted in A's
  space is a citation all four can read. A third meeting's space P is joined
  by R alone, so a message in P is readable by R and nobody else.

  `async: false`: pushes are observed through a recorder installed in app
  env (`:notifications_module`).
  """

  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.TenancyFixtures

  alias Platform.Access.Grants
  alias Platform.Access.Scope
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Inbox
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.MeetingBriefings
  alias Platform.Meetings.Participant
  alias Platform.Meetings.Room
  alias Platform.Meetings.Synthesis
  alias Platform.Meetings.SynthesisFinding
  alias Platform.Meetings.SynthesisFindings
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy.OrgMembership

  defmodule Recorder do
    @moduledoc "Records `fan_out_to_user/2` pushes as `{:push, user_id, body}`."
    def install(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

    def fan_out_to_user(user_id, notification) do
      send(:persistent_term.get({__MODULE__, :owner}), {:push, user_id, notification.body})
      :ok
    end
  end

  setup do
    Application.put_env(:platform, :notifications_module, Recorder)
    Recorder.install(self())

    on_exit(fn ->
      Application.delete_env(:platform, :notifications_module)
      :persistent_term.erase({Recorder, :owner})
    end)

    [r, j, c, k] = for _ <- 1..4, do: user!()
    a = concluded!([r, j])
    b = concluded!([c, k])

    for u <- [r, j, c, k], m <- [a, b], do: join!(m.chat_space_id, u)

    # Each attendee got exactly one push for their meeting's first delivery.
    for u <- [r, j, c, k], do: assert_received({:push, id, _} when id == u.id)
    refute_received {:push, _, _}

    %{r: r, j: j, c: c, k: k, a: a, b: b}
  end

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp user! do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "delivery-#{n}@example.com",
        name: "Delivery #{n}",
        oidc_sub: "oidc-delivery-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: acme_org_id(), role: "member"})
    |> Repo.insert!()

    user
  end

  defp scope(%User{} = user), do: Scope.for_user(Repo.get!(User, user.id))

  defp join!(space_id, user) do
    if Chat.participant?(space_id, user.id) do
      :ok
    else
      {:ok, _} =
        Chat.add_participant(space_id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: user.name,
          joined_at: DateTime.utc_now()
        })

      :ok
    end
  end

  # A concluded meeting attended by `attendees`, delivered by the bounded
  # fallback (ended 1201 s ago).
  defp concluded!(attendees) do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Delivery Project #{n}", org_id: acme_org_id()})
    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Delivery #{n}"})

    {:ok, live} =
      meeting
      |> Meeting.status_changeset("live", %{
        started_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      })
      |> Repo.update()

    room =
      %Room{}
      |> Room.changeset(%{
        space_id: live.chat_space_id,
        livekit_room_name: "space-#{live.chat_space_id}"
      })
      |> Repo.insert!()

    for user <- attendees do
      %Participant{}
      |> Participant.changeset(%{
        room_id: room.id,
        user_id: user.id,
        display_name: user.name,
        joined_at: DateTime.add(DateTime.utc_now(), -3000, :second)
      })
      |> Repo.insert!()
    end

    {:ok, ended} = Meetings.end_meeting(live)

    ended =
      ended
      |> Ecto.Changeset.change(ended_at: DateTime.add(DateTime.utc_now(), -1201))
      |> Repo.update!()

    assert {:ok, %{created: created}} = MeetingBriefings.deliver(ended)
    assert created == length(attendees)
    ended
  end

  defp message!(space_id, user, text) do
    join!(space_id, user)
    participant = Repo.get_by!(Chat.Participant, space_id: space_id, participant_id: user.id)

    Repo.insert!(%Chat.Message{space_id: space_id, participant_id: participant.id, content: text})
  end

  defp citation(%Chat.Message{id: id}, title),
    do: %{source_kind: "message", ref: "message:" <> id, title: title}

  defp citation(%Tasks.Task{id: id}, title),
    do: %{source_kind: "task", ref: "task:" <> id, title: title}

  defp finding!(origin, meeting_ids, citations, recipients, attrs \\ %{}) do
    {:ok, finding, _} =
      SynthesisFindings.upsert(
        Map.merge(
          %{
            org_id: acme_org_id(),
            origin_meeting_id: origin.id,
            meeting_ids: Enum.map(meeting_ids, & &1.id),
            kind: "conflicts_with",
            confidence: "high",
            body: "Meeting A drops Stripe; meeting B ships billing on Stripe.",
            citations: citations,
            recipient_user_ids: Enum.map(recipients, & &1.id)
          },
          attrs
        )
      )

    finding
  end

  # The common conflict: one readable citation from each meeting's space,
  # for all four people, placed through the synthesis placement path.
  defp shared_conflict!(c, attrs \\ %{}) do
    in_a = message!(c.a.chat_space_id, c.r, "Drop Stripe; move billing to Paddle")
    in_b = message!(c.b.chat_space_id, c.c, "Ship billing on Stripe by Friday")

    finding =
      finding!(
        c.a,
        [c.a, c.b],
        [
          citation(in_a, "Drop Stripe; move billing to Paddle"),
          citation(in_b, "Ship billing on Stripe by Friday")
        ],
        [c.r, c.j, c.c, c.k],
        attrs
      )

    :ok = Synthesis.place_findings([finding])
    finding
  end

  defp briefing(meeting, user), do: MeetingBriefings.get_for_attendee(meeting.id, user.id)
  defp view(meeting, user), do: MeetingBriefings.view(briefing(meeting, user), scope(user))

  defp finding_entry(view) do
    Enum.find(view.open ++ view.resolved, &(&1.kind == "finding"))
  end

  defp inbox_row(meeting, user) do
    b = briefing(meeting, user)

    Repo.one!(
      from(i in Inbox.Item,
        where:
          i.user_id == ^user.id and i.source_type == "meeting_briefing" and i.source_id == ^b.id
      )
    )
  end

  defp key(finding), do: elem(SynthesisFindings.item(finding), 0)

  # ── Placement ─────────────────────────────────────────────────────────────

  describe "placement" do
    test "a cross-meeting finding is one item in BOTH briefings, with no second push", c do
      before_a = inbox_row(c.a, c.r)
      before_b = inbox_row(c.b, c.c)
      assert before_a.body == "0 items" and before_b.body == "0 items"

      finding = shared_conflict!(c)
      key = key(finding)

      for {m, u} <- [{c.a, c.r}, {c.b, c.c}] do
        items = briefing(m, u).items
        assert %{"kind" => "finding", "ref" => "finding:" <> id} = items[key]
        assert id == finding.id
        assert Enum.count(items, fn {_k, i} -> is_map(i) and i["kind"] == "finding" end) == 1
      end

      # The other meeting's Inbox row was updated through deliver's upsert:
      # its count now includes the finding ...
      for {m, u} <- [{c.a, c.r}, {c.a, c.j}, {c.b, c.c}, {c.b, c.k}] do
        assert inbox_row(m, u).body == "1 item"
      end

      # ... and nobody, in either meeting, got a second push.
      refute_received {:push, _, _}

      # Placing it again adds nothing and still pushes nobody.
      :ok = Synthesis.place_findings([finding])
      assert map_size(Map.delete(briefing(c.b, c.c).items, "_content")) == 1
      refute_received {:push, _, _}
    end

    test "only a person who can see the new item has their Inbox row relisted", c do
      for u <- [c.c, c.k] do
        row = inbox_row(c.b, u)
        Repo.update!(Ecto.Changeset.change(row, read_at: DateTime.utc_now()))
      end

      in_a = message!(c.a.chat_space_id, c.r, "Paddle")
      in_b = message!(c.b.chat_space_id, c.c, "Stripe")

      # K is not a recipient.
      finding =
        finding!(c.a, [c.a, c.b], [citation(in_a, "Paddle"), citation(in_b, "Stripe")], [
          c.r,
          c.c
        ])

      :ok = Synthesis.place_findings([finding])

      assert is_nil(inbox_row(c.b, c.c).read_at)
      assert inbox_row(c.b, c.c).body == "1 item"
      # K's row is not relisted and its count does not reveal the item.
      refute is_nil(inbox_row(c.b, c.k).read_at)
      assert inbox_row(c.b, c.k).body == "0 items"
      refute_received {:push, _, _}
    end
  end

  # ── Per-viewer view ───────────────────────────────────────────────────────

  describe "per-viewer filtering" do
    setup c do
      # P: a space only R reads (a third meeting's chat space).
      p_meeting = concluded!([c.r])
      assert_received {:push, _, _}
      p_msg = message!(p_meeting.chat_space_id, c.r, "Billing stays on Stripe (private)")
      in_a = message!(c.a.chat_space_id, c.r, "Move billing to Paddle")

      finding =
        finding!(
          c.a,
          [c.a],
          [citation(in_a, "Move billing to Paddle"), citation(p_msg, "P thread title")],
          [c.r, c.j]
        )

      :ok = Synthesis.place_findings([finding])
      %{finding: finding, p_msg: p_msg}
    end

    test "a recipient who cannot read a citation sees no item, no citation and no count", c do
      # Positive control: R can read both citations and sees the finding.
      r_view = view(c.a, c.r)
      assert %{finding: %{citations: cites}} = finding_entry(r_view)
      assert Enum.any?(cites, &(&1.title == "P thread title"))
      assert r_view.counts.total == 1
      assert inbox_row(c.a, c.r).body == "1 item"
      assert MeetingBriefings.visible_item_count(briefing(c.a, c.r), c.r.id) == 1

      # J is a recipient but cannot read P.
      j_view = view(c.a, c.j)
      assert finding_entry(j_view) == nil
      assert j_view.counts == %{total: 0, open: 0, resolved: 0}
      refute inspect(j_view) =~ "P thread title"
      assert inbox_row(c.a, c.j).body == "0 items"
      assert MeetingBriefings.visible_item_count(briefing(c.a, c.j), c.j.id) == 0
    end

    test "readability is re-checked at render: access revoked later hides the item", c do
      assert finding_entry(view(c.a, c.r))

      {:ok, _} =
        Grants.deny(%{
          principal: c.r,
          permission: "chat.read",
          resource: {:space, c.p_msg.space_id}
        })

      assert finding_entry(view(c.a, c.r)) == nil
      assert view(c.a, c.r).counts.total == 0
    end

    test "a non-recipient who can read every citation still sees nothing", c do
      in_a = message!(c.a.chat_space_id, c.r, "Readable by all")
      other = finding!(c.a, [c.a], [citation(in_a, "Readable by all")], [c.r])
      :ok = Synthesis.place_findings([other])

      # Positive control: J can read the citation ...
      assert Platform.Meetings.Synthesis.Visibility.citation_readable_by?(
               c.j.id,
               hd(other.citations)
             )

      # ... but is not a recipient.
      refute MeetingBriefings.finding_visible?(other, c.j.id)
      assert MeetingBriefings.finding_visible?(other, c.r.id)
      assert view(c.a, c.j).counts.total == 0
      assert view(c.a, c.r).counts.total == 2
    end
  end

  # ── Acting ────────────────────────────────────────────────────────────────

  describe "act/5 on a finding" do
    test "a non-recipient's act is refused and writes nothing", c do
      p_meeting = concluded!([c.r])
      assert_received {:push, _, _}
      p_msg = message!(p_meeting.chat_space_id, c.r, "private")
      in_a = message!(c.a.chat_space_id, c.r, "shared")

      # f1: J is not a recipient. f2: J is a recipient who cannot read P.
      f1 = finding!(c.a, [c.a], [citation(in_a, "shared")], [c.r])

      f2 =
        finding!(
          c.a,
          [c.a],
          [citation(in_a, "shared"), citation(p_msg, "private")],
          [c.r, c.j],
          %{kind: "contradicts"}
        )

      :ok = Synthesis.place_findings([f1, f2])

      for {f, u} <- [{f1, c.j}, {f2, c.j}], verb <- [:confirm, :dismiss, :align] do
        assert {:error, :not_found} =
                 MeetingBriefings.act(briefing(c.a, u), key(f), verb, scope(u))
      end

      assert Repo.get!(SynthesisFinding, f1.id).receipt == nil
      assert Repo.get!(SynthesisFinding, f2.id).receipt == nil

      # Positive control: R may act on the same finding.
      assert {:ok, _} = MeetingBriefings.act(briefing(c.a, c.r), key(f1), :confirm, scope(c.r))
      assert %{"verb" => "confirmed"} = Repo.get!(SynthesisFinding, f1.id).receipt
    end

    test "Seek alignment posts ONE message to each named meeting's space with inert mentions",
         c do
      finding =
        shared_conflict!(c, %{body: "Ask @[Everyone] about billing"})
        |> then(&Repo.get!(SynthesisFinding, &1.id))

      # A citation title carrying a mention token.
      cites =
        Enum.map(finding.citations, fn cite ->
          Map.put(cite, "title", cite["title"] <> " @[Ops]")
        end)

      finding = Repo.update!(Ecto.Changeset.change(finding, citations: cites))

      count = fn space ->
        Repo.aggregate(from(m in Chat.Message, where: m.space_id == ^space), :count)
      end

      before = {count.(c.a.chat_space_id), count.(c.b.chat_space_id)}

      assert {:ok, _} = MeetingBriefings.act(briefing(c.a, c.r), key(finding), :align, scope(c.r))

      assert {count.(c.a.chat_space_id), count.(c.b.chat_space_id)} ==
               {elem(before, 0) + 1, elem(before, 1) + 1}

      for space <- [c.a.chat_space_id, c.b.chat_space_id] do
        msg =
          Repo.one!(
            from(m in Chat.Message,
              where: m.space_id == ^space and like(m.content, "Seeking alignment%")
            )
          )

        participant = Repo.get!(Chat.Participant, msg.participant_id)
        assert participant.participant_id == c.r.id
        refute msg.content =~ "@["
        assert msg.content =~ "@⁠[Everyone]"
        assert msg.content =~ "@⁠[Ops]"
        assert msg.content =~ "/inbox/meeting/"
      end

      # One receipt resolves it everywhere; a second click from B is a no-op.
      assert %{"verb" => "aligned", "by" => by} = Repo.get!(SynthesisFinding, finding.id).receipt
      assert by == c.r.id

      assert {:error, :already_resolved, _} =
               MeetingBriefings.act(briefing(c.b, c.c), key(finding), :align, scope(c.c))

      assert {count.(c.a.chat_space_id), count.(c.b.chat_space_id)} ==
               {elem(before, 0) + 1, elem(before, 1) + 1}

      assert %{verb: "aligned"} = finding_entry(view(c.b, c.k)).receipt
    end

    test "Seek alignment never adds the clicker to a space they are not already in", c do
      # Both citations live in A's space, so J can still read them after
      # leaving B's space; the finding still names both meetings.
      m1 = message!(c.a.chat_space_id, c.r, "Paddle")
      m2 = message!(c.a.chat_space_id, c.c, "Stripe")

      finding =
        finding!(c.a, [c.a, c.b], [citation(m1, "Paddle"), citation(m2, "Stripe")], [c.r, c.j])

      :ok = Synthesis.place_findings([finding])

      # J leaves B's space.
      Repo.delete_all(
        from(p in Chat.Participant,
          where: p.space_id == ^c.b.chat_space_id and p.participant_id == ^c.j.id
        )
      )

      assert {:ok, _} = MeetingBriefings.act(briefing(c.a, c.j), key(finding), :align, scope(c.j))
      refute Chat.participant?(c.b.chat_space_id, c.j.id)

      refute Repo.exists?(
               from(m in Chat.Message,
                 where: m.space_id == ^c.b.chat_space_id and like(m.content, "Seeking alignment%")
               )
             )

      assert Repo.exists?(
               from(m in Chat.Message,
                 where: m.space_id == ^c.a.chat_space_id and like(m.content, "Seeking alignment%")
               )
             )
    end

    test "dismiss resolves once everywhere and records one outcome signal", c do
      finding = shared_conflict!(c)

      {:ok, experiment} =
        Platform.Experiments.create_experiment(%{
          slug: "delivery-signal-#{System.unique_integer([:positive])}",
          name: "Delivery signal",
          status: "draft",
          surface_key: "meetings.brief_synthesis",
          surface_target: "meetings.brief_synthesis"
        })

      Repo.insert!(%Platform.Experiments.Assignment{
        experiment_id: experiment.id,
        subject_type: "meeting",
        subject_id: c.a.id,
        variant_slug: "control",
        assigned_at: DateTime.utc_now()
      })

      assert {:ok, _} =
               MeetingBriefings.act(briefing(c.b, c.k), key(finding), :dismiss, scope(c.k))

      assert {:error, :already_resolved, _} =
               MeetingBriefings.act(briefing(c.a, c.r), key(finding), :confirm, scope(c.r))

      assert [signal] = Platform.Experiments.Signals.list(experiment.id)
      assert signal.label == "dismissed"
      assert signal.source_id == finding.id
      assert signal.source_type == SynthesisFindings.signal_source_type()

      for {m, u} <- [{c.a, c.r}, {c.a, c.j}, {c.b, c.c}] do
        entry = finding_entry(view(m, u))
        assert entry.receipt.verb == "dismissed"
        assert entry.actions == []
      end
    end

    test "verbs outside the finding set are unsupported", c do
      finding = shared_conflict!(c)

      assert {:error, :unsupported} =
               MeetingBriefings.act(briefing(c.a, c.r), key(finding), :ask, scope(c.r), %{
                 "question" => "?"
               })

      assert finding_entry(view(c.a, c.r)).actions == [:align, :confirm, :dismiss]
    end
  end

  # ── Filing interplay ──────────────────────────────────────────────────────

  describe "filing interplay" do
    test "a duplicate of a backlog task this meeting filed offers Revert; nothing is reverted unattended",
         c do
      {:ok, filed} =
        Tasks.create_task(%{
          project_id: c.a.project_id,
          title: "Migrate billing to Paddle (filed)",
          status: "backlog",
          metadata: %{"meeting_id" => c.a.id}
        })

      {:ok, existing} =
        Tasks.create_task(%{project_id: c.a.project_id, title: "Migrate billing to Paddle"})

      tasks_before = Repo.aggregate(Tasks.Task, :count)

      finding =
        finding!(
          c.a,
          [c.a],
          [citation(existing, "Migrate billing to Paddle"), citation(filed, "filed copy")],
          [c.r, c.j],
          %{kind: "duplicates"}
        )

      :ok = Synthesis.place_findings([finding])

      entry = finding_entry(view(c.a, c.r))
      assert entry.finding.revert_ref == "task:" <> filed.id
      assert entry.revertible?
      assert entry.actions == [:revert, :align, :confirm, :dismiss]

      # Placement reverted nothing and filed nothing.
      assert is_nil(Repo.get!(Tasks.Task, filed.id).deleted_at)
      assert Repo.aggregate(Tasks.Task, :count) == tasks_before

      assert {:ok, _} =
               MeetingBriefings.act(briefing(c.a, c.r), key(finding), :revert, scope(c.r))

      assert Repo.get!(Tasks.Task, filed.id).deleted_at
      assert is_nil(Repo.get!(Tasks.Task, existing.id).deleted_at)

      assert %{"verb" => "reverted", "ref" => ref} =
               Repo.get!(SynthesisFinding, finding.id).receipt

      assert ref == "task:" <> filed.id
    end

    test "a filed task that left backlog is not offered for Revert", c do
      {:ok, filed} =
        Tasks.create_task(%{
          project_id: c.a.project_id,
          title: "Filed then started",
          status: "in_progress",
          metadata: %{"meeting_id" => c.a.id}
        })

      {:ok, other} = Tasks.create_task(%{project_id: c.a.project_id, title: "Other"})

      finding =
        finding!(c.a, [c.a], [citation(other, "Other"), citation(filed, "Filed")], [c.r], %{
          kind: "duplicates"
        })

      :ok = Synthesis.place_findings([finding])
      entry = finding_entry(view(c.a, c.r))
      assert entry.finding.revert_ref == nil
      refute :revert in entry.actions

      assert {:error, :not_revertible} =
               MeetingBriefings.act(briefing(c.a, c.r), key(finding), :revert, scope(c.r))
    end
  end
end
