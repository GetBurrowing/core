defmodule Platform.Context.SessionTest do
  @moduledoc "Unit tests for Platform.Context.Session value module."
  use ExUnit.Case, async: true

  alias Platform.Context.Session
  alias Platform.Context.Session.Scope

  # ---------------------------------------------------------------------------
  # Scope construction
  # ---------------------------------------------------------------------------

  describe "to_scope/1" do
    test "accepts a %Scope{} passthrough" do
      scope = %Scope{task_id: "t1"}
      assert {:ok, ^scope} = Session.to_scope(scope)
    end

    test "accepts atom-key map" do
      assert {:ok, %Scope{task_id: "abc", project_id: "p1"}} =
               Session.to_scope(%{task_id: "abc", project_id: "p1"})
    end

    test "accepts string-key map" do
      assert {:ok, %Scope{task_id: "t1"}} =
               Session.to_scope(%{"task_id" => "t1"})
    end

    test "accepts keyword list" do
      assert {:ok, %Scope{task_id: "t2", run_id: "r1"}} =
               Session.to_scope(task_id: "t2", run_id: "r1")
    end

    test "returns error when all fields are nil" do
      assert {:error, :invalid_scope} = Session.to_scope(%{})
      assert {:error, :invalid_scope} = Session.to_scope([])
    end
  end

  # ---------------------------------------------------------------------------
  # Scope key derivation
  # ---------------------------------------------------------------------------

  describe "scope_key/1" do
    test "single part scope" do
      scope = %Scope{task_id: "t1"}
      assert {:ok, "t1"} = Session.scope_key(scope)
    end

    test "project + epic + task + run" do
      scope = %Scope{project_id: "p", epic_id: "e", task_id: "t", run_id: "r"}
      assert {:ok, "p/e/t/r"} = Session.scope_key(scope)
    end

    test "skips nil segments" do
      scope = %Scope{project_id: "p", task_id: "t"}
      assert {:ok, "p/t"} = Session.scope_key(scope)
    end

    test "returns error for fully empty scope" do
      assert {:error, :empty_scope} = Session.scope_key(%Scope{})
    end

    test "accepts map input" do
      assert {:ok, "task-99"} = Session.scope_key(%{task_id: "task-99"})
    end
  end

  # ---------------------------------------------------------------------------
  # Session construction and version
  # ---------------------------------------------------------------------------

  describe "new/1 and bump_version/1" do
    test "new creates session at version 0" do
      scope = %Scope{task_id: "t-new"}
      session = Session.new(scope)

      assert session.version == 0
      assert session.required_version == 0
      assert session.scope == scope
      assert %DateTime{} = session.inserted_at
    end

    test "bump_version increments version and updates updated_at" do
      scope = %Scope{task_id: "bump"}
      session = Session.new(scope)

      {v1, s1} = Session.bump_version(session)
      {v2, s2} = Session.bump_version(s1)

      assert v1 == 1
      assert v2 == 2
      assert s2.version == 2
    end

    test "set_required pins required_version to current version" do
      scope = %Scope{task_id: "req"}
      session = Session.new(scope)
      {_v, s1} = Session.bump_version(session)
      {_v, s2} = Session.bump_version(s1)

      s3 = Session.set_required(s2)
      assert s3.required_version == 2
    end
  end
end
