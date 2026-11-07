defmodule Platform.AgentHost.NoLoginRelayTest do
  @moduledoc """
  What core holds of a Claude login (task 01a17b10 stage 1, amended by task
  01a1b365 stage 2).

  The rule now: the owner's own Claude sign-in URL and pasted code travel only
  in the ref'd request and reply of `AgentHost.claude_login_start/3` and
  `claude_login_submit/4`. `Platform.AgentHost.State`, host observations, the
  `agent_host:status` broadcasts, the audit log and tool results still hold
  nothing URL- or code-shaped, before, during and after a full login.

  A host observation for a `needs_login` agent may carry whatever its
  reporter put under `login`, including a login URL. Core keeps the state and
  the step name only.

  The guards at the bottom grep the core library and the agent host's source
  for the names a relayed login URL travelled under before task 01a17b10
  (`login_url`, `login.url`, `login?.url`) and assert none is left, and walk
  every lib module's code for `Platform.AgentHost.LoginCode`: only the
  allowlisted modules may carry one, and only the channel and the dev
  stand-in host may unwrap it.

  Mutants these name:

    * store `payload["login"]["url"]` again (a `login_url` field on the
      State entry) → "an observation's login url is not stored" goes red, and
      so does the guard;
    * copy `login.url` into the observation in services/agent-host/src →
      the guard goes red (and the bun unit test does too);
    * put the sign-in URL into State in `AgentHost.claude_login_start/3` →
      "a full Claude login leaves nothing URL- or code-shaped" goes red;
    * carry or unwrap a LoginCode in any other lib module → the allowlist
      guard goes red.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.AgentHost
  alias Platform.AgentHost.{FakeHost, LoginCode, Reconciler, State}
  alias Platform.Agents.NativeAgents
  alias Platform.Chat
  alias Platform.Federation.ToolSurface
  alias Platform.Repo

  @url "https://claude.com/cai/oauth/authorize?code=true&state=RELAYSTATE01a17b10"
  @repo_root Path.expand("../../../../..", __DIR__)
  @guarded_dirs ["apps/platform/lib", "services/agent-host/src"]
  @forbidden ["login_url", "login.url", "login?.url"]

  # The only lib modules whose CODE may name `Platform.AgentHost.LoginCode`
  # (task 01a1b365), and the only ones that may call `LoginCode.reveal/1`.
  # Connect AI (stage 3) wraps the pasted code and hands it on; it never
  # unwraps one.
  @login_code_allowlist [
    "apps/platform/lib/platform_web/live/connect_ai_live.ex",
    "apps/platform/lib/platform/agent_host/login_code.ex",
    "apps/platform/lib/platform/agent_host.ex",
    "apps/platform/lib/platform/agent_host/reconciler.ex",
    "apps/platform/lib/platform/agent_host/fake_host.ex",
    "apps/platform/lib/platform_web/channels/agent_host_channel.ex"
  ]
  @reveal_allowlist [
    "apps/platform/lib/platform/agent_host/login_code.ex",
    "apps/platform/lib/platform/agent_host/fake_host.ex",
    "apps/platform/lib/platform_web/channels/agent_host_channel.ex"
  ]

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

  # URL-shaped, or carrying the stubbed host's known-good code (in full or in
  # part), raw or wrapped.
  defp url_or_code_shaped?(term) do
    text = inspect(term, limit: :infinity, printable_limit: :infinity, structs: false)

    url_shaped?(term) or text =~ FakeHost.claude_login_code() or
      text =~ "fake-claude-login-code" or text =~ "fake-agent-host" or text =~ "LoginCode"
  end

  defp tool_results(agent) do
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

    for {tool, args} <- [
          {"space_list_agents", %{"space_id" => space.id}},
          {"federation_status", %{}}
        ] do
      {tool, ToolSurface.execute(tool, args, context)}
    end
  end

  defp drain_status(acc) do
    receive do
      {:agent_host_status, _} = msg -> drain_status([msg | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  # Every alias of `Platform.AgentHost.LoginCode` in a file's code (not its
  # docs or comments, which the parser does not turn into aliases), and every
  # call to `LoginCode.reveal`.
  defp login_code_uses(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!()

    {_, acc} =
      Macro.prewalk(ast, %{alias: false, reveal: false}, fn
        {{:., _, [{:__aliases__, _, parts}, :reveal]}, _, _} = node, acc ->
          if List.last(parts) == :LoginCode,
            do: {node, %{acc | alias: true, reveal: true}},
            else: {node, acc}

        {:__aliases__, _, parts} = node, acc ->
          if :LoginCode in parts, do: {node, %{acc | alias: true}}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    acc
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

  describe "a full Claude login (task 01a1b365)" do
    setup %{host: host} do
      # Make way for the stubbed host: one host per install.
      Process.unlink(host)
      Process.exit(host, :kill)
      ref = Process.monitor(host)
      assert_receive {:DOWN, ^ref, :process, ^host, _}
      start_supervised!(Platform.FakeAgentHost)
      :ok
    end

    test "leaves nothing URL- or code-shaped in State, broadcasts, audit or tools", %{
      agent: agent,
      owner: owner
    } do
      since = DateTime.utc_now() |> DateTime.add(-1, :second)
      :ok = AgentHost.subscribe()
      {:ok, code} = LoginCode.new(FakeHost.claude_login_code())

      assert {:ok, url} = AgentHost.claude_login_start(owner, agent)
      # Positive control: the predicate sees the URL and the code.
      assert url_or_code_shaped?(url)
      assert url_or_code_shaped?(LoginCode.reveal(code))

      # During: a login is pending.
      refute url_or_code_shaped?(State.all())
      refute url_or_code_shaped?(AgentHost.status(agent))

      assert {:ok, %{account: "owner@example.com"}} =
               AgentHost.claude_login_submit(owner, agent, code)

      # After.
      refute url_or_code_shaped?(State.all())
      refute url_or_code_shaped?(AgentHost.status(agent))
      refute url_or_code_shaped?(:sys.get_state(Reconciler))
      refute url_or_code_shaped?(drain_status([]))

      audit =
        Repo.all(
          from(e in Platform.Audit.Event,
            where: e.inserted_at >= ^since
          )
        )

      refute url_or_code_shaped?(audit)

      for {tool, result} <- tool_results(agent) do
        refute url_or_code_shaped?(result), "#{tool} returned a login value: #{inspect(result)}"
      end
    end
  end

  describe "guard: only the allowlisted modules carry a LoginCode" do
    test "apps/platform/lib names LoginCode in code only in the allowlist" do
      files = Path.wildcard(Path.join([@repo_root, "apps/platform/lib", "**", "*.{ex,exs}"]))

      uses =
        for path <- files,
            use = login_code_uses(path),
            use.alias,
            into: %{},
            do: {Path.relative_to(path, @repo_root), use}

      # Positive control: the walk finds the real carriers.
      assert Map.has_key?(uses, "apps/platform/lib/platform_web/channels/agent_host_channel.ex")
      assert Map.has_key?(uses, "apps/platform/lib/platform/agent_host/reconciler.ex")
      assert uses["apps/platform/lib/platform_web/channels/agent_host_channel.ex"].reveal

      assert Map.keys(uses) -- @login_code_allowlist == []

      revealers = for {path, %{reveal: true}} <- uses, do: path
      assert revealers -- @reveal_allowlist == []
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
