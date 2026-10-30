defmodule Platform.Access.OrgDenyTest do
  @moduledoc """
  Task 01a18d38 stage 2: ORG-level deny grants, inherited at check time by
  spaces, meetings and canvases created AFTER the deny, and the project deny
  that covers a meeting created later (`Platform.Access.Lineage`).

  Fixture stand-ins: the root org (acme) plays the operator's org, a tenant
  org "nettlefold" plays the client under the hold. `denied` and `allowed` are
  plain members of both orgs; `denied` holds the org-level denies, `allowed`
  none, and an agent owned by `allowed` is the agent positive control. Every
  absence below is paired with a presence on the same fixture and the same
  call.
  """

  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.TenancyFixtures

  alias Platform.Access
  alias Platform.Access.{Grant, Grants, Scope}
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat
  alias Platform.Chat.{CanvasAccess, ExternalScope, Space}
  alias Platform.Meetings
  alias Platform.Meetings.{Archive, Meeting}
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy.OrgMembership

  @migration "priv/repo/migrations/20261030164512_access_grants_org_resource_type.exs"

  setup do
    root = acme_org_id()
    client = tenant_org_id("nettlefold")

    denied = member!([root, client])
    allowed = member!([root, client])

    {:ok, client_project} =
      Tasks.create_project(%{name: "Client Project #{uniq()}", org_id: client})

    %{
      root: root,
      client: client,
      client_project: client_project,
      denied: denied,
      allowed: allowed
    }
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp uniq, do: System.unique_integer([:positive])

  defp member!(org_ids) do
    n = uniq()

    user =
      Repo.insert!(%User{
        email: "org-deny-#{n}@example.com",
        name: "Org Deny Fixture #{n}",
        oidc_sub: "oidc-org-deny-#{n}"
      })

    for org_id <- org_ids do
      %OrgMembership{}
      |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: "member"})
      |> Repo.insert!()
    end

    user
  end

  defp scope(user), do: Scope.for_user(Accounts.get_user(user.id))

  defp deny!(user, permission, resource) do
    {:ok, grant} = Grants.deny(%{principal: user, permission: permission, resource: resource})
    grant
  end

  defp channel!(org_id) do
    n = uniq()

    {:ok, space} =
      Chat.create_space(%{
        name: "Channel #{n}",
        slug: "org-deny-#{n}",
        kind: "channel",
        org_id: org_id
      })

    space
  end

  defp join!(space, type, id) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: type,
        participant_id: id,
        display_name: "Fixture",
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp agent_runtime!(owner, space) do
    n = uniq()

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "org-deny-agent-#{n}",
        name: "Org Deny Agent #{n}",
        status: "active"
      })
      |> Repo.insert()

    join!(space, "agent", agent.id)

    {:ok, rt} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "org-deny-rt-#{n}",
        owner_user_id: owner.id,
        agent_id: agent.id,
        auth_token_hash: AgentRuntime.hash_token(AgentRuntime.generate_token()),
        status: "active"
      })
      |> Repo.insert()

    {:ok, _profile} =
      Platform.Access.RuntimeProfiles.create_for_runtime(
        rt,
        AgentRuntime.default_tool_profile(),
        Platform.Access.RuntimeProfiles.translated_permissions(
          AgentRuntime.default_tool_profile()
        )
      )

    rt
  end

  defp ended_meeting!(project, name) do
    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})
    at = DateTime.add(DateTime.utc_now(), -1, :day)

    {:ok, live} = meeting |> Meeting.status_changeset("live", %{started_at: at}) |> Repo.update()

    {:ok, ended} =
      live
      |> Meeting.status_changeset("ended", %{ended_at: DateTime.add(at, 1800, :second)})
      |> Repo.update()

    ended
  end

  defp visible_spaces(user, ids) do
    from(s in Space, where: s.id in ^ids)
    |> ExternalScope.scope_spaces(scope(user))
    |> Repo.all()
    |> MapSet.new(& &1.id)
  end

  defp listed(user), do: MapSet.new(Meetings.list_meetings_for_user(user), & &1.id)

  defp archived(user) do
    result = Archive.search(user, [])
    MapSet.new(result.matches ++ result.others, & &1.id)
  end

  # ── an org deny covers a CHANNEL and its CANVAS created after it ───────────

  describe "an org deny on a channel created after it" do
    setup ctx do
      deny!(ctx.denied, "chat.read", {:org, ctx.client})
      deny!(ctx.denied, "canvas.read", {:org, ctx.client})

      # Only now: the channel, its canvas, and a root-org channel.
      channel = channel!(ctx.client)
      root_channel = channel!(ctx.root)

      for user <- [ctx.denied, ctx.allowed], space <- [channel, root_channel] do
        join!(space, "user", user.id)
      end

      author = join!(channel, "user", Ecto.UUID.generate())

      {:ok, canvas} =
        Chat.create_canvas(%{space_id: channel.id, created_by: author.id, title: "Later canvas"})

      Map.merge(ctx, %{channel: channel, root_channel: root_channel, canvas: canvas})
    end

    test "the space listing drops the later channel for the denied user only", ctx do
      ids = [ctx.channel.id, ctx.root_channel.id]

      assert visible_spaces(ctx.denied, ids) == MapSet.new([ctx.root_channel.id])
      assert visible_spaces(ctx.allowed, ids) == MapSet.new(ids)
    end

    test "can? refuses the later channel to the denied user; allowed and their agent read it",
         ctx do
      refute Access.can?(scope(ctx.denied), "chat.read", {:space, ctx.channel.id})
      assert Access.can?(scope(ctx.denied), "chat.read", {:space, ctx.root_channel.id})
      assert Access.can?(scope(ctx.allowed), "chat.read", {:space, ctx.channel.id})

      agent_scope = Scope.for_runtime(agent_runtime!(ctx.allowed, ctx.channel))
      assert Access.can?(agent_scope, "chat.read", {:space, ctx.channel.id})
    end

    test "a canvas in the later channel is refused like a missing one", ctx do
      denied = {:user, ctx.denied.id}

      assert CanvasAccess.fetch_for_viewer(ctx.canvas.id, denied, access_scope: scope(ctx.denied)) ==
               {:error, :not_found}

      assert {:ok, %{id: id}, _level} =
               CanvasAccess.fetch_for_viewer(ctx.canvas.id, {:user, ctx.allowed.id},
                 access_scope: scope(ctx.allowed)
               )

      assert id == ctx.canvas.id
    end
  end

  # ── an org deny covers a MEETING created after it ─────────────────────────

  describe "an org deny on a meeting created after it" do
    setup ctx do
      deny!(ctx.denied, "chat.read", {:org, ctx.client})

      {:ok, root_project} =
        Tasks.create_project(%{name: "Root Project #{uniq()}", org_id: ctx.root})

      Map.merge(ctx, %{
        meeting: ended_meeting!(ctx.client_project, "Later client meeting"),
        root_meeting: ended_meeting!(root_project, "Later root meeting")
      })
    end

    test "absent from the list, the archive, by slug and by id; allowed sees it", ctx do
      m = ctx.meeting

      refute m.id in listed(ctx.denied)
      refute m.id in archived(ctx.denied)
      assert Meetings.fetch_meeting_for_user(ctx.denied, m.slug) == {:error, :not_found}
      assert Meetings.get_meeting_for_user(ctx.denied, m.id) == {:error, :not_found}

      assert ctx.root_meeting.id in listed(ctx.denied)
      assert ctx.root_meeting.id in archived(ctx.denied)

      assert m.id in listed(ctx.allowed)
      assert m.id in archived(ctx.allowed)
      assert {:ok, _} = Meetings.fetch_meeting_for_user(ctx.allowed, m.slug)
      assert {:ok, _} = Meetings.get_meeting_for_user(ctx.allowed, m.id)
    end
  end

  # ── a PROJECT deny covers a meeting created after it ──────────────────────

  describe "a project deny on a meeting created after it" do
    test "the meeting's chat space inherits the project deny", ctx do
      {:ok, project} = Tasks.create_project(%{name: "Shared Project #{uniq()}", org_id: ctx.root})
      deny!(ctx.denied, "chat.read", {:project, project.id})

      meeting = ended_meeting!(project, "Later project meeting")

      refute meeting.id in listed(ctx.denied)
      refute meeting.id in archived(ctx.denied)
      assert Meetings.fetch_meeting_for_user(ctx.denied, meeting.slug) == {:error, :not_found}
      assert Meetings.get_meeting_for_user(ctx.denied, meeting.id) == {:error, :not_found}
      refute Access.can?(scope(ctx.denied), "chat.read", {:space, meeting.chat_space_id})

      assert meeting.id in listed(ctx.allowed)
      assert meeting.id in archived(ctx.allowed)
      assert {:ok, _} = Meetings.fetch_meeting_for_user(ctx.allowed, meeting.slug)
      assert {:ok, _} = Meetings.get_meeting_for_user(ctx.allowed, meeting.id)
    end
  end

  # ── the grant row and the migration ───────────────────────────────────────

  describe "the org grant row" do
    test "an org deny names its own org; a mismatched org_id is refused", ctx do
      grant = deny!(ctx.denied, "chat.read", {:org, ctx.client})
      assert grant.resource_type == "org"
      assert grant.resource_id == ctx.client
      assert grant.org_id == ctx.client
      assert Grant.target(grant) == {:org, ctx.client}

      assert {:error, %Ecto.Changeset{} = cs} =
               Grants.deny(%{
                 principal: ctx.allowed,
                 permission: "chat.read",
                 resource: {:org, ctx.client},
                 org_id: ctx.root
               })

      assert {"an org-level grant names its own org", _} = cs.errors[:resource_id]
    end

    test "an org ALLOW is refused, by the context and by the changeset", ctx do
      assert Grants.grant(%{
               principal: ctx.allowed,
               permission: "chat.read",
               resource: {:org, ctx.client}
             }) ==
               {:error, :org_allow_refused}

      cs =
        Grant.changeset(%Grant{}, %{
          org_id: ctx.client,
          principal_type: "user",
          principal_id: ctx.allowed.id,
          permission: "chat.read",
          resource_type: "org",
          resource_id: ctx.client,
          effect: "allow"
        })

      refute cs.valid?
      assert {"an org-level grant must be a deny", _} = cs.errors[:effect]
    end

    test "the migration's rollback refuses while an org row exists, and never deletes it",
         ctx do
      [{mod, _}] = Code.require_file(@migration, File.cwd!())

      assert mod.refuse_while_org_rows!(Repo) == :ok

      grant = deny!(ctx.denied, "chat.read", {:org, ctx.client})

      assert_raise RuntimeError, ~r/refusing to roll back: 1 org-level/, fn ->
        mod.refuse_while_org_rows!(Repo)
      end

      assert Repo.get(Grant, grant.id)

      {:ok, _} = Grants.revoke(grant)
      assert mod.refuse_while_org_rows!(Repo) == :ok
    end
  end
end
