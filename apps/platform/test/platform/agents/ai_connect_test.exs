defmodule Platform.Agents.AiConnectTest do
  @moduledoc """
  `NativeAgents.adopt/3` and `AiConnect.prepare/3` (task 01a1b84b stage 1):
  a builder-made plain agent becomes a native one, keeping its id and its
  files, and a prepare brings it up on the provider's harness.

  Mutants these name:

    * drop the `may_federate?` conjunct in `may_adopt?/2` -> survives: no
      fixture manages an agent while its agents module is locked (the lock
      also removes `manage?`), so "refuses an admin whose agents module is
      locked" goes red only with both conjuncts gone;
    * drop the `manage?` conjunct -> "a member who does not manage it";
    * seed with `overwrite: true` -> "files stay byte-equal";
    * drop the character section -> "the instructions file points at SOUL.md";
    * drop the `FOR UPDATE` re-read -> "two adopts make one runtime";
    * drop the `can_manage?/2` re-check in `prepare/3` -> "B cannot adopt A's
      agent through prepare";
    * `run_on/2` switching a running agent -> "a running agent keeps its harness".
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.AsyncAssertions

  alias Platform.Access.Grants
  alias Platform.AgentHost
  alias Platform.AgentHost.{FakeHost, Reconciler}
  alias Platform.Agents.{Agent, AgentRuntime, AiConnect, Character, MemoryContext, NativeAgents}
  alias Platform.Repo
  alias Platform.TenancyFixtures
  alias Platform.VaultFixtures

  setup do
    fake = start_supervised!({FakeHost, report_after_ms: 0})
    assert_eventually(fn -> Reconciler.host_pid() == fake end, 3_000)
    %{fake: fake}
  end

  defp character!(creator) do
    b =
      Character.new("scout")
      |> Map.merge(%{
        n: "Tester #{System.unique_integer([:positive])}",
        color: "indigo",
        portrait: "fox",
        sl: %{"chatty" => 20, "bold" => 80, "playful" => 10, "collab" => 90},
        traits: ["skeptic", "tidy", "night owl"],
        vc: %{p: 3, ov: %{"emoji" => 1}, q: "pr", free: nil}
      })

    {:ok, %{agent: agent}} = Character.create(b, creator)
    agent
  end

  defp files(agent),
    do: agent.id |> MemoryContext.list_workspace_files() |> Map.new(&{&1.file_key, &1.content})

  defp runtimes(agent),
    do: Repo.all(from(r in AgentRuntime, where: r.agent_id == ^agent.id))

  describe "adopt/3" do
    test "keeps the agent id, its row and its files, and makes it native and owned by the actor" do
      admin = VaultFixtures.admin!()
      agent = character!(admin)
      before = files(agent)
      assert Map.keys(before) |> Enum.sort() == ["IDENTITY.md", "SOUL.md", "TOOLS.md"]
      refute NativeAgents.managed?(agent)

      assert {:ok, %Agent{} = adopted} = NativeAgents.adopt(admin, agent, "claude_code")

      assert adopted.id == agent.id
      assert adopted.name == agent.name
      assert adopted.metadata["character"] == agent.metadata["character"]
      assert adopted.runtime_type == "external"
      assert NativeAgents.managed?(adopted)

      runtime = NativeAgents.get_managed_runtime(adopted)
      assert runtime.managed_by == "install"
      assert runtime.harness == "claude_code"
      assert runtime.desired_state == "stopped"
      assert runtime.owner_user_id == admin.id
      assert runtime.status == "active"
      assert runtime.agent_id == agent.id

      after_files = files(adopted)

      for key <- ["SOUL.md", "IDENTITY.md", "TOOLS.md"],
          do: assert(after_files[key] == before[key], "#{key} changed")

      assert Map.has_key?(after_files, "CLAUDE.md")
      assert Map.has_key?(after_files, ".claude/settings.json")
      assert NativeAgents.can_manage?(admin, adopted)
    end

    test "the instructions file the agent runs points at SOUL.md and IDENTITY.md (start_files)" do
      admin = VaultFixtures.admin!()
      agent = character!(admin)

      {:ok, adopted} = NativeAgents.adopt(admin, agent, "claude_code")
      started = Map.new(NativeAgents.start_files(adopted), &{&1["key"], &1["content"]})

      assert started["CLAUDE.md"] =~ "SOUL.md"
      assert started["CLAUDE.md"] =~ "IDENTITY.md"
      assert started["CLAUDE.md"] =~ "@SOUL.md"
      assert started["SOUL.md"] == files(agent)["SOUL.md"]

      codex = character!(admin)
      {:ok, codex} = NativeAgents.adopt(admin, codex, "codex")
      started = Map.new(NativeAgents.start_files(codex), &{&1["key"], &1["content"]})
      assert started["AGENTS.md"] =~ "SOUL.md"
      assert started["AGENTS.md"] =~ "IDENTITY.md"

      # A switch reseeds the new harness's file with the pointer too.
      {:ok, _} = NativeAgents.set_harness(codex, "claude_code")
      started = Map.new(NativeAgents.start_files(codex), &{&1["key"], &1["content"]})
      assert started["CLAUDE.md"] =~ "IDENTITY.md"
    end

    test "an existing instructions file is not overwritten" do
      admin = VaultFixtures.admin!()
      agent = character!(admin)
      {:ok, _} = MemoryContext.upsert_workspace_file(agent.id, "CLAUDE.md", "mine, keep it\n")

      {:ok, adopted} = NativeAgents.adopt(admin, agent, "claude_code")
      assert files(adopted)["CLAUDE.md"] == "mine, keep it\n"
    end

    test "is idempotent: an agent that is already native comes back unchanged" do
      admin = VaultFixtures.admin!()
      agent = character!(admin)

      {:ok, first} = NativeAgents.adopt(admin, agent, "claude_code")
      runtime = NativeAgents.get_managed_runtime(first)

      # The stale struct (runtime_id nil) and the fresh one both.
      assert {:ok, again} = NativeAgents.adopt(admin, agent, "codex")
      assert {:ok, _} = NativeAgents.adopt(admin, first, "codex")
      assert again.id == agent.id
      assert [%AgentRuntime{id: id, harness: "claude_code"}] = runtimes(agent)
      assert id == runtime.id
    end

    test "two adopts at once make one runtime" do
      admin = VaultFixtures.admin!()
      agent = character!(admin)
      parent = self()

      results =
        1..2
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
            NativeAgents.adopt(admin, agent, "claude_code")
          end)
        end)
        |> Enum.map(&Task.await(&1, 10_000))

      assert Enum.all?(results, &match?({:ok, %Agent{}}, &1))
      assert [_one] = runtimes(agent)
    end

    test "refuses a member who does not manage it, and creates nothing" do
      admin = VaultFixtures.admin!()
      member = VaultFixtures.non_admin!()
      agent = character!(admin)

      assert Platform.Access.Agents.may_federate?(Platform.Access.Scope.for_user(member))
      assert {:error, :forbidden} = NativeAgents.adopt(member, agent, "claude_code")
      assert runtimes(agent) == []
      refute NativeAgents.managed?(Repo.reload!(agent))
    end

    test "refuses an admin whose agents module is locked (may not federate)" do
      admin = TenancyFixtures.root_admin!()
      agent = character!(admin)
      assert NativeAgents.may_adopt?(admin, agent)

      {:ok, _} =
        Grants.deny(%{
          principal: {:user, admin.id},
          permission: "agents",
          resource: {:module, TenancyFixtures.acme_org_id()}
        })

      refute Platform.Access.Agents.may_federate?(Platform.Access.Scope.for_user(admin))

      assert {:error, :forbidden} = NativeAgents.adopt(admin, agent, "claude_code")
      assert runtimes(agent) == []
    end
  end

  describe "prepare/3" do
    test "adopts a builder agent and starts it on the provider's harness" do
      admin = VaultFixtures.admin!()
      agent = character!(admin)

      assert {:ok, prepared} = AiConnect.prepare(admin, agent, :codex)
      assert prepared.id == agent.id
      assert NativeAgents.get_managed_runtime(prepared).harness == "codex"
      assert NativeAgents.get_managed_runtime(prepared).desired_state == "running"

      assert_eventually(
        fn -> match?(%{state: :needs_login}, AgentHost.status(prepared)) end,
        3_000
      )
    end

    test "switches the harness only when the agent is not running" do
      admin = VaultFixtures.admin!()
      agent = character!(admin)

      {:ok, agent} = AiConnect.prepare(admin, agent, :codex)
      # Not running (waiting at the device code): a switch.
      {:ok, agent} = AiConnect.prepare(admin, agent, :claude_subscription)
      assert NativeAgents.get_managed_runtime(agent).harness == "claude_code"
      # The fake host's own report of the restart lands first.
      assert_eventually(
        fn -> match?(%{state: :needs_login, detail: "login"}, AgentHost.status(agent)) end,
        3_000
      )

      # Running: it keeps its harness.
      :ok =
        Reconciler.agent_state(Reconciler.host_pid(), %{
          "agent_id" => agent.id,
          "state" => "running"
        })

      assert_eventually(fn -> match?(%{state: :running}, AgentHost.status(agent)) end, 3_000)
      {:ok, agent} = AiConnect.prepare(admin, agent, :codex)
      assert NativeAgents.get_managed_runtime(agent).harness == "claude_code"
    end

    test "a harness switch forgets the sign-in summary" do
      admin = VaultFixtures.admin!()
      agent = character!(admin)
      {:ok, agent} = AiConnect.prepare(admin, agent, :claude_subscription)

      {:ok, _} =
        NativeAgents.put_ai_login(agent, %{"provider" => "claude", "account" => "a@example.com"})

      assert NativeAgents.ai_login(agent)["account"] == "a@example.com"

      {:ok, agent} = AiConnect.prepare(admin, agent, :codex)
      assert NativeAgents.ai_login(agent) == nil
    end

    test "B cannot adopt or prepare A's agent" do
      owner = VaultFixtures.admin!()
      agent = character!(owner)
      {:ok, agent} = NativeAgents.adopt(owner, agent, "claude_code")
      member = VaultFixtures.non_admin!()

      assert {:error, :forbidden} = AiConnect.prepare(member, agent, :codex)
      assert NativeAgents.get_managed_runtime(agent).owner_user_id == owner.id
      assert NativeAgents.get_managed_runtime(agent).harness == "claude_code"
    end

    test "an unknown provider is refused" do
      admin = VaultFixtures.admin!()
      assert {:error, :unknown_provider} = AiConnect.prepare(admin, character!(admin), :api_key)
    end
  end

  describe "ai_login summary" do
    test "keeps provider, account and plan only, per agent" do
      admin = VaultFixtures.admin!()
      {:ok, a} = NativeAgents.adopt(admin, character!(admin), "claude_code")
      {:ok, b} = NativeAgents.adopt(admin, character!(admin), "claude_code")

      {:ok, _} =
        NativeAgents.put_ai_login(a, %{
          "provider" => "claude",
          "account" => "a@example.com",
          "plan" => "max",
          "url" => "https://example.com/x",
          "code" => "secret"
        })

      assert NativeAgents.ai_login(a) == %{
               "provider" => "claude",
               "account" => "a@example.com",
               "plan" => "max"
             }

      assert NativeAgents.ai_login(b) == nil
      {:ok, _} = NativeAgents.clear_ai_login(a)
      assert NativeAgents.ai_login(a) == nil
    end

    test "a codex agent first seen running is recorded as ChatGPT" do
      admin = VaultFixtures.admin!()
      {:ok, agent} = NativeAgents.adopt(admin, character!(admin), "codex")
      assert :ok = AiConnect.note_observed(agent, %{state: :needs_login})
      assert NativeAgents.ai_login(agent) == nil
      assert :ok = AiConnect.note_observed(agent, %{state: :running})
      assert NativeAgents.ai_login(agent) == %{"provider" => "chatgpt"}
    end
  end

  describe "fake host login command record" do
    test "names only, per agent, and the dev route lists them", %{fake: fake} do
      admin = VaultFixtures.admin!()
      {:ok, agent} = AiConnect.prepare(admin, character!(admin), :claude_subscription)
      assert FakeHost.login_commands(agent.id, fake) == []

      {:ok, _url} = AgentHost.claude_login_start(admin, agent, timeout: 1_000)
      {:ok, code} = Platform.AgentHost.LoginCode.new(FakeHost.claude_login_code())
      {:ok, _} = AgentHost.claude_login_submit(admin, agent, code, timeout: 1_000)

      assert FakeHost.login_commands(agent.id, fake) ==
               ["agent.claude_login_start", "agent.claude_login_code"]

      conn =
        Plug.Test.conn(:get, "/#{agent.id}/login-commands")
        |> PlatformWeb.Dev.FakeAgentHost.call([])

      assert conn.status == 200

      assert Jason.decode!(conn.resp_body) ==
               ["agent.claude_login_start", "agent.claude_login_code"]

      refute conn.resp_body =~ FakeHost.claude_login_code()
      assert FakeHost.login_commands(Ecto.UUID.generate(), fake) == []
    end
  end
end
