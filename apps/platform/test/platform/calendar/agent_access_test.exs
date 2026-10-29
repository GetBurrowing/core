defmodule Platform.Calendar.AgentAccessTest do
  use Platform.DataCase, async: false
  alias Platform.{Repo, Calendar}
  alias Platform.Calendar.{AgentAccess, Consent, Event}
  alias Platform.Access.{Scope, RuntimeProfile, RuntimeProfiles}
  alias Platform.Memory.{Briefing, Insights.Briefings}

  setup do
    n = System.unique_integer([:positive])
    user = Platform.ExternalUserFixtures.create_user!()
    Platform.ExternalUserFixtures.plain_member!(user, Platform.Tenancy.get_org_by_slug!("globex"))

    agent =
      Repo.insert!(%Platform.Agents.Agent{name: "Calendar agent", slug: "calendar-grant-#{n}"})

    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        runtime_id: "calendar-#{n}",
        owner_user_id: user.id,
        agent_id: agent.id,
        status: "active",
        display_name: "Calendar agent"
      })

    Repo.insert!(%RuntimeProfile{
      runtime_id: runtime.id,
      tool_profile: ["context_read"],
      restricted_permissions: RuntimeProfiles.translated_permissions(["context_read"])
    })

    %{
      owner: Scope.for_user(user),
      runtime: runtime,
      scope: Scope.for_runtime(runtime),
      agent: agent
    }
  end

  defp attrs(extra \\ %{}),
    do:
      Map.merge(
        %{
          title: "Agent appointment",
          starts_at: ~U[2026-11-05 10:00:00.000000Z],
          ends_at: ~U[2026-11-05 11:00:00.000000Z],
          time_zone: "Etc/UTC"
        },
        extra
      )

  defp grant(ctx, extra \\ %{}) do
    {:ok, grant} =
      AgentAccess.grant(
        ctx.owner,
        ctx.agent.id,
        Map.merge(%{read: true, read_private: true, create: true, move: true}, extra)
      )

    grant
  end

  defp propose(ctx, key \\ "request") do
    AgentAccess.propose(ctx.scope, ctx.owner.actor.id, "create", attrs(), key)
  end

  defp row(c), do: Repo.get!(Briefing, c.briefing_id)
  defp key(c), do: "calendar:" <> c.id

  test "ungranted context and federation paths refuse reads and writes", ctx do
    assert {:error, :forbidden} =
             AgentAccess.read(
               ctx.scope,
               ctx.owner.actor.id,
               ~U[2026-11-01 00:00:00Z],
               ~U[2026-11-10 00:00:00Z]
             )

    assert {:error, :forbidden} = propose(ctx)

    assert {:error, _} =
             Platform.Federation.ToolSurface.execute(
               "calendar_propose",
               %{
                 "owner_id" => ctx.owner.actor.id,
                 "operation" => "create",
                 "attributes" => attrs(),
                 "request_key" => "wire"
               },
               %{runtime_id: ctx.runtime.runtime_id, agent_id: ctx.agent.id}
             )

    assert [] =
             Calendar.list_entries(ctx.scope, ~U[2026-11-01 00:00:00Z], ~U[2026-11-10 00:00:00Z])

    assert [] = Calendar.feed_events(ctx.scope)

    assert [] =
             Calendar.list_events(ctx.scope, ~U[2026-11-01 00:00:00Z], ~U[2026-11-10 00:00:00Z])
  end

  test "read grants omit private events unless explicitly enabled", ctx do
    grant(ctx, %{read_private: false})
    {:ok, event} = Calendar.create_event(ctx.owner, attrs())

    assert {:ok, []} =
             AgentAccess.read(
               ctx.scope,
               ctx.owner.actor.id,
               ~U[2026-11-01 00:00:00Z],
               ~U[2026-11-10 00:00:00Z]
             )

    grant(ctx)

    assert {:ok, [%{id: id}]} =
             AgentAccess.read(
               ctx.scope,
               ctx.owner.actor.id,
               ~U[2026-11-01 00:00:00Z],
               ~U[2026-11-10 00:00:00Z]
             )

    assert id == event.id
    Repo.update!(Ecto.Changeset.change(ctx.runtime, status: "revoked"))

    assert {:error, :forbidden} =
             AgentAccess.read(
               ctx.scope,
               ctx.owner.actor.id,
               ~U[2026-11-01 00:00:00Z],
               ~U[2026-11-10 00:00:00Z]
             )
  end

  test "intent, tentative hold, Inbox row and approval receipt are durable and idempotent", ctx do
    grant(ctx)
    assert {:ok, c} = propose(ctx)
    assert Repo.get!(Event, c.hold_id).tentative
    assert Calendar.Feed.render(ctx.owner) =~ "STATUS:TENTATIVE"

    assert {:ok, duplicate} =
             AgentAccess.propose(
               ctx.scope,
               ctx.owner.actor.id,
               "create",
               attrs(%{title: "tampered"}),
               "request"
             )

    assert duplicate.id == c.id
    assert Repo.aggregate(Consent, :count) == 1
    assert Repo.get!(Event, c.hold_id).title == "Agent appointment"
    assert Repo.get_by!(Platform.Inbox.Item, source_id: c.briefing_id).url =~ "/inbox/briefing/"
    view = Briefings.view(row(c), ctx.owner)
    assert [%{kind: :calendar, state: "pending"}] = view.needs_call
    assert view.counts.calls == 1
    assert Briefings.view(row(c), Scope.for_user(%{id: ctx.owner.actor.id})).counts.calls == 1
    assert Briefings.open_item?(row(c))
    refute Briefings.inbox_row_stale?(c.briefing_id, today: Date.add(row(c).digest_date, 8))
    assert {:ok, approved} = Briefings.handle(row(c), key(c), "approve", ctx.owner)
    refute Repo.get!(Event, c.hold_id).tentative
    assert approved.receipts[key(c)]["verb"] == "approve"

    assert Briefings.view(approved, ctx.owner).counts == %{
             total: 1,
             open: 0,
             calls: 0,
             handled: 1
           }

    assert {:ok, _} = Briefings.handle(approved, key(c), "approve", ctx.owner)
    assert Repo.get!(Event, c.hold_id).sequence == 1
    assert {:ok, _} = Briefings.handle(row(c), key(c), "revert", ctx.owner)
    assert Repo.get!(Event, c.hold_id).cancelled_at
    assert {:ok, _} = Briefings.handle(row(c), key(c), "revert", ctx.owner)
  end

  test "pending revert removes hold, owner tampering and unknown keys do nothing", ctx do
    grant(ctx)
    {:ok, c} = propose(ctx)
    stranger = Scope.for_user(Platform.ExternalUserFixtures.create_user!())
    assert {:error, _} = Briefings.handle(row(c), key(c), "approve", stranger)

    assert {:error, _} =
             Briefings.handle(row(c), "calendar:" <> Ecto.UUID.generate(), "approve", ctx.owner)

    assert Repo.get!(Consent, c.id).state == "pending"
    assert {:error, _} = Calendar.update_event(ctx.owner, c.hold_id, attrs(%{title: "tampered"}))
    assert {:ok, _} = Briefings.handle(row(c), key(c), "revert", ctx.owner)
    assert Repo.get!(Event, c.hold_id).cancelled_at
  end

  test "revocation cancels unresolved holds and resolves Inbox before a stale approve", ctx do
    grant(ctx)
    {:ok, first} = propose(ctx, "first")
    {:ok, second} = propose(ctx, "second")
    assert {:ok, _} = AgentAccess.revoke(ctx.owner, ctx.agent.id)

    for c <- [first, second] do
      assert Repo.get!(Consent, c.id).state == "revoked"
      assert Repo.get!(Event, c.hold_id).sequence == 1
      assert Repo.get!(Event, c.hold_id).cancelled_at
      assert row(c).receipts[key(c)]["verb"] == "revoked"
      assert {:error, :already_resolved} = Briefings.handle(row(c), key(c), "approve", ctx.owner)
    end

    assert {:error, :forbidden} = propose(ctx, "after")
    grant(ctx)

    assert {:error, :already_resolved} =
             Briefings.handle(row(first), key(first), "approve", ctx.owner)
  end

  test "preapproval is owner policy and client attributes cannot override it", ctx do
    grant(ctx)

    {:ok, c} =
      AgentAccess.propose(
        ctx.scope,
        ctx.owner.actor.id,
        "create",
        Map.merge(attrs(), %{preapprove: true, owner_id: Ecto.UUID.generate(), tentative: false}),
        "override"
      )

    assert c.state == "pending"
    grant(ctx, %{preapprove: true})
    {:ok, approved} = propose(ctx, "policy")
    assert approved.state == "approved"
    assert row(approved).receipts[key(approved)]["auto"]
    assert Repo.get!(Event, approved.event_id).owner_id == ctx.owner.actor.id
  end

  test "move retains prior state until approval and revert restores it", ctx do
    grant(ctx)
    {:ok, event} = Calendar.create_event(ctx.owner, attrs())

    move = %{
      starts_at: ~U[2026-11-06 10:00:00.000000Z],
      ends_at: ~U[2026-11-06 11:00:00.000000Z],
      title: "tampered"
    }

    {:ok, c} = AgentAccess.propose(ctx.scope, ctx.owner.actor.id, "move", move, "move", event.id)
    assert Repo.get!(Event, event.id).starts_at == event.starts_at
    assert {:ok, _} = Briefings.handle(row(c), key(c), "approve", ctx.owner)
    assert Repo.get!(Event, event.id).starts_at == move.starts_at
    assert Repo.get!(Event, event.id).title == event.title
    assert Repo.get!(Event, c.hold_id).cancelled_at
    assert {:ok, _} = Briefings.handle(row(c), key(c), "revert", ctx.owner)
    assert Repo.get!(Event, event.id).starts_at == event.starts_at
  end

  test "stale approve and revert roll back without overwriting owner edits", ctx do
    grant(ctx)
    {:ok, event} = Calendar.create_event(ctx.owner, attrs())

    {:ok, c} =
      AgentAccess.propose(
        ctx.scope,
        ctx.owner.actor.id,
        "move",
        %{starts_at: ~U[2026-11-06 10:00:00Z], ends_at: ~U[2026-11-06 11:00:00Z]},
        "stale",
        event.id
      )

    {:ok, _} = Calendar.update_event(ctx.owner, event.id, %{title: "Owner edit"})
    assert {:error, :stale} = Briefings.handle(row(c), key(c), "approve", ctx.owner)
    assert Repo.get!(Consent, c.id).state == "pending"
    assert row(c).receipts == %{}
    {:ok, create} = propose(ctx)
    {:ok, _} = Briefings.handle(row(create), key(create), "approve", ctx.owner)
    {:ok, _} = Calendar.update_event(ctx.owner, create.hold_id, %{title: "Keep me"})
    assert {:error, :stale} = Briefings.handle(row(create), key(create), "revert", ctx.owner)
    assert Repo.get!(Event, create.hold_id).title == "Keep me"
  end

  test "tentative reservation participates in public availability", ctx do
    grant(ctx)
    {:ok, c} = propose(ctx)

    assert {:ok, [%{starts_at: start}]} =
             Calendar.Subscriptions.availability(
               ctx.owner,
               ~U[2026-11-05 09:00:00Z],
               ~U[2026-11-05 12:00:00Z]
             )

    assert start == attrs().starts_at
    assert {:ok, _} = AgentAccess.revoke(ctx.owner, ctx.agent.id)

    assert {:ok, []} =
             Calendar.Subscriptions.availability(
               ctx.owner,
               ~U[2026-11-05 09:00:00Z],
               ~U[2026-11-05 12:00:00Z]
             )

    assert Repo.get!(Consent, c.id).state == "revoked"
  end

  test "invalid intent rolls back every durable reservation and Inbox write", ctx do
    grant(ctx)

    assert {:error, %Ecto.Changeset{}} =
             AgentAccess.propose(
               ctx.scope,
               ctx.owner.actor.id,
               "create",
               attrs(%{ends_at: ~U[2026-11-05 09:00:00Z]}),
               "invalid"
             )

    assert Repo.aggregate(Consent, :count) == 0
    assert Repo.aggregate(Event, :count) == 0
    assert Repo.get_by(Briefing, user_id: ctx.owner.actor.id) == nil
  end

  test "public-booked events cannot be moved behind their reservation buffers", ctx do
    grant(ctx)
    day = Date.add(Date.utc_today(), 7)

    {:ok, link} =
      Calendar.BookingLinks.create(ctx.owner, %{
        title: "Public",
        start_date: day,
        end_date: day,
        time_zone: "Etc/UTC",
        duration_minutes: 30,
        windows: [%{"weekday" => Date.day_of_week(day), "start" => "10:00", "end" => "11:00"}]
      })

    {:ok, [slot | _]} = Calendar.BookingLinks.slots(link.token, day)

    {:ok, booking} =
      Calendar.BookingLinks.book(
        link.token,
        %{"name" => "Guest", "starts_at" => DateTime.to_iso8601(slot.starts_at)},
        "agent-booked-reservation"
      )

    assert {:error, :unsupported_move} =
             AgentAccess.propose(
               ctx.scope,
               ctx.owner.actor.id,
               "move",
               %{
                 starts_at: DateTime.add(slot.starts_at, 3600),
                 ends_at: DateTime.add(slot.starts_at, 5400)
               },
               "move-booked",
               booking.event_id
             )

    assert Repo.get!(Event, booking.event_id).starts_at == slot.starts_at
    assert Repo.aggregate(Consent, :count) == 0
  end

  test "shared busy-only events do not expose private details through a read grant", ctx do
    grant(ctx, %{read_private: false})

    project =
      Repo.insert!(%Platform.Tasks.Project{
        name: "Calendar privacy",
        slug: "calendar-privacy-#{System.unique_integer([:positive])}",
        org_id: Platform.Tenancy.get_org_by_slug!("globex").id
      })

    {:ok, _} =
      Calendar.create_event(
        ctx.owner,
        attrs(%{project_id: project.id, visibility: "busy", description: "Private notes"})
      )

    assert {:ok, [%{title: "Busy", description: nil}]} =
             AgentAccess.read(
               ctx.scope,
               ctx.owner.actor.id,
               ~U[2026-11-01 00:00:00Z],
               ~U[2026-11-10 00:00:00Z]
             )
  end

  test "federation rejects malformed input and uses runtime identity over client agent ids",
       ctx do
    grant(ctx)

    assert {:error, %{}} =
             Platform.Federation.ToolSurface.execute(
               "calendar_list",
               %{"owner_id" => ctx.owner.actor.id, "from" => [], "to" => "2026-11-10T00:00:00Z"},
               %{runtime_id: ctx.runtime.runtime_id, agent_id: Ecto.UUID.generate()}
             )

    assert {:ok, %{events: [], total: 0, has_more: false}} =
             Platform.Federation.ToolSurface.execute(
               "calendar_list",
               %{
                 "owner_id" => ctx.owner.actor.id,
                 "from" => "2026-11-01T00:00:00Z",
                 "to" => "2026-11-10T00:00:00Z"
               },
               %{runtime_id: ctx.runtime.runtime_id, agent_id: Ecto.UUID.generate()}
             )

    assert {:error, %{}} =
             Platform.Federation.ToolSurface.execute(
               "calendar_propose",
               %{
                 "owner_id" => ctx.owner.actor.id,
                 "operation" => "create",
                 "attributes" => [],
                 "request_key" => "malformed"
               },
               %{runtime_id: ctx.runtime.runtime_id}
             )
  end

  test "each Calendar owner may explicitly delegate the same active agent, independently of runtime ownership",
       ctx do
    grant(ctx)
    other = Platform.ExternalUserFixtures.create_user!()

    Platform.ExternalUserFixtures.plain_member!(
      other,
      Platform.Tenancy.get_org_by_slug!("globex")
    )

    other_scope = Scope.for_user(other)

    assert {:error, :forbidden} =
             AgentAccess.propose(ctx.scope, other.id, "create", attrs(), "second-owner")

    assert {:ok, _} =
             AgentAccess.grant(other_scope, ctx.agent.id, %{
               read: true,
               read_private: true,
               create: true
             })

    assert {:ok, intent} =
             AgentAccess.propose(ctx.scope, other.id, "create", attrs(), "second-owner")

    assert Repo.get!(Event, intent.hold_id).owner_id == other.id
    assert intent.agent_id == ctx.agent.id
    assert {:ok, _} = AgentAccess.revoke(other_scope, ctx.agent.id)

    assert {:error, :forbidden} =
             AgentAccess.propose(ctx.scope, other.id, "create", attrs(), "second-after-revoke")

    assert {:ok, _} = propose(ctx, "first-still-granted")
  end
end
