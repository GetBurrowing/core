defmodule Platform.Sharing.SharingToolsTest do
  @moduledoc """
  Task 01a1b678 stage 3: the `sharing_list` and `sharing_set` agent tools.
  Both ride the `federation` bundle, are always listed, and refuse anyone
  whose runtime owner is not an admin of the root org. Since stage 4,
  `sharing_set` instead authorizes the PERSON who asked, as the server saw
  the dispatch (`Platform.Federation.DispatchOrigin`), and writes through
  `Platform.Sharing.set/4`, so an admin's change leaves an audit row naming
  that admin and the agent; a refused one changes and records nothing.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts.User
  alias Platform.Access.ToolPermissions
  alias Platform.Agents.{AgentRuntime, Burrow, NativeAgents}
  alias Platform.Audit.Event
  alias Platform.Federation.{AttentionDispatch, ToolArguments, ToolCall, ToolSurface}
  alias Platform.Repo
  alias Platform.Sharing
  alias Platform.Tenancy.OrgMembership

  setup do
    _ = Platform.TenancyFixtures.acme_org_id()
    :ok
  end

  defp user!(label) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "sharing-#{label}-#{n}@example.com",
      name: "Sharing #{label} #{n}",
      oidc_sub: "oidc-sharing-#{label}-#{n}"
    })
  end

  defp member!(user, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.Tenancy.get_root_org().id,
      role: role
    })
    |> Repo.insert!()
  end

  defp ctx(agent) do
    runtime = Repo.get!(AgentRuntime, agent.runtime_id)
    ToolCall.build_context(%{}, runtime)
  end

  # A chat dispatch from `user` to `agent`'s runtime, through the one
  # attention funnel, as the responder sends it (stage 4: the server-side
  # requester). Then the context the next tool call would get.
  defp asked_by(agent, users) do
    runtime = Repo.get!(AgentRuntime, agent.runtime_id)

    for user <- List.wrap(users) do
      :ok =
        AttentionDispatch.broadcast(
          runtime.runtime_id,
          %{message: %{author_type: "user", author_user_id: user.id, content: "please"}},
          space_id: nil,
          agent_id: agent,
          source: :agent_responder
        )
    end

    ToolCall.build_context(%{}, runtime)
  end

  defp audit_rows,
    do: Repo.all(from(e in Event, where: e.event_type == "platform.sharing.switch_set"))

  test "both tools are listed in the federation bundle, flag or no flag, and permissioned" do
    defs = Enum.filter(ToolSurface.tool_definitions(), &(&1.name in ~w(sharing_list sharing_set)))

    assert Enum.map(defs, &{&1.name, &1.bundle}) == [
             {"sharing_list", "federation"},
             {"sharing_set", "federation"}
           ]

    assert ToolPermissions.for_tool("sharing_list") == "agents.manage_own"
    assert ToolPermissions.for_tool("sharing_set") == "agents.manage_own"
  end

  describe "an install admin's agent" do
    setup do
      owner = user!("admin")
      member!(owner, "admin")
      {:ok, agent} = Burrow.ensure(owner.id, "claude_code")
      # No dispatch is recorded here: each test records exactly the people
      # who asked, so a member's request is never mixed with the owner's
      # (an ambiguous requester is refused on its own, which would let a
      # broken admin check pass the member test).
      %{agent: agent, owner: owner}
    end

    test "lists every registry entry with its state", %{agent: agent} do
      ctx = ctx(agent)
      {:ok, _} = Sharing.set(:friction_reports, true, :system)

      assert {:ok, %{entries: entries, never_sent: never}} =
               ToolArguments.dispatch("sharing_list", %{}, ctx)

      assert Enum.map(entries, & &1.key) == Enum.map(Sharing.keys(), &Atom.to_string/1)
      assert %{on: true} = Enum.find(entries, &(&1.key == "friction_reports"))
      assert %{on: false} = Enum.find(entries, &(&1.key == "help_channel_reports"))
      assert never == Sharing.never_sent()
    end

    test "an admin asks: sharing_set changes the switch and writes one audit row naming them",
         %{agent: agent, owner: owner} do
      ctx = asked_by(agent, owner)

      assert {:ok, %{key: "help_channel_reports", on: true, previous: false}} =
               ToolArguments.dispatch(
                 "sharing_set",
                 %{"key" => "help_channel_reports", "on" => true},
                 ctx
               )

      assert Sharing.enabled?(:help_channel_reports)

      assert [%Event{actor_type: "user", actor_id: actor_id, metadata: metadata}] = audit_rows()
      assert actor_id == owner.id
      assert metadata["via_agent_id"] == agent.id
      assert metadata["key"] == "help_channel_reports"
      assert metadata["value"] == true
    end

    # Stage 4 (from the stage 3 audit): the requester, not the agent owner,
    # is who is authorized.
    test "a member asks the admin-owned agent: refused, nothing changed or recorded",
         %{agent: agent} do
      member = user!("asker")
      member!(member, "member")
      ctx = asked_by(agent, member)
      # The server resolved the member as the one requester, so the refusal
      # below is about their role, not an ambiguous requester.
      assert ctx.requester_user_id == member.id

      assert {:error, %{code: :forbidden}} =
               ToolArguments.dispatch(
                 "sharing_set",
                 %{"key" => "help_channel_reports", "on" => true},
                 ctx
               )

      refute Sharing.enabled?(:help_channel_reports)
      assert audit_rows() == []
    end

    test "nobody asked, or an admin and a member both did: refused", %{agent: agent, owner: owner} do
      member = user!("other")
      member!(member, "member")
      args = %{"key" => "help_channel_reports", "on" => true}

      assert {:error, %{code: :forbidden}} =
               ToolArguments.dispatch("sharing_set", args, %{ctx(agent) | requester_user_id: nil})

      assert {:error, %{code: :forbidden}} =
               ToolArguments.dispatch("sharing_set", args, asked_by(agent, [owner, member]))

      assert audit_rows() == []
    end

    test "a requester id in the arguments is not read", %{agent: agent, owner: owner} do
      member = user!("forger")
      member!(member, "member")

      ctx = asked_by(agent, member)
      assert ctx.requester_user_id == member.id

      assert {:error, %{code: :forbidden}} =
               ToolArguments.dispatch(
                 "sharing_set",
                 %{
                   "key" => "help_channel_reports",
                   "on" => true,
                   "requester_user_id" => owner.id
                 },
                 ctx
               )

      assert audit_rows() == []
    end

    test "an unknown key is refused and changes nothing", %{agent: agent, owner: owner} do
      ctx = asked_by(agent, owner)

      assert {:error, %{code: :invalid_argument}} =
               ToolArguments.dispatch("sharing_set", %{"key" => "everything", "on" => true}, ctx)

      assert audit_rows() == []
    end
  end

  describe "a non-admin's agent" do
    setup do
      owner = user!("member")
      member!(owner, "member")

      {:ok, agent, _runtime} =
        NativeAgents.create(owner.id, %{name: "Helper", harness: "claude_code"})

      %{ctx: ctx(agent)}
    end

    test "is refused by both tools, and sharing_set changes and records nothing", %{ctx: ctx} do
      assert {:error, %{code: :forbidden}} = ToolArguments.dispatch("sharing_list", %{}, ctx)

      assert {:error, %{code: :forbidden}} =
               ToolArguments.dispatch(
                 "sharing_set",
                 %{"key" => "help_channel_reports", "on" => true},
                 ctx
               )

      refute Sharing.enabled?(:help_channel_reports)
      assert audit_rows() == []
    end

    test "a call with no runtime is refused" do
      assert {:error, %{code: :forbidden}} =
               ToolArguments.dispatch("sharing_set", %{"key" => "feedback", "on" => false}, %{})
    end
  end
end
