defmodule Platform.ZzFirstRunGreenControlTest do
  # THROWAWAY positive control for task 01a08d81 — reverted in the next commit.
  # Fails on the first `mix test` pass (no marker), passes on the serial
  # `--failed` retry (marker present, same container), so the Run tests step
  # takes its retry-green path and `first-run-green` must go RED on this run.
  use ExUnit.Case, async: true

  test "fails once, then passes on the retry" do
    marker =
      Path.join(
        System.get_env("RUNNER_TEMP", System.tmp_dir!()),
        "first-run-green-control-01a08d81"
      )

    if File.exists?(marker) do
      assert true
    else
      File.write!(marker, "fired")
      flunk("first pass: forcing the serial retry (positive control for first-run-green)")
    end
  end
end
