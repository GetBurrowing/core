defmodule Platform.ScopeRegistryConsistencyTest do
  @moduledoc """
  Cross-source consistency guard for the sub-org scope enum.

  The scope enum is redeclared in more than a dozen places (see the inventory
  comment in `PlatformWeb.Live.TasksLive.active_scope_keys/1`). Half of those
  sources are programmatically comparable — those are pinned here. The rest
  (component `attr … values:` lists, the non-total `ScopePill.slug/1` and
  `scope_label/1`, the `~w(...)` swatch palette in `chat_live.html.heex`) are
  covered at render level in `scope_pill_test.exs` and the chat LiveView tests.

  Adding a SEVENTH org to only some of these sources must fail here rather
  than half-landing.
  """
  use ExUnit.Case, async: true

  alias Platform.Tasks
  alias Platform.Tenancy
  alias PlatformWeb.Components.ScopePill

  @expected [:fabrikam, :soylent, :wayne_tech, :sxi, :paragon, :cyberdyne]

  test "Tasks.scope_keys/0 is the canonical enum, in order" do
    assert Tasks.scope_keys() == @expected
  end

  test "ScopePill.scopes/0 matches Tasks.scope_keys/0 exactly, order included" do
    assert ScopePill.scopes() == Tasks.scope_keys()
  end

  test "Tenancy scope-class and scope-label maps cover exactly the enum" do
    for scope <- @expected do
      assert Tenancy.scope_color(scope) == "text-#{String.replace(to_string(scope), "_", "-")}",
             "Tenancy.@scope_classes is missing or wrong for #{inspect(scope)}"

      refute Tenancy.scope_label(scope) in [nil, ""],
             "Tenancy.@scope_labels is missing #{inspect(scope)}"
    end
  end

  test "every enum member has a Tenancy label and it is not the unknown fallback" do
    assert Tenancy.scope_label(:cyberdyne) == "Cyberdyne"
    assert Tenancy.scope_color(:cyberdyne) == "text-cyberdyne"
  end

  test "tenant_priority/0 is deliberately NOT extended for cyberdyne" do
    # Decision recorded on task 019ffe9d stage 3: `tenant_priority/0` is a
    # curation list, not a registration requirement. An unknown slug gets the
    # 9_999 sentinel from `tenant_priority_index/1` and sorts last, then
    # alphabetically — which is the honest position for a new client and
    # already matches cyberdyne's position at the tail of `scope_keys/0`.
    refute "cyberdyne" in Tenancy.tenant_priority()
    assert Tenancy.tenant_priority_index("cyberdyne") == 9_999
  end

  test "cyberdyne is appended, not inserted — existing rail order is unchanged" do
    # The append-don't-insert invariant (tasks_live.ex) protects the rail order
    # for the five pre-existing tenants. Assert the prefix explicitly so a
    # mid-list insertion fails here rather than silently reordering the board.
    assert Enum.take(Tasks.scope_keys(), 5) == [:fabrikam, :soylent, :wayne_tech, :sxi, :paragon]
    assert List.last(Tasks.scope_keys()) == :cyberdyne

    assert Enum.take(Tasks.scope_keys(), 5) |> Enum.map(&Atom.to_string/1) ==
             Tenancy.tenant_priority()
  end
end
