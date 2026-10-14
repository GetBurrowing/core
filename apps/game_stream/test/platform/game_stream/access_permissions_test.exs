defmodule Platform.GameStream.AccessPermissionsTest do
  @moduledoc """
  Play's side of `Platform.Access.Registry` (task 01a1386d-cb5c stage 1).
  Core's `test/platform/access/registry_test.exs` runs with no Play; this
  case runs where Play is registered and checks that the `play` bundle is
  declared, so the registry covers every `ToolSurface.all_bundles/0` entry
  in a with-Play build too.
  """
  use ExUnit.Case, async: false

  alias Platform.Access.Registry
  alias Platform.Federation.ToolSurface

  test "the play bundle maps to Play's one permission, and every bundle is declared" do
    assert "play" in ToolSurface.all_bundles()
    assert Registry.bundle_permission("play") == "play.use"
    assert "play.use" in Registry.permission_names()
    assert Registry.undeclared_bundles() == []
  end
end
