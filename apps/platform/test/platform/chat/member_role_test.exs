defmodule Platform.Chat.MemberRoleTest do
  @moduledoc """
  Task 01a19355-9f4d-7000-befc-284f2df2318d stage 1: `Chat.set_member_role/4`
  and `Chat.can_manage_roles?/2`, the gate behind channel admin promote and
  demote.

  Every case reads the participant row back from the DB, so a version that
  returned the right tuple after writing the wrong thing cannot pass.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  setup do
    %{
      org_id: Tenancy.get_org_by_slug!("initech").id,
      other_org_id: Tenancy.get_org_by_slug!("globex").id,
      acme_id: Tenancy.get_org_by_slug!("acme").id
    }
  end

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: "Role User #{n}",
      email: "role-#{n}@example.com",
      oidc_sub: "sub-role-#{n}"
    })
  end

  defp agent! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Agents.Agent{
      name: "Role Agent #{n}",
      slug: "role-agent-#{n}",
      status: "active"
    })
  end

  defp membership!(user, org_id, role, external \\ false) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: org_id,
      role: role,
      external: external
    })
    |> Repo.insert!()
  end

  defp space!(kind, org_id) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{name: "Roles #{n}", slug: "roles-#{n}", kind: kind, org_id: org_id})

    space
  end

  defp user_participant!(space_id, user, role) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        role: role,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp agent_participant!(space_id, agent, role) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "agent",
        participant_id: agent.id,
        display_name: agent.name,
        role: role,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp role_of(%Participant{id: id}), do: Repo.get!(Participant, id).role

  defp rows_for(space_id, user_id) do
    Repo.aggregate(
      from(p in Participant, where: p.space_id == ^space_id and p.participant_id == ^user_id),
      :count
    )
  end

  # A channel in `org_id` with one human admin and one plain member.
  defp seeded(org_id) do
    space = space!("channel", org_id)
    admin = user!()
    member = user!()
    admin_p = user_participant!(space.id, admin, "admin")
    member_p = user_participant!(space.id, member, "member")
    %{space: space, admin: admin, member: member, admin_p: admin_p, member_p: member_p}
  end

  describe "authorization" do
    test "a plain member cannot promote another member", %{org_id: org_id} do
      s = seeded(org_id)
      other = user_participant!(s.space.id, user!(), "member")

      assert {:error, :unauthorized} =
               Chat.set_member_role(s.space, s.member.id, other.id, "admin")

      assert role_of(other) == "member"
    end

    test "a channel admin promotes a member, then demotes them", %{org_id: org_id} do
      s = seeded(org_id)

      assert {:ok, %Participant{role: "admin"}} =
               Chat.set_member_role(s.space, s.admin.id, s.member_p.id, "admin")

      assert role_of(s.member_p) == "admin"

      assert {:ok, %Participant{role: "member"}} =
               Chat.set_member_role(s.space, s.admin.id, s.member_p.id, "member")

      assert role_of(s.member_p) == "member"
      assert role_of(s.admin_p) == "admin"
    end

    test "an org admin with no participant row can promote, and gets no row", ctx do
      s = seeded(ctx.org_id)
      org_admin = user!()
      membership!(org_admin, ctx.org_id, "admin")
      assert rows_for(s.space.id, org_admin.id) == 0

      assert {:ok, _} = Chat.set_member_role(s.space, org_admin.id, s.member_p.id, "admin")

      assert role_of(s.member_p) == "admin"
      assert rows_for(s.space.id, org_admin.id) == 0
    end

    test "a root admin with no row in this org can promote", ctx do
      s = seeded(ctx.org_id)
      root = user!()
      membership!(root, ctx.acme_id, "admin")
      assert Tenancy.root_admin?(root)
      refute Tenancy.org_admin?(root, ctx.org_id)

      assert {:ok, _} = Chat.set_member_role(s.space, root.id, s.member_p.id, "admin")
      assert role_of(s.member_p) == "admin"
      assert rows_for(s.space.id, root.id) == 0
    end

    test "an org admin of a DIFFERENT org cannot promote", ctx do
      s = seeded(ctx.org_id)
      foreign = user!()
      membership!(foreign, ctx.other_org_id, "admin")
      assert Tenancy.org_admin?(foreign, ctx.other_org_id)

      assert {:error, :unauthorized} =
               Chat.set_member_role(s.space, foreign.id, s.member_p.id, "admin")

      assert role_of(s.member_p) == "member"
    end

    test "an EXTERNAL admin of the same org cannot promote", ctx do
      s = seeded(ctx.org_id)
      ext = user!()
      membership!(ext, ctx.org_id, "admin", true)

      assert {:error, :unauthorized} =
               Chat.set_member_role(s.space, ext.id, s.member_p.id, "admin")

      assert role_of(s.member_p) == "member"
    end
  end

  describe "agents" do
    test "an agent row as target is refused :not_a_user and left unchanged", %{org_id: org_id} do
      s = seeded(org_id)
      agent_p = agent_participant!(s.space.id, agent!(), "member")

      assert {:error, :not_a_user} =
               Chat.set_member_role(s.space, s.admin.id, agent_p.id, "admin")

      assert role_of(agent_p) == "member"
    end

    test "an agent holding role admin does not count toward the floor", %{org_id: org_id} do
      s = seeded(org_id)
      agent_p = agent_participant!(s.space.id, agent!(), "admin")

      assert {:error, :last_admin} =
               Chat.set_member_role(s.space, s.admin.id, s.admin_p.id, "member")

      assert role_of(s.admin_p) == "admin"
      assert role_of(agent_p) == "admin"
    end
  end

  describe "last human admin floor" do
    test "the sole human admin cannot demote themselves", %{org_id: org_id} do
      s = seeded(org_id)

      assert {:error, :last_admin} =
               Chat.set_member_role(s.space, s.admin.id, s.admin_p.id, "member")

      assert role_of(s.admin_p) == "admin"
    end

    test "with a second human admin, self-demotion succeeds", %{org_id: org_id} do
      s = seeded(org_id)
      second = user_participant!(s.space.id, user!(), "admin")

      assert {:ok, %Participant{role: "member"}} =
               Chat.set_member_role(s.space, s.admin.id, s.admin_p.id, "member")

      assert role_of(s.admin_p) == "member"
      assert role_of(second) == "admin"
    end

    test "an org admin cannot demote the sole channel admin either", ctx do
      s = seeded(ctx.org_id)
      org_admin = user!()
      membership!(org_admin, ctx.org_id, "admin")

      assert {:error, :last_admin} =
               Chat.set_member_role(s.space, org_admin.id, s.admin_p.id, "member")

      assert role_of(s.admin_p) == "admin"
    end
  end

  describe "input refusals" do
    test "a DM is refused :not_a_channel", %{org_id: org_id} do
      dm = space!("dm", org_id)
      a = user!()
      b = user!()
      a_p = user_participant!(dm.id, a, "admin")
      b_p = user_participant!(dm.id, b, "member")

      assert {:error, :not_a_channel} = Chat.set_member_role(dm, a.id, b_p.id, "admin")
      assert role_of(b_p) == "member"
      assert role_of(a_p) == "admin"
    end

    test "groups and execution spaces are refused :not_a_channel", %{org_id: org_id} do
      for kind <- ["group", "execution"] do
        space = space!(kind, org_id)
        a = user!()
        b = user!()
        user_participant!(space.id, a, "admin")
        b_p = user_participant!(space.id, b, "member")

        assert {:error, :not_a_channel} = Chat.set_member_role(space, a.id, b_p.id, "admin")
        assert role_of(b_p) == "member"
      end
    end

    test "a malformed or other-space participant id is :not_found", %{org_id: org_id} do
      s = seeded(org_id)
      other = seeded(org_id)

      assert {:error, :not_found} = Chat.set_member_role(s.space, s.admin.id, "nope", "admin")

      assert {:error, :not_found} =
               Chat.set_member_role(s.space, s.admin.id, other.member_p.id, "admin")

      # A space id is never taken as a participant id.
      assert {:error, :not_found} =
               Chat.set_member_role(s.space, s.admin.id, s.space.id, "admin")

      assert role_of(other.member_p) == "member"
      assert role_of(s.member_p) == "member"
    end

    test "an unknown role is :invalid_role before any DB work", %{org_id: org_id} do
      s = seeded(org_id)

      for role <- ["owner", "observer", "principal", nil, :admin] do
        assert {:error, :invalid_role} =
                 Chat.set_member_role(s.space, s.admin.id, s.member_p.id, role)
      end

      assert role_of(s.member_p) == "member"
    end

    test "requesting the current role is an idempotent no-op", %{org_id: org_id} do
      s = seeded(org_id)
      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, ChatPubSub.space_topic(s.space.id))

      assert {:ok, %Participant{role: "member"}} =
               Chat.set_member_role(s.space, s.admin.id, s.member_p.id, "member")

      assert role_of(s.member_p) == "member"
      refute_receive {:participant_role_changed, _}, 100
    end
  end

  describe "broadcast" do
    test "a change broadcasts after commit; a refusal broadcasts nothing", %{org_id: org_id} do
      s = seeded(org_id)
      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, ChatPubSub.space_topic(s.space.id))

      assert {:error, :unauthorized} =
               Chat.set_member_role(s.space, s.member.id, s.member_p.id, "admin")

      refute_receive {:participant_role_changed, _}, 100

      assert {:error, :last_admin} =
               Chat.set_member_role(s.space, s.admin.id, s.admin_p.id, "member")

      refute_receive {:participant_role_changed, _}, 100

      member_p_id = s.member_p.id
      assert {:ok, _} = Chat.set_member_role(s.space, s.admin.id, member_p_id, "admin")

      assert_receive {:participant_role_changed, %Participant{id: ^member_p_id, role: "admin"}}
      assert role_of(s.member_p) == "admin"
    end

    test "a change emits participant_role_changed telemetry", %{org_id: org_id} do
      s = seeded(org_id)
      ref = make_ref()
      parent = self()
      handler = "member-role-test-#{inspect(ref)}"

      :ok =
        :telemetry.attach(
          handler,
          [:platform, :chat, :participant_role_changed],
          fn _event, _measurements, meta, _ -> send(parent, {ref, meta}) end,
          nil
        )

      try do
        assert {:ok, _} = Chat.set_member_role(s.space, s.admin.id, s.member_p.id, "admin")
        assert_receive {^ref, meta}

        assert meta == %{
                 space_id: s.space.id,
                 participant_id: s.member_p.id,
                 actor_user_id: s.admin.id,
                 role: "admin"
               }
      after
        :telemetry.detach(handler)
      end
    end
  end

  describe "can_manage_roles?/2" do
    test "truth table", ctx do
      s = seeded(ctx.org_id)

      org_admin = user!()
      membership!(org_admin, ctx.org_id, "admin")
      root = user!()
      membership!(root, ctx.acme_id, "admin")
      foreign = user!()
      membership!(foreign, ctx.other_org_id, "admin")
      ext = user!()
      membership!(ext, ctx.org_id, "admin", true)
      org_member = user!()
      membership!(org_member, ctx.org_id, "member")

      assert Chat.can_manage_roles?(s.space, s.admin.id)
      assert Chat.can_manage_roles?(s.space, org_admin.id)
      assert Chat.can_manage_roles?(s.space, root.id)
      refute Chat.can_manage_roles?(s.space, s.member.id)
      refute Chat.can_manage_roles?(s.space, foreign.id)
      refute Chat.can_manage_roles?(s.space, ext.id)
      refute Chat.can_manage_roles?(s.space, org_member.id)
      refute Chat.can_manage_roles?(s.space, nil)
      refute Chat.can_manage_roles?(s.space, 123)

      # Not a channel: false even for the space's own admin.
      dm = space!("dm", ctx.org_id)
      user_participant!(dm.id, s.admin, "admin")
      refute Chat.can_manage_roles?(dm, s.admin.id)
      refute Chat.can_manage_roles?(dm, root.id)

      # A channel with no org: the org ground is false, the others still hold.
      orgless = space!("channel", nil)
      user_participant!(orgless.id, s.admin, "admin")
      assert Chat.can_manage_roles?(orgless, s.admin.id)
      refute Chat.can_manage_roles?(orgless, org_admin.id)
      assert Chat.can_manage_roles?(orgless, root.id)
    end
  end
end
