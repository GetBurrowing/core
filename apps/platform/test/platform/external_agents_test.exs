defmodule Platform.ExternalAgentsTest do
  @moduledoc """
  Tests for the `Platform.ExternalAgents` context.

  Covers the kind-gating invariants:
    * `create_external_agent/1` forces `kind: "external"`
    * `update_external_agent/2` strips `:kind` and raises on non-external rows
    * `get_external_agent/1` and `list_external_agents/1` filter by kind
    * `delete_external_agent/1` works on external rows
  """
  use Platform.DataCase, async: true

  alias Platform.Agents.Agent
  alias Platform.ExternalAgents
  alias Platform.Repo

  @valid_external_attrs %{
    slug: "ext-agent",
    name: "Ext Agent",
    status: "active",
    workspace_id: nil,
    endpoint_kind: "openai_compat",
    base_url: "https://api.openai.com/v1",
    model: "gpt-4o-mini"
  }

  defp unique_attrs(overrides \\ %{}) do
    suffix = System.unique_integer([:positive])

    @valid_external_attrs
    |> Map.put(:slug, "ext-agent-#{suffix}")
    |> Map.merge(overrides)
  end

  defp insert_native_agent!(overrides \\ %{}) do
    suffix = System.unique_integer([:positive])

    attrs =
      %{
        slug: "native-#{suffix}",
        name: "Native #{suffix}",
        status: "active",
        kind: "native",
        workspace_id: nil
      }
      |> Map.merge(overrides)

    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert!()
  end

  describe "create_external_agent/1" do
    test "inserts a row with kind=external" do
      assert {:ok, %Agent{} = agent} =
               ExternalAgents.create_external_agent(unique_attrs())

      assert agent.kind == "external"
      assert agent.endpoint_kind == "openai_compat"
      assert agent.base_url == "https://api.openai.com/v1"
      assert agent.model == "gpt-4o-mini"
    end

    test "forces kind=external even when caller passes kind=native" do
      assert {:ok, %Agent{} = agent} =
               ExternalAgents.create_external_agent(unique_attrs(%{kind: "native"}))

      assert agent.kind == "external"
    end

    test "forces kind=external when caller passes string-keyed kind=native" do
      attrs =
        unique_attrs()
        |> Map.put("kind", "native")

      assert {:ok, %Agent{} = agent} = ExternalAgents.create_external_agent(attrs)
      assert agent.kind == "external"
    end

    test "returns changeset error when required external fields are missing" do
      attrs = unique_attrs() |> Map.delete(:endpoint_kind)
      assert {:error, %Ecto.Changeset{} = cs} = ExternalAgents.create_external_agent(attrs)
      refute cs.valid?
    end
  end

  describe "update_external_agent/2" do
    test "updates an external agent" do
      {:ok, agent} = ExternalAgents.create_external_agent(unique_attrs())

      assert {:ok, %Agent{} = updated} =
               ExternalAgents.update_external_agent(agent, %{name: "Renamed"})

      assert updated.name == "Renamed"
      assert updated.kind == "external"
    end

    test "strips :kind from attrs (caller cannot flip to native via update)" do
      {:ok, agent} = ExternalAgents.create_external_agent(unique_attrs())

      assert {:ok, %Agent{} = updated} =
               ExternalAgents.update_external_agent(agent, %{kind: "native", name: "Still Ext"})

      assert updated.kind == "external"
      assert updated.name == "Still Ext"
    end

    test "strips string-keyed \"kind\" from attrs" do
      {:ok, agent} = ExternalAgents.create_external_agent(unique_attrs())

      assert {:ok, %Agent{} = updated} =
               ExternalAgents.update_external_agent(agent, %{"kind" => "native", "name" => "X"})

      assert updated.kind == "external"
    end

    test "raises ArgumentError when called on a kind=native agent" do
      native = insert_native_agent!()

      assert_raise ArgumentError, ~r/kind="native"/, fn ->
        ExternalAgents.update_external_agent(native, %{name: "won't apply"})
      end
    end
  end

  describe "get_external_agent/1" do
    test "returns the agent when kind=external" do
      {:ok, agent} = ExternalAgents.create_external_agent(unique_attrs())
      assert %Agent{id: id} = ExternalAgents.get_external_agent(agent.id)
      assert id == agent.id
    end

    test "returns nil for a native-kind agent with the same id" do
      native = insert_native_agent!()
      assert ExternalAgents.get_external_agent(native.id) == nil
    end

    test "returns nil when no row matches" do
      assert ExternalAgents.get_external_agent(Ecto.UUID.generate()) == nil
    end
  end

  describe "get_external_agent!/1" do
    test "returns the agent when kind=external" do
      {:ok, agent} = ExternalAgents.create_external_agent(unique_attrs())
      assert %Agent{id: id} = ExternalAgents.get_external_agent!(agent.id)
      assert id == agent.id
    end

    test "raises Ecto.NoResultsError on miss" do
      assert_raise Ecto.NoResultsError, fn ->
        ExternalAgents.get_external_agent!(Ecto.UUID.generate())
      end
    end

    test "raises Ecto.NoResultsError on kind mismatch" do
      native = insert_native_agent!()

      assert_raise Ecto.NoResultsError, fn ->
        ExternalAgents.get_external_agent!(native.id)
      end
    end
  end

  describe "list_external_agents/1" do
    test "returns only kind=external rows" do
      {:ok, ext} = ExternalAgents.create_external_agent(unique_attrs())
      _native = insert_native_agent!()

      ids = ExternalAgents.list_external_agents() |> Enum.map(& &1.id)
      assert ext.id in ids
      assert Enum.all?(ExternalAgents.list_external_agents(), &(&1.kind == "external"))
    end

    test "honors :endpoint_kind filter" do
      {:ok, openai} =
        ExternalAgents.create_external_agent(unique_attrs(%{endpoint_kind: "openai_compat"}))

      {:ok, ollama} =
        ExternalAgents.create_external_agent(
          unique_attrs(%{
            endpoint_kind: "ollama_native",
            base_url: "http://localhost:11434",
            model: "llama3"
          })
        )

      openai_ids =
        ExternalAgents.list_external_agents(endpoint_kind: "openai_compat") |> Enum.map(& &1.id)

      ollama_ids =
        ExternalAgents.list_external_agents(endpoint_kind: "ollama_native") |> Enum.map(& &1.id)

      assert openai.id in openai_ids
      refute ollama.id in openai_ids
      assert ollama.id in ollama_ids
      refute openai.id in ollama_ids
    end

    test "honors :workspace_id filter" do
      ws_a = Ecto.UUID.generate()
      ws_b = Ecto.UUID.generate()

      {:ok, a} = ExternalAgents.create_external_agent(unique_attrs(%{workspace_id: ws_a}))
      {:ok, b} = ExternalAgents.create_external_agent(unique_attrs(%{workspace_id: ws_b}))

      ws_a_ids = ExternalAgents.list_external_agents(workspace_id: ws_a) |> Enum.map(& &1.id)
      assert a.id in ws_a_ids
      refute b.id in ws_a_ids
    end

    test "default order is inserted_at DESC" do
      {:ok, first} = ExternalAgents.create_external_agent(unique_attrs())
      # Ensure a measurable time difference
      Process.sleep(2)
      {:ok, second} = ExternalAgents.create_external_agent(unique_attrs())

      ids = ExternalAgents.list_external_agents() |> Enum.map(& &1.id)
      first_idx = Enum.find_index(ids, &(&1 == first.id))
      second_idx = Enum.find_index(ids, &(&1 == second.id))

      assert first_idx != nil
      assert second_idx != nil
      assert second_idx < first_idx, "expected newer row to come first (inserted_at DESC)"
    end
  end

  describe "delete_external_agent/1" do
    test "removes an external row" do
      {:ok, agent} = ExternalAgents.create_external_agent(unique_attrs())
      assert {:ok, %Agent{}} = ExternalAgents.delete_external_agent(agent)
      assert ExternalAgents.get_external_agent(agent.id) == nil
    end
  end

  describe "liveness/2" do
    # Reference clock for all cases below. All durations are computed
    # relative to this so the assertions are easy to reason about.
    @now ~U[2026-06-01 12:00:00.000000Z]

    # Defaults from the moduledoc: 15 minutes / 1 hour.
    @liveness_window_ms 15 * 60 * 1000
    @probe_ok_window_ms 60 * 60 * 1000

    defp shift(now, offset_ms),
      do: DateTime.add(now, offset_ms, :millisecond)

    defp agent_with(overrides) do
      base = %Agent{
        kind: "external",
        last_successful_fire_at: nil,
        last_probe_at: nil,
        last_probe_status: nil
      }

      Map.merge(base, overrides)
    end

    test "1: nil fire + nil probe → :dead" do
      agent = agent_with(%{})
      assert ExternalAgents.liveness(agent, @now) == :dead
    end

    test "2: fire-fresh (within liveness_window) → :live" do
      # 1 minute ago — well inside the 15-minute window.
      agent = agent_with(%{last_successful_fire_at: shift(@now, -60_000)})
      assert ExternalAgents.liveness(agent, @now) == :live
    end

    test "3: fire-old + probe-ok-fresh (within probe_ok_window) → :stale" do
      # Fire 30 min ago (outside 15m liveness_window), probe 5 min ago
      # (well within 1h probe_ok_window) → :stale.
      agent =
        agent_with(%{
          last_successful_fire_at: shift(@now, -(@liveness_window_ms + 60_000)),
          last_probe_at: shift(@now, -5 * 60_000),
          last_probe_status: "ok"
        })

      assert ExternalAgents.liveness(agent, @now) == :stale
    end

    test "4: fire-old + probe-ok-stale (older than probe_ok_window) → :dead" do
      # Fire 30 min ago, probe 2 hours ago (outside 1h window).
      agent =
        agent_with(%{
          last_successful_fire_at: shift(@now, -(@liveness_window_ms + 60_000)),
          last_probe_at: shift(@now, -(@probe_ok_window_ms + 60_000)),
          last_probe_status: "ok"
        })

      assert ExternalAgents.liveness(agent, @now) == :dead
    end

    test "5: fire-old + probe-failed → :dead" do
      agent =
        agent_with(%{
          last_successful_fire_at: shift(@now, -(@liveness_window_ms + 60_000)),
          last_probe_at: shift(@now, -5 * 60_000),
          last_probe_status: "unauthorized"
        })

      assert ExternalAgents.liveness(agent, @now) == :dead
    end

    test "6: no-fire + probe-ok-fresh → :stale" do
      agent =
        agent_with(%{
          last_probe_at: shift(@now, -10 * 60_000),
          last_probe_status: "ok"
        })

      assert ExternalAgents.liveness(agent, @now) == :stale
    end

    test "7: no-fire + probe-failed → :dead" do
      agent =
        agent_with(%{
          last_probe_at: shift(@now, -2 * 60_000),
          last_probe_status: "timeout"
        })

      assert ExternalAgents.liveness(agent, @now) == :dead
    end

    test "8: no-fire + no-probe → :dead (duplicates case 1 explicitly)" do
      agent =
        agent_with(%{
          last_successful_fire_at: nil,
          last_probe_at: nil,
          last_probe_status: nil
        })

      assert ExternalAgents.liveness(agent, @now) == :dead
    end

    test "default `now` arg works (smoke)" do
      # Just verifies the default-arg head clauses match without
      # exploding; correctness is exercised above with pinned `now`.
      agent = agent_with(%{last_successful_fire_at: DateTime.utc_now()})
      assert ExternalAgents.liveness(agent) == :live
    end
  end

  describe "probe/1" do
    # Mirrors the Req.Test stub pattern used in
    # Platform.Memory.Providers.StartupSuiteTest and
    # Platform.Agents.Providers.CodexTest: register a named stub keyed
    # for this suite, point the injected Req client at it via
    # `Application.put_env/3`, and clear the env on exit.
    setup do
      {:ok, _} = Application.ensure_all_started(:req)

      Application.put_env(
        :platform,
        :external_agents_req_client,
        Req.new(plug: {Req.Test, :external_agents_test})
      )

      on_exit(fn ->
        Application.delete_env(:platform, :external_agents_req_client)
      end)

      :ok
    end

    defp probe_agent_fixture(endpoint_kind, overrides \\ %{}) do
      suffix = System.unique_integer([:positive])

      base = %{
        slug: "probe-test-#{suffix}",
        name: "Probe Test #{suffix}",
        status: "active",
        kind: "external",
        endpoint_kind: endpoint_kind,
        base_url: "https://example.test",
        model: "test-model",
        metadata: %{"_probe_token" => "sk-test"}
      }

      %Agent{}
      |> Ecto.Changeset.change(Map.merge(base, overrides))
      |> Repo.insert!()
    end

    test "openai_compat happy path returns model_count and persists ok" do
      test_pid = self()

      Req.Test.stub(:external_agents_test, fn conn ->
        send(test_pid, {:probe_req, conn})

        Req.Test.json(conn, %{
          "data" => [
            %{"id" => "model-a"},
            %{"id" => "model-b"},
            %{"id" => "model-c"}
          ]
        })
      end)

      agent = probe_agent_fixture("openai_compat")

      assert {:ok, %{latency_ms: latency_ms, model_count: 3}} =
               ExternalAgents.probe(agent)

      assert is_integer(latency_ms) and latency_ms >= 0

      assert_receive {:probe_req, conn}
      assert conn.request_path == "/models"

      auth =
        conn.req_headers
        |> Enum.find_value(fn
          {"authorization", v} -> v
          _ -> nil
        end)

      assert auth == "Bearer sk-test"

      reloaded = Repo.get!(Agent, agent.id)
      assert reloaded.last_probe_status == "ok"
      assert reloaded.last_probe_latency_ms == latency_ms
      assert %DateTime{} = reloaded.last_probe_at
    end

    test "ollama_native happy path returns model_count and persists ok (no auth header)" do
      test_pid = self()

      Req.Test.stub(:external_agents_test, fn conn ->
        send(test_pid, {:probe_req, conn})

        Req.Test.json(conn, %{
          "models" => [
            %{"name" => "llama3"},
            %{"name" => "mistral"}
          ]
        })
      end)

      agent =
        probe_agent_fixture("ollama_native", %{
          base_url: "http://localhost:11434",
          model: "llama3"
        })

      assert {:ok, %{latency_ms: latency_ms, model_count: 2}} =
               ExternalAgents.probe(agent)

      assert latency_ms >= 0

      assert_receive {:probe_req, conn}
      assert conn.request_path == "/api/tags"

      refute Enum.any?(conn.req_headers, fn
               {"authorization", _} -> true
               _ -> false
             end)

      reloaded = Repo.get!(Agent, agent.id)
      assert reloaded.last_probe_status == "ok"
    end

    test "401 maps to :unauthorized and persists last_probe_status=\"unauthorized\"" do
      Req.Test.stub(:external_agents_test, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, "{}")
      end)

      agent = probe_agent_fixture("openai_compat")

      assert {:error, :unauthorized} = ExternalAgents.probe(agent)

      reloaded = Repo.get!(Agent, agent.id)
      assert reloaded.last_probe_status == "unauthorized"
      assert %DateTime{} = reloaded.last_probe_at
    end

    test "500 maps to :http_error and persists last_probe_status=\"http_error\"" do
      Req.Test.stub(:external_agents_test, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, "{}")
      end)

      agent = probe_agent_fixture("openai_compat")

      assert {:error, :http_error} = ExternalAgents.probe(agent)

      reloaded = Repo.get!(Agent, agent.id)
      assert reloaded.last_probe_status == "http_error"
      assert %DateTime{} = reloaded.last_probe_at
    end

    test "transport :nxdomain maps to :network_error and persists last_probe_status=\"network_error\"" do
      Req.Test.stub(:external_agents_test, fn conn ->
        Req.Test.transport_error(conn, :nxdomain)
      end)

      agent = probe_agent_fixture("openai_compat")

      assert {:error, :network_error} = ExternalAgents.probe(agent)

      reloaded = Repo.get!(Agent, agent.id)
      assert reloaded.last_probe_status == "network_error"
      assert %DateTime{} = reloaded.last_probe_at
    end
  end

  # ── UUID boundary (task 019fa129 stage 4) ────────────────────────────────
  #
  # The load-bearing input is the 16-CHARACTER one. `Ecto.UUID.cast/1`
  # hex-encodes any 16-byte binary and returns {:ok, _} while
  # `Ecto.UUID.dump/1` rejects it, so a suite built from "higgins" plus a
  # valid UUID is fully green against the bug. Do not prune the 16-character
  # cases as duplicates.
  describe "UUID boundary: the id:-keyed get_by pair" do
    @slug_16 "higginshigginsxx"

    test "get_external_agent/1 returns nil for a malformed id" do
      # `Repo.get_by(Agent, id: id, kind: _)` raises exactly like Repo.get/2 —
      # the id: keyword is pinned against the same strict UUIDv7 key. This
      # spelling is invisible to `git grep "Repo.get("`.
      assert ExternalAgents.get_external_agent("higgins") == nil
      assert ExternalAgents.get_external_agent(@slug_16) == nil
      assert ExternalAgents.get_external_agent("") == nil
    end

    test "get_external_agent!/1 raises Ecto.NoResultsError, not Ecto.Query.CastError" do
      # The bang twin the plan missed. Its DOCUMENTED contract is
      # NoResultsError on a miss; a malformed id is a miss, not a new
      # exception class for callers to learn about.
      assert_raise Ecto.NoResultsError, fn -> ExternalAgents.get_external_agent!(@slug_16) end
      assert_raise Ecto.NoResultsError, fn -> ExternalAgents.get_external_agent!("higgins") end
    end
  end
end
