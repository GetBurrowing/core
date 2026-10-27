defmodule Platform.CiNoSelfHostedRunnersTest do
  @moduledoc """
  A drift alarm on every workflow under `.github/workflows`: no job may run on
  a self-hosted runner. The repository is public, so any job that can reach a
  self-hosted runner can be made to run code from a fork pull request on that
  host. Every job runs on a GitHub-hosted runner instead.

  Like `Platform.CiFirstRunGreenTest`, this reads the workflows, it does not
  run them. It parses each file as YAML and resolves every job's `runs-on`:

    * a string (`runs-on: self-hosted`), a list (`[self-hosted, linux, x64]`,
      inline or block), or a map (`group:` / `labels:`) is checked as written;
    * an expression that reads `matrix.<key>` (`${{ matrix.runner }}`,
      `${{ fromJSON(matrix.runner) }}`) is checked against every value
      `<key>` takes in that job's `strategy.matrix`, top-level and `include:`;
    * any other expression (`vars.*`, `inputs.*`, ...) fails, because the
      label it resolves to is not in the repository and cannot be checked.

  The positive controls at the bottom plant each form and assert the same
  checker reports it, so a parser change that stops seeing a form is caught.
  """

  use ExUnit.Case, async: true

  @test_root Path.expand("..", __DIR__)
  @workflows_dir Path.expand("../../../.github/workflows", @test_root)

  defp workflow_files do
    Path.wildcard(Path.join(@workflows_dir, "*.{yml,yaml}"))
  end

  # [{job_id, reason}] for every job in `doc` whose runs-on is, or may be, a
  # self-hosted label set.
  defp violations(doc) do
    for {job_id, job} <- Map.get(doc, "jobs") || %{},
        is_map(job),
        Map.has_key?(job, "runs-on"),
        reason <- runs_on_violations(job["runs-on"], job),
        do: {job_id, reason}
  end

  defp runs_on_violations(value, job) when is_binary(value) do
    if String.contains?(value, "${{") do
      expression_violations(value, job)
    else
      label_violations(value)
    end
  end

  defp runs_on_violations(value, job) when is_list(value),
    do: Enum.flat_map(value, &runs_on_violations(&1, job))

  defp runs_on_violations(value, job) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&runs_on_violations(&1, job))

  defp runs_on_violations(value, _job), do: ["unrecognised runs-on #{inspect(value)}"]

  defp label_violations(text) do
    if text =~ ~r/self-hosted/i, do: ["runs-on names #{inspect(text)}"], else: []
  end

  defp expression_violations(expr, job) do
    case Regex.scan(~r/matrix\.([A-Za-z0-9_-]+)/, expr, capture: :all_but_first) do
      [] ->
        ["runs-on #{inspect(expr)} is an expression this guard cannot resolve"]

      keys ->
        values = for [key] <- keys, value <- matrix_values(job, key), do: value

        if values == [] do
          ["runs-on #{inspect(expr)} reads a matrix key with no values in this job"]
        else
          Enum.flat_map(values, fn value ->
            value |> stringify() |> label_violations()
          end)
        end
    end
  end

  defp matrix_values(job, key) do
    matrix = get_in(job, ["strategy", "matrix"]) || %{}

    top =
      case Map.get(matrix, key) do
        nil -> []
        list when is_list(list) -> list
        other -> [other]
      end

    included =
      for entry <- List.wrap(Map.get(matrix, "include")),
          is_map(entry),
          Map.has_key?(entry, key),
          do: entry[key]

    top ++ included
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value)

  defp parse!(text), do: YamlElixir.read_from_string!(text)

  test "the workflows directory has workflows to check" do
    assert workflow_files() != [],
           "no workflow files under #{@workflows_dir}; this guard would pass vacuously."
  end

  test "no job in any workflow runs on a self-hosted runner" do
    found =
      for file <- workflow_files(),
          {job_id, reason} <- violations(parse!(File.read!(file))),
          do:
            "#{Path.relative_to(file, Path.dirname(Path.dirname(@workflows_dir)))}: job `#{job_id}`: #{reason}"

    assert found == [],
           "self-hosted runners in .github/workflows (the repository is public, so a " <>
             "fork pull request could run code on that host). Use a GitHub-hosted " <>
             "runner (`ubuntu-latest`, `ubuntu-24.04-arm`):\n  " <> Enum.join(found, "\n  ")
  end

  describe "positive controls: the checker sees every runs-on form" do
    @planted [
      string: """
      jobs:
        a:
          runs-on: self-hosted
      """,
      inline_list: """
      jobs:
        a:
          runs-on: [self-hosted, linux, x64]
      """,
      block_list: """
      jobs:
        a:
          runs-on:
            - linux
            - self-hosted
      """,
      group_labels: """
      jobs:
        a:
          runs-on:
            group: runners
            labels: [self-hosted, x64]
      """,
      matrix_include_from_json: """
      jobs:
        a:
          strategy:
            matrix:
              include:
                - arch: amd64
                  runner: '["self-hosted", "linux", "x64"]'
                - arch: arm64
                  runner: '"ubuntu-24.04-arm"'
          runs-on: ${{ fromJSON(matrix.runner) }}
      """,
      matrix_top_level: """
      jobs:
        a:
          strategy:
            matrix:
              os: [ubuntu-latest, self-hosted]
          runs-on: ${{ matrix.os }}
      """,
      unresolvable_expression: """
      jobs:
        a:
          runs-on: ${{ vars.RUNNER }}
      """
    ]

    for {form, yaml} <- @planted do
      @yaml yaml
      test "#{form} is reported" do
        assert [{"a", _reason}] = violations(parse!(@yaml))
      end
    end

    test "GitHub-hosted labels in each form pass" do
      yaml = """
      jobs:
        a:
          runs-on: ubuntu-latest
        b:
          runs-on: [ubuntu-24.04-arm]
        c:
          strategy:
            matrix:
              include:
                - runner: ubuntu-latest
                - runner: ubuntu-24.04-arm
          runs-on: ${{ matrix.runner }}
        d:
          uses: ./.github/workflows/other.yml
      """

      assert violations(parse!(yaml)) == []
    end
  end
end
