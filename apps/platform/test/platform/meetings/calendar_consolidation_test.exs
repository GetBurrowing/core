defmodule Platform.Meetings.CalendarConsolidationTest do
  @moduledoc """
  Task 01a1b8a5 stage 4, at the context level:

    * the call toggle is enforced server-side: `meetings.call_enabled = false`
      refuses every join and token path (web, companion, native app, guest)
      and mints nothing;
    * cancelling a call record from any surface cancels its owner's linked
      native `calendar_events` row in the same transaction;
    * `Platform.Meetings.PastEvents` pages the viewer's past calls with each
      record (summary, transcript, recording) checked on its own.

  Every refusal carries a positive control on the same fixture.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.ExternalUserFixtures

  alias Platform.Access.Scope
  alias Platform.Calendar
  alias Platform.Calendar.{Authoring, Event}
  alias Platform.Meetings
  alias Platform.Meetings.{Meeting, PastEvents, Recording, Room, Transcript}
  alias Platform.Mobile.NativeCall
  alias Platform.Tasks
  alias Platform.Tenancy

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

    globex = Tenancy.get_org_by_slug!("globex")
    owner = create_user!()
    plain_member!(owner, globex)
    other = create_user!()
    plain_member!(other, globex)
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Consolidation #{n}", org_id: globex.id})

    %{globex: globex, owner: owner, other: other, project: project}
  end

  defp window(days) do
    start =
      DateTime.utc_now()
      |> DateTime.add(days * 86_400, :second)
      |> Map.merge(%{minute: 0, second: 0, microsecond: {0, 6}})

    {start, DateTime.add(start, 3600, :second)}
  end

  # A native event with a call record, through the one Authoring path.
  defp linked!(ctx, extra \\ %{}) do
    {start, finish} = window(3)
    scope = Scope.for_user(ctx.owner)

    attrs =
      Map.merge(
        %{
          "title" => "Design review",
          "starts_at" => DateTime.to_iso8601(start),
          "ends_at" => DateTime.to_iso8601(finish),
          "time_zone" => "America/Chicago",
          "project_id" => ctx.project.id
        },
        extra
      )

    {:ok, %{event: event, meeting: meeting}} =
      Authoring.save(scope, Authoring.new_draft(scope), attrs)

    %{event: event, meeting: meeting}
  end

  defp call_off!(ctx) do
    linked!(ctx, %{
      "call_enabled" => "false",
      "add_invitees" => [%{"kind" => "user", "user_id" => ctx.other.id}]
    })
  end

  defp participants(space_id),
    do:
      Repo.aggregate(from(p in Platform.Chat.Participant, where: p.space_id == ^space_id), :count)

  describe "the call toggle's server gate" do
    test "a call-off meeting really is off, and its space reports it", ctx do
      %{meeting: off} = call_off!(ctx)
      %{meeting: on} = linked!(ctx)

      assert off.call_enabled == false
      assert Meetings.call_disabled_for_space?(off.chat_space_id)
      refute Meetings.call_disabled_for_space?(on.chat_space_id), "positive control"
      refute Meetings.call_enabled?(off)
      assert Meetings.call_enabled?(on)
    end

    test "join_for_user refuses with :call_disabled and writes nothing", ctx do
      %{meeting: off} = call_off!(ctx)
      before = participants(off.chat_space_id)

      assert Meetings.join_for_user(off.chat_space_id, ctx.other.id, "Other") ==
               {:error, :call_disabled}

      assert participants(off.chat_space_id) == before
      assert Repo.get(Meeting, off.id).status == "scheduled"
    end

    test "the companion token is refused the same way", ctx do
      %{meeting: off} = call_off!(ctx)

      assert Meetings.companion_token_for_user(off.chat_space_id, ctx.other.id, "Other") ==
               {:error, :call_disabled}
    end

    test "the guest mint is refused before any LiveKit work", ctx do
      %{meeting: off} = call_off!(ctx)
      %{meeting: on} = linked!(ctx)

      assert Meetings.mint_guest_join_bundle(off, "Guest") == {:error, :call_disabled}
      # Control: with the call on, the mint gets past the toggle (here it
      # stops at the unconfigured media plane instead).
      refute Meetings.mint_guest_join_bundle(on, "Guest") == {:error, :call_disabled}
    end

    test "the native app's join is refused and does not flip the meeting live", ctx do
      %{meeting: off} = call_off!(ctx)

      assert NativeCall.join(ctx.owner, off.id) == {:error, :call_disabled}
      assert Repo.get(Meeting, off.id).status == "scheduled"
    end

    test "a soft-deleted call-off meeting no longer blocks its space", ctx do
      %{meeting: off} = call_off!(ctx)
      assert Meetings.call_disabled_for_space?(off.chat_space_id)

      Repo.update_all(from(m in Meeting, where: m.id == ^off.id),
        set: [deleted_at: DateTime.utc_now()]
      )

      refute Meetings.call_disabled_for_space?(off.chat_space_id)
    end

    test "a plain chat space and a malformed id are never call-off" do
      refute Meetings.call_disabled_for_space?(Ecto.UUID.generate())
      refute Meetings.call_disabled_for_space?("not-a-uuid")
      refute Meetings.call_disabled_for_space?(nil)
    end
  end

  describe "cancel keeps the owner's calendar in step" do
    test "cancelling the call record cancels its linked native event and tells the owner",
         ctx do
      %{event: event, meeting: meeting} = linked!(ctx)
      %{event: bystander} = linked!(ctx, %{"title" => "Another call"})
      Calendar.subscribe(Scope.for_user(ctx.owner))

      assert {:ok, %Meeting{status: "cancelled"}} =
               Meetings.cancel_meeting_for_user(meeting.id, ctx.owner)

      cancelled = Repo.get(Event, event.id)
      assert %DateTime{} = cancelled.cancelled_at
      assert cancelled.sequence == event.sequence + 1
      event_id = event.id
      assert_receive {:calendar_changed, ^event_id}

      # Control: another call's event is untouched.
      assert is_nil(Repo.get(Event, bystander.id).cancelled_at)
    end

    test "the owner's Calendar then shows the cancelled call, not an active event", ctx do
      %{event: event, meeting: meeting} = linked!(ctx)
      scope = Scope.for_user(ctx.owner)
      {start, finish} = {meeting.scheduled_start_at, meeting.scheduled_end_at}
      {from, to} = {DateTime.add(start, -86_400), DateTime.add(finish, 86_400)}

      assert [%{kind: :event, id: id}] = Calendar.list_entries(scope, from, to)
      assert id == event.id

      {:ok, _} = Meetings.cancel_meeting_for_user(meeting.id, ctx.owner)

      assert [%{kind: :meeting, meeting: %{status: "cancelled"}}] =
               Calendar.list_entries(scope, from, to, cancelled_meetings: :keep)
    end

    test "a refused cancel leaves the native event active", ctx do
      %{event: event, meeting: meeting} = linked!(ctx)

      assert {:error, :forbidden} = Meetings.cancel_meeting_for_user(meeting.id, ctx.other)
      assert is_nil(Repo.get(Event, event.id).cancelled_at)
    end

    test "cancel_linked_events ignores a malformed id" do
      assert Calendar.cancel_linked_events("nope") == []
      assert Calendar.cancel_linked_events(nil) == []
    end
  end

  # ── past events ─────────────────────────────────────────────────────────

  defp ended!(ctx, name, ended_at) do
    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: ctx.project.id,
        name: name,
        created_by_user_id: ctx.owner.id
      })

    started = DateTime.add(ended_at, -1800, :second)

    Repo.update_all(from(m in Meeting, where: m.id == ^meeting.id),
      set: [status: "ended", started_at: started, ended_at: ended_at]
    )

    Repo.get!(Meeting, meeting.id)
  end

  defp transcript!(meeting, attrs) do
    %Transcript{}
    |> Transcript.changeset(
      Map.merge(
        %{
          room_id: "space-#{meeting.chat_space_id}",
          space_id: meeting.chat_space_id,
          meeting_id: meeting.id,
          started_at: DateTime.utc_now(),
          status: "complete"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp recording!(meeting, attrs) do
    room =
      %Room{}
      |> Room.changeset(%{
        space_id: meeting.chat_space_id,
        livekit_room_name: "rec-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert!()

    %Recording{}
    |> Recording.changeset(Map.merge(%{room_id: room.id, space_id: meeting.chat_space_id}, attrs))
    |> Repo.insert!()
  end

  describe "PastEvents" do
    test "a page carries each call's own records, and absent ones are absent", ctx do
      now = DateTime.utc_now()
      full = ended!(ctx, "Full recap call", DateTime.add(now, -3600))
      bare = ended!(ctx, "Nothing kept call", DateTime.add(now, -7200))

      t =
        transcript!(full, %{
          summary: "  We agreed the bucket policy.  ",
          segments: [%{"speaker_name" => "A", "text" => "hi"}]
        })

      recording!(full, %{status: "ready", file_url: "https://files.example/rec.mp4"})
      # A recording still processing is not offered.
      recording!(bare, %{status: "processing", file_url: "https://files.example/wip.mp4"})

      {:ok, page} = PastEvents.page(Scope.for_user(ctx.owner), 1)
      rows = Map.new(page.rows, &{&1.id, &1})

      assert rows[full.id].summary == "We agreed the bucket policy."
      assert rows[full.id].transcript_id == t.id
      assert rows[full.id].recording_url == "https://files.example/rec.mp4"

      assert rows[bare.id].summary == nil
      assert rows[bare.id].transcript_id == nil
      assert rows[bare.id].recording_url == nil

      # Newest first.
      ids = Enum.map(page.rows, & &1.id)
      assert Enum.find_index(ids, &(&1 == full.id)) < Enum.find_index(ids, &(&1 == bare.id))
    end

    test "a transcript still recording, or with no segments, is not offered", ctx do
      m = ended!(ctx, "Still recording call", DateTime.utc_now())
      transcript!(m, %{status: "recording", segments: [%{"text" => "x"}], summary: "Draft"})

      {:ok, page} = PastEvents.page(Scope.for_user(ctx.owner), 1)
      row = Enum.find(page.rows, &(&1.id == m.id))
      assert row.transcript_id == nil
    end

    test "another org's calls and their records never appear", ctx do
      acme = Tenancy.get_org_by_slug!("acme")
      outsider = create_user!()
      plain_member!(outsider, acme)

      m = ended!(ctx, "Globex only call", DateTime.utc_now())
      transcript!(m, %{summary: "secret", segments: [%{"text" => "x"}]})
      recording!(m, %{status: "ready", file_url: "https://files.example/secret.mp4"})

      {:ok, mine} = PastEvents.page(Scope.for_user(ctx.owner), 1)
      assert Enum.any?(mine.rows, &(&1.id == m.id)), "positive control"

      {:ok, theirs} = PastEvents.page(Scope.for_user(outsider), 1)
      refute Enum.any?(theirs.rows, &(&1.id == m.id))
      refute Enum.any?(theirs.rows, &(&1.summary == "secret"))
    end

    test "an external user without calls is told Past events are unavailable, invited or not",
         ctx do
      m = ended!(ctx, "Invited call", DateTime.utc_now())
      recording!(m, %{status: "ready", file_url: "https://files.example/inv.mp4"})
      external = external_user!(ctx.globex)
      {:ok, _} = Meetings.invite_user(m, external.id)

      # Externals hold no `meetings.join` on this install, so the surface is
      # unavailable rather than an empty or partial list.
      refute Platform.Access.can?(Scope.for_user(external), "meetings.join")
      assert PastEvents.page(Scope.for_user(external), 1) == {:error, :unavailable}

      # The recording itself is still gated by the meeting rule.
      assert PastEvents.records(external, m).recording_url ==
               "https://files.example/inv.mp4"

      acme = Tenancy.get_org_by_slug!("acme")
      stranger = create_user!()
      plain_member!(stranger, acme)
      assert PastEvents.records(stranger, m).recording_url == nil
    end

    test "pages are bounded and say whether there is more", ctx do
      base = DateTime.utc_now()
      per = PastEvents.per_page()
      Repo.delete_all(Meeting)

      for i <- 1..(per + 3), do: ended!(ctx, "Paged #{i}", DateTime.add(base, -i * 60))

      scope = Scope.for_user(ctx.owner)
      {:ok, one} = PastEvents.page(scope, 1)
      {:ok, two} = PastEvents.page(scope, "2")

      assert length(one.rows) == per and one.more?
      assert length(two.rows) == 3 and not two.more?
      assert MapSet.disjoint?(MapSet.new(one.rows, & &1.id), MapSet.new(two.rows, & &1.id))
      assert one.total == per + 3

      # A junk page is page 1, never an error or an offset past the end.
      for junk <- ["0", "-2", "abc", nil, "99999999"] do
        {:ok, p} = PastEvents.page(scope, junk)
        assert p.page == 1, inspect(junk)
      end
    end

    test "an empty history is an empty page, not unavailable", ctx do
      Repo.delete_all(Meeting)

      assert {:ok, %{rows: [], total: 0, more?: false}} =
               PastEvents.page(Scope.for_user(ctx.owner), 1)
    end

    test "no meetings.join is unavailable, which is not the same answer as empty", ctx do
      scope = %Scope{actor: ctx.owner, permissions: %{"calendar.read" => :all}}
      assert PastEvents.page(scope, 1) == {:error, :unavailable}
      assert PastEvents.page(nil, 1) == {:error, :unavailable}
    end

    test "records/2 is per meeting and empty for a call that is not over", ctx do
      m = ended!(ctx, "Records call", DateTime.utc_now())
      transcript!(m, %{summary: "Done", segments: [%{"text" => "x"}]})

      assert %{summary: "Done", transcript_id: tid} = PastEvents.records(ctx.owner, m)
      assert is_binary(tid)

      acme = Tenancy.get_org_by_slug!("acme")
      outsider = create_user!()
      plain_member!(outsider, acme)

      assert PastEvents.records(outsider, m) == %{
               summary: nil,
               transcript_id: nil,
               recording_url: nil
             }

      %{meeting: scheduled} = linked!(ctx)
      assert PastEvents.records(ctx.owner, scheduled).summary == nil
    end
  end
end
