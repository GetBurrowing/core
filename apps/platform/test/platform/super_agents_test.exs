defmodule Platform.SuperAgentsTest do
  @moduledoc """
  The two super-agent roles, `doctor` and `relationship_steward`: closed
  roster entries seeded unassigned, one cron responsibility each routed
  through the explicit provider registry, the doctor's safe heals and
  escalations, and the steward's drafts-only guarantee.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query

  alias Platform.Agents.Agent
  alias Platform.Audit
  alias Platform.Chat
  alias Platform.Doctor
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Inbox
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Cron
  alias Platform.Responsibilities.Handlers.DoctorCheckup
  alias Platform.Responsibilities.Handlers.RelationshipsFollowUpSweep, as: Steward
  alias Platform.Responsibilities.Providers
  alias Platform.Responsibilities.Router
  alias Platform.Roles
  alias Platform.Roles.Role
  alias Platform.Roles.RoleAssignment
  alias Platform.Roles.RoleResponsibility
  alias Platform.Roles.Seeds
  alias Platform.SuperAgents
  alias Platform.Tenancy

  @roles [
    {"doctor", DoctorCheckup, "doctor.checkup", "doctor", "0 * * * *"},
    {"relationship_steward", Steward, "relationships.follow_up_sweep", "relationships",
     "0 8 * * 1-5"}
  ]

  setup do
    user = World.create_user!()
    World.plain_member!(user, Tenancy.get_org_by_slug!("globex"))
    %{user: user}
  end

  defp agent!(name) do
    %Agent{}
    |> Agent.changeset(%{
      slug: "#{name}-#{System.unique_integer([:positive])}",
      name: name,
      status: "active",
      kind: "native",
      workspace_id: nil
    })
    |> Repo.insert!()
  end

  defp row!(handler) do
    [spec] = handler.register()
    {:ok, row} = Responsibilities.upsert_by_key(spec)
    row
  end

  defp crashed(agent, desired \\ "running") do
    %{agent_id: agent.id, name: agent.name, state: :crashed, desired_state: desired, detail: nil}
  end

  defp empty_checkup do
    %{
      agents: [],
      dependency_waits: [],
      human_waits: [],
      expired_leases: [],
      unreachable_responsibilities: [],
      update_held?: false,
      agent_host: :ok
    }
  end

  describe "the roster" do
    test "both roles are closed-roster keys with one-key bundles, seeded unassigned" do
      for {role, handler, key, _feature, _cron} <- @roles do
        assert role in Role.valid_keys()
        seed = Enum.find(Seeds.default_roles(), &(&1.key == role))
        assert seed.bundle == [key]
        assert handler.key() == key

        # The migration seeded the role, the bundle row and the template.
        assert %Role{} = Repo.get(Role, role)

        assert Repo.exists?(
                 from(rr in RoleResponsibility,
                   where: rr.role_key == ^role and rr.responsibility_key == ^key
                 )
               )

        assert PromptTemplates.get_template_by_slug(handler.template_slug())

        # Unassigned: assignment happens in ops.
        refute Repo.exists?(from(a in RoleAssignment, where: a.role_key == ^role))
        assert Roles.agent_id_for_role(role) == nil
      end
    end

    test "each key is a global cron row whose feature resolves to its provider" do
      for {role, handler, key, feature, cron} <- @roles do
        assert [spec] = handler.register()
        assert spec.key == key
        assert spec.feature == feature
        assert spec.trigger_kind == "cron"
        assert spec.trigger_config == %{"expression" => cron}
        assert spec.scope == "global"
        assert spec.metadata["role"] == role
        assert spec.metadata["tool_bundles"] == handler.tool_bundles()
        assert {:ok, _} = Cron.parse(cron)

        assert {:ok, provider} = Providers.feature_provider(feature)
        assert provider.handler_for(key) == handler
        assert handler in Platform.Responsibilities.BuiltIns.providers()
      end
    end

    test "every declared tool bundle is a real bundle, and the doctor holds no admin tools" do
      for {_role, handler, _key, _feature, _cron} <- @roles,
          bundle <- handler.tool_bundles() do
        assert bundle in Platform.Federation.ToolSurface.all_bundles()
      end

      refute "admin" in DoctorCheckup.tool_bundles()
    end

    test "an unassigned role fires as :unfilled and reads nothing" do
      for {_role, handler, _key, _feature, _cron} <- @roles do
        row = row!(handler)

        capture_log(fn ->
          send(self(), {:result, Router.fire_trigger(row, %{kind: :cron}, %{})})
        end)

        assert_received {:result, {:ok, :unfilled}}
      end
    end
  end

  describe "provision" do
    test "assigns the role and stores the escalation human; idempotent", %{user: user} do
      agent = agent!("Doctor")

      assert {:ok, %{role: :assigned}} =
               Doctor.provision(agent_id: agent.id, escalate_user_id: user.id)

      assert {:ok, %{role: :unchanged}} =
               Doctor.provision(agent_id: agent.id, escalate_user_id: user.id)

      assert Roles.agent_id_for_role("doctor") == agent.id
      row = Responsibilities.get_by_key("doctor.checkup")
      assert row.trigger_config["escalate_user_id"] == user.id
      assert row.trigger_config["operator_set"] == true
      assert row.trigger_config["expression"] == "0 * * * *"
    end

    test "a role held by another agent is refused unless reassign: true", %{user: user} do
      other = agent!("Other")
      {:ok, _} = Roles.assign_role("relationship_steward", other.id)
      agent = agent!("Steward")
      attrs = %{agent_id: agent.id, escalate_user_id: user.id}

      assert {:error, {:role_held_by, held}} = Steward.provision(attrs)
      assert held == other.id

      assert {:ok, %{role: :reassigned}} = Steward.provision(Map.put(attrs, :reassign, true))
    end

    test "an unknown agent or user writes nothing", %{user: user} do
      assert {:error, {:not_found, :agent_id}} =
               Doctor.provision(agent_id: Ecto.UUID.generate(), escalate_user_id: user.id)

      assert {:error, {:missing, :escalate_user_id}} =
               Doctor.provision(agent_id: agent!("Doctor").id)

      assert Roles.agent_id_for_role("doctor") == nil
    end
  end

  describe "SuperAgents.escalate/4" do
    test "one DM message and one inbox row, asked once while open", %{user: user} do
      agent = agent!("Doctor")

      assert {:ok, :asked} =
               SuperAgents.escalate(agent.id, user.id, "Agent X needs a login", detail: "why")

      assert {:ok, :already_open} =
               SuperAgents.escalate(agent.id, user.id, "Agent X needs a login", detail: "why")

      assert [item] = Inbox.list_unread_for_user(user.id)
      assert item.title == "Needs you: Agent X needs a login"

      {:ok, %{space_id: dm_id}} = SuperAgents.dm(agent.id, user.id)
      assert [message] = Chat.list_messages(dm_id, limit: 10)
      assert message.content =~ "Agent X needs a login"
    end

    test "with nobody configured it only logs" do
      assert capture_log(fn ->
               assert {:skipped, :no_escalate_user} =
                        SuperAgents.escalate(Ecto.UUID.generate(), nil, "Q")
             end) =~ "nobody to ask"
    end
  end

  describe "Doctor.heal/3" do
    test "restarts a crashed agent meant to be running, once per backoff window, audited" do
      agent = agent!("Worker")
      test_pid = self()

      restart = fn %Agent{id: id} ->
        send(test_pid, {:restarted, id})
        :ok
      end

      checkup = %{empty_checkup() | agents: [crashed(agent)]}

      assert %{healed: [line], escalations: []} = Doctor.heal(checkup, nil, restart: restart)
      assert line =~ "restarted Worker"
      assert_received {:restarted, id} when id == agent.id

      assert Repo.exists?(
               from(e in Audit.Event,
                 where:
                   e.event_type == "doctor.heal" and e.action == "restart_agent" and
                     e.resource_id == ^agent.id
               )
             )

      # Crashed again inside the window: escalated, never restarted again.
      assert %{healed: [], escalations: [%{question: question}]} =
               Doctor.heal(checkup, nil, restart: restart)

      assert question =~ "keeps crashing"
      refute_received {:restarted, _}
    end

    test "a failed restart is escalated" do
      agent = agent!("Worker")
      checkup = %{empty_checkup() | agents: [crashed(agent)]}

      assert %{healed: [], escalations: [%{question: question}]} =
               Doctor.heal(checkup, nil, restart: fn _ -> {:error, :not_connected} end)

      assert question =~ "could not be restarted"
    end

    test "needs_login, a held update and a disconnected host are escalated, never healed" do
      agent = agent!("Worker")
      test_pid = self()

      checkup = %{
        empty_checkup()
        | agents: [%{crashed(agent) | state: :needs_login}],
          update_held?: true,
          agent_host: :not_connected
      }

      %{healed: healed, escalations: escalations} =
        Doctor.heal(checkup, nil, restart: fn _ -> send(test_pid, :restarted) end)

      assert healed == []
      questions = Enum.map(escalations, & &1.question)
      assert Enum.any?(questions, &(&1 =~ "needs a login"))
      assert Enum.any?(questions, &(&1 =~ "release is held"))
      assert Enum.any?(questions, &(&1 =~ "agent host is not connected"))
      refute_received :restarted
    end

    test "a crashed agent meant to be stopped is left alone" do
      agent = agent!("Worker")
      checkup = %{empty_checkup() | agents: [crashed(agent, "stopped")]}

      assert %{healed: [], escalations: []} =
               Doctor.heal(checkup, nil, restart: fn _ -> flunk("restarted") end)
    end

    test "a dependency wait is re-verified; a spent budget is escalated" do
      task_id = Ecto.UUID.generate()
      wait = %{task_id: task_id, phase: "execution", block_reason: nil, since: nil}
      checkup = %{empty_checkup() | dependency_waits: [wait]}

      assert %{healed: [line]} =
               Doctor.heal(checkup, nil, reassess: fn ^task_id -> {:ok, [{:requested, %{}}]} end)

      assert line =~ task_id

      assert %{healed: [], escalations: [%{question: question}]} =
               Doctor.heal(checkup, nil, reassess: fn _ -> {:ok, [:exhausted]} end)

      assert question =~ "never verified"

      assert %{healed: [], escalations: []} =
               Doctor.heal(checkup, nil, reassess: fn _ -> {:ok, [:not_due]} end)
    end
  end

  describe "doctor.checkup gather_context" do
    test "a healthy install dispatches nothing" do
      row = row!(DoctorCheckup)

      assert {:handled, %{healthy: true}} =
               DoctorCheckup.gather_context(row, %{}, checkup: empty_checkup())
    end

    test "heals, escalates to the configured human, then dispatches for diagnosis",
         %{user: user} do
      agent = agent!("Doctor")
      {:ok, _} = Doctor.provision(agent_id: agent.id, escalate_user_id: user.id)
      row = Responsibilities.get_by_key("doctor.checkup")
      worker = agent!("Worker")

      checkup = %{
        empty_checkup()
        | agents: [%{crashed(worker) | state: :needs_login}]
      }

      assert {:ok, context} = DoctorCheckup.gather_context(row, %{}, checkup: checkup)
      assert context.findings =~ "needs_login"
      assert is_binary(context.report_space_id)

      assert [item] = Inbox.list_unread_for_user(user.id)
      assert item.title == DoctorCheckup.escalation_prefix() <> "Worker needs a login"

      assert {:ok, %{system: system, user: prompt}} =
               DoctorCheckup.build_prompt(context)

      assert system =~ "never take a destructive action"
      assert prompt =~ "Worker"
      assert prompt =~ context.report_space_id

      # The same fault an hour later: the question is still open, nothing new
      # to diagnose, so no second row and no dispatch.
      assert {:handled, %{escalated: 0}} =
               DoctorCheckup.gather_context(row, %{}, checkup: checkup)

      assert [_] = Inbox.list_unread_for_user(user.id)
    end

    test "the real checkup reads every section without raising" do
      checkup = Doctor.checkup()
      assert is_list(checkup.agents)
      assert is_list(checkup.unreachable_responsibilities)
      assert is_boolean(checkup.update_held?)
    end
  end

  describe "relationships.follow_up_sweep" do
    test "with no escalation human it parks and dispatches nothing" do
      row = row!(Steward)

      capture_log(fn ->
        assert {:handled, %{parked: :no_escalate_user}} = Steward.gather_context(row, %{}, [])
      end)
    end

    test "provisioned, it reports to the person's DM and drafts with no send tool",
         %{user: user} do
      agent = agent!("Steward")
      {:ok, _} = Steward.provision(agent_id: agent.id, escalate_user_id: user.id)
      row = Responsibilities.get_by_key("relationships.follow_up_sweep")

      assert {:ok, context} = Steward.gather_context(row, %{}, [])
      {:ok, %{space_id: dm_id}} = SuperAgents.dm(agent.id, user.id)
      assert context.report_space_id == dm_id
      assert context.meetings =~ "no meetings ended"

      assert {:ok, %{system: system, user: prompt}} = Steward.build_prompt(context)
      assert system =~ "never send mail"
      assert prompt =~ "mail_draft_create"
      assert prompt =~ dm_id
    end

    test "no tool on the surface sends mail, so the steward cannot" do
      names = Platform.Federation.ToolSurface.reserved_tool_names()
      assert "mail_draft_create" in names
      refute Enum.any?(names, &(&1 =~ ~r/mail.*send|send.*mail|mail_reply|mail_forward/))
    end

    test "an external endpoint's drafts are put to the person once", %{user: user} do
      agent = agent!("Steward")
      {:ok, _} = Steward.provision(agent_id: agent.id, escalate_user_id: user.id)
      row = Responsibilities.get_by_key("relationships.follow_up_sweep")
      output = Jason.encode!(%{"summary" => "Two clients owed.", "draft_ids" => ["d1", "d2"]})

      assert :ok = Steward.handle_output(row, output, %{})
      assert :ok = Steward.handle_output(row, output, %{})

      assert [item] = Inbox.list_unread_for_user(user.id)
      assert item.title =~ "2 follow-up draft(s) are waiting for you to send"
    end
  end
end
