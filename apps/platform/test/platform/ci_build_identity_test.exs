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
  passes `GIT_SHA=${{ github.sha }}` under `build-args:` (both image
  flavours' Dockerfiles take it, ADR 0055). The job is
  push-only, so `github.sha` is the branch head being built, not a merge
  commit. The step count is pinned so a second build step cannot appear
  without this guard noticing.

  Multi-arch (task 01a0d6ab): `build-and-push` builds the `core` flavour
  (apps/platform/Dockerfile, without modules) as a matrix with one leg per
  architecture, each pushing an untagged image by digest, and
  `publish-manifest` applies the `core-*` tags with `docker buildx imagetools
  create`. The `play` flavour (ADR 0055) is built by `build-and-push-play`,
  amd64 only, which `needs: publish-manifest` so `latest` (on play) is still
  the last tag to move. The tag sets are asserted as raw literals, one per
  expression, rather than as a set derived from the file: a derived set would
  agree with whatever the workflow says, including a tag that silently
  disappeared.

  GHCR only (task 01a14afe): every image is pushed to `ghcr.io/getburrowing`
  and to no other registry. Docker Hub was a second publish target from task
  01a14a79 until this task; its repositories stay for rollback but receive no
  new tags. Each step's GHCR tag list is compared as a FULL list against its
  own raw literal, so a missing tag fails and so does a stray extra one (a
  membership check alone would pass a widened list). Separately, no tag,
  `-t` argument or `outputs:` name anywhere in the workflow may name
  `docker.io`: the `registry: docker.io` logins that remain are pull auth.
  """

  use ExUnit.Case, async: true

  @test_root Path.expand("..", __DIR__)
  @ci_workflow Path.expand("../../../.github/workflows/ci.yml", @test_root)

  setup_all do
    lines = @ci_workflow |> File.read!() |> String.split("\n")
    job = job_body(lines, "build-and-push")
    publish = job_body(lines, "publish-manifest")
    play = job_body(lines, "build-and-push-play")

    {:ok,
     job: job,
     publish: publish,
     play: play,
     build_steps: build_steps(job),
     play_steps: build_steps(play)}
  end

  defp build_steps(job) do
    job
    |> step_bodies()
    |> Enum.filter(&(code_only(&1) =~ ~r/docker\/build-push-action/))
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

    test "has exactly one build-push-action step (run once per matrix leg)",
         %{build_steps: steps} do
      assert length(steps) == 1,
             "expected exactly 1 `docker/build-push-action` step in `build-and-push` " <>
               "(the per-arch leg; tags are applied by publish-manifest), found " <>
               "#{length(steps)}. A new build step must carry the GIT_SHA build-arg " <>
               "too; extend this test when adding one."
    end

    test "its matrix builds linux/amd64 and linux/arm64", %{job: job} do
      code = code_only(job)

      for platform <- ["linux/amd64", "linux/arm64"] do
        assert code =~ ~r/^\s+platform: #{Regex.escape(platform)}\s*$/m,
               "`build-and-push` matrix no longer names `platform: #{platform}`. " <>
                 "The Mac install target (task 01a0d6ab) needs a native arm64 image."
      end

      assert code =~ ~r/^\s+platforms: \$\{\{ matrix\.platform \}\}\s*$/m,
             "the build step no longer passes `platforms: ${{ matrix.platform }}`, " <>
               "so every leg would build the runner's default arch."
    end

    test "each leg pushes by digest, untagged", %{build_steps: [step]} do
      code = code_only(step)

      assert code =~
               ~r/^\s+outputs: type=image,"name=ghcr\.io\/getburrowing\/core",push-by-digest=true,name-canonical=true,push=true\s*$/m,
             "the build step no longer pushes by digest to ghcr.io/getburrowing/core " <>
               "alone. A leg that tags directly would overwrite `latest` with a " <>
               "single-arch image; a leg missing the name leaves publish-manifest " <>
               "nothing to stitch; a second name would publish to another registry."

      refute code =~ ~r/^\s+tags:/m,
             "the per-arch build step carries `tags:`; tags belong to publish-manifest only."
    end

    test "every build-push-action step passes GIT_SHA=github.sha as a build-arg",
         %{build_steps: core_steps, play_steps: play_steps} do
      for step <- core_steps ++ play_steps do
        code = code_only(step)
        [name_line | _] = String.split(step, "\n")

        assert code =~ ~r/^\s+build-args: \|\n(\s+.*\n)*?\s+GIT_SHA=\$\{\{ github\.sha \}\}\s*$/m,
               "#{String.trim(name_line)} no longer passes `GIT_SHA=${{ github.sha }}` " <>
                 "under `build-args:`. The Dockerfile then writes `unknown` to " <>
                 "priv/build_commit and /health cannot report which commit is running."
      end
    end
  end

  describe "the publish-manifest job" do
    test "is push-only and needs build-and-push", %{publish: job} do
      code = code_only(job)
      assert code =~ ~r/^    if: github\.event_name == 'push'\s*$/m
      assert code =~ ~r/^    needs: build-and-push\s*$/m
    end

    # Raw literals, one per tag expression: the `core` flavour's tag sets
    # (ADR 0055; main: core, core-<sha>, core-<short sha>; feature branch:
    # core-<branch tag>, core-<sha>, core-<short sha>). Each must appear as a
    # `-t` argument.
    @ghcr_main_tags [
      "ghcr.io/getburrowing/core:core",
      "ghcr.io/getburrowing/core:core-${{ github.sha }}",
      "ghcr.io/getburrowing/core:core-${{ steps.vars.outputs.short_sha }}"
    ]
    @ghcr_branch_tags [
      "ghcr.io/getburrowing/core:core-${{ steps.vars.outputs.branch_tag }}",
      "ghcr.io/getburrowing/core:core-${{ github.sha }}",
      "ghcr.io/getburrowing/core:core-${{ steps.vars.outputs.short_sha }}"
    ]

    test "main publishes core, core-<sha> and core-<short sha>", %{publish: job} do
      step = named_step(job, "Create manifest list (main)")
      assert code_only(step) =~ ~r/^\s+if: github\.ref == 'refs\/heads\/main'\s*$/m

      for tag <- @ghcr_main_tags do
        assert code_only(step) =~ ~r/^\s+-t #{Regex.escape(tag)} \\\s*$/m,
               "main manifest step no longer tags `#{tag}`."
      end

      assert all_manifest_tags(step) == @ghcr_main_tags
    end

    test "feature branches publish the core- branch, sha and short sha tags",
         %{publish: job} do
      step = named_step(job, "Create manifest list (feature branch)")
      assert code_only(step) =~ ~r/^\s+if: github\.ref != 'refs\/heads\/main'\s*$/m

      for tag <- @ghcr_branch_tags do
        assert code_only(step) =~ ~r/^\s+-t #{Regex.escape(tag)} \\\s*$/m,
               "feature-branch manifest step no longer tags `#{tag}`."
      end

      assert all_manifest_tags(step) == @ghcr_branch_tags
    end

    test "no -t argument names a registry other than ghcr.io", %{publish: job} do
      for name <- ["Create manifest list (main)", "Create manifest list (feature branch)"] do
        step = named_step(job, name)
        all = all_manifest_tags(step)

        assert all != [], "#{name}: no -t arguments extracted"

        assert length(all) == length(manifest_tags(step, "ghcr.io/")),
               "#{name} tags a ref outside ghcr.io/: #{inspect(all)}"
      end
    end

    test "manifests are stitched from the GHCR digests only", %{publish: job} do
      collect = job |> named_step("Collect digests") |> code_only()

      assert collect =~
               ~s|echo "ghcr_refs=$(printf 'ghcr.io/getburrowing/core@sha256:%s ' *)" >> "$GITHUB_OUTPUT"|

      refute collect =~ ~r/^\s+echo "refs=/m,
             "Collect digests still emits a non-GHCR `refs` output."

      for name <- ["Create manifest list (main)", "Create manifest list (feature branch)"] do
        code = job |> named_step(name) |> code_only()

        assert length(Regex.scan(~r/docker buildx imagetools create/, code)) == 1,
               "#{name}: expected exactly one `imagetools create` (GHCR)"

        assert code =~ ~r/^\s+\$\{\{ steps\.digests\.outputs\.ghcr_refs \}\}\s*$/m
        refute code =~ "steps.digests.outputs.refs"
      end
    end
  end

  describe "the build-and-push-play job" do
    test "is push-only and runs after publish-manifest", %{play: job} do
      code = code_only(job)
      assert code =~ ~r/^    if: github\.event_name == 'push'\s*$/m

      assert code =~ ~r/^    needs: publish-manifest\s*$/m,
             "`build-and-push-play` must wait for publish-manifest, so `latest` " <>
               "(on the play image, watched by test-host's auto-update) is the last tag to move."
    end

    test "has exactly two build-push-action steps (main and feature branch)",
         %{play_steps: steps} do
      assert length(steps) == 2,
             "expected exactly 2 `docker/build-push-action` steps in `build-and-push-play`, " <>
               "found #{length(steps)}. A new build step must carry the GIT_SHA build-arg " <>
               "too; extend this test when adding one."
    end

    @ghcr_play_main_tags [
      "ghcr.io/getburrowing/core:play",
      "ghcr.io/getburrowing/core:play-${{ github.sha }}",
      "ghcr.io/getburrowing/core:play-${{ steps.vars.outputs.short_sha }}",
      "ghcr.io/getburrowing/core:latest",
      "ghcr.io/getburrowing/core:${{ github.sha }}",
      "ghcr.io/getburrowing/core:${{ steps.vars.outputs.short_sha }}"
    ]
    @ghcr_play_branch_tags [
      "ghcr.io/getburrowing/core:play-${{ steps.vars.outputs.branch_tag }}",
      "ghcr.io/getburrowing/core:play-${{ github.sha }}",
      "ghcr.io/getburrowing/core:play-${{ steps.vars.outputs.short_sha }}",
      "ghcr.io/getburrowing/core:${{ steps.vars.outputs.branch_tag }}",
      "ghcr.io/getburrowing/core:${{ github.sha }}",
      "ghcr.io/getburrowing/core:${{ steps.vars.outputs.short_sha }}"
    ]

    test "main keeps latest, the full sha and the short sha on the play image",
         %{play: job} do
      step = named_step(job, "Build and push play (main)")
      assert code_only(step) =~ ~r/^\s+if: github\.ref == 'refs\/heads\/main'\s*$/m

      for tag <- @ghcr_play_main_tags do
        assert code_only(step) =~ ~r/^\s+#{Regex.escape(tag)}\s*$/m,
               "play main build step no longer tags `#{tag}`."
      end

      assert play_tags(step, "ghcr.io/") == @ghcr_play_main_tags
      assert tag_list(step) == @ghcr_play_main_tags
    end

    test "feature branches tag the play image with the branch, sha and short sha",
         %{play: job} do
      step = named_step(job, "Build and push play (feature branch)")
      assert code_only(step) =~ ~r/^\s+if: github\.ref != 'refs\/heads\/main'\s*$/m

      for tag <- @ghcr_play_branch_tags do
        assert code_only(step) =~ ~r/^\s+#{Regex.escape(tag)}\s*$/m,
               "play feature-branch build step no longer tags `#{tag}`."
      end

      assert play_tags(step, "ghcr.io/") == @ghcr_play_branch_tags
      assert tag_list(step) == @ghcr_play_branch_tags
    end
  end

  # Task 01a14dd8 stage 2: the agent-host image is pushed under its burrow
  # name on GHCR, AND under the pre-rename suite-agent-host name (GHCR only
  # since task 01a14afe), because hosts installed before the rename pull that
  # name. A full list, so a dropped legacy tag fails as surely as a missing
  # burrow tag, and so does any tag on another registry.
  describe "the build-and-push-agent-host job" do
    @agent_host_ghcr_tags [
      "ghcr.io/getburrowing/suite-agent-host:latest",
      "ghcr.io/getburrowing/suite-agent-host:${{ github.sha }}",
      "ghcr.io/getburrowing/burrow-agent-host:latest",
      "ghcr.io/getburrowing/burrow-agent-host:${{ github.sha }}"
    ]

    test "tags burrow-agent-host on GHCR beside the legacy suite-agent-host tags" do
      step =
        @ci_workflow
        |> File.read!()
        |> String.split("\n")
        |> job_body("build-and-push-agent-host")
        |> named_step("Build and push agent-host")

      assert play_tags(step, "ghcr.io/") == @agent_host_ghcr_tags
      assert tag_list(step) == @agent_host_ghcr_tags
    end
  end

  # Task 01a14afe: Docker Hub is no longer a publish target. No image ref the
  # workflow PUBLISHES (a `-t` argument, a `tags:` list entry or an
  # `outputs:` name) may name docker.io. What docker.io text remains is pull
  # auth (`registry: docker.io` logins) and pulled images (`docker run
  # docker.io/oven/bun:1`), neither of which publishes anything.
  describe "no Docker Hub publish refs" do
    test "no -t, tags: entry or outputs: name in ci.yml names docker.io" do
      refs = published_refs(File.read!(@ci_workflow))

      assert Enum.any?(refs, &String.starts_with?(&1, "ghcr.io/getburrowing/")),
             "the extractor found no GHCR refs, so it cannot see any ref: #{inspect(refs)}"

      assert Enum.filter(refs, &(&1 =~ ~r/docker\.io/)) == []
    end

    test "positive control: the same extractor finds a planted docker.io ref in each form" do
      planted = """
          steps:
            - name: Build
              with:
                outputs: type=image,"name=docker.io/acme/suite-core,ghcr.io/getburrowing/core",push=true
                tags: |
                  docker.io/acme/suite-core:play
                  ghcr.io/getburrowing/core:play
            - name: Manifest
              run: |
                docker buildx imagetools create \\
                  -t docker.io/acme/suite-core:core \\
                  ${{ steps.digests.outputs.ghcr_refs }}
      """

      hub = planted |> published_refs() |> Enum.filter(&(&1 =~ ~r/docker\.io/))

      assert hub == [
               "docker.io/acme/suite-core",
               "docker.io/acme/suite-core:play",
               "docker.io/acme/suite-core:core"
             ]
    end
  end

  # Every ref a step publishes, in file order: each `outputs: type=image,"name=a,b"`
  # name, each `tags: |` list entry, and each `-t <ref> \\` argument.
  # Comment lines are dropped first.
  defp published_refs(text) do
    code = code_only(text)

    outputs =
      ~r/^\s+outputs: type=image,"name=([^"]+)"/m
      |> Regex.scan(code)
      |> Enum.flat_map(fn [_, names] -> String.split(names, ",") end)

    tags =
      ~r/^( +)tags: \|\n((?:\1  .*\n?)+)/m
      |> Regex.scan(code)
      |> Enum.flat_map(fn [_, _, block] ->
        block |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
      end)

    dash_t =
      ~r/^\s+-t (.+?) \\\s*$/m
      |> Regex.scan(code)
      |> Enum.map(&List.last/1)

    outputs ++ tags ++ dash_t
  end

  defp named_step(job, name) do
    job
    |> step_bodies()
    |> Enum.find(&String.starts_with?(&1, "      - name: #{name}\n")) ||
      flunk("no step named `#{name}`")
  end

  # Every `-t <ref>` argument in a manifest step whose ref starts with
  # `prefix`, in file order. Compared as a full list, so a stray extra tag on
  # any registry fails as surely as a missing one.
  defp manifest_tags(step, prefix) do
    step |> all_manifest_tags() |> Enum.filter(&String.starts_with?(&1, prefix))
  end

  # Every `-t <ref> \\` argument, whole: refs contain `${{ ... }}` with
  # spaces, so the ref runs to the line-continuation backslash.
  defp all_manifest_tags(step) do
    ~r/^\s+-t (.+?) \\\s*$/m
    |> Regex.scan(code_only(step))
    |> Enum.map(&List.last/1)
  end

  # Every bare-ref line of a play step (the `tags: |` list entries) whose ref
  # starts with `prefix`, in file order. Positive control for the extraction
  # is the GHCR literal lists above: an empty result fails them.
  defp play_tags(step, prefix) do
    step
    |> code_only()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, prefix))
  end

  # Every entry of a step's `tags: |` list, whatever its registry, in file
  # order. Compared against the GHCR literal as a FULL list, so a tag on any
  # other registry fails.
  defp tag_list(step) do
    [_, block] = String.split(code_only(step), ~r/^\s+tags: \|\n/m, parts: 2)

    block
    |> String.split("\n")
    |> Enum.take_while(&String.starts_with?(&1, "            "))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
