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
