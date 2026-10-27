defmodule Platform.CiTestShardsTest do
  @moduledoc """
  A drift alarm on the sharded `Test` check in `.github/workflows/ci.yml`.
  Like `Platform.CiFirstRunGreenTest`, this reads the workflow, it does not run
  it.

  The contract pinned here. The main `mix test --include slow` pass runs as
  `test-shard`, one matrix leg per partition of `mix test --partitions
  $TEST_PARTITIONS`, each with its own database. `test-checks` runs the steps
  that run once. `test`, named `Test` (a required check, matched by name),
  needs both, runs even when one failed (a skipped required check counts as
  passing), and fails unless both succeeded, every partition left an outcome,
  and the summed test count clears MIN_TEST_COUNT. Its `retry_fired` output is
  `true` when the serial retry fired in ANY shard, which is what
  `first-run-green` reads.

  Structure is checked on the parsed YAML; shell is checked as text on the
  comment-stripped step bodies.
  """

  use ExUnit.Case, async: true

  @test_root Path.expand("..", __DIR__)
  @ci_workflow Path.expand("../../../.github/workflows/ci.yml", @test_root)

  @required_checks ["Test", "first-run-green", "Test (with Play)", "Test (with Social)"]

  setup_all do
    doc = YamlElixir.read_from_string!(File.read!(@ci_workflow))
    {:ok, doc: doc, jobs: doc["jobs"]}
  end

  defp step!(job, name) do
    Enum.find(job["steps"], &(&1["name"] == name)) ||
      flunk("no `#{name}` step in the job")
  end

  defp code_only(text) do
    text
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
    |> Enum.join("\n")
  end

  defp partitions(doc), do: doc["env"]["TEST_PARTITIONS"]

  test "the four required checks exist under their exact names", %{jobs: jobs} do
    names = jobs |> Map.values() |> Enum.map(& &1["name"])

    for check <- @required_checks do
      assert check in names,
             "no job named `#{check}` in ci.yml. Branch protection requires it by name; " <>
               "renaming it silently un-requires it."
    end
  end

  describe "the floors and the partition count" do
    test "are workflow env integers, and the shard floor sits below a shard's share",
         %{doc: doc} do
      env = doc["env"]
      n = partitions(doc)

      assert is_integer(n) and n >= 2,
             "TEST_PARTITIONS is #{inspect(n)}; expected an integer of at least 2."

      assert is_integer(env["MIN_SHARD_TEST_COUNT"]) and env["MIN_SHARD_TEST_COUNT"] >= 100,
             "MIN_SHARD_TEST_COUNT must be an integer crash floor (>= 100)."

      assert env["MIN_SHARD_TEST_COUNT"] * n <= env["MIN_TEST_COUNT"],
             "MIN_SHARD_TEST_COUNT * TEST_PARTITIONS exceeds MIN_TEST_COUNT, so a " <>
               "shard floor is above an even share of the total floor."
    end
  end

  describe "the test-shard job" do
    test "has one matrix leg per partition, 1..TEST_PARTITIONS", %{doc: doc, jobs: jobs} do
      shard = jobs["test-shard"] || flunk("no `test-shard` job")

      assert shard["strategy"]["matrix"]["partition"] == Enum.to_list(1..partitions(doc)),
             "`test-shard`'s matrix.partition is not 1..TEST_PARTITIONS; a partition " <>
               "would never run, or run twice."

      assert shard["strategy"]["fail-fast"] == false,
             "`test-shard` must not fail fast: one red shard would cancel the rest " <>
               "and hide their failures."
    end

    test "takes MIX_TEST_PARTITION from the matrix and has a database per partition",
         %{jobs: jobs} do
      env = jobs["test-shard"]["env"]

      assert env["MIX_TEST_PARTITION"] == "${{ matrix.partition }}"

      assert env["PLATFORM_TEST_DATABASE"] =~ "${{ matrix.partition }}",
             "PLATFORM_TEST_DATABASE no longer varies by partition."
    end

    test "Run tests partitions the main pass and is the only shard step that runs it",
         %{jobs: jobs} do
      shard = jobs["test-shard"]
      code = code_only(step!(shard, "Run tests")["run"])

      assert code =~ ~r/if ! mix test --include slow --partitions "\$TEST_PARTITIONS" 2>&1/,
             "the main pass no longer runs `--partitions \"$TEST_PARTITIONS\"`; every " <>
               "shard would run the whole suite."

      assert step!(shard, "Run tests")["id"] == "run-tests"
    end

    test "records retry_fired and the test count into a per-partition artifact",
         %{jobs: jobs} do
      shard = jobs["test-shard"]
      record = step!(shard, "Record the shard outcome")

      assert record["env"]["RETRY_FIRED"] == "${{ steps.run-tests.outputs.retry_fired }}"
      assert record["run"] =~ ~s(shard-outcome/partition-$MIX_TEST_PARTITION)
      assert record["run"] =~ "retry_fired=%s"
      assert record["run"] =~ "test_count=%s"

      upload =
        Enum.find(
          shard["steps"],
          &(&1["uses"] == "actions/upload-artifact@v4" and &1["with"]["path"] == "shard-outcome/")
        ) ||
          flunk("`test-shard` no longer uploads shard-outcome/")

      assert upload["with"]["name"] == "test-shard-outcome-${{ matrix.partition }}"
    end
  end

  describe "the aggregating Test job" do
    test "is named Test, needs the checks and every shard, and always runs", %{jobs: jobs} do
      test = jobs["test"] || flunk("no `test` job")

      assert test["name"] == "Test"
      assert Enum.sort(List.wrap(test["needs"])) == ["test-checks", "test-shard"]

      assert test["if"] =~ "always()",
             "`Test` lost `if: always()`. When a shard fails, a skipped `Test` " <>
               "reports `skipped`, which branch protection treats as passing."
    end

    test "fails on any red need, a missing partition, or a total below MIN_TEST_COUNT",
         %{jobs: jobs} do
      agg =
        step!(jobs["test"], "Every shard green, test count over the floor, retry fired anywhere")

      code = code_only(agg["run"])

      assert agg["id"] == "aggregate"
      assert agg["env"]["CHECKS_RESULT"] == "${{ needs.test-checks.result }}"
      assert agg["env"]["SHARDS_RESULT"] == "${{ needs.test-shard.result }}"

      assert code =~
               ~r/if \[ "\$CHECKS_RESULT" != success \]; then\n\s*echo "::error::[^"]*"\n\s*exit 1/

      assert code =~
               ~r/if \[ "\$SHARDS_RESULT" != success \]; then\n\s*echo "::error::[^"]*"\n\s*exit 1/

      assert code =~ ~r/for p in \$\(seq 1 "\$TEST_PARTITIONS"\); do/
      assert code =~ ~r/if \[ ! -f "\$f" \]; then\n\s*echo "::error::[^"]*"\n\s*exit 1/

      assert code =~
               ~r/if \[ "\$total" -lt "\$MIN_TEST_COUNT" \]; then\n\s*echo\s+"::error::[^"]*"\n\s*exit 1/
    end

    test "retry_fired is true if any shard's retry fired, and written only after every check",
         %{jobs: jobs} do
      agg =
        step!(jobs["test"], "Every shard green, test count over the floor, retry fired anywhere")

      code = code_only(agg["run"])

      assert code =~ ~r/^\s*fired=false\s*$/m

      assert code =~ ~r/^\s*true\) fired=true ;;\s*$/m,
             "a shard's `retry_fired=true` no longer sets the aggregate to true; " <>
               "`first-run-green` would pass on a retry-green shard."

      assert [_, arm] = Regex.run(~r/^\s*\*\)\n(.*?)^\s*;;/ms, code)

      assert arm =~ ~r/^\s*exit 1\s*$/m,
             "an unrecognised shard retry_fired no longer fails `Test`."

      {write_at, _} = :binary.match(code, ~s(echo "retry_fired=$fired" >> "$GITHUB_OUTPUT"))
      {floor_at, _} = :binary.match(code, ~s(-lt "$MIN_TEST_COUNT"))
      assert floor_at < write_at, "`retry_fired` is written before the total floor is checked."

      assert jobs["test"]["outputs"]["retry_fired"] ==
               "${{ steps.aggregate.outputs.retry_fired }}"
    end
  end

  test "first-run-green reads the aggregate Test job", %{jobs: jobs} do
    frg = jobs["first-run-green"]
    assert frg["needs"] == "test"
    [step] = frg["steps"]
    assert step["env"]["RETRY_FIRED"] == "${{ needs.test.outputs.retry_fired }}"
  end
end
