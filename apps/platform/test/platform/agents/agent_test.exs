defmodule Platform.Agents.AgentTest do
  @moduledoc """
  Tests for Agent schemas and changesets.

  Changeset-only tests use ExUnit.Case (no DB required).
  DB round-trip tests (slug uniqueness, workspace file, memory ordering)
  use Platform.DataCase and require a running Postgres instance.
  """
  use ExUnit.Case, async: true

  alias Platform.Agents.Agent
  alias Platform.Agents.Memory
  alias Platform.Agents.WorkspaceFile

  @valid_agent_attrs %{
    slug: "my-agent",
    name: "My Agent",
    status: "active",
    workspace_id: nil
  }

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  describe "Agent changeset/2" do
    test "valid changeset with required fields" do
      changeset = Agent.changeset(%Agent{}, @valid_agent_attrs)
      assert changeset.valid?
    end

    test "invalid status is rejected" do
      changeset = Agent.changeset(%Agent{}, Map.put(@valid_agent_attrs, :status, "unknown"))
      refute changeset.valid?
      assert %{status: [_]} = errors_on(changeset)
    end

    test "all valid statuses are accepted" do
      for status <- ~w(active paused archived) do
        changeset = Agent.changeset(%Agent{}, Map.put(@valid_agent_attrs, :status, status))
        assert changeset.valid?, "expected status=#{status} to be valid"
      end
    end

    test "missing slug fails validation" do
      changeset = Agent.changeset(%Agent{}, Map.delete(@valid_agent_attrs, :slug))
      refute changeset.valid?
      assert %{slug: ["can't be blank"]} = errors_on(changeset)
    end

    test "missing name fails validation" do
      changeset = Agent.changeset(%Agent{}, Map.delete(@valid_agent_attrs, :name))
      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "all valid kinds are accepted with their required field complements" do
      for kind <- Agent.valid_kinds() do
        attrs =
          case kind do
            "native" ->
              Map.put(@valid_agent_attrs, :kind, "native")

            "external" ->
              @valid_agent_attrs
              |> Map.put(:kind, "external")
              |> Map.put(:endpoint_kind, "openai_compat")
              |> Map.put(:base_url, "https://api.openai.com/v1")
              |> Map.put(:model, "gpt-4o-mini")
          end

        changeset = Agent.changeset(%Agent{}, attrs)
        assert changeset.valid?, "expected kind=#{kind} to be valid with its required complements"
      end
    end
  end

  describe "Agent changeset/2 — external kind" do
    @external_attrs %{
      slug: "ext-agent",
      name: "Ext Agent",
      status: "active",
      workspace_id: nil,
      kind: "external",
      endpoint_kind: "openai_compat",
      base_url: "https://api.openai.com/v1",
      model: "gpt-4o-mini"
    }

    test "valid external agent with all required fields" do
      changeset = Agent.changeset(%Agent{}, @external_attrs)
      assert changeset.valid?
    end

    test "kind=external missing endpoint_kind is invalid" do
      attrs = Map.delete(@external_attrs, :endpoint_kind)
      changeset = Agent.changeset(%Agent{}, attrs)
      refute changeset.valid?
      assert %{endpoint_kind: ["can't be blank"]} = errors_on(changeset)
    end

    test "kind=external missing base_url is invalid" do
      attrs = Map.delete(@external_attrs, :base_url)
      changeset = Agent.changeset(%Agent{}, attrs)
      refute changeset.valid?
      assert %{base_url: ["can't be blank"]} = errors_on(changeset)
    end

    test "kind=external missing model is invalid" do
      attrs = Map.delete(@external_attrs, :model)
      changeset = Agent.changeset(%Agent{}, attrs)
      refute changeset.valid?
      assert %{model: ["can't be blank"]} = errors_on(changeset)
    end

    test "kind=external with bogus endpoint_kind is invalid" do
      attrs = Map.put(@external_attrs, :endpoint_kind, "bogus")
      changeset = Agent.changeset(%Agent{}, attrs)
      refute changeset.valid?
      assert %{endpoint_kind: [msg]} = errors_on(changeset)
      assert msg =~ "is invalid"
    end

    test "kind=external with non-URL base_url is invalid" do
      attrs = Map.put(@external_attrs, :base_url, "not a url")
      changeset = Agent.changeset(%Agent{}, attrs)
      refute changeset.valid?
      assert %{base_url: ["must be an http(s) URL"]} = errors_on(changeset)
    end

    test "kind=external with non-http scheme is invalid" do
      attrs = Map.put(@external_attrs, :base_url, "ftp://x")
      changeset = Agent.changeset(%Agent{}, attrs)
      refute changeset.valid?
      assert %{base_url: ["must be an http(s) URL"]} = errors_on(changeset)
    end

    test "kind=external with nil vault_key is valid (ephemeral path)" do
      attrs =
        @external_attrs
        |> Map.put(:base_url, "https://example.com")
        |> Map.put(:vault_key, nil)

      changeset = Agent.changeset(%Agent{}, attrs)
      assert changeset.valid?
    end

    test "kind=native with endpoint_kind set is invalid" do
      attrs =
        @valid_agent_attrs
        |> Map.put(:kind, "native")
        |> Map.put(:endpoint_kind, "openai_compat")

      changeset = Agent.changeset(%Agent{}, attrs)
      refute changeset.valid?
      assert %{endpoint_kind: [msg]} = errors_on(changeset)
      assert msg =~ "can only be set when kind is external"
    end

    test "kind=native with base_url set is invalid" do
      attrs =
        @valid_agent_attrs
        |> Map.put(:kind, "native")
        |> Map.put(:base_url, "https://x")

      changeset = Agent.changeset(%Agent{}, attrs)
      refute changeset.valid?
      assert %{base_url: [msg]} = errors_on(changeset)
      assert msg =~ "can only be set when kind is external"
    end
  end

  describe "Agent changeset/2 — probe + liveness columns (M5)" do
    test "casts all four probe + liveness fields" do
      now = DateTime.utc_now()

      attrs =
        @valid_agent_attrs
        |> Map.put(:last_probe_at, now)
        |> Map.put(:last_probe_status, "ok")
        |> Map.put(:last_probe_latency_ms, 42)
        |> Map.put(:last_successful_fire_at, now)

      changeset = Agent.changeset(%Agent{}, attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :last_probe_at) == now
      assert Ecto.Changeset.get_field(changeset, :last_probe_status) == "ok"
      assert Ecto.Changeset.get_field(changeset, :last_probe_latency_ms) == 42
      assert Ecto.Changeset.get_field(changeset, :last_successful_fire_at) == now
    end

    test "probe + liveness fields are optional (nil is valid)" do
      changeset = Agent.changeset(%Agent{}, @valid_agent_attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :last_probe_at) == nil
      assert Ecto.Changeset.get_field(changeset, :last_probe_status) == nil
      assert Ecto.Changeset.get_field(changeset, :last_probe_latency_ms) == nil
      assert Ecto.Changeset.get_field(changeset, :last_successful_fire_at) == nil
    end
  end

  describe "WorkspaceFile changeset/2" do
    test "valid changeset with all required fields" do
      changeset =
        WorkspaceFile.changeset(%WorkspaceFile{}, %{
          agent_id: Ecto.UUID.generate(),
          file_key: "SOUL.md",
          content: "You are a helpful agent."
        })

      assert changeset.valid?
    end

    test "missing file_key fails validation" do
      changeset =
        WorkspaceFile.changeset(%WorkspaceFile{}, %{
          agent_id: Ecto.UUID.generate(),
          content: "content"
        })

      refute changeset.valid?
      assert %{file_key: ["can't be blank"]} = errors_on(changeset)
    end

    test "version defaults to 1" do
      changeset =
        WorkspaceFile.changeset(%WorkspaceFile{}, %{
          agent_id: Ecto.UUID.generate(),
          file_key: "MEMORY.md",
          content: "mem"
        })

      assert changeset.valid?
      # default version is 1 via schema
      assert Ecto.Changeset.get_field(changeset, :version) == 1
    end
  end

  describe "Memory changeset/2" do
    test "memory changeset validates required fields" do
      changeset = Memory.changeset(%Memory{}, %{})
      refute changeset.valid?

      errors = errors_on(changeset)
      assert Map.has_key?(errors, :agent_id)
      assert Map.has_key?(errors, :memory_type)
      assert Map.has_key?(errors, :content)
    end

    test "invalid memory_type is rejected" do
      changeset =
        Memory.changeset(%Memory{}, %{
          agent_id: Ecto.UUID.generate(),
          memory_type: "invalid",
          content: "some content"
        })

      refute changeset.valid?
      assert %{memory_type: [_]} = errors_on(changeset)
    end

    test "all valid memory types are accepted" do
      for memory_type <- ~w(long_term daily snapshot) do
        changeset =
          Memory.changeset(%Memory{}, %{
            agent_id: Ecto.UUID.generate(),
            memory_type: memory_type,
            content: "content"
          })

        assert changeset.valid?, "expected memory_type=#{memory_type} to be valid"
      end
    end
  end
end

defmodule Platform.Agents.AgentDBTest do
  @moduledoc """
  DB round-trip tests for Agent schemas.
  Requires a running Postgres instance with migrations applied.
  """
  use Platform.DataCase, async: true

  alias Platform.Agents.Agent
  alias Platform.Agents.Memory
  alias Platform.Agents.WorkspaceFile
  alias Platform.Repo

  @valid_agent_attrs %{
    slug: "my-agent",
    name: "My Agent",
    status: "active",
    workspace_id: nil
  }

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  describe "Agent slug uniqueness" do
    test "slug uniqueness is enforced within a workspace" do
      workspace_id = Ecto.UUID.generate()
      attrs = Map.put(@valid_agent_attrs, :workspace_id, workspace_id)

      assert {:ok, _agent} = Repo.insert(Agent.changeset(%Agent{}, attrs))

      assert {:error, changeset} = Repo.insert(Agent.changeset(%Agent{}, attrs))
      assert %{slug: [_]} = errors_on(changeset)
    end

    test "same slug is allowed in different workspaces" do
      attrs1 = Map.put(@valid_agent_attrs, :workspace_id, Ecto.UUID.generate())
      attrs2 = Map.put(@valid_agent_attrs, :workspace_id, Ecto.UUID.generate())

      assert {:ok, _} = Repo.insert(Agent.changeset(%Agent{}, attrs1))
      assert {:ok, _} = Repo.insert(Agent.changeset(%Agent{}, attrs2))
    end
  end

  describe "WorkspaceFile round-trip with version" do
    test "workspace file can be inserted and retrieved with version" do
      {:ok, agent} = Repo.insert(Agent.changeset(%Agent{}, @valid_agent_attrs))

      file_attrs = %{
        agent_id: agent.id,
        file_key: "SOUL.md",
        content: "You are a helpful agent.",
        version: 1
      }

      assert {:ok, file} = Repo.insert(WorkspaceFile.changeset(%WorkspaceFile{}, file_attrs))
      assert file.file_key == "SOUL.md"
      assert file.version == 1

      updated =
        file
        |> WorkspaceFile.changeset(%{content: "Updated soul.", version: 2})
        |> Repo.update!()

      assert updated.version == 2
      assert updated.content == "Updated soul."
    end

    test "unique_key constraint prevents duplicate file_key per agent" do
      {:ok, agent} = Repo.insert(Agent.changeset(%Agent{}, @valid_agent_attrs))

      file_attrs = %{agent_id: agent.id, file_key: "MEMORY.md", content: "mem"}

      assert {:ok, _} = Repo.insert(WorkspaceFile.changeset(%WorkspaceFile{}, file_attrs))

      assert {:error, changeset} =
               Repo.insert(WorkspaceFile.changeset(%WorkspaceFile{}, file_attrs))

      assert %{file_key: [_]} = errors_on(changeset)
    end
  end

  describe "Agent probe + liveness columns round-trip (M5)" do
    test "all four probe + liveness columns round-trip through the DB" do
      probe_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      fire_at = DateTime.add(probe_at, -120, :second)

      attrs =
        @valid_agent_attrs
        |> Map.put(:workspace_id, Ecto.UUID.generate())
        |> Map.put(:last_probe_at, probe_at)
        |> Map.put(:last_probe_status, "ok")
        |> Map.put(:last_probe_latency_ms, 123)
        |> Map.put(:last_successful_fire_at, fire_at)

      {:ok, inserted} = Repo.insert(Agent.changeset(%Agent{}, attrs))

      loaded = Repo.get!(Agent, inserted.id)
      assert loaded.last_probe_at == probe_at
      assert loaded.last_probe_status == "ok"
      assert loaded.last_probe_latency_ms == 123
      assert loaded.last_successful_fire_at == fire_at
    end

    test "probe + liveness columns default to nil on insert" do
      attrs = Map.put(@valid_agent_attrs, :workspace_id, Ecto.UUID.generate())

      {:ok, inserted} = Repo.insert(Agent.changeset(%Agent{}, attrs))

      loaded = Repo.get!(Agent, inserted.id)
      assert loaded.last_probe_at == nil
      assert loaded.last_probe_status == nil
      assert loaded.last_probe_latency_ms == nil
      assert loaded.last_successful_fire_at == nil
    end

    test "lightweight Ecto.Changeset.change/2 update can write probe fields without slug/name" do
      attrs = Map.put(@valid_agent_attrs, :workspace_id, Ecto.UUID.generate())
      {:ok, agent} = Repo.insert(Agent.changeset(%Agent{}, attrs))

      probe_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      {:ok, updated} =
        agent
        |> Ecto.Changeset.change(%{
          last_probe_at: probe_at,
          last_probe_status: "http_error",
          last_probe_latency_ms: 999
        })
        |> Repo.update()

      assert updated.last_probe_status == "http_error"
      assert updated.last_probe_latency_ms == 999
      assert updated.last_probe_at == probe_at
      # original fields untouched
      assert updated.slug == agent.slug
      assert updated.name == agent.name
    end
  end

  describe "Agent avatar columns round-trip (task 01a00122 stage 1)" do
    test "avatar_url and avatar_storage_key round-trip through the DB" do
      storage_key = "agent-avatars/#{Ecto.UUID.generate()}/#{Ecto.UUID.generate()}-face.png"

      attrs =
        @valid_agent_attrs
        |> Map.put(:workspace_id, Ecto.UUID.generate())
        |> Map.put(:avatar_url, "/agents/abc/avatar")
        |> Map.put(:avatar_storage_key, storage_key)

      {:ok, inserted} = Repo.insert(Agent.changeset(%Agent{}, attrs))

      loaded = Repo.get!(Agent, inserted.id)
      assert loaded.avatar_url == "/agents/abc/avatar"
      assert loaded.avatar_storage_key == storage_key
    end

    test "avatar columns default to nil — an agent without a face is still valid" do
      attrs = Map.put(@valid_agent_attrs, :workspace_id, Ecto.UUID.generate())

      {:ok, inserted} = Repo.insert(Agent.changeset(%Agent{}, attrs))

      loaded = Repo.get!(Agent, inserted.id)
      assert loaded.avatar_url == nil
      assert loaded.avatar_storage_key == nil
    end

    test "replacing an avatar overwrites both columns, so the old key is recoverable first" do
      attrs =
        @valid_agent_attrs
        |> Map.put(:workspace_id, Ecto.UUID.generate())
        |> Map.put(:avatar_url, "/agents/abc/avatar")
        |> Map.put(:avatar_storage_key, "agent-avatars/a/old.png")

      {:ok, agent} = Repo.insert(Agent.changeset(%Agent{}, attrs))

      # The whole reason avatar_storage_key exists: the caller reads the
      # previous key off the row before writing the new one, so the old
      # blob can be deleted instead of leaked.
      previous_key = agent.avatar_storage_key

      {:ok, updated} =
        Repo.update(Agent.changeset(agent, %{avatar_storage_key: "agent-avatars/a/new.webp"}))

      assert previous_key == "agent-avatars/a/old.png"
      assert updated.avatar_storage_key == "agent-avatars/a/new.webp"
    end
  end

  describe "Memory bigserial ordering" do
    test "memories are ordered by bigserial id (monotonically increasing)" do
      {:ok, agent} = Repo.insert(Agent.changeset(%Agent{}, @valid_agent_attrs))

      base_attrs = %{agent_id: agent.id, memory_type: "long_term"}

      {:ok, m1} =
        Repo.insert(Memory.changeset(%Memory{}, Map.put(base_attrs, :content, "First memory")))

      {:ok, m2} =
        Repo.insert(Memory.changeset(%Memory{}, Map.put(base_attrs, :content, "Second memory")))

      {:ok, m3} =
        Repo.insert(Memory.changeset(%Memory{}, Map.put(base_attrs, :content, "Third memory")))

      assert m1.id < m2.id
      assert m2.id < m3.id
    end
  end
end
