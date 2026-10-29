defmodule Platform.Meetings.SynthesisFindingsTest do
  @moduledoc """
  The shared finding store and cross-briefing resolve-once (task
  01a16974-e3db-7000-97e9-8ec9611189bc, stage 1): one finding row sits in
  two meetings' briefings, and one receipt on it resolves the item in both.

  `async: false`: the concurrency test runs two `act/5` calls in separate
  processes, which needs the sandbox's shared mode.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Access.Scope
  alias Platform.Accounts.User
  alias Platform.Inbox
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.MeetingBriefing
  alias Platform.Meetings.MeetingBriefings
  alias Platform.Meetings.Participant
  alias Platform.Meetings.Room
  alias Platform.Meetings.SynthesisFinding
  alias Platform.Meetings.SynthesisFindings
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy.OrgMembership

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp user! do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "finding-#{n}@example.com",
        name: "Finder #{n}",
        oidc_sub: "oidc-finding-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: acme_org_id(), role: "member"})
    |> Repo.insert!()

    user
  end

  defp scope(%User{} = user), do: Scope.for_user(Repo.get!(User, user.id))

  # A concluded meeting attended by `attendees`, with its briefing delivered
  # by the bounded fallback.
  defp concluded!(attendees) do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Finding Project #{n}", org_id: acme_org_id()})
    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Finding #{n}"})

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

    assert {:ok, %{created: _}} = MeetingBriefings.deliver(ended)
    ended
  end

  defp citation(ref, title),
    do: %{source_kind: "action_item", ref: ref, title: title, url: "/x/" <> ref}

  # Meeting A (attendees r, j) and meeting B (attendees c, k), and a
  # conflicts_with finding from A citing one item in each, placed in BOTH
  # briefings.
  defp two_meetings_with_finding! do
    [r, j, c, k] = for _ <- 1..4, do: user!()
    a = concluded!([r, j])
    b = concluded!([c, k])

    # Stage 4 re-checks every citation for the viewer at render and click,
    # so the citations are real messages all four can read: everyone is a
    # participant in both meetings' spaces.
    for u <- [r, j, c, k], m <- [a, b] do
      {:ok, _} =
        Platform.Chat.add_participant(m.chat_space_id, %{
          participant_type: "user",
          participant_id: u.id,
          display_name: u.name,
          joined_at: DateTime.utc_now()
        })
    end

    msg = fn meeting, user, text ->
      p =
        Repo.get_by!(Platform.Chat.Participant,
          space_id: meeting.chat_space_id,
          participant_id: user.id
        )

      m =
        Repo.insert!(%Platform.Chat.Message{
          space_id: meeting.chat_space_id,
          participant_id: p.id,
          content: text
        })

      "message:" <> m.id
    end

    {:ok, finding, :created} =
      SynthesisFindings.upsert(%{
        org_id: acme_org_id(),
        origin_meeting_id: a.id,
        meeting_ids: [a.id, b.id],
        kind: "conflicts_with",
        confidence: "high",
        body: "Meeting A drops Stripe; meeting B ships billing on Stripe.",
        citations: [
          citation(msg.(a, r, "Drop Stripe"), "Drop Stripe; move billing to Paddle"),
          citation(msg.(b, c, "Stripe Friday"), "Ship billing on Stripe by Friday")
        ],
        recipient_user_ids: [r.id, j.id, c.id, k.id]
      })

    assert {:ok, _, %{new_keys: [key]}} = MeetingBriefings.add_finding(a, finding)
    assert {:ok, _, %{new_keys: [^key]}} = MeetingBriefings.add_finding(b, finding)

    %{a: a, b: b, r: r, j: j, c: c, k: k, finding: finding, key: key}
  end

  defp briefing(meeting, user), do: MeetingBriefings.get_for_attendee(meeting.id, user.id)

  defp view_item(meeting, user, key) do
    view = MeetingBriefings.view(briefing(meeting, user), scope(user))
    {Enum.find(view.open ++ view.resolved, &(&1.key == key)), view}
  end

  # ── Store ─────────────────────────────────────────────────────────────────

  describe "SynthesisFinding changeset" do
    test "derives dedupe_key, puts the origin into meeting_ids and validates enums" do
      origin = Ecto.UUID.generate()

      cs =
        SynthesisFinding.changeset(%SynthesisFinding{}, %{
          org_id: acme_org_id(),
          origin_meeting_id: origin,
          kind: "duplicates",
          confidence: "medium",
          body: "same work",
          citations: [citation("task:1", "one"), citation("task:2", "two")]
        })

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :meeting_ids) == [origin]

      assert Ecto.Changeset.get_field(cs, :dedupe_key) ==
               SynthesisFinding.dedupe_key("duplicates", ["task:2", "task:1"])

      valid = %{
        org_id: acme_org_id(),
        origin_meeting_id: origin,
        kind: "duplicates",
        confidence: "medium",
        body: "x",
        citations: [citation("task:1", "one")]
      }

      # Positive control: the base attrs are valid.
      assert SynthesisFinding.changeset(%SynthesisFinding{}, valid).valid?

      for {field, value} <- [
            kind: "agrees_with",
            confidence: "certain",
            citations: [],
            citations: [%{title: "no ref"}]
          ] do
        bad = SynthesisFinding.changeset(%SynthesisFinding{}, Map.put(valid, field, value))
        refute bad.valid?, "expected #{field}=#{inspect(value)} to be refused"
      end
    end

    test "dedupe_key is order-independent and kind-sensitive" do
      assert SynthesisFinding.dedupe_key("conflicts_with", ["a", "b"]) ==
               SynthesisFinding.dedupe_key("conflicts_with", ["b", "a", "a"])

      refute SynthesisFinding.dedupe_key("conflicts_with", ["a", "b"]) ==
               SynthesisFinding.dedupe_key("duplicates", ["a", "b"])
    end
  end

  describe "upsert/1 dedupe" do
    test "mirrored findings from either side collapse into ONE row" do
      [r, c] = [user!(), user!()]
      a = concluded!([r])
      b = concluded!([c])

      base = %{
        org_id: acme_org_id(),
        kind: "conflicts_with",
        confidence: "high",
        body: "conflict"
      }

      {:ok, from_a, :created} =
        SynthesisFindings.upsert(
          Map.merge(base, %{
            origin_meeting_id: a.id,
            meeting_ids: [a.id, b.id],
            citations: [citation("x:a", "A side"), citation("x:b", "B side")],
            recipient_user_ids: [r.id]
          })
        )

      # B's run cites the same two sources in the other order.
      {:ok, from_b, :merged} =
        SynthesisFindings.upsert(
          Map.merge(base, %{
            origin_meeting_id: b.id,
            meeting_ids: [b.id],
            body: "conflict, seen from B",
            citations: [citation("x:b", "B side"), citation("x:a", "A side")],
            recipient_user_ids: [c.id]
          })
        )

      assert from_b.id == from_a.id
      assert Repo.aggregate(SynthesisFinding, :count) == 1
      assert Enum.sort(from_b.meeting_ids) == Enum.sort([a.id, b.id])
      assert Enum.sort(from_b.recipient_user_ids) == Enum.sort([r.id, c.id])
      # The first writer's body and origin stand.
      assert from_b.body == "conflict"
      assert from_b.origin_meeting_id == a.id

      # Positive control: a different kind over the same refs is a second row.
      {:ok, other, :created} =
        SynthesisFindings.upsert(
          Map.merge(base, %{
            origin_meeting_id: a.id,
            kind: "depends_on",
            citations: [citation("x:a", "A side"), citation("x:b", "B side")]
          })
        )

      refute other.id == from_a.id
      assert Repo.aggregate(SynthesisFinding, :count) == 2

      assert Enum.map(SynthesisFindings.list_for_meeting(b.id), & &1.id) == [from_a.id]
    end

    test "a merge never touches an existing receipt" do
      ctx = two_meetings_with_finding!()

      assert {:ok, _} =
               MeetingBriefings.act(briefing(ctx.a, ctx.r), ctx.key, :confirm, scope(ctx.r))

      {:ok, merged, :merged} =
        SynthesisFindings.upsert(%{
          org_id: acme_org_id(),
          origin_meeting_id: ctx.b.id,
          kind: "conflicts_with",
          confidence: "low",
          body: "again",
          citations: Enum.reverse(ctx.finding.citations)
        })

      assert merged.id == ctx.finding.id
      assert merged.receipt["by"] == ctx.r.id
    end
  end

  # ── Placement ─────────────────────────────────────────────────────────────

  describe "add_finding/2" do
    test "the finding appears as one item in BOTH briefings, keyed by node_key" do
      ctx = two_meetings_with_finding!()
      ref = "finding:" <> ctx.finding.id
      assert ctx.key == MeetingBriefings.node_key(ref)

      for {meeting, user} <- [{ctx.a, ctx.r}, {ctx.b, ctx.c}] do
        assert %{"kind" => "finding", "ref" => ^ref} = briefing(meeting, user).items[ctx.key]
        {item, view} = view_item(meeting, user, ctx.key)
        assert item in view.open
        assert item.receipt == nil
        assert item.kind == "finding"
      end

      # Idempotent: adding again adds nothing.
      assert {:ok, _, %{new_keys: []}} = MeetingBriefings.add_finding(ctx.a, ctx.finding)
    end

    test "a meeting the finding does not name is refused" do
      ctx = two_meetings_with_finding!()
      other = concluded!([user!()])

      assert {:error, :not_found} = MeetingBriefings.add_finding(other, ctx.finding)
      refute Map.has_key?(Repo.get_by!(MeetingBriefing, meeting_id: other.id).items, ctx.key)
    end
  end

  # ── Resolve once ──────────────────────────────────────────────────────────

  describe "act/5 on a finding item" do
    test "acting in A resolves it in B's view, for every recipient of both" do
      ctx = two_meetings_with_finding!()
      Inbox.subscribe(ctx.k.id)
      MeetingBriefings.subscribe(briefing(ctx.b, ctx.c).id)

      assert {:ok, _} =
               MeetingBriefings.act(briefing(ctx.a, ctx.r), ctx.key, :confirm, scope(ctx.r))

      # The receipt is on the finding row, not on either briefing.
      finding = Repo.get!(SynthesisFinding, ctx.finding.id)
      assert finding.receipt["by"] == ctx.r.id
      assert finding.receipt["verb"] == "confirmed"
      assert finding.receipt["kind"] == "finding"

      for {meeting, user} <- [{ctx.a, ctx.r}, {ctx.a, ctx.j}, {ctx.b, ctx.c}, {ctx.b, ctx.k}] do
        refute Map.has_key?(briefing(meeting, user).receipts, ctx.key)
        {item, view} = view_item(meeting, user, ctx.key)
        assert item in view.resolved
        assert item.actions == []
        assert item.receipt.by == ctx.r.id
        assert item.receipt.by_name == ctx.r.name
      end

      k_id = ctx.k.id
      b_briefing_id = briefing(ctx.b, ctx.c).id
      assert_receive {:inbox_changed, ^k_id}
      assert_receive {:meeting_briefing_changed, ^b_briefing_id}

      # A second click from the OTHER briefing is refused and writes nothing.
      assert {:error, :already_resolved, %MeetingBriefing{}} =
               MeetingBriefings.act(briefing(ctx.b, ctx.c), ctx.key, :confirm, scope(ctx.c))

      assert Repo.get!(SynthesisFinding, ctx.finding.id).receipt == finding.receipt
    end

    test "concurrent acts from the two briefings serialise to one receipt" do
      ctx = two_meetings_with_finding!()
      parent = self()

      results =
        [{ctx.a, ctx.r}, {ctx.b, ctx.c}]
        |> Enum.map(fn {meeting, user} ->
          row = briefing(meeting, user)
          s = scope(user)

          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> MeetingBriefings.act(row, ctx.key, :confirm, s, %{})
            end
          end)
        end)
        |> tap(fn tasks ->
          for _ <- tasks, do: assert_receive({:ready, _})
          Enum.each(tasks, &send(&1.pid, :go))
        end)
        |> Enum.map(&Task.await(&1, 10_000))

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :already_resolved, _}, &1)) == 1
      assert %{"by" => by} = Repo.get!(SynthesisFinding, ctx.finding.id).receipt
      assert by in [ctx.r.id, ctx.c.id]
    end

    test "an attendee who is not a recipient gets :not_found" do
      ctx = two_meetings_with_finding!()
      outsider = user!()
      a = concluded!([outsider])

      {:ok, finding, :created} =
        SynthesisFindings.upsert(%{
          org_id: acme_org_id(),
          origin_meeting_id: a.id,
          kind: "depends_on",
          confidence: "low",
          body: "for nobody here",
          citations: [citation("x:solo", "solo")],
          recipient_user_ids: [ctx.r.id]
        })

      {:ok, _, %{new_keys: [key]}} = MeetingBriefings.add_finding(a, finding)

      assert {:error, :not_found} =
               MeetingBriefings.act(briefing(a, outsider), key, :confirm, scope(outsider))

      assert Repo.get!(SynthesisFinding, finding.id).receipt == nil

      # Positive control: a recipient attendee of the same kind of item CAN act.
      assert {:ok, _} =
               MeetingBriefings.act(briefing(ctx.b, ctx.k), ctx.key, :confirm, scope(ctx.k))
    end
  end

  # ── Rebuild ───────────────────────────────────────────────────────────────

  describe "build/1" do
    test "a rebuild preserves the finding item and its resolution" do
      ctx = two_meetings_with_finding!()

      assert {:ok, _} =
               MeetingBriefings.act(briefing(ctx.a, ctx.j), ctx.key, :confirm, scope(ctx.j))

      for meeting <- [ctx.a, ctx.b] do
        assert {:ok, rebuilt, %{new_keys: new_keys}} = MeetingBriefings.build(meeting)
        refute ctx.key in new_keys
        assert %{"kind" => "finding"} = rebuilt.items[ctx.key]
      end

      {item, view} = view_item(ctx.b, ctx.k, ctx.key)
      assert item in view.resolved
      assert item.receipt.by == ctx.j.id
    end

    test "a finding item whose finding row is gone is left out of the view" do
      ctx = two_meetings_with_finding!()
      Repo.delete!(Repo.get!(SynthesisFinding, ctx.finding.id))

      {item, view} = view_item(ctx.a, ctx.r, ctx.key)
      assert item == nil
      assert view.counts.total == 0

      assert {:error, :not_found} =
               MeetingBriefings.act(briefing(ctx.a, ctx.r), ctx.key, :confirm, scope(ctx.r))
    end
  end
end
