defmodule Mix.Tasks.SuiteTaskShimsTest do
  @moduledoc """
  Task 01a14b9e-50a4 stage 1: the mix tasks moved to `burrow.*`. The old
  `suite.*` names are thin shims that delegate to the Burrow modules and
  carry no `@shortdoc`, so `mix help` lists only the Burrow names while a
  script typing the old name still works.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Burrow.Deploy.ScopeGate, as: BurrowScopeGate
  alias Mix.Tasks.Burrow.ResponsibilityReachability, as: BurrowReachability
  alias Mix.Tasks.Suite.Deploy.ScopeGate, as: SuiteScopeGate
  alias Mix.Tasks.Suite.ResponsibilityReachability, as: SuiteReachability

  @pairs [
    {"burrow.deploy.scope_gate", "suite.deploy.scope_gate", BurrowScopeGate, SuiteScopeGate},
    {"burrow.responsibility_reachability", "suite.responsibility_reachability",
     BurrowReachability, SuiteReachability}
  ]

  test "both names resolve; only the Burrow name carries a shortdoc" do
    for {burrow, suite, burrow_mod, suite_mod} <- @pairs do
      assert Mix.Task.get(burrow) == burrow_mod
      assert Mix.Task.get(suite) == suite_mod

      assert is_binary(Mix.Task.shortdoc(burrow_mod)), "#{burrow} lost its shortdoc"
      assert Mix.Task.shortdoc(suite_mod) == nil, "#{suite} is listed by mix help"
    end
  end

  test "the scope_gate shim refuses exactly as the Burrow task does, naming the Burrow command" do
    for args <- [[], ["a", "b"], ["--bogus", "x"]] do
      assert SuiteScopeGate.scope(args) == BurrowScopeGate.scope(args)
      assert {:error, _reason} = SuiteScopeGate.scope(args)
    end

    burrow = assert_raise(Mix.Error, fn -> BurrowScopeGate.run([]) end)
    suite = assert_raise(Mix.Error, fn -> SuiteScopeGate.run([]) end)

    assert suite.message == burrow.message
    assert burrow.message =~ "mix burrow.deploy.scope_gate"
    refute burrow.message =~ "mix suite."
  end

  test "the reachability shim prints what the Burrow task prints" do
    burrow = capture_io(fn -> assert :ok = BurrowReachability.run([]) end)
    suite = capture_io(fn -> assert :ok = SuiteReachability.run([]) end)

    # Each render stamps its own `as_of`; everything else must match.
    strip = &Regex.replace(~r/^as_of: .*$/m, &1, "as_of: <stamp>")

    assert burrow =~ "as_of: "
    assert strip.(suite) == strip.(burrow)
  end
end
