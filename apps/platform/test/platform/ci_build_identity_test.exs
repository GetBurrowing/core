defmodule Platform.CiBuildIdentityTest do
  @moduledoc """
  A drift alarm on the `build-and-push` job in `.github/workflows/ci.yml`
  (task 01a089d5). Like `Platform.CiFirstRunGreenTest`, this reads the
  workflow's TEXT: it detects the `build-args` being edited away, and it
  cannot prove GitHub executed any of it. The execution evidence is e2e
  case (c) of the task: a CI-built image whose `/health` reports the commit
  it was built from.

  The contract pinned here: `apps/platform/Dockerfile` takes `ARG GIT_SHA`
  and writes it to `priv/build_commit`, which `Platform.BuildInfo.commit/0`
  reads. That arg only has a value if every `docker/build-push-action` step
  passes `GIT_SHA=${{ github.sha }}` under `build-args:`. The job is
  push-only, so `github.sha` is the branch head being built, not a merge
  commit. The step count is pinned so a third build step cannot appear
  without this guard noticing.
  """

  use ExUnit.Case, async: true

  @test_root Path.expand("..", __DIR__)
  @ci_workflow Path.expand("../../../.github/workflows/ci.yml", @test_root)

  setup_all do
    lines = @ci_workflow |> File.read!() |> String.split("\n")
    job = job_body(lines, "build-and-push")

    build_steps =
      job
      |> step_bodies()
      |> Enum.filter(&(code_only(&1) =~ ~r/docker\/build-push-action/))

    {:ok, job: job, build_steps: build_steps}
  end

  # A job body: from `  <name>:` (job indent, two spaces) to the next line at
  # job indent (`  <word>:` or `  #`). Same slicer as Platform.CiFirstRunGreenTest.
  defp job_body(lines, name) do
    start =
      Enum.find_index(lines, &(&1 == "  #{name}:")) ||
        flunk("no `#{name}:` job in #{@ci_workflow}")

    rest = Enum.drop(lines, start + 1)
    len = Enum.find_index(rest, &Regex.match?(~r/^  (\S|#)/, &1)) || length(rest)
    rest |> Enum.take(len) |> Enum.join("\n")
  end

  # Split a job body into step bodies on `      - name:` (step indent). Text
  # before the first named step (unnamed `- uses:` steps) is dropped; none of
  # those is a build step.
  defp step_bodies(job) do
    job
    |> String.split(~r/^(?=      - name:)/m)
    |> Enum.filter(&String.starts_with?(&1, "      - name:"))
  end

  # Comment-stripped view of a body, so a `#` line that merely mentions the
  # required text cannot satisfy an assertion.
  defp code_only(body) do
    body
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
    |> Enum.join("\n")
  end

  describe "the build-and-push job" do
    test "is push-only, so github.sha is the commit being built", %{job: job} do
      assert code_only(job) =~ ~r/^    if: github\.event_name == 'push'\s*$/m,
             "`build-and-push` is no longer gated on `github.event_name == 'push'`. " <>
               "On a pull_request event github.sha is a synthetic merge commit, so " <>
               "the baked build_commit would name a commit that exists on no branch."
    end

    test "has exactly two build-push-action steps", %{build_steps: steps} do
      assert length(steps) == 2,
             "expected exactly 2 `docker/build-push-action` steps in `build-and-push` " <>
               "(main and feature branch), found #{length(steps)}. A new build step " <>
               "must carry the GIT_SHA build-arg too; extend this test when adding one."
    end

    test "every build-push-action step passes GIT_SHA=github.sha as a build-arg",
         %{build_steps: steps} do
      for step <- steps do
        code = code_only(step)
        [name_line | _] = String.split(step, "\n")

        assert code =~ ~r/^\s+build-args: \|\n(\s+.*\n)*?\s+GIT_SHA=\$\{\{ github\.sha \}\}\s*$/m,
               "#{String.trim(name_line)} no longer passes `GIT_SHA=${{ github.sha }}` " <>
                 "under `build-args:`. The Dockerfile then writes `unknown` to " <>
                 "priv/build_commit and /health cannot report which commit is running."
      end
    end
  end
end
