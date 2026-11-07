defmodule Platform.Secretary.InputsTest do
  @moduledoc """
  `Platform.Secretary.Inputs.gather/3` restates `Platform.Access` as a test
  (task 01a1b721 stage 1). The world: A, B and C are members of one sub-org.
  Each absence below is paired with a positive control on the same fixture:
  the row exists and a reader who may see it does.
  """
  use Platform.DataCase, async: false

  import Platform.ExternalUserFixtures
  import Platform.TenancyFixtures

  alias Platform.Access.{Grants, Restrictions}
  alias Platform.Accounts
  alias Platform.Chat.{Message, Space}
  alias Platform.Inbox.Item
  alias Platform.Meetings.{Meeting, MeetingBriefing}
  alias Platform.Repo
  alias Platform.Secretary.Inputs
  alias Platform.Tasks
  alias Platform.Tasks.Task
  alias Platform.Tenancy

  @since ~U[2000-01-01 00:00:00Z]

  defp space!(kind, org_id) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Space{
      kind: kind,
      name: "#{kind} #{n}",
      slug: "sec-#{kind}-#{n}",
      org_id: org_id
    })
  end

  defp say!(space, user, text) do
    p = add_user!(space.id, user.id)

    Repo.insert!(%Message{
      space_id: space.id,
      participant_id: p.id,
      content_type: "text",
      content: text,
      author_user_id: user.id,
      author_display_name: user.name,
      author_participant_type: "user"
    })
  end

  defp say_as_existing!(space, participant, user, text) do
    Repo.insert!(%Message{
      space_id: space.id,
      participant_id: participant.id,
      content_type: "text",
      content: text,
      author_user_id: user.id,
      author_display_name: user.name,
      author_participant_type: "user"
    })
  end

  defp reload(user), do: Accounts.get_user(user.id)

  defp texts(user), do: user |> reload() |> Inputs.gather(@since) |> Enum.map(& &1.text)

  defp meeting!(project, chat_space, attendee, text) do
    meeting =
      Repo.insert!(%Meeting{
        project_id: project.id,
        chat_space_id: chat_space.id,
        slug: "sec-meet-#{System.unique_integer([:positive])}",
        livekit_room_name: Ecto.UUID.generate(),
        name: "Meeting",
        status: "ended"
      })

    Repo.insert!(%MeetingBriefing{
      meeting_id: meeting.id,
      attendee_user_ids: [attendee.id],
      items: %{
        "_content" => %{
          "unfiled_action_items" => [%{"id" => Ecto.UUID.generate(), "text" => text}]
        }
      }
    })
  end

  setup do
    s1 = Tenancy.get_org!(tenant_org_id("secretary_s1"))
    s2 = Tenancy.get_org!(tenant_org_id("secretary_s2"))
    [a, b, c, admin, d] = for _ <- 1..5, do: create_user!()
    for u <- [a, b, c, d], do: plain_member!(u, s1)
    plain_member!(admin, s1, "admin")
    s2_member = create_user!()
    plain_member!(s2_member, s2)

    # B writes in the DM and the group: a person's own messages are not
    # inputs, so A's view of them is the positive control.
    dm = space!("dm", s1.id)
    add_user!(dm.id, a.id)
    say!(dm, b, "dm-secret-xyz")

    group = space!("group", s1.id)
    say!(group, b, "grp-secret-xyz")
    add_user!(group.id, a.id)

    open = channel!(%{org_id: s1.id})
    say!(open, a, "open-text")

    restricted = channel!(%{org_id: s1.id})
    say!(restricted, a, "restricted-xyz")
    {:ok, _} = Restrictions.restrict_space(restricted, ["admin"], admin.id)

    exec = space!("execution", s1.id)
    say!(exec, a, "exec-xyz")

    suborg = channel!(%{org_id: s2.id})
    say!(suborg, s2_member, "suborg-xyz")

    denied = channel!(%{org_id: s1.id})
    say!(denied, a, "denied-xyz")

    {:ok, _} =
      Grants.grant(%{
        principal: {:user, c.id},
        permission: "chat.read",
        resource: {:space, denied.id},
        effect: "deny"
      })

    allowed = space!("dm", s1.id)
    say!(allowed, a, "allowed-xyz")
    add_user!(allowed.id, d.id)

    {:ok, _} =
      Grants.grant(%{
        principal: {:user, c.id},
        permission: "chat.read",
        resource: {:space, allowed.id},
        effect: "allow"
      })

    %{s1: s1, a: a, b: b, c: c, dm: dm, open: open, exec: exec}
  end

  describe "readability (chat.read for the viewer, channel|dm|group only)" do
    test "C reads the open channel (not a member) and the allowed DM, and nothing else", ctx do
      inputs = ctx.c |> reload() |> Inputs.gather(@since)
      texts = Enum.map(inputs, & &1.text)

      assert "open-text" in texts
      assert "allowed-xyz" in texts

      assert %{member?: false, space_kind: "channel"} =
               Enum.find(inputs, &(&1.text == "open-text"))

      for secret <-
            ~w(dm-secret-xyz grp-secret-xyz restricted-xyz exec-xyz suborg-xyz denied-xyz) do
        refute secret in texts, "#{secret} reached C"
      end
    end

    test "A reads its own DM and group (positive control), as a member", ctx do
      inputs = ctx.a |> reload() |> Inputs.gather(@since, sources: [:chat])
      texts = Enum.map(inputs, & &1.text)

      assert "dm-secret-xyz" in texts
      assert "grp-secret-xyz" in texts
      assert %{member?: true, space_kind: "dm"} = Enum.find(inputs, &(&1.text == "dm-secret-xyz"))
      # A's own messages are not A's inputs.
      refute "open-text" in texts
    end

    test "Access does admit the execution space; only the kind filter keeps it out", ctx do
      scope = Platform.Access.Scope.for_user(reload(ctx.c))

      readable =
        Space
        |> Platform.Access.Query.where_readable(scope, "chat.read", :space, %{id: :id})
        |> select([s], s.id)
        |> Repo.all()

      assert ctx.exec.id in readable
      refute "exec-xyz" in texts(ctx.c)
    end

    test "an external user gets nothing", ctx do
      ext = external_user!(ctx.s1)
      add_user!(ctx.open.id, ext.id)
      assert Inputs.gather(reload(ext), @since) == []
    end

    test "per-space and per-batch caps", ctx do
      [p] = Repo.all(from(p in Platform.Chat.Participant, where: p.space_id == ^ctx.open.id))
      for i <- 1..5, do: say_as_existing!(ctx.open, p, ctx.a, "extra-#{i}")

      capped = Inputs.gather(reload(ctx.c), @since, sources: [:chat], per_space: 2)
      assert Enum.count(capped, &(&1.space_id == ctx.open.id)) == 2

      assert length(Inputs.gather(reload(ctx.c), @since, sources: [:chat], max_batch_items: 1)) ==
               1
    end
  end

  describe "meeting action items" do
    test "an item from a meeting whose chat space C cannot read is absent; a readable one is present",
         ctx do
      {:ok, project} =
        Tasks.create_project(%{
          name: "sec-#{System.unique_integer([:positive])}",
          org_id: ctx.s1.id
        })

      meeting!(project, ctx.dm, ctx.c, "meet-secret-xyz")
      meeting!(project, ctx.open, ctx.c, "meet-open-xyz")

      texts =
        ctx.c |> reload() |> Inputs.gather(@since, sources: [:meetings]) |> Enum.map(& &1.text)

      assert "meet-open-xyz" in texts
      refute "meet-secret-xyz" in texts
    end
  end

  describe "inbox rows" do
    test "come only through reachable_unread_scope: a row on a task C cannot read is absent",
         ctx do
      {:ok, project} =
        Tasks.create_project(%{
          name: "sec-#{System.unique_integer([:positive])}",
          org_id: ctx.s1.id
        })

      hidden = Repo.insert!(%Task{project_id: project.id, title: "hidden", status: "backlog"})
      shown = Repo.insert!(%Task{project_id: project.id, title: "shown", status: "backlog"})

      for {task, body} <- [{hidden, "inbox-hidden-xyz"}, {shown, "inbox-shown-xyz"}] do
        Repo.insert!(%Item{
          user_id: ctx.c.id,
          kind: "task_plan_review",
          source_type: "task",
          source_id: task.id,
          title: task.title,
          body: body,
          url: "/tasks/" <> task.id
        })
      end

      {:ok, _} =
        Grants.grant(%{
          principal: {:user, ctx.c.id},
          permission: "tasks.read",
          resource: {:task, hidden.id},
          effect: "deny"
        })

      texts = ctx.c |> reload() |> Inputs.gather(@since, sources: [:inbox]) |> Enum.map(& &1.text)
      assert "inbox-shown-xyz" in texts
      refute "inbox-hidden-xyz" in texts
    end
  end

  test "mail is declared and reads nothing" do
    assert :mail in Inputs.sources()
  end
end
