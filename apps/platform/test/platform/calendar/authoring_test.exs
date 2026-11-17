defmodule Platform.Calendar.AuthoringTest do
  @moduledoc """
  Outcome tests for `Platform.Calendar.Authoring` and `Platform.Calendar.EventDraft`
  (task 01a1b8a5 stage 1): one logical event per time window across Calendar,
  booking availability and the private feed, ordinary call ON/OFF on create and
  edit, legacy meeting ids/slugs/guest links, presets, recurrence/time zone/DST,
  permissions, and transactional failure with retry.

  The "thin coordinator" tests at the bottom are the falsifier the stage names:
  Authoring's preview and save recipients must be exactly what `Platform.Meetings`
  returns, because Authoring has no recipient or authorization logic of its own.

  async: false: it flips `:meetings_enabled` in application env.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Access.Scope
  alias Platform.Accounts.User
  alias Platform.Calendar
  alias Platform.Calendar.{Authoring, Event, EventDraft}
  alias Platform.Meetings
  alias Platform.Meetings.{Invite, Meeting}
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership

  defmodule Quiet do
    @moduledoc "Inbox and notifications stand-in."
    def emit(attrs), do: {:ok, attrs}
    def fan_out_to_user(_user_id, _payload, _opts \\ []), do: :ok
    def fan_out_to_humans(_ids, _payload, _opts \\ []), do: :ok
  end

  setup do
    keys = [:meetings_enabled, :inbox_module, :notifications_module]
    prior = for key <- keys, into: %{}, do: {key, Application.fetch_env(:platform, key)}

    Application.put_env(:platform, :meetings_enabled, true)
    Application.put_env(:platform, :inbox_module, Quiet)
    Application.put_env(:platform, :notifications_module, Quiet)

    on_exit(fn ->
      for {key, value} <- prior do
        case value do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end
    end)

    org_id = Platform.TenancyFixtures.acme_org_id()
    owner = member!(org_id, "Owner Alpha")
    member = member!(org_id, "Member Beta")
    outsider = member!(org_id, "Member Gamma")
    n = System.unique_integer([:positive])

    project =
      Repo.insert!(%Project{name: "Authoring #{n}", slug: "authoring-#{n}", org_id: org_id})

    %{
      org_id: org_id,
      owner: owner,
      member: member,
      outsider: outsider,
      scope: Scope.for_user(owner),
      project: project
    }
  end

  defp member!(org_id, name) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{name: name, email: "authoring-#{n}@example.com", oidc_sub: "au-#{n}"})
      |> Repo.insert!()

    Repo.insert!(%OrgMembership{user_id: user.id, org_id: org_id, role: "member"})
    user
  end

  # `days` from now at the top of the hour, `minutes` long.
  defp window(days, minutes \\ 60) do
    start =
      DateTime.utc_now()
      |> DateTime.add(days * 86_400, :second)
      |> Map.merge(%{minute: 0, second: 0, microsecond: {0, 6}})

    {start, DateTime.add(start, minutes * 60, :second)}
  end

  defp range({start, finish}),
    do: {DateTime.add(start, -86_400, :second), DateTime.add(finish, 86_400, :second)}

  defp entries(scope, win) do
    {from, to} = range(win)
    Calendar.list_entries(scope, from, to)
  end

  defp busy(scope, win) do
    {from, to} = range(win)
    {:ok, busy} = Calendar.Subscriptions.availability(scope, from, to)
    busy
  end

  defp vevents(scope) do
    scope |> Calendar.Feed.render() |> String.split("BEGIN:VEVENT") |> length() |> Kernel.-(1)
  end

  defp event_count, do: Repo.aggregate(Event, :count)
  defp meeting_count, do: Repo.aggregate(Meeting, :count)

  defp ordinary(win, extra \\ %{}) do
    {start, finish} = win

    Map.merge(
      %{
        "title" => "Planning sync",
        "starts_at" => DateTime.to_iso8601(start),
        "ends_at" => DateTime.to_iso8601(finish),
        "time_zone" => "America/Chicago"
      },
      extra
    )
  end

  defp legacy_meeting!(ctx, win, name \\ "Legacy review") do
    {start, finish} = win

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: ctx.project.id,
        name: name,
        scheduled_start_at: start,
        scheduled_end_at: finish,
        created_by_user_id: ctx.owner.id
      })

    meeting
  end

  # ── Defaults and backward mappings ────────────────────────────────────────

  describe "defaults" do
    test "a new ordinary event defaults the call ON only when calls are available", ctx do
      assert %EventDraft{call_enabled: true, preset: "event"} = Authoring.new_draft(ctx.scope)

      Application.put_env(:platform, :meetings_enabled, false)
      assert %EventDraft{call_enabled: false} = Authoring.new_draft(ctx.scope)
    end

    test "a preset draft never defaults a call", ctx do
      assert %EventDraft{call_enabled: false} =
               Authoring.new_draft(ctx.scope, %{"preset" => "focus"})
    end

    test "an old plain event loads OFF and an existing meeting loads ON", ctx do
      win = window(3)
      {start, finish} = win

      {:ok, event} =
        Calendar.create_event(ctx.scope, %{title: "Plain", starts_at: start, ends_at: finish})

      meeting = legacy_meeting!(ctx, window(4))

      assert {:ok, %EventDraft{call_enabled: false, event_id: id}} =
               Authoring.load_draft(ctx.scope, {:event, event.id})

      assert id == event.id

      assert {:ok, %EventDraft{call_enabled: true, meeting_id: mid}} =
               Authoring.load_draft(ctx.scope, {:meeting, meeting.id})

      assert mid == meeting.id
    end
  end

  # ── Create ────────────────────────────────────────────────────────────────

  describe "create" do
    test "call ON creates one logical entry: one row in Calendar, booking and the feed", ctx do
      win = window(5)
      draft = Authoring.new_draft(ctx.scope)

      assert {:ok, %{event: event, meeting: %Meeting{} = meeting}} =
               Authoring.save(
                 ctx.scope,
                 draft,
                 ordinary(win, %{"project_id" => ctx.project.id, "notes" => "Agenda"})
               )

      assert event.meeting_id == meeting.id
      assert meeting.call_enabled
      assert meeting.description == "Agenda"
      assert is_nil(event.description)
      assert meeting.name == event.title
      assert meeting.scheduled_start_at == event.starts_at

      assert [entry] = entries(ctx.scope, win)
      assert entry.kind == :event and entry.id == event.id
      assert [_one] = busy(ctx.scope, win)
      assert vevents(ctx.scope) == 1
    end

    test "another member who can see both the project event and the call sees the call once",
         ctx do
      win = window(5)

      {:ok, %{meeting: meeting}} =
        Authoring.save(
          ctx.scope,
          Authoring.new_draft(ctx.scope),
          ordinary(win, %{
            "project_id" => ctx.project.id,
            "visibility" => "busy",
            "add_invitees" => [%{"kind" => "user", "user_id" => ctx.member.id}]
          })
        )

      member_scope = Scope.for_user(ctx.member)
      assert [%{kind: :meeting, id: id}] = entries(member_scope, win)
      assert id == meeting.id
      assert [_one] = busy(member_scope, win)
    end

    test "call OFF with nobody invited creates a native event and no call record", ctx do
      win = window(5)
      before = meeting_count()

      assert {:ok, %{event: event, meeting: nil}} =
               Authoring.save(
                 ctx.scope,
                 Authoring.new_draft(ctx.scope),
                 ordinary(win, %{"call_enabled" => "false", "notes" => "Native notes"})
               )

      assert event.description == "Native notes"
      assert is_nil(event.meeting_id)
      assert meeting_count() == before
      assert [%{kind: :event}] = entries(ctx.scope, win)
    end

    test "a forged call ON is refused server-side when calls are unavailable", ctx do
      Application.put_env(:platform, :meetings_enabled, false)
      before = {event_count(), meeting_count()}
      draft = Authoring.new_draft(ctx.scope)

      assert {:error, %Ecto.Changeset{} = cs} =
               Authoring.save(
                 ctx.scope,
                 draft,
                 ordinary(window(5), %{"call_enabled" => "true", "project_id" => ctx.project.id})
               )

      assert cs.errors[:call_enabled]
      assert {event_count(), meeting_count()} == before
    end

    test "a call needs a project, refused explicitly", ctx do
      assert {:error, %Ecto.Changeset{} = cs} =
               Authoring.save(ctx.scope, Authoring.new_draft(ctx.scope), ordinary(window(5)))

      assert cs.errors[:project_id]
    end

    test "a failed call create rolls the native event back, and a retry creates exactly one",
         ctx do
      before = {event_count(), meeting_count()}

      ctx.project
      |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
      |> Repo.update!()

      attrs = ordinary(window(6), %{"project_id" => ctx.project.id})
      draft = Authoring.new_draft(ctx.scope)

      assert {:error, _reason} = Authoring.save(ctx.scope, draft, attrs)
      assert {event_count(), meeting_count()} == before

      Project
      |> Repo.get!(ctx.project.id)
      |> Ecto.Changeset.change(archived_at: nil)
      |> Repo.update!()

      assert {:ok, %{meeting: %Meeting{}}} = Authoring.save(ctx.scope, draft, attrs)
      assert {event_count(), meeting_count()} == {elem(before, 0) + 1, elem(before, 1) + 1}
    end

    test "people with the call OFF keep a call record with the call disabled", ctx do
      assert {:ok, %{meeting: %Meeting{} = meeting}} =
               Authoring.save(
                 ctx.scope,
                 Authoring.new_draft(ctx.scope),
                 ordinary(window(5), %{
                   "call_enabled" => "false",
                   "project_id" => ctx.project.id,
                   "add_invitees" => [%{"kind" => "user", "user_id" => ctx.member.id}]
                 })
               )

      refute meeting.call_enabled
      assert [%Invite{user_id: user_id}] = Meetings.list_invites(meeting.id)
      assert user_id == ctx.member.id
    end
  end

  # ── Edit ──────────────────────────────────────────────────────────────────

  describe "edit" do
    setup ctx do
      win = window(7)

      {:ok, %{event: event, meeting: meeting}} =
        Authoring.save(
          ctx.scope,
          Authoring.new_draft(ctx.scope),
          ordinary(win, %{"project_id" => ctx.project.id})
        )

      Map.merge(ctx, %{win: win, event: event, meeting: meeting})
    end

    test "turning the call OFF keeps the event id, meeting id, slug and guest links", ctx do
      {:ok, %{invite: guest}} =
        Meetings.invite_guest(ctx.meeting, %{
          display_name: "Guest Delta",
          email: "guest-delta@example.com",
          host_user_id: ctx.owner.id
        })

      {:ok, draft} = Authoring.load_draft(ctx.scope, {:event, ctx.event.id})

      assert {:ok, %{event: event, meeting: meeting}} =
               Authoring.save(ctx.scope, draft, %{"call_enabled" => "false"})

      assert event.id == ctx.event.id
      assert meeting.id == ctx.meeting.id
      assert meeting.slug == ctx.meeting.slug
      refute meeting.call_enabled
      assert meeting.ical_sequence == ctx.meeting.ical_sequence + 1
      assert [%Invite{id: id, revoked_at: nil}] = Meetings.list_invites(meeting.id)
      assert id == guest.id
      assert [_one] = entries(ctx.scope, ctx.win)
    end

    test "an explicit OFF survives an unrelated edit", ctx do
      {:ok, draft} = Authoring.load_draft(ctx.scope, {:event, ctx.event.id})
      {:ok, _} = Authoring.save(ctx.scope, draft, %{"call_enabled" => "false"})

      {:ok, draft} = Authoring.load_draft(ctx.scope, {:event, ctx.event.id})
      assert draft.call_enabled == false

      {:ok, %{meeting: meeting}} = Authoring.save(ctx.scope, draft, %{"title" => "Renamed"})
      refute meeting.call_enabled
      assert meeting.name == "Renamed"
      assert Repo.get!(Event, ctx.event.id).title == "Renamed"
    end

    test "moving a call-backed event moves both records together", ctx do
      {start, _} = window(9)
      finish = DateTime.add(start, 1800, :second)
      {:ok, draft} = Authoring.load_draft(ctx.scope, {:event, ctx.event.id})

      {:ok, %{event: event, meeting: meeting}} =
        Authoring.save(ctx.scope, draft, %{
          "starts_at" => DateTime.to_iso8601(start),
          "ends_at" => DateTime.to_iso8601(finish)
        })

      assert event.starts_at == start and meeting.scheduled_start_at == start
      assert event.ends_at == finish and meeting.scheduled_end_at == finish
      assert [_one] = entries(ctx.scope, {start, finish})
    end

    test "a refused meeting edit leaves the native event untouched", ctx do
      {:ok, invite} = Meetings.invite_user(ctx.meeting, ctx.member.id)
      {:ok, draft} = Authoring.load_draft(ctx.scope, {:event, ctx.event.id})

      assert {:error, :last_invitee} =
               Authoring.save(ctx.scope, draft, %{
                 "title" => "Should not land",
                 "remove_invite_ids" => [invite.id]
               })

      assert Repo.get!(Event, ctx.event.id).title == ctx.event.title
      assert Repo.get!(Meeting, ctx.meeting.id).name == ctx.meeting.name
    end

    test "an unauthorized editor is refused by Meetings and nothing is written", ctx do
      outsider = Scope.for_user(ctx.outsider)
      {:ok, draft} = Authoring.load_draft(outsider, {:meeting, ctx.meeting.id})
      before = event_count()

      assert {:error, :forbidden} = Authoring.save(outsider, draft, %{"title" => "Hijack"})
      assert event_count() == before
      assert Repo.get!(Meeting, ctx.meeting.id).name == ctx.meeting.name
    end

    test "a native event gains a call without changing its id, and its notes move to the call",
         ctx do
      win = window(10)
      {start, finish} = win

      {:ok, plain} =
        Calendar.create_event(ctx.scope, %{
          title: "Plain",
          description: "Bring numbers",
          starts_at: start,
          ends_at: finish
        })

      {:ok, draft} = Authoring.load_draft(ctx.scope, {:event, plain.id})

      assert {:ok, %{event: event, meeting: %Meeting{} = meeting}} =
               Authoring.save(ctx.scope, draft, %{
                 "call_enabled" => "true",
                 "project_id" => ctx.project.id
               })

      assert event.id == plain.id
      assert event.meeting_id == meeting.id
      assert meeting.description == "Bring numbers"
      assert is_nil(event.description)
      assert [_one] = entries(ctx.scope, win)
      assert vevents(ctx.scope) == 2
    end
  end

  # ── Legacy meetings ──────────────────────────────────────────────────────

  describe "legacy meetings" do
    test "a legacy meeting turned OFF keeps its id, slug and invites, with no native copy", ctx do
      win = window(11)
      meeting = legacy_meeting!(ctx, win)
      {:ok, invite} = Meetings.invite_user(meeting, ctx.member.id)
      before = event_count()

      {:ok, draft} = Authoring.load_draft(ctx.scope, {:meeting, meeting.id})

      assert {:ok, %{event: nil, meeting: updated}} =
               Authoring.save(ctx.scope, draft, %{"call_enabled" => "false"})

      assert updated.id == meeting.id and updated.slug == meeting.slug
      refute updated.call_enabled
      assert [%Invite{id: id}] = Meetings.list_invites(meeting.id)
      assert id == invite.id
      assert event_count() == before
      assert [%{kind: :meeting}] = entries(ctx.scope, win)
    end

    test "a legacy meeting set to Out of office keeps its call record and projects once", ctx do
      win = window(12)
      meeting = legacy_meeting!(ctx, win)
      {:ok, invite} = Meetings.invite_user(meeting, ctx.member.id)
      {:ok, draft} = Authoring.load_draft(ctx.scope, {:meeting, meeting.id})

      assert {:error, %Ecto.Changeset{} = cs} =
               Authoring.save(ctx.scope, draft, %{"preset" => "ooo"})

      assert cs.errors[:call_enabled]

      assert {:ok, %{event: %Event{} = event, meeting: updated}} =
               Authoring.save(ctx.scope, draft, %{"preset" => "ooo", "call_enabled" => "false"})

      assert event.preset == "ooo" and event.meeting_id == meeting.id
      assert updated.id == meeting.id and updated.slug == meeting.slug
      refute updated.call_enabled
      assert [%Invite{id: id}] = Meetings.list_invites(meeting.id)
      assert id == invite.id

      assert [%{kind: :event, id: event_id}] = entries(ctx.scope, win)
      assert event_id == event.id
      assert [_one] = busy(ctx.scope, win)

      member_scope = Scope.for_user(ctx.member)
      assert [%{kind: :meeting, id: meeting_id}] = entries(member_scope, win)
      assert meeting_id == meeting.id

      assert {:ok, %EventDraft{event_id: ^event_id, preset: "ooo"}} =
               Authoring.load_draft(ctx.scope, {:meeting, meeting.id})
    end

    test "a legacy edit made outside Calendar keeps a linked event's window in step", ctx do
      win = window(13)
      meeting = legacy_meeting!(ctx, win)
      {:ok, draft} = Authoring.load_draft(ctx.scope, {:meeting, meeting.id})

      {:ok, %{event: event}} =
        Authoring.save(ctx.scope, draft, %{"visibility" => "busy"})

      {new_start, new_end} = window(14)

      {:ok, _} =
        Meetings.update_meeting_for_user(
          meeting.id,
          %{scheduled_start_at: new_start, scheduled_end_at: new_end, name: "Moved"},
          ctx.owner
        )

      moved = Repo.get!(Event, event.id)
      assert moved.starts_at == new_start and moved.ends_at == new_end
      assert moved.title == "Moved"
      assert [_one] = entries(ctx.scope, {new_start, new_end})
    end
  end

  # ── Presets, recurrence, time zones ──────────────────────────────────────

  describe "presets and recurrence" do
    test "focus and OOO refuse a call and people, explicitly", ctx do
      draft = Authoring.new_draft(ctx.scope, %{"preset" => "focus"})

      assert {:error, cs} =
               Authoring.save(ctx.scope, draft, ordinary(window(15), %{"call_enabled" => "true"}))

      assert cs.errors[:call_enabled]

      assert {:error, cs} =
               Authoring.save(
                 ctx.scope,
                 Authoring.new_draft(ctx.scope, %{"preset" => "ooo"}),
                 ordinary(window(15), %{
                   "add_invitees" => [%{"kind" => "user", "user_id" => ctx.member.id}]
                 })
               )

      assert cs.errors[:add_invitees]
    end

    test "OOO blocks availability and keeps the overlapping event", ctx do
      win = window(16, 120)
      {start, finish} = win

      {:ok, existing} =
        Calendar.create_event(ctx.scope, %{title: "Existing", starts_at: start, ends_at: finish})

      assert {:ok, %{event: ooo}} =
               Authoring.save(
                 ctx.scope,
                 Authoring.new_draft(ctx.scope, %{"preset" => "ooo"}),
                 ordinary(win, %{"title" => "Away"})
               )

      assert ooo.preset == "ooo"
      assert Repo.get!(Event, existing.id).cancelled_at == nil
      ids = entries(ctx.scope, win) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([existing.id, ooo.id])
      assert length(busy(ctx.scope, win)) == 2
    end

    test "a repeating event cannot carry a call, refused explicitly", ctx do
      assert {:error, cs} =
               Authoring.save(
                 ctx.scope,
                 Authoring.new_draft(ctx.scope),
                 ordinary(window(17), %{
                   "project_id" => ctx.project.id,
                   "recurrence" => "FREQ=WEEKLY"
                 })
               )

      assert cs.errors[:recurrence]
    end

    test "native recurrence, time zone and all-day across DST round-trip through the draft",
         ctx do
      draft = Authoring.new_draft(ctx.scope, %{"call_enabled" => "false"})

      assert {:ok, %{event: event}} =
               Authoring.save(ctx.scope, draft, %{
                 "title" => "Holiday",
                 "time_zone" => "America/New_York",
                 "all_day" => "true",
                 "start_date" => "2026-11-01",
                 "end_date" => "2026-11-02",
                 "call_enabled" => "false"
               })

      assert event.starts_at == ~U[2026-11-01 04:00:00.000000Z]
      assert event.ends_at == ~U[2026-11-02 05:00:00.000000Z]

      {:ok, loaded} = Authoring.load_draft(ctx.scope, {:event, event.id})
      assert loaded.all_day and loaded.start_date == ~D[2026-11-01]
      assert loaded.time_zone == "America/New_York"

      assert {:ok, %{event: weekly}} =
               Authoring.save(
                 ctx.scope,
                 Authoring.new_draft(ctx.scope),
                 %{
                   "title" => "Standup",
                   "starts_at" => "2026-10-26T13:00:00Z",
                   "ends_at" => "2026-10-26T13:30:00Z",
                   "time_zone" => "America/New_York",
                   "recurrence" => "FREQ=WEEKLY",
                   "call_enabled" => "false"
                 }
               )

      {:ok, loaded} = Authoring.load_draft(ctx.scope, {:event, weekly.id})
      assert loaded.recurrence == "FREQ=WEEKLY"
      refute loaded.call_enabled
    end
  end

  # ── Delete ───────────────────────────────────────────────────────────────

  describe "delete" do
    test "a future call-backed event is not deletable, per the meeting lifecycle", ctx do
      {:ok, %{event: event}} =
        Authoring.save(
          ctx.scope,
          Authoring.new_draft(ctx.scope),
          ordinary(window(18), %{"project_id" => ctx.project.id})
        )

      {:ok, draft} = Authoring.load_draft(ctx.scope, {:event, event.id})
      assert {:error, :not_deletable} = Authoring.delete(ctx.scope, draft)
      assert is_nil(Repo.get!(Event, event.id).cancelled_at)
    end

    test "a native event is cancelled", ctx do
      {:ok, %{event: event}} =
        Authoring.save(
          ctx.scope,
          Authoring.new_draft(ctx.scope, %{"call_enabled" => "false"}),
          ordinary(window(18), %{"call_enabled" => "false"})
        )

      {:ok, draft} = Authoring.load_draft(ctx.scope, {:event, event.id})
      assert {:ok, _} = Authoring.delete(ctx.scope, draft)
      assert Repo.get!(Event, event.id).cancelled_at
    end
  end

  # ── Thin coordinator falsifiers ──────────────────────────────────────────

  describe "Authoring delegates to Meetings" do
    test "preview is exactly Meetings.preview_meeting_edit/2's answer", ctx do
      win = window(19)
      meeting = legacy_meeting!(ctx, win)
      {:ok, _} = Meetings.invite_user(meeting, ctx.member.id)
      {new_start, new_end} = window(20)
      {:ok, draft} = Authoring.load_draft(ctx.scope, {:meeting, meeting.id})

      attrs = %{
        "title" => "Renamed review",
        "starts_at" => DateTime.to_iso8601(new_start),
        "ends_at" => DateTime.to_iso8601(new_end),
        "call_enabled" => "false"
      }

      expected =
        Meetings.preview_meeting_edit(meeting, %{
          name: "Renamed review",
          scheduled_start_at: new_start,
          scheduled_end_at: new_end,
          call_enabled: false
        })

      assert {:ok, ^expected} = Authoring.preview(ctx.scope, draft, attrs)
      assert :call in expected.changed
    end

    test "the call ON/OFF change flows through the guarded edit: a non-scheduled meeting refuses",
         ctx do
      win = window(21)
      meeting = legacy_meeting!(ctx, win)
      {:ok, draft} = Authoring.load_draft(ctx.scope, {:meeting, meeting.id})

      from(m in Meeting, where: m.id == ^meeting.id) |> Repo.update_all(set: [status: "live"])

      assert {:error, :forbidden} = Authoring.save(ctx.scope, draft, %{"call_enabled" => "false"})
      assert Repo.get!(Meeting, meeting.id).call_enabled
    end
  end
end
