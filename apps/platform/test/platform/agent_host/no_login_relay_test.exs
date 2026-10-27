defmodule Platform.AgentHost.NoLoginRelayTest do
  @moduledoc """
  Burrow never relays or handles a Claude login (task 01a17b10 stage 1).

  A host observation for a `needs_login` agent may carry whatever its
  reporter put under `login`, including a login URL. Core keeps the state and
  the step name only: nothing URL-shaped reaches `Platform.AgentHost.State`,
  and no tool result for that agent contains it.

  The guard at the bottom greps the core library and the agent host's source
  for the names a relayed login URL travelled under before this task
  (`login_url`, `login.url`, `login?.url`) and asserts none is left.

  Mutants these name:

    * store `payload["login"]["url"]` again (a `login_url` field on the
      State entry) → "an observation's login url is not stored" goes red, and
      so does the guard;
    * copy `login.url` into the observation in services/agent-host/src →
      the guard goes red (and the bun unit test does too).
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.AgentHost
  alias Platform.AgentHost.{Reconciler, State}
  alias Platform.Agents.NativeAgents
  alias Platform.Chat
  alias Platform.Federation.ToolSurface
  alias Platform.Repo

  @url "https://claude.com/cai/oauth/authorize?code=true&state=RELAYSTATE01a17b10"
  @repo_root Path.expand("../../../../..", __DIR__)
  @guarded_dirs ["apps/platform/lib", "services/agent-host/src"]
  @forbidden ["login_url", "login.url", "login?.url"]

  setup do
    previous = Application.get_env(:platform, :agent_host_token)
    Application.put_env(:platform, :agent_host_token, "agent-host-token-01a17b10-s1")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, :agent_host_token, previous),
        else: Application.delete_env(:platform, :agent_host_token)
    end)

    n = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        email: "no-login-relay-#{n}@example.com",
        name: "No login relay #{n}",
        oidc_sub: "oidc-no-login-relay-#{n}"
      })

    {:ok, agent, _runtime} =
      NativeAgents.create(owner.id, %{name: "Relay #{n}", harness: "claude_code"})

    host = spawn_link(fn -> receive_forever() end)
    :ok = Reconciler.host_joined(host, %{"profile" => "contained"})

    %{agent: agent, host: host, owner: owner}
  end

  defp receive_forever do
    receive do
      _ -> receive_forever()
    end
  end

  defp url_shaped?(term) do
    text = inspect(term, limit: :infinity, printable_limit: :infinity)
    text =~ "https://" or text =~ "oauth" or text =~ "RELAYSTATE01a17b10"
  end

  describe "an observation carrying login.url" do
    test "stores nothing URL-shaped in State; the state and step are kept", %{
      agent: agent,
      host: host
    } do
      :ok =
        Reconciler.agent_state(host, %{
          "agent_id" => agent.id,
          "state" => "needs_login",
          "detail" => "login_url",
          "login" => %{"step" => "login_url", "url" => @url}
        })

      entry = State.get(agent.id)
      # Positive control: the observation WAS recorded.
      assert %{state: :needs_login, detail: "login_url"} = entry
      refute Map.has_key?(entry, :login_url)
      refute Map.has_key?(entry, :login)
      refute url_shaped?(entry)
      refute url_shaped?(AgentHost.status(agent))
      refute url_shaped?(State.all())
    end

    test "an inventory carrying login.url stores nothing URL-shaped either", %{
      agent: agent,
      host: host
    } do
      :ok =
        Reconciler.inventory(host, %{
          "agents" => [
            %{
              "agent_id" => agent.id,
              "state" => "needs_login",
              "login" => %{"step" => "login_url", "url" => @url}
            }
          ]
        })

      assert %{state: :needs_login} = State.get(agent.id)
      refute url_shaped?(State.all())
    end

    test "no tool result for that agent contains it", %{agent: agent, host: host} do
      :ok =
        Reconciler.agent_state(host, %{
          "agent_id" => agent.id,
          "state" => "needs_login",
          "login" => %{"step" => "login_url", "url" => @url}
        })

      n = System.unique_integer([:positive])

      {:ok, space} =
        Chat.create_space(%{name: "Relay #{n}", slug: "relay-#{n}", kind: "channel"})

      {:ok, _} =
        Chat.add_participant(space.id, %{
          participant_type: "agent",
          participant_id: agent.id,
          display_name: agent.name,
          joined_at: DateTime.utc_now()
        })

      context = %{agent_id: agent.id, space_id: space.id}

      results =
        for {tool, args} <- [
              {"space_list_agents", %{"space_id" => space.id}},
              {"federation_status", %{}}
            ] do
          {tool, ToolSurface.execute(tool, args, context)}
        end

      # Positive control: the agent is in the listing.
      {"space_list_agents", listing} = List.keyfind(results, "space_list_agents", 0)
      assert inspect(listing) =~ agent.id

      for {tool, result} <- results do
        refute url_shaped?(result), "#{tool} returned a login URL: #{inspect(result)}"
      end
    end
  end

  describe "guard: no login URL path is left" do
    test "apps/platform/lib and services/agent-host/src never name login_url or login.url" do
      files =
        for dir <- @guarded_dirs,
            path <- Path.wildcard(Path.join([@repo_root, dir, "**", "*.{ex,exs,ts}"])),
            do: path

      # Positive control: the scan reads real source, including the files the
      # URL used to travel through.
      rels = Enum.map(files, &Path.relative_to(&1, @repo_root))
      assert "apps/platform/lib/platform/agent_host/reconciler.ex" in rels
      assert "apps/platform/lib/platform/agent_host/state.ex" in rels
      assert "services/agent-host/src/agents.ts" in rels

      hits =
        for path <- files,
            {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
            needle <- @forbidden,
            String.contains?(line, needle),
            do: "#{Path.relative_to(path, @repo_root)}:#{n}: #{String.trim(line)}"

      assert hits == []
    end
  end
end
