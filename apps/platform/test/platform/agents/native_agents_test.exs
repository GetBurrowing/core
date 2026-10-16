defmodule Platform.Agents.NativeAgentsTest do
  @moduledoc """
  Native (install-managed) agents, task 01a10322 stage 1.

  The parity claim under test: a native agent is a ROW SHAPE, so every reader
  that resolves an agent through its runtime treats it as a federated agent
  with no code change. `PhaseRuntime.resolve/1` and `Kind.classify/1` are the
  two readers asserted here.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  require Logger
  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime, Kind, NativeAgents}
  alias Platform.Federation
  alias Platform.Orchestration.PhaseRuntime
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskSchema
  alias Platform.Tenancy.OrgMembership

  defp create_user(label \\ "owner") do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "native-#{label}-#{n}@example.com",
      name: "Native #{label} #{n}",
      oidc_sub: "oidc-native-#{label}-#{n}"
    })
  end

  defp create_admin do
    user = create_user("admin")

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "admin"
    })
    |> Repo.insert!()

    user
  end

  defp create_member do
    user = create_user("member")

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    user
  end

  defp federated_agent!(owner) do
    n = System.unique_integer([:positive])

    {:ok, agent, runtime, _token} =
      Federation.provision_agent_runtime(
        owner.id,
        %{slug: "fed-#{n}", name: "Fed #{n}", status: "active"},
        %{runtime_id: "fed-rt-#{n}"}
      )

    {agent, runtime}
  end

  # A runtime token is `AgentRuntime.generate_token/0`: 32 random bytes,
  # url-safe base64 without padding, so 43 characters of [A-Za-z0-9_-].
  # Returns every candidate in `text` whose hash equals `hash`.
  defp token_hits(text, hash) do
    ~r/[A-Za-z0-9_-]{43}/
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.filter(&(AgentRuntime.hash_token(&1) == hash))
  end

  describe "create/2" do
    test "creates an external agent on an activated, install-managed runtime" do
      owner = create_user()

      assert {:ok, %Agent{} = agent, %AgentRuntime{} = runtime} =
               NativeAgents.create(owner.id, %{name: "Ada Lovelace", harness: "claude_code"})

      assert agent.runtime_type == "external"
      assert agent.runtime_id == runtime.id
      assert agent.slug == "ada-lovelace"

      runtime = Repo.get!(AgentRuntime, runtime.id)
      assert runtime.status == "active"
      assert runtime.agent_id == agent.id
      assert runtime.owner_user_id == owner.id
      assert runtime.managed_by == "install"
      assert runtime.harness == "claude_code"
      assert runtime.desired_state == "stopped"
      assert runtime.runtime_id =~ ~r/\Aada-lovelace-native-[0-9a-f]{8}\z/
      assert is_binary(runtime.auth_token_hash)
    end

    test "string keys work, an unknown harness is refused and nothing is written" do
      owner = create_user()

      assert {:ok, _agent, %AgentRuntime{harness: "codex"}} =
               NativeAgents.create(owner.id, %{"name" => "Cody", "harness" => "codex"})

      before = Repo.aggregate(AgentRuntime, :count)

      assert {:error, %Ecto.Changeset{} = changeset} =
               NativeAgents.create(owner.id, %{name: "Bad", harness: "vim"})

      assert {"is invalid", _} = changeset.errors[:harness]
      assert Repo.aggregate(AgentRuntime, :count) == before
      assert {:error, :name_required} = NativeAgents.create(owner.id, %{name: "  "})
    end

    test "never returns or logs the raw runtime token" do
      # The test config drops info and debug lines before any capture sees
      # them, so `with_log(level: :debug)` alone is blind to an info-level
      # leak (a mutation logging the token at info stayed green until this).
      previous_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      owner = create_user()

      {result, log} =
        with_log([level: :debug], fn ->
          NativeAgents.create(owner.id, %{name: "Quiet", harness: "claude_code"})
        end)

      assert {:ok, _agent, runtime} = result
      hash = Repo.get!(AgentRuntime, runtime.id).auth_token_hash

      assert token_hits(inspect(result, limit: :infinity), hash) == []
      assert token_hits(log, hash) == []

      # POSITIVE CONTROL: the same scan finds the token where it IS present.
      # `provision_agent_runtime/3` returns it, and the scan detects it.
      {:ok, _a, rt, raw} =
        Federation.provision_agent_runtime(
          owner.id,
          %{slug: "control-#{System.unique_integer([:positive])}", name: "Control"},
          %{runtime_id: "control-#{System.unique_integer([:positive])}"}
        )

      rt_hash = Repo.get!(AgentRuntime, rt.id).auth_token_hash
      assert token_hits(inspect({:ok, raw}), rt_hash) == [raw]

      # POSITIVE CONTROL for the log path: an info line carrying the token is
      # captured and found.
      {_, planted} = with_log([level: :debug], fn -> Logger.info("planted #{raw}") end)
      assert token_hits(planted, rt_hash) == [raw]
    end
  end

  describe "parity with federated agents" do
    test "PhaseRuntime.resolve/1 resolves a native agent exactly like a federated one" do
      owner = create_user()

      {:ok, agent, runtime} =
        NativeAgents.create(owner.id, %{name: "Ada", harness: "claude_code"})

      {:ok, project} =
        Tasks.create_project(%{
          name: "Native Parity #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/native-parity"
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Native parity #{System.unique_integer([:positive])}",
          description: "Phase-assigned to a native agent"
        })

      task =
        task
        |> Ecto.Changeset.change(%{
          status: "in_progress",
          phase_assignees: %{
            "execution" => %{"assignee_id" => agent.id, "assignee_type" => "agent"}
          }
        })
        |> Repo.update!()

      assert %TaskSchema{} = task
      assert Tasks.current_phase(task) == "execution"

      runtime_id = runtime.runtime_id
      assert {:ok, %{type: :federated, id: ^runtime_id}} = PhaseRuntime.resolve(task)
      assert Kind.classify(Repo.get!(Agent, agent.id)) == :fed_conversational
    end
  end

  describe "first-agent grant" do
    test "the first create gets every bundle, the second gets the defaults" do
      owner = create_user()

      {:ok, _first, first_rt} =
        NativeAgents.create(owner.id, %{name: "First", harness: "claude_code"})

      {:ok, _second, second_rt} =
        NativeAgents.create(owner.id, %{name: "Second", harness: "claude_code"})

      first_rt = Repo.get!(AgentRuntime, first_rt.id)
      second_rt = Repo.get!(AgentRuntime, second_rt.id)

      assert Enum.sort(Platform.Access.RuntimeProfiles.tool_profile(first_rt)) ==
               Enum.sort(Platform.Access.RuntimeProfiles.valid_modules())

      assert first_rt.metadata["first_agent_grant"] == true

      assert Enum.sort(Platform.Access.RuntimeProfiles.tool_profile(second_rt)) ==
               Enum.sort(AgentRuntime.default_tool_profile())

      refute Map.has_key?(second_rt.metadata, "first_agent_grant")
    end

    test "an existing federated agent means the first native agent gets the defaults" do
      owner = create_user()
      {_fed, fed_rt} = federated_agent!(owner)
      assert Repo.get!(AgentRuntime, fed_rt.id).metadata["first_agent_grant"] == true

      {:ok, _agent, rt} = NativeAgents.create(owner.id, %{name: "Late", harness: "claude_code"})
      rt = Repo.get!(AgentRuntime, rt.id)

      assert Enum.sort(Platform.Access.RuntimeProfiles.tool_profile(rt)) ==
               Enum.sort(AgentRuntime.default_tool_profile())

      refute Map.has_key?(rt.metadata, "first_agent_grant")
    end

    test "built_in and archived agents do not count" do
      owner = create_user()

      Repo.insert!(
        Agent.changeset(%Agent{}, %{
          slug: "builtin-#{System.unique_integer([:positive])}",
          name: "B",
          status: "active"
        })
      )

      {fed, _rt} = federated_agent!(owner)
      fed |> Agent.changeset(%{status: "archived"}) |> Repo.update!()

      {:ok, _agent, rt} = NativeAgents.create(owner.id, %{name: "Real First", harness: "codex"})
      assert Repo.get!(AgentRuntime, rt.id).metadata["first_agent_grant"] == true
    end

    test "FIRST_AGENT_BUNDLES narrows the grant and drops names that are not grantable" do
      previous = Application.get_env(:platform, :first_agent_bundles)
      on_exit(fn -> restore_env(:first_agent_bundles, previous) end)

      Application.put_env(:platform, :first_agent_bundles, "task, plan,not-a-bundle")
      owner = create_user()

      {{:ok, _agent, rt}, log} =
        with_log(fn ->
          NativeAgents.create(owner.id, %{name: "Narrow", harness: "claude_code"})
        end)

      assert Platform.Access.RuntimeProfiles.tool_profile(Repo.get!(AgentRuntime, rt.id)) == [
               "task",
               "plan"
             ]

      assert log =~ "not-a-bundle"
    end
  end

  # ── Concurrency: the advisory lock ─────────────────────────────────────────
  #
  # Under the shared sandbox every process uses ONE connection, so two
  # "concurrent" creates are serialised by the connection itself and the lock
  # is never exercised: removing it would leave a sandboxed version of this
  # test green. This test therefore leaves the sandbox (`unboxed_run/2`), so
  # each create runs on its own connection and really commits, and cleans up
  # every row it committed. The module is `async: false`, so no other test
  # module runs while those rows exist.
  describe "first-agent grant under real concurrency" do
    test "concurrent creates on an empty install give exactly one all-bundles grant" do
      n = 6
      stamp = System.unique_integer([:positive])

      owner =
        unboxed(fn ->
          # Precondition that makes the assertion mean something: the
          # committed database has no external agent yet.
          assert Repo.aggregate(
                   from(a in Agent,
                     where: a.runtime_type == "external" and a.status != "archived"
                   ),
                   :count
                 ) == 0

          Repo.insert!(%User{
            email: "native-race-#{stamp}@example.com",
            name: "Native Race",
            oidc_sub: "oidc-native-race-#{stamp}"
          })
        end)

      on_exit(fn ->
        unboxed(fn ->
          Repo.delete_all(from(a in Agent, where: like(a.slug, ^"race-#{stamp}-%")))
          Repo.delete_all(from(u in User, where: u.id == ^owner.id))
        end)
      end)

      results =
        1..n
        |> Enum.map(fn i ->
          Task.async(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              NativeAgents.create(owner.id, %{name: "race-#{stamp}-#{i}", harness: "claude_code"})
            end)
          end)
        end)
        |> Task.await_many(30_000)

      assert Enum.all?(results, &match?({:ok, _, _}, &1))

      runtimes =
        unboxed(fn ->
          Repo.all(from(r in AgentRuntime, where: r.owner_user_id == ^owner.id))
        end)

      assert length(runtimes) == n

      granted = Enum.filter(runtimes, &(&1.metadata["first_agent_grant"] == true))
      assert length(granted) == 1

      all = Enum.sort(Platform.Access.RuntimeProfiles.valid_modules())

      assert Enum.count(
               runtimes,
               &(Enum.sort(Platform.Access.RuntimeProfiles.tool_profile(&1)) == all)
             ) == 1
    end
  end

  describe "can_manage?/2" do
    test "ownership does not retain management after the owner's Access scope is revoked" do
      owner = create_member()

      {:ok, agent, _runtime} =
        NativeAgents.create(owner.id, %{name: "Revoked owner", harness: "codex"})

      assert NativeAgents.can_manage?(owner, agent)

      {:ok, _} =
        Platform.Tenancy.mark_membership_external(%{
          user_id: owner.id,
          org_id: Platform.TenancyFixtures.acme_org_id()
        })

      refute NativeAgents.can_manage?(owner, agent)
      refute NativeAgents.can_manage?(owner.id, agent)
    end

    test "true for the runtime owner and an install admin, false for other members" do
      owner = create_user()
      admin = create_admin()
      member = create_member()

      {:ok, agent, _rt} =
        NativeAgents.create(owner.id, %{name: "Managed", harness: "claude_code"})

      assert NativeAgents.can_manage?(owner, agent)
      assert NativeAgents.can_manage?(owner.id, agent)
      assert NativeAgents.can_manage?(admin, agent)
      refute NativeAgents.can_manage?(member, agent)
      refute NativeAgents.can_manage?(nil, agent)
    end
  end

  describe "list/0, get_managed_runtime/1, managed?/1, set_desired_state/2" do
    test "a native agent is managed and a federated one is not" do
      owner = create_user()
      {:ok, native, native_rt} = NativeAgents.create(owner.id, %{name: "Nat", harness: "codex"})
      {fed, _fed_rt} = federated_agent!(owner)

      assert NativeAgents.managed?(native)
      refute NativeAgents.managed?(fed)
      assert %AgentRuntime{id: id} = NativeAgents.get_managed_runtime(native)
      assert id == native_rt.id
      assert NativeAgents.get_managed_runtime(fed) == nil

      assert [%{agent: %Agent{id: listed_id}, runtime: %AgentRuntime{}}] = NativeAgents.list()
      assert listed_id == native.id

      assert {:ok, %AgentRuntime{desired_state: "running"}} =
               NativeAgents.set_desired_state(native, "running")

      assert {:error, :not_managed} = NativeAgents.set_desired_state(fed, "running")
      assert {:error, %Ecto.Changeset{}} = NativeAgents.set_desired_state(native, "paused")
    end
  end

  # `unboxed_run/2` only leaves the sandbox in a process that is not already
  # allowed on it. The test process IS allowed (shared mode), so run every
  # unboxed step in its own process.
  defp unboxed(fun) do
    fn -> Sandbox.unboxed_run(Repo, fun) end
    |> Task.async()
    |> Task.await(30_000)
  end

  defp restore_env(key, nil), do: Application.delete_env(:platform, key)
  defp restore_env(key, value), do: Application.put_env(:platform, key, value)
end
