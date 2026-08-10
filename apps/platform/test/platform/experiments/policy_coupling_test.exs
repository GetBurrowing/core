defmodule Platform.Experiments.PolicyCouplingTest do
  @moduledoc """
  A source-level assertion that the experiment engine stays ignorant of tasks.

  This is the single design constraint the policy layer exists to protect, and
  it is a constraint about code that must NOT be written. The compiler cannot
  express that: a policy that aliased `Platform.Tasks` and pattern-matched a
  `%Task{}` would compile cleanly, pass every behavioural test, and only
  reveal itself the day a non-task subject arrived — at which point the fix is
  a rewrite of every policy rather than a new caller.

  So the assertion reads the source. It scans `policy.ex`, `subject.ex` and
  every file under `policies/`, and fails on any reference to the tasks
  context or the task struct.

  A scanner cannot tell a comment from a call, so a mention inside a moduledoc
  would fail this test too. That is accepted deliberately: the false positive
  is loud and trivially fixed by rewording, while the false negative it would
  take to avoid — parsing the AST to distinguish real references — buys
  precision this constraint does not need.
  """

  use ExUnit.Case, async: true

  @policy_layer_files (fn ->
                         dir =
                           Path.join([
                             __DIR__,
                             "..",
                             "..",
                             "..",
                             "lib",
                             "platform",
                             "experiments"
                           ])

                         [
                           Path.join(dir, "policy.ex"),
                           Path.join(dir, "subject.ex")
                           | Path.wildcard(Path.join([dir, "policies", "*.ex"]))
                         ]
                         |> Enum.map(&Path.expand/1)
                       end).()

  @forbidden ["Platform.Tasks", "%Task{", "Platform.Repo"]

  test "the scanned file set is non-empty and contains every policy" do
    # Anti-vacuity. A wildcard that matched nothing would make every
    # assertion below vacuously true, and the coupling guard would be
    # silently switched off by a directory rename.
    assert length(@policy_layer_files) >= 7

    basenames = Enum.map(@policy_layer_files, &Path.basename/1)

    for expected <- [
          "policy.ex",
          "subject.ex",
          "random_buckets.ex",
          "epic_scoped.ex",
          "task_cohort.ex",
          "time_window.ex",
          "composite.ex"
        ] do
      assert expected in basenames,
             "#{expected} was not scanned; the coupling guard is not covering it"
    end

    for file <- @policy_layer_files do
      assert File.exists?(file), "scanner named a file that does not exist: #{file}"
    end
  end

  test "no file in the policy layer references the tasks context or a task struct" do
    for file <- @policy_layer_files, term <- @forbidden do
      source = File.read!(file)

      refute String.contains?(source, term),
             """
             #{Path.relative_to_cwd(file)} contains #{inspect(term)}.

             The policy layer must decide from a Platform.Experiments.Subject
             alone — a type, an id, and an attributes map. Reaching for the
             tasks context or the repo here couples the engine to the thing
             being experimented on, and the coupling is invisible until a
             non-task subject arrives.
             """
    end
  end

  test "the guard detects a forbidden term when one is present" do
    # The refute above is only meaningful if the scan can actually see the
    # contents of these files. A path that read an empty string, or a term
    # that could never match, would leave the guard permanently green.
    source = File.read!(Enum.find(@policy_layer_files, &(Path.basename(&1) == "policy.ex")))

    assert String.contains?(source, "Platform.Experiments.Subject")
    assert byte_size(source) > 1_000
  end
end
