defmodule Platform.Meetings.MeetingBriefingsActTest do
  @moduledoc """
  `get_for_attendee/2`, `view/2` and `act/5` (task 01a1694a stage 3): one
  shared receipt per item, refused server-side once written.

  `async: false`: the concurrency test runs two `act/5` calls in separate
  processes, which needs the sandbox's shared mode.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Access.Scope
  alias Platform.Accounts.User
  alias Platform.Chat.Message
  alias Platform.Inbox
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.MeetingBriefing
  alias Platform.Meetings.MeetingBriefings
  alias Platform.Meetings.Participant
  alias Platform.Meetings.Room
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskRecord
  alias Platform.Tenancy.OrgMembership

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp user!(org_id \\ acme_org_id()) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "act-#{n}@example.com",
        name: "Actor #{n}",
        oidc_sub: "oidc-act-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: "member"})
    |> Repo.insert!()

    user
  end

  defp scope(%User{} = user), do: Scope.for_user(Repo.get!(User, user.id))

  # Historical live-minted task fixture; live code must no longer create it.
  defp graduate!(meeting, quote) do
    {:ok, task} =
      Platform.Tasks.create_task(%{
        project_id: meeting.project_id,
        title: quote,
        metadata: %{
          "source" => "meetings.candidate",
          "meeting_id" => meeting.id,
          "candidate_id" => Ecto.UUID.generate()
        }
      })

    task
  end

  # Historical completed-ack task, for briefing rollback coverage after cutover.
  defp ack_done!(meeting) do
    {:ok, task} =
      Platform.Tasks.create_task(%{
        project_id: meeting.project_id,
        title: "somebody write the CSV export",
        status: "done",
        metadata: %{
          "source" => "meetings.candidate",
          "meeting_id" => meeting.id,
          "candidate_id" => Ecto.UUID.generate(),
          "completed_via" => "meeting_intent_ack"
        }
      })

    task
  end

  # A concluded meeting with attendees A and B (and any `extra` attendees),
  # two backlog tasks, and its briefing built by conclusion.
  defp concluded!(opts \\ []) do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Tasks.create_project(%{name: "Act Project #{n}", org_id: acme_org_id()})

    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Act #{n}"})

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

    a = user!()
    b = user!()
    extra = Keyword.get(opts, :extra, [])

    for user <- [a, b | extra] do
      %Participant{}
      |> Participant.changeset(%{
        room_id: room.id,
        user_id: user.id,
        display_name: user.name,
        joined_at: DateTime.add(DateTime.utc_now(), -3000, :second)
      })
      |> Repo.insert!()
    end

    t1 = graduate!(live, "somebody should rotate the S3 keys")
    t2 = graduate!(live, "somebody should renew the TLS certs")
    done = if Keyword.get(opts, :ack_done, false), do: ack_done!(live)

    {:ok, ended} = Meetings.end_meeting(live)
    briefing = MeetingBriefings.get_for_attendee(ended.id, a.id)
    assert %MeetingBriefing{} = briefing

    %{meeting: ended, briefing: briefing, a: a, b: b, t1: t1, t2: t2, done: done}
  end

  defp key(%TaskRecord{id: id}), do: MeetingBriefings.node_key("task:" <> id)

  defp item(view, key), do: Enum.find(view.open ++ view.resolved, &(&1.key == key))

  # ── get_for_attendee/2 ────────────────────────────────────────────────────

  describe "get_for_attendee/2" do
    test "a non-attendee, a forged meeting id and a malformed id all get nil" do
      ctx = concluded!()
      outsider = user!()

      # Positive control: both attendees load it.
      assert %MeetingBriefing{} = MeetingBriefings.get_for_attendee(ctx.meeting.id, ctx.a.id)
      assert %MeetingBriefing{} = MeetingBriefings.get_for_attendee(ctx.meeting.id, ctx.b.id)

      assert MeetingBriefings.get_for_attendee(ctx.meeting.id, outsider.id) == nil
      assert MeetingBriefings.get_for_attendee(Ecto.UUID.generate(), ctx.a.id) == nil
      assert MeetingBriefings.get_for_attendee("not-a-uuid", ctx.a.id) == nil
      assert MeetingBriefings.get_for_attendee(ctx.meeting.id, "not-a-uuid") == nil
      assert MeetingBriefings.get_for_attendee(nil, ctx.a.id) == nil
    end
  end

  # ── Shared resolution ─────────────────────────────────────────────────────

  describe "act/5 shared resolution" do
    test "A reverts; B sees it resolved by A with no actions; B's revert is refused" do
      ctx = concluded!()
      k = key(ctx.t1)

      assert {:ok, _} = MeetingBriefings.act(ctx.briefing, k, :revert, scope(ctx.a), %{})

      deleted_at = Repo.get!(TaskRecord, ctx.t1.id).deleted_at
      assert %DateTime{} = deleted_at

      # B's view, from B's own load.
      b_briefing = MeetingBriefings.get_for_attendee(ctx.meeting.id, ctx.b.id)
      view = MeetingBriefings.view(b_briefing, scope(ctx.b))
      reverted = item(view, k)

      assert reverted in view.resolved
      assert reverted.actions == []
      assert reverted.receipt.verb == "reverted"
      assert reverted.receipt.by == ctx.a.id
      assert reverted.receipt.by_name == ctx.a.name
      assert reverted.receipt.ref == "task:" <> ctx.t1.id

      # The other task is still open for B, with all three actions.
      other = item(view, key(ctx.t2))
      assert other in view.open
      assert other.actions == [:revert, :confirm, :ask]
      assert view.counts == %{total: 2, open: 1, resolved: 1}

      # B acts on its STALE copy: refused, with the fresh row.
      assert {:error, :already_resolved, %MeetingBriefing{} = fresh} =
               MeetingBriefings.act(ctx.briefing, k, :revert, scope(ctx.b), %{})

      assert fresh.receipts[k]["by"] == ctx.a.id
      assert Repo.get!(TaskRecord, ctx.t1.id).deleted_at == deleted_at

      # And a different verb is refused the same way.
      assert {:error, :already_resolved, _} =
               MeetingBriefings.act(ctx.briefing, k, :confirm, scope(ctx.b), %{})
    end

    test "two concurrent acts on one key give exactly one :ok" do
      ctx = concluded!()
      k = key(ctx.t2)
      parent = self()

      results =
        [{ctx.a, :confirm}, {ctx.b, :confirm}]
        |> Enum.map(fn {user, verb} ->
          s = scope(user)

          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> MeetingBriefings.act(ctx.briefing, k, verb, s, %{})
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
      assert map_size(Repo.get!(MeetingBriefing, ctx.briefing.id).receipts) == 1
    end

    test "every attendee gets {:inbox_changed, _} and the briefing topic fires" do
      ctx = concluded!()
      Inbox.subscribe(ctx.a.id)
      Inbox.subscribe(ctx.b.id)
      MeetingBriefings.subscribe(ctx.briefing.id)

      assert {:ok, _} =
               MeetingBriefings.act(ctx.briefing, key(ctx.t1), :confirm, scope(ctx.a), %{})

      a_id = ctx.a.id
      b_id = ctx.b.id
      briefing_id = ctx.briefing.id
      assert_receive {:inbox_changed, ^a_id}
      assert_receive {:inbox_changed, ^b_id}
      assert_receive {:meeting_briefing_changed, ^briefing_id}
    end
  end

  # ── Refusals ──────────────────────────────────────────────────────────────

  describe "act/5 refusals" do
    test "a non-attendee and a forged key both get :not_found and write nothing" do
      ctx = concluded!()
      outsider = user!()

      assert {:error, :not_found} =
               MeetingBriefings.act(ctx.briefing, key(ctx.t1), :confirm, scope(outsider), %{})

      assert {:error, :not_found} =
               MeetingBriefings.act(
                 ctx.briefing,
                 "mdeadbeefdeadbeef",
                 :confirm,
                 scope(ctx.a),
                 %{}
               )

      assert {:error, :not_found} =
               MeetingBriefings.act(ctx.briefing, "_content", :confirm, scope(ctx.a), %{})

      assert Repo.get!(MeetingBriefing, ctx.briefing.id).receipts == %{}

      # Positive control: the attendee's real key works.
      assert {:ok, _} =
               MeetingBriefings.act(ctx.briefing, key(ctx.t1), :confirm, scope(ctx.a), %{})
    end

    test "an attendee who is a guest of the meeting's org gets :not_found" do
      guest = user!()

      {:ok, _} =
        Repo.get_by!(OrgMembership, user_id: guest.id, org_id: acme_org_id())
        |> Ecto.Changeset.change(external: true)
        |> Repo.update()

      ctx = concluded!(extra: [guest])
      # Delivery already left the guest out; force them onto the row to prove
      # act/5 refuses on its own.
      ctx.briefing
      |> Ecto.Changeset.change(attendee_user_ids: [guest.id | ctx.briefing.attendee_user_ids])
      |> Repo.update!()

      assert {:error, :not_found} =
               MeetingBriefings.act(ctx.briefing, key(ctx.t1), :confirm, scope(guest), %{})
    end

    test "an ack-done task is not revertible; its actions are Looks right and Ask" do
      ctx = concluded!(ack_done: true)
      k = key(ctx.done)

      view = MeetingBriefings.view(ctx.briefing, scope(ctx.a))
      assert item(view, k).revertible? == false
      assert item(view, k).actions == [:confirm, :ask]

      assert {:error, :not_revertible} =
               MeetingBriefings.act(ctx.briefing, k, :revert, scope(ctx.a), %{})

      assert Repo.get!(TaskRecord, ctx.done.id).deleted_at == nil
      assert Repo.get!(MeetingBriefing, ctx.briefing.id).receipts == %{}
    end

    test "a task moved to planning after the build is not revertible" do
      ctx = concluded!()

      ctx.t1 |> Ecto.Changeset.change(status: "planning") |> Repo.update!()

      assert {:error, :not_revertible} =
               MeetingBriefings.act(ctx.briefing, key(ctx.t1), :revert, scope(ctx.a), %{})

      assert Repo.get!(TaskRecord, ctx.t1.id).deleted_at == nil

      # Positive control: the untouched backlog task does revert.
      assert {:ok, _} =
               MeetingBriefings.act(ctx.briefing, key(ctx.t2), :revert, scope(ctx.a), %{})
    end

    test "a clicker without tasks.write gets :unauthorized and no receipt is written" do
      # An attendee whose only membership is in ANOTHER org: not a guest of
      # the meeting's org, but fenced out of its tasks.
      outsider_member = user!(tenant_org_id("globex"))
      ctx = concluded!(extra: [outsider_member])
      assert outsider_member.id in ctx.briefing.attendee_user_ids

      assert {:error, :unauthorized} =
               MeetingBriefings.act(
                 ctx.briefing,
                 key(ctx.t1),
                 :revert,
                 scope(outsider_member),
                 %{}
               )

      assert Repo.get!(TaskRecord, ctx.t1.id).deleted_at == nil
      assert Repo.get!(MeetingBriefing, ctx.briefing.id).receipts == %{}

      # The same clicker can still confirm: the refusal is the permission,
      # not the attendance.
      assert {:ok, _} =
               MeetingBriefings.act(
                 ctx.briefing,
                 key(ctx.t1),
                 :confirm,
                 scope(outsider_member),
                 %{}
               )
    end
  end

  # ── Ask ───────────────────────────────────────────────────────────────────

  describe "act/5 :ask" do
    test "posts one message as the clicker; a blank question is refused" do
      ctx = concluded!()
      k = key(ctx.t1)

      count = fn ->
        Repo.aggregate(where(Message, space_id: ^ctx.meeting.chat_space_id), :count)
      end

      before = count.()

      assert {:error, :blank} =
               MeetingBriefings.act(ctx.briefing, k, :ask, scope(ctx.b), %{"question" => "   "})

      assert count.() == before
      assert Repo.get!(MeetingBriefing, ctx.briefing.id).receipts == %{}

      assert {:ok, briefing} =
               MeetingBriefings.act(ctx.briefing, k, :ask, scope(ctx.b), %{
                 "question" => "Who owns this?"
               })

      assert count.() == before + 1
      assert "message:" <> message_id = briefing.receipts[k]["ref"]
      message = Repo.get!(Message, message_id)
      poster = Repo.get!(Platform.Chat.Participant, message.participant_id)

      assert poster.participant_type == "user"
      assert poster.participant_id == ctx.b.id
      assert message.content =~ "Who owns this?"
      assert briefing.receipts[k]["verb"] == "asked"
    end
  end

  test "an asker with no chat participant row gets one, with their display name" do
    ctx = concluded!()

    rows = fn ->
      Repo.all(
        from(p in Platform.Chat.Participant,
          where:
            p.space_id == ^ctx.meeting.chat_space_id and p.participant_type == "user" and
              p.participant_id == ^ctx.b.id
        )
      )
    end

    assert rows.() == []

    assert {:ok, _} =
             MeetingBriefings.act(ctx.briefing, key(ctx.t1), :ask, scope(ctx.b), %{
               "question" => "Is this still needed?"
             })

    assert [participant] = rows.()
    assert participant.display_name == ctx.b.name
  end

  # ── Archived actor ────────────────────────────────────────────────────────

  test "an actor archived since is still named on the receipt" do
    ctx = concluded!()
    k = key(ctx.t1)

    assert {:ok, briefing} = MeetingBriefings.act(ctx.briefing, k, :confirm, scope(ctx.a), %{})

    Repo.get!(User, ctx.a.id)
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
    |> Repo.update!()

    assert item(MeetingBriefings.view(briefing, scope(ctx.b)), k).receipt.by_name == ctx.a.name
  end
end
