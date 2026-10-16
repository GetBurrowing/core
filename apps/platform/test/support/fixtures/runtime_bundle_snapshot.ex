defmodule Platform.RuntimeBundleSnapshot do
  @moduledoc """
  Ordered bundle arrays observed on the two installations before RBAC v2.

  Each entry records only an owner class and row count. Array N is treated as
  root-admin-owned after Rowan's promotion ruling. Arrays C and K contain
  Play, whose three tools Rowan accepted as a temporary cap exception.
  """

  alias Platform.Federation.ToolSurface

  @a ~w(federation space context_read messaging review canvas task plan skill attachment memory files meetings mail prototype)
  @h ~w(federation space context_read messaging review canvas task plan memory skill attachment files meetings mail prototype)

  @snapshots [
    %{key: :a, bundles: @a, owner: :root_admin, fabrikam: 14, ellis: 0},
    %{key: :b, bundles: List.insert_at(@a, -1, "code_mode"), owner: :root_admin, fabrikam: 2, ellis: 0},
    %{key: :c, bundles: ~w(federation space context_read messaging attachment canvas review task plan skill memory files meetings mail play code_mode experiments prototype), owner: :root_admin, fabrikam: 1, ellis: 0},
    %{key: :d, bundles: ~w(federation space context_read messaging review canvas task plan memory skill attachment meetings mail prototype), owner: :root_admin, fabrikam: 1, ellis: 0},
    %{key: :e, bundles: ~w(federation space context_read messaging attachment skill meetings mail prototype), owner: :root_admin, fabrikam: 8, ellis: 0},
    %{key: :f, bundles: ~w(federation space context_read messaging memory skill attachment meetings mail prototype), owner: :root_admin, fabrikam: 1, ellis: 0},
    %{key: :g, bundles: ~w(federation space context_read messaging review canvas task plan memory skill attachment meetings mail code_mode prototype), owner: :root_admin, fabrikam: 1, ellis: 0},
    %{key: :h, bundles: @h, owner: :root_admin, fabrikam: 2, ellis: 1},
    %{key: :i, bundles: ~w(federation space messaging meetings mail prototype), owner: :root_admin, fabrikam: 1, ellis: 0},
    %{key: :j, bundles: List.insert_at(@h, -1, "code_mode"), owner: :root_admin, fabrikam: 1, ellis: 0},
    %{key: :k, bundles: List.insert_at(@h, -1, "experiments") |> List.insert_at(-1, "play"), owner: :root_admin, fabrikam: 1, ellis: 0},
    %{key: :l, bundles: ~w(messaging context_read prototype), owner: :root_admin, fabrikam: 1, ellis: 0},
    %{key: :m, bundles: ~w(prototype), owner: :root_admin, fabrikam: 2, ellis: 0},
    %{key: :n, bundles: ~w(federation space context_read messaging review canvas task plan memory skill attachment files meetings mail experiments code_mode play prototype), owner: :root_admin_after_promotion, fabrikam: 1, ellis: 0}
  ]

  def snapshots, do: @snapshots

  def legacy_tool_names(bundles, external? \\ false) do
    bundles
    |> ToolSurface.list_tools()
    |> ToolSurface.scope_for_external(external?)
    |> Enum.map(& &1.name)
  end
end
