defmodule Platform.TestTempTest do
  use ExUnit.Case, async: true

  alias Platform.TestTemp

  # READ THIS BEFORE TRUSTING THESE TESTS.
  #
  # Every test in this file runs inside ONE BEAM, and the defect being fixed is
  # a collision BETWEEN BEAMs. So these tests pass against the old, broken
  # `System.unique_integer/1` construction too — they would have caught the
  # defect zero times. They are necessary (they pin the two contracts and the
  # direction) but they are NOT the guard. The guard is the cross-process test
  # added in the next stage.
  #
  # Concretely, per entropy component:
  #
  #   * `:crypto.strong_rand_bytes/1` — the ONLY component the N=1000
  #     distinctness test below actually exercises. It carries that test
  #     entirely.
  #   * `System.pid()` — the component that fixes the real defect, and the one
  #     NO test here can reach: it is constant within a single run, so it
  #     contributes nothing to intra-BEAM distinctness.
  #   * the monotonic counter — intra-BEAM disambiguation only. A fresh BEAM
  #     restarts it near 1, which is the bug; a single-BEAM test cannot see that
  #     either.

  describe "path/1" do
    test "generates distinct paths within this BEAM" do
      # Exercises the random bytes and nothing else. See the comment above.
      paths = for _ <- 1..1000, do: TestTemp.path("platform-test-temp-distinct")

      assert length(Enum.uniq(paths)) == 1000
    end

    test "roots every path at System.tmp_dir!() resolved at runtime" do
      # Asserted against the COMPUTED prefix, never a hardcoded directory:
      # `System.tmp_dir!()` is `$TMPDIR` on macOS and commonly `/tmp` on Linux,
      # so a literal assertion (or a literal refutation) is green on one
      # platform and red on the other for the correct answer.
      tmp_dir = System.tmp_dir!()

      for _ <- 1..10 do
        assert String.starts_with?(TestTemp.path("platform-test-temp-root"), tmp_dir)
      end
    end

    test "creates nothing on disk" do
      path = TestTemp.path("platform-test-temp-nocreate")

      refute File.exists?(path)
    end

    test "keeps the prefix and appends a token of all three components" do
      path = TestTemp.path("platform-test-temp-shape")

      assert Regex.match?(
               ~r/^platform-test-temp-shape-[a-z2-7]+-\d+-\d+$/,
               Path.basename(path)
             )
    end
  end

  describe "mkdir!/1" do
    test "creates the directory and returns a path of the same shape as path/1" do
      dir = TestTemp.mkdir!("platform-test-temp-mkdir")
      on_exit(fn -> File.rm_rf(dir) end)

      assert File.dir?(dir)
      assert String.starts_with?(dir, System.tmp_dir!())

      assert Regex.match?(
               ~r/^platform-test-temp-mkdir-[a-z2-7]+-\d+-\d+$/,
               Path.basename(dir)
             )
    end

    test "generates distinct directories within this BEAM" do
      dirs = for _ <- 1..25, do: TestTemp.mkdir!("platform-test-temp-mkdir-distinct")
      on_exit(fn -> Enum.each(dirs, &File.rm_rf/1) end)

      assert length(Enum.uniq(dirs)) == 25
      assert Enum.all?(dirs, &File.dir?/1)
    end

    test "does not register its own cleanup" do
      # The contract is caller-owned cleanup: the directory must still exist
      # after mkdir!/1 returns, with nothing scheduled to remove it behind the
      # caller's back.
      dir = TestTemp.mkdir!("platform-test-temp-no-onexit")

      assert File.dir?(dir)
      assert File.rm_rf(dir) |> elem(0) == :ok
    end
  end

  # THE GUARD.
  #
  # Everything above runs in one BEAM and so cannot observe the defect this
  # module exists to fix. This test starts TWO fresh OS processes and asserts
  # their token sets do not intersect. It is the only test here that fails
  # against the old `System.unique_integer/1` construction.
  #
  # WHY TWO CHILDREN AND NOT PARENT-VS-CHILD.
  #
  # An earlier version compared this long-lived `mix test` BEAM against one
  # freshly spawned child. That made the guard depend on ExUnit's execution
  # order, which is a function of `--seed`: both BEAMs start
  # `System.unique_integer([:positive, :monotonic])` at 1, but the parent's
  # counter has already been advanced by whichever tests in this file ran
  # first. On a seed where the guard ran first the counter ranges overlapped
  # and a counter-only construction was caught; on a seed where it ran last the
  # parent's counter had moved past the child's range, the ranges did not
  # intersect, and the regression went unnoticed. Measured kill rate across
  # seeds 0-9: 5/10.
  #
  # Two fresh children both start their counter at 1, so a counter-only
  # construction collides on EVERY seed. It also makes the test's claim --
  # "two independently started BEAMs cannot converge" -- literally what the
  # test performs. The alternatives are weaker: asserting the token merely
  # *contains* `System.pid()` tests the shape rather than the property, and
  # generating the parent's tokens before any other test can advance the
  # counter re-encodes the ordering assumption instead of removing it (and
  # would break again the next time a test is added to this file).
  #
  # Three preconditions are asserted before the uniqueness claim, because
  # without them a pass would be vacuous:
  #
  #   1. each child exited 0 — a child that never ran prints no duplicates,
  #   2. the two children report different OS pids — otherwise "two BEAMs" is a
  #      lie and the union is just one process's tokens,
  #   3. each child loaded the SAME compiled module this BEAM did, compared by
  #      `module_info(:md5)` — otherwise a child may be answering from a stale
  #      `_build` artifact, and the test would be describing code that is no
  #      longer in the tree.
  #
  # Cost: two `mix run` boots (a few seconds each) instead of one. That is the
  # price of the only test in this file that can detect this defect class. No
  # retries, no sleeps, no re-run wrapper, no `@tag :flaky`: not smoothing over
  # shared-state nondeterminism is this file's entire subject.
  describe "uniqueness across OS processes" do
    @token_count 200

    test "tokens from two freshly started BEAMs never collide" do
      {pid_a, md5_a, tokens_a} = run_child(@token_count)
      {pid_b, md5_b, tokens_b} = run_child(@token_count)

      assert pid_a != pid_b,
             "the two children report the SAME OS pid (#{inspect(pid_a)}), so this ran " <>
               "in one process and proves nothing about cross-BEAM uniqueness."

      for {md5, label} <- [{md5_a, "first"}, {md5_b, "second"}] do
        assert md5 == parent_md5(),
               "the #{label} child loaded a DIFFERENT build of Platform.TestTemp than " <>
                 "this BEAM (child md5 #{md5}, ours #{parent_md5()}). The result " <>
                 "describes a stale _build artifact, not the module in the tree."
      end

      duplicates =
        (tokens_a ++ tokens_b)
        |> Enum.frequencies()
        |> Enum.filter(fn {_token, count} -> count > 1 end)

      assert duplicates == [],
             "the same token was produced by two separate OS processes (pids #{pid_a} " <>
               "and #{pid_b}), so the path is not unique across BEAMs: #{inspect(duplicates)}"

      assert length(Enum.uniq(tokens_a ++ tokens_b)) == 2 * @token_count
    end
  end

  defp run_child(count) do
    {output, status} =
      System.cmd("mix", ["run", "--no-start", "-e", child_script(count)],
        cd: Path.expand("../..", __DIR__),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0,
           "child BEAM exited #{status} instead of 0, so it produced no evidence. " <>
             "Platform.TestTemp lives in test/support and exists only in the test " <>
             "build (mix.exs elixirc_paths(:test)), so a child without MIX_ENV=test " <>
             "reports it undefined. Child output:\n#{output}"

    tokens = extract_all(output, "TOKEN")

    assert length(tokens) == count,
           "expected #{count} tokens from the child, got #{length(tokens)}. " <>
             "Child output:\n#{output}"

    {extract(output, "PID", status), extract(output, "MD5", status), tokens}
  end

  defp child_script(count) do
    """
    IO.puts("PID " <> System.pid())
    IO.puts("MD5 " <> Base.encode16(Platform.TestTemp.module_info(:md5), case: :lower))

    Enum.each(1..#{count}, fn _ ->
      IO.puts("TOKEN " <> Platform.TestTemp.unique_token())
    end)
    """
  end

  defp parent_md5 do
    Base.encode16(Platform.TestTemp.module_info(:md5), case: :lower)
  end

  defp extract(output, label, status) do
    case extract_all(output, label) do
      [value] ->
        value

      other ->
        flunk(
          "expected exactly one #{label} line from the child (exit #{status}), got " <>
            "#{inspect(other)}. Child output:\n#{output}"
        )
    end
  end

  defp extract_all(output, label) do
    output
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case String.split(String.trim(line), " ", parts: 2) do
        [^label, value] -> [value]
        _ -> []
      end
    end)
  end
end
