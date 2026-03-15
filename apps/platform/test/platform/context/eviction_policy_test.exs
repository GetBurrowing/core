defmodule Platform.Context.EvictionPolicyTest do
  @moduledoc """
  Tests for Platform.Context.EvictionPolicy: promotion rules,
  deterministic eviction by scope, and lifecycle hooks.
  """
  use ExUnit.Case, async: false

  alias Platform.Context
  alias Platform.Context.{Cache, EvictionPolicy, Session}

  defp uid, do: "#{System.unique_integer([:positive, :monotonic])}"

  defp open!(scope) do
    {:ok, _} = Context.ensure_session(scope)
    scope
  end

  # ---------------------------------------------------------------------------
  # Item.Kind eviction scope
  # ---------------------------------------------------------------------------

  describe "Item.Kind.eviction_scope/1" do
    alias Platform.Context.Item.Kind

    test "run-scoped kinds" do
      for kind <- [:generic, :env_var, :runner_hint, :artifact_ref, :system_event] do
        assert Kind.eviction_scope(kind) == :run
      end
    end

    test "task-scoped kinds" do
      for kind <- [:task_description, :task_metadata] do
        assert Kind.eviction_scope(kind) == :task
      end
    end

    test "epic-scoped kinds" do
      assert Kind.eviction_scope(:epic_context) == :epic
    end

    test "project-scoped kinds" do
      assert Kind.eviction_scope(:project_config) == :project
    end

    test "unknown kind defaults to :run" do
      assert Kind.eviction_scope(:some_unknown_kind) == :run
    end
  end

  # ---------------------------------------------------------------------------
  # keys_to_evict / evict_by_scope
  # ---------------------------------------------------------------------------

  describe "keys_to_evict/2" do
    test "returns keys matching the eviction scope" do
      scope_key = "proj/#{uid()}"
      _scope = open!(%{project_id: scope_key})

      Cache.put_item(scope_key, "env1", "val", kind: :env_var)
      Cache.put_item(scope_key, "task_desc", "text", kind: :task_description)
      Cache.put_item(scope_key, "artifact", "ref", kind: :artifact_ref)

      run_keys = EvictionPolicy.keys_to_evict(scope_key, :run)
      task_keys = EvictionPolicy.keys_to_evict(scope_key, :task)

      assert "env1" in run_keys
      assert "artifact" in run_keys
      assert "task_desc" in task_keys
      refute "task_desc" in run_keys
    end
  end

  describe "evict_by_scope/2" do
    test "removes only matching items, leaves others" do
      scope_key = "proj/#{uid()}"
      _scope = open!(%{project_id: scope_key})

      Cache.put_item(scope_key, "ev", "v", kind: :env_var)
      Cache.put_item(scope_key, "td", "v", kind: :task_description)
      Cache.put_item(scope_key, "pc", "v", kind: :project_config)

      {:ok, 1} = EvictionPolicy.evict_by_scope(scope_key, :run)

      items = Cache.all_items(scope_key)
      keys = Enum.map(items, & &1.key)

      refute "ev" in keys
      assert "td" in keys
      assert "pc" in keys
    end

    test "returns {:ok, 0} when no matching items" do
      scope_key = "proj/#{uid()}"
      _scope = open!(%{project_id: scope_key})

      Cache.put_item(scope_key, "td", "v", kind: :task_description)

      {:ok, 0} = EvictionPolicy.evict_by_scope(scope_key, :run)
    end
  end

  # ---------------------------------------------------------------------------
  # Artifact promotion
  # ---------------------------------------------------------------------------

  describe "promote_artifacts/2" do
    test "promotes :artifact_ref items from run to task session" do
      task_id = uid()
      run_id = uid()

      task_scope_key = task_id
      run_scope_key = "#{task_id}/#{run_id}"

      open!(%{task_id: task_id})
      open!(%{task_id: task_id, run_id: run_id})

      Cache.put_item(run_scope_key, "artifact:output", "s3://bucket/key", kind: :artifact_ref)
      Cache.put_item(run_scope_key, "env", "prod", kind: :env_var)

      {:ok, 1} = EvictionPolicy.promote_artifacts(run_scope_key, task_scope_key)

      task_items = Cache.all_items(task_scope_key)
      task_keys = Enum.map(task_items, & &1.key)

      assert "artifact:output" in task_keys
      refute "env" in task_keys
    end

    test "promotion is idempotent" do
      task_id = uid()
      run_id = uid()

      task_scope_key = task_id
      run_scope_key = "#{task_id}/#{run_id}"

      open!(%{task_id: task_id})
      open!(%{task_id: task_id, run_id: run_id})

      Cache.put_item(run_scope_key, "artifact:out", "ref", kind: :artifact_ref)

      {:ok, 1} = EvictionPolicy.promote_artifacts(run_scope_key, task_scope_key)
      {:ok, 1} = EvictionPolicy.promote_artifacts(run_scope_key, task_scope_key)

      task_items = Cache.all_items(task_scope_key)
      artifact_items = Enum.filter(task_items, &(&1.key == "artifact:out"))
      assert length(artifact_items) == 1
    end

    test "returns {:ok, 0} when no artifacts" do
      task_id = uid()
      run_id = uid()

      open!(%{task_id: task_id})
      open!(%{task_id: task_id, run_id: run_id})

      {:ok, 0} = EvictionPolicy.promote_artifacts("#{task_id}/#{run_id}", task_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Lifecycle hooks
  # ---------------------------------------------------------------------------

  describe "run_terminated/1" do
    test "evicts run session and promotes artifacts to task session" do
      task_id = uid()
      run_id = uid()

      open!(%{task_id: task_id})
      open!(%{task_id: task_id, run_id: run_id})

      run_scope_key = "#{task_id}/#{run_id}"
      Cache.put_item(run_scope_key, "artifact:x", "ref", kind: :artifact_ref)
      Cache.put_item(run_scope_key, "env", "prod", kind: :env_var)

      :ok =
        EvictionPolicy.run_terminated(%{task_id: task_id, run_id: run_id})

      # Run session gone
      assert {:error, :not_found} = Cache.get_session(run_scope_key)

      # Task session still has the artifact
      task_items = Cache.all_items(task_id)
      task_keys = Enum.map(task_items, & &1.key)
      assert "artifact:x" in task_keys
    end

    test "run_terminated is safe when run session does not exist" do
      :ok =
        EvictionPolicy.run_terminated(%{task_id: uid(), run_id: uid()})
    end
  end

  describe "task_closed/1" do
    test "evicts the task session" do
      task_id = uid()
      open!(%{task_id: task_id})

      Cache.put_item(task_id, "td", "v", kind: :task_description)

      :ok = EvictionPolicy.task_closed(%{task_id: task_id})

      assert {:error, :not_found} = Cache.get_session(task_id)
    end
  end

  describe "epic_closed/1" do
    test "evicts the epic session" do
      epic_id = uid()
      open!(%{epic_id: epic_id})

      Cache.put_item(epic_id, "ec", "v", kind: :epic_context)

      :ok = EvictionPolicy.epic_closed(%{epic_id: epic_id})

      assert {:error, :not_found} = Cache.get_session(epic_id)
    end
  end

  describe "project_closed/1" do
    test "evicts the project session" do
      project_id = uid()
      open!(%{project_id: project_id})

      Cache.put_item(project_id, "pc", "v", kind: :project_config)

      :ok = EvictionPolicy.project_closed(%{project_id: project_id})

      assert {:error, :not_found} = Cache.get_session(project_id)
    end
  end
end
