defmodule Platform.Agents.Burrow.StarterTest do
  @moduledoc """
  Burrow's starter allowance (`Platform.Agents.Burrow.Starter`).

  Mutants these name:

    * make `configured?/0` always true → "without a key nothing is created"
      goes red;
    * drop `Starter.activate/1` in `Burrow.ensure_starter/1` → "creates Burrow
      on the starter key" goes red (no key in the start env);
    * drop `Starter.retire/1` in `Burrow.ensure/2` → every swap-over test goes
      red (the key is still in the start env);
    * make `retire/1` write `"active"` or clear nothing in the database →
      "a retired starter is not revived" goes red;
    * skip the root-admin check in `provision/1` → "a member is not
      provisioned" goes red.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Agents.{Burrow, NativeAgents, NativeLogin}
  alias Platform.Agents.Burrow.{GettingStarted, Starter}
  alias Platform.Chat.Space
  alias Platform.Repo
  alias Platform.VaultFixtures

  @starter "sk-ant-api03-" <> String.duplicate("s", 40) <> "STARTERKEYtail"
  @own "sk-ant-api03-" <> String.duplicate("o", 40) <> "OWNERKEYtail"

  setup do
    previous = Application.get_env(:platform, :agent_host_token)
    Application.put_env(:platform, :agent_host_token, "test-host-token")
    put_starter(@starter)

    on_exit(fn ->
      Application.delete_env(:platform, :starter_anthropic_api_key)
      Application.delete_env(:platform, :native_agent_login)

      if previous,
        do: Application.put_env(:platform, :agent_host_token, previous),
        else: Application.delete_env(:platform, :agent_host_token)
    end)

    %{admin: VaultFixtures.admin!()}
  end

  defp put_starter(nil), do: Application.delete_env(:platform, :starter_anthropic_api_key)
  defp put_starter(key), do: Application.put_env(:platform, :starter_anthropic_api_key, key)

  defp burrow_count do
    Enum.count(NativeAgents.list(), fn %{agent: a} -> a.slug == "burrow" end)
  end

  defp space_count(agent) do
    Repo.aggregate(from(s in Space, where: s.slug == ^GettingStarted.space_slug(agent)), :count)
  end

  describe "the key" do
    test "unset or not shaped like an API key is not configured" do
      assert Starter.configured?()

      put_starter(nil)
      refute Starter.configured?()
      assert Starter.key() == nil

      put_starter("not-a-key")
      refute Starter.configured?()
    end
  end

  describe "provision/1" do
    test "without a key nothing is created", %{admin: admin} do
      put_starter(nil)

      assert Starter.provision(admin) == :disabled
      assert burrow_count() == 0
    end

    test "a member is not provisioned" do
      assert Starter.provision(VaultFixtures.non_admin!()) == :disabled
      assert burrow_count() == 0
    end

    test "creates Burrow on the starter key and opens Getting started, once", %{admin: admin} do
      assert {:ok, %Space{id: id} = space} = Starter.provision(admin)
      assert {:ok, %Space{id: ^id}} = Starter.provision(admin)

      agent = Burrow.get()
      assert burrow_count() == 1
      assert Burrow.harness(agent) == "claude_code"
      assert Starter.state(agent) == "active"
      assert space.slug == GettingStarted.space_slug(agent)
      assert space_count(agent) == 1

      # The key reaches the agent's start env, in either login mode, and the
      # vault holds nothing for it.
      assert NativeLogin.start_env(agent) == %{"ANTHROPIC_API_KEY" => @starter}
      Application.put_env(:platform, :native_agent_login, "operator")
      assert NativeLogin.start_env(agent) == %{"ANTHROPIC_API_KEY" => @starter}
      refute NativeLogin.api_key_set?(agent)
    end

    test "an existing Burrow is left alone and never marked", %{admin: admin} do
      {:ok, agent} = Burrow.ensure(admin.id, "codex")

      assert {:ok, _space} = Starter.provision(admin)

      assert burrow_count() == 1
      assert Starter.state(agent) == nil
      refute Starter.active?(agent)
      assert NativeLogin.start_env(agent) == %{}
    end

    test "the handover landing is the conversation, or the picker without a key", %{admin: admin} do
      assert "/chat/getting-started-" <> _ = Starter.handover_landing(admin)

      put_starter(nil)
      assert Starter.handover_landing(admin) == "/setup/connect-ai"
    end

    test "the allowance line is in Burrow's instructions while it is on the starter", %{
      admin: admin
    } do
      {:ok, _space} = Starter.provision(admin)
      agent = Burrow.get()

      assert instructions(agent) =~ "Your allowance (generated at start)"
      {:ok, _} = Burrow.ensure(admin.id, "claude_code")
      refute instructions(agent) =~ "Your allowance (generated at start)"
    end
  end

  describe "swap-over" do
    setup %{admin: admin} do
      {:ok, _space} = Starter.provision(admin)
      %{agent: Burrow.get()}
    end

    test "choosing ChatGPT retires the starter and moves the harness", %{admin: admin, agent: a} do
      assert {:ok, _} = Burrow.ensure(admin.id, "codex")

      assert Starter.state(a) == "retired"
      assert Burrow.harness(a) == "codex"
      assert NativeLogin.start_env(a) == %{}
    end

    test "choosing Claude Pro or Max keeps the harness but drops the key", %{
      admin: admin,
      agent: a
    } do
      assert NativeLogin.start_env(a) == %{"ANTHROPIC_API_KEY" => @starter}

      assert {:ok, _} = Burrow.ensure(admin.id, "claude_code")

      assert Starter.state(a) == "retired"
      assert Burrow.harness(a) == "claude_code"
      assert NativeLogin.start_env(a) == %{}
      Application.put_env(:platform, :native_agent_login, "operator")
      assert NativeLogin.start_env(a) == %{}
    end

    test "the owner's own API key replaces the starter key", %{admin: admin, agent: a} do
      assert {:ok, _} = Burrow.ensure(admin.id, "claude_code")
      assert :ok = NativeLogin.put_api_key(admin.id, a, @own)

      assert NativeLogin.start_env(a) == %{"ANTHROPIC_API_KEY" => @own}
    end

    test "a retired starter is not revived by a restart or a second sign-in", %{
      admin: admin,
      agent: a
    } do
      {:ok, _} = Burrow.ensure(admin.id, "codex")

      # The env var is still set (a core restart reads it again); the mark is not.
      assert Starter.configured?()
      assert {:ok, _space} = Starter.provision(admin)
      assert Starter.state(a) == "retired"
      refute Starter.active?(a)
      assert Starter.key_for(a) == nil
      assert NativeLogin.start_env(a) == %{}
    end
  end

  defp instructions(agent) do
    NativeAgents.start_files(agent)
    |> Enum.find(&(&1["key"] in ["CLAUDE.md", "AGENTS.md"]))
    |> Map.fetch!("content")
  end
end
