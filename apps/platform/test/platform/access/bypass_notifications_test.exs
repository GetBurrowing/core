defmodule Platform.Access.BypassNotificationsTest do
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Access.{Grants, Scope}
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.AttentionRouter
  alias Platform.Inbox
  alias Platform.Inbox.Item
  alias Platform.Meetings
  alias Platform.Meetings.MeetingNotifier
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy.OrgMembership

  defmodule Recorder do
    def fan_out_to_user(user_id, payload, _opts \\ []) do
      send(:persistent_term.get({__MODULE__, :owner}), {:push, user_id, payload})
      :ok
    end

    def fan_out_to_humans(participant_ids, payload, opts \\ []) do
      send(
        :persistent_term.get({__MODULE__, :owner}),
        {:push_humans, participant_ids, payload, opts}
      )

      :ok
    end
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    Application.put_env(:platform, :notifications_module, Recorder)
    :persistent_term.put({Recorder, :owner}, self())

    on_exit(fn ->
      Application.delete_env(:platform, :notifications_module)
      :persistent_term.erase({Recorder, :owner})
    end)

    org_id = tenant_org_id("bpn-#{System.unique_integer([:positive])}")
    {:ok, project} = Tasks.create_project(%{name: "bpn project", org_id: org_id})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "bpn task"})
    user = user!(org_id)

    %{project: project, task: task, user: user}
  end

  test "emit refuses task rows before insert, broadcast and push; a preexisting row leaves list and badge",
       ctx do
    user = ctx.user
    :ok = Inbox.subscribe(user.id)

    attrs = %{
      user_id: user.id,
      kind: "task_plan_review",
      source_type: "task",
      source_id: ctx.task.id,
      title: "ZQX-BYPASS-NOTIF",
      body: "ZQX-BYPASS-NOTIF",
      url: "/tasks/#{ctx.task.id}"
    }

    # Positive control: all three emit transports are observed before denial.
    assert {:ok, %Item{} = earlier} = Inbox.emit(attrs)
    assert_receive {:inbox_item_added, %Item{id: id}}
    assert id == earlier.id
    assert_receive {:push, user_id, %{kind: "task_plan_review", body: "bpn task"}}
    assert user_id == user.id
    assert Inbox.reachable_unread_count(user.id) == 1

    {:ok, _deny} =
      Grants.deny(%{
        principal: {:user, user.id},
        permission: "tasks.read",
        resource: {:project, ctx.project.id}
      })

    assert {:error, :denied} = Inbox.emit(attrs)
    refute_receive {:inbox_item_added, _}, 100
    refute_receive {:push, _, _}, 100
    assert Repo.aggregate(from(i in Item, where: i.user_id == ^user.id), :count) == 1

    scope = Scope.for_user(user)

    refute earlier.id in Repo.all(
             select(Inbox.reachable_unread_scope(user.id, false, scope), [i], i.id)
           )

    assert Repo.aggregate(Inbox.reachable_badge_scope(user.id, false, scope), :count) == 0
    assert Inbox.reachable_unread_count(user.id) == 0

    {:ok, view, html} = live(init_test_session(ctx.conn, current_user_id: user.id), "/inbox")
    refute html =~ "ZQX-BYPASS-NOTIF"
    refute render(view) =~ "ZQX-BYPASS-NOTIF"
  end

  test "a mentioned participant gets a push before a chat deny and none after", ctx do
    user = ctx.user
    {:ok, space} = ExecutionSpace.find_or_create(ctx.task.id)
    author = user!(ctx.project.org_id)

    {:ok, author_row} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: author.id,
        joined_at: DateTime.utc_now()
      })

    {:ok, recipient} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })

    :ok = Inbox.subscribe(user.id)

    before = post!(space.id, author_row.id, "@[#{user.name}] ZQX-BYPASS-NOTIF")
    assert_receive {:inbox_item_added, %Item{source_id: before_id}}
    assert before_id == before.id
    assert {:ok, _} = AttentionRouter.route(before)
    assert_receive {:push, user_id, payload}
    assert user_id == user.id
    assert payload.body =~ "ZQX-BYPASS-NOTIF"

    {:ok, _deny} =
      Grants.deny(%{
        principal: {:user, user.id},
        permission: "chat.read",
        resource: {:project, ctx.project.id}
      })

    after_deny = post!(space.id, author_row.id, "@[#{user.name}] ZQX-BYPASS-NOTIF")
    refute_receive {:inbox_item_added, _}, 100
    assert {:ok, _} = AttentionRouter.route(after_deny)
    refute_receive {:push, ^user_id, _}, 100
    assert recipient.participant_id == user.id
  end

  test "the canonical external world keeps its zero-grant inbox rows" do
    world = Platform.ExternalUserFixtures.external_world()
    scope = Scope.for_user(world.ext)
    refute Scope.has_grants?(scope)

    {:ok, row} =
      Inbox.emit(%{
        user_id: world.ext.id,
        kind: "chat_mention",
        source_type: "chat_message",
        source_id: Ecto.UUID.generate(),
        title: "external zero-grant control",
        url: "/chat/#{world.a.slug}"
      })

    baseline = Repo.all(Inbox.reachable_unread_scope(world.ext.id, true))
    restricted = Repo.all(Inbox.reachable_unread_scope(world.ext.id, true, scope))
    assert Enum.map(restricted, & &1.id) == Enum.map(baseline, & &1.id)
    assert Enum.any?(restricted, &(&1.id == row.id))
  end

  test "sponsor assignment push and row stop after a task read deny", ctx do
    user = ctx.user

    assert {:ok, assigned} =
             Tasks.update_task(ctx.task, %{sponsor_user_id: user.id},
               actor: {:agent, Ecto.UUID.generate()}
             )

    assert_receive {:push, user_id, %{title: "You're now sponsoring: bpn task"}}
    assert user_id == user.id
    assert [%Item{kind: "task_sponsor_assigned"}] = Inbox.list_unread_for_user(user.id)

    {:ok, _deny} =
      Grants.deny(%{
        principal: {:user, user.id},
        permission: "tasks.read",
        resource: {:project, ctx.project.id}
      })

    {:ok, cleared} = Tasks.update_task(assigned, %{sponsor_user_id: nil})

    assert {:ok, _reassigned} =
             Tasks.update_task(cleared, %{sponsor_user_id: user.id},
               actor: {:agent, Ecto.UUID.generate()}
             )

    refute_receive {:push, ^user_id, _}, 100
    assert length(Inbox.list_unread_for_user(user.id)) == 1
  end

  test "review_request_pending uses the task_review source and cannot preview a denied task",
       ctx do
    attrs = %{
      user_id: ctx.user.id,
      kind: "review_request_pending",
      source_type: "task_review",
      source_id: ctx.task.id,
      title: "ZQX-BYPASS-NOTIF review",
      url: "/tasks/#{ctx.task.id}"
    }

    assert {:ok, %Item{}} = Inbox.emit(attrs)
    assert_receive {:push, user_id, %{kind: "review_request_pending"}}
    assert user_id == ctx.user.id

    {:ok, _deny} =
      Grants.deny(%{
        principal: {:user, ctx.user.id},
        permission: "tasks.read",
        resource: {:project, ctx.project.id}
      })

    assert {:error, :denied} = Inbox.emit(attrs)
    refute_receive {:push, ^user_id, _}, 100
    assert length(Inbox.list_unread_for_user(ctx.user.id)) == 1
  end

  test "meeting start omits a denied chat participant from inbox and push", ctx do
    {:ok, _notifier} = start_supervised({MeetingNotifier, []})
    :ok = Inbox.subscribe(ctx.user.id)
    host = user!(ctx.project.org_id)

    before = meeting_with_participants!(ctx.project.id, host, ctx.user)
    {:ok, _} = Meetings.start_meeting(before.meeting)
    assert_receive {:push_humans, ids, _, _}, 2_000
    assert before.recipient_id in ids
    assert_receive {:inbox_item_added, %Item{source_id: source_id}}, 2_000
    assert source_id == before.meeting.id

    {:ok, _deny} =
      Grants.deny(%{
        principal: {:user, ctx.user.id},
        permission: "chat.read",
        resource: {:project, ctx.project.id}
      })

    after_deny = meeting_with_participants!(ctx.project.id, host, ctx.user)
    {:ok, _} = Meetings.start_meeting(after_deny.meeting)
    assert_receive {:push_humans, denied_ids, _, _}, 2_000
    refute after_deny.recipient_id in denied_ids
    refute_receive {:inbox_item_added, _}, 100
  end

  defp meeting_with_participants!(project_id, host, recipient) do
    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project_id,
        name: "bpn meeting #{System.unique_integer([:positive])}"
      })

    {:ok, host_row} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: host.id,
        joined_at: DateTime.utc_now()
      })

    {:ok, recipient_row} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: recipient.id,
        joined_at: DateTime.utc_now()
      })

    meeting =
      meeting
      |> Ecto.Changeset.change(host_participant_id: host_row.id)
      |> Repo.update!()

    %{meeting: meeting, recipient_id: recipient_row.id}
  end

  defp user!(org_id) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{name: "BPN #{n}", email: "bpn-#{n}@example.com", oidc_sub: "bpn-#{n}"})

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: "member"})
    |> Repo.insert!()

    user
  end

  defp post!(space_id, participant_id, content) do
    {:ok, message} =
      Chat.post_message(
        %{
          space_id: space_id,
          participant_id: participant_id,
          content_type: "text",
          content: content
        },
        from_pid: self()
      )

    message
  end
end
