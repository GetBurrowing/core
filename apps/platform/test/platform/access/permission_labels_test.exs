defmodule Platform.Access.PermissionLabelsTest do
  @moduledoc "Task 01a1a2e4-9265 stage 1: every registered permission has a plain label."
  use ExUnit.Case, async: true

  alias Platform.Access.{PermissionLabels, Registry}

  test "the explicit labels the agent page and roles page name" do
    assert PermissionLabels.label("prototypes.publish") == "Publish prototypes"
    assert PermissionLabels.label("prototypes.read") == "View prototypes"
  end

  test "every explicit label names a registered permission" do
    names = Registry.permission_names()

    for {permission, label} <- PermissionLabels.labels() do
      assert permission in names, "#{permission} is labelled but not registered"
      assert label != ""
    end
  end

  test "the explicit map covers the prototypes, tasks, canvas, chat, files and mail modules" do
    for permission <- Registry.permission_names(),
        [module | _] = String.split(permission, "."),
        module in ~w(prototypes tasks canvas chat files mail) do
      assert Map.has_key?(PermissionLabels.labels(), permission),
             "#{permission} has no explicit label"
    end
  end

  test "every registered permission gets a non-empty label that is not its key" do
    for permission <- Registry.permission_names() do
      label = PermissionLabels.label(permission)
      assert String.trim(label) != "", "#{permission} has an empty label"
      refute label == permission, "#{permission} fell through to its raw key"
    end
  end

  test "the fallback is \"<Action> <module>\" humanized" do
    assert PermissionLabels.label("agents.manage_all") == "Manage all agents"
    assert PermissionLabels.label("inbox.read") == "Read inbox"
  end
end
