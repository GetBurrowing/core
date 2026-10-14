defmodule Platform.Measurements.UiSluggishnessSeedGuardTest do
  @moduledoc """
  The ui_sluggishness perf seed (task 01a13884 stage 1) must refuse to run
  anywhere but a dev BEAM: `mix run` under MIX_ENV=test escapes the Ecto
  sandbox and writes 1,363 tasks straight into the test database.

  The guard lives in its own file so both branches can be driven here
  without running the seed. The allow-branch cases are the positive control:
  a guard that raised for every input would pass the refuse cases too.
  """
  use ExUnit.Case, async: true

  @dir Path.expand("../../../priv/measurements/ui_sluggishness", __DIR__)

  setup_all do
    {guard, _binding} = Code.eval_file(Path.join(@dir, "guard.exs"))
    %{guard: guard}
  end

  test "refuses under Mix.env() :test", %{guard: guard} do
    assert_raise RuntimeError, ~r/Mix\.env\(\) is :test/, fn -> guard.({:test, "test"}) end
    assert_raise RuntimeError, ~r/Mix\.env\(\) is :test/, fn -> guard.({:test, nil}) end
  end

  test "refuses MIX_ENV=test even when Mix.env() reads :dev", %{guard: guard} do
    assert_raise RuntimeError, ~r/MIX_ENV=test/, fn -> guard.({:dev, "test"}) end
  end

  test "refuses :prod", %{guard: guard} do
    assert_raise RuntimeError, ~r/Mix\.env\(\) is :prod/, fn -> guard.({:prod, "prod"}) end
  end

  test "allows a dev BEAM (positive control)", %{guard: guard} do
    assert guard.({:dev, "dev"}) == :ok
    assert guard.({:dev, nil}) == :ok
  end

  test "seed.exs wires the guard: evaluating it in this test BEAM raises before any write" do
    assert Mix.env() == :test

    assert_raise RuntimeError, ~r/ui_sluggishness seed refused/, fn ->
      Code.eval_file(Path.join(@dir, "seed.exs"))
    end
  end
end
