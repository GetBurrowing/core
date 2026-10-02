defmodule Platform.Regression.ADRCorpusPackagingTest do
  @moduledoc """
  The ADR index resolves `available?: false, reason: :adr_dir_unreachable`
  inside the release image unless the ADR corpus is physically packaged into
  the app's `priv/`. Every link in that packaging chain fails SILENTLY — a
  green build, a running image, and a drift check that reports "no
  architectural decisions" instead of erroring.

  The three silent failure modes this file exists to catch:

    1. The `COPY docs/decisions priv/adr_decisions` line is dropped. Build
       still succeeds; the image just has no corpus.
    2. The COPY drifts BELOW `RUN mix release`. `mix release` snapshots
       `priv/` as it runs, so a later copy lands in the build stage's
       working tree and never reaches the release the runtime stage takes.
    3. `.dockerignore` grows an entry that excludes `docs`. Docker reads
       only the context-root ignore file, so the COPY silently copies
       nothing.

  It also pins the build context itself: the corpus is at the REPO ROOT, so
  a context of `apps/platform` puts `docs/decisions` physically out of reach
  and no Dockerfile edit can recover it.

  Everything here is asserted against the files AS TEXT — the point is to
  fail on the source that CI actually consumes, not on a re-derivation of it.
  """
  use ExUnit.Case, async: true

  # The repo root, walked from this file rather than configured, so the test
  # carries no absolute path and no assumption about the checkout location.
  @repo_root Path.expand("../../../../..", __DIR__)

  @dockerfile Path.join(@repo_root, "apps/platform/Dockerfile")

  # Every image Dockerfile under apps/ (ADR 0055 stage 4: the without-modules
  # image above and each with-modules release host's). Globbed, never listed,
  # so core names no module and a new image cannot skip these assertions.
  @image_dockerfiles Path.wildcard(Path.join(@repo_root, "apps/*/Dockerfile"))
  @dockerignore Path.join(@repo_root, ".dockerignore")
  @ci_workflow Path.join(@repo_root, ".github/workflows/ci.yml")

  @runtime_config Path.join(@repo_root, "apps/platform/config/runtime.exs")

  # Derived, never retyped. The subdir name lives in exactly one place
  # (ContextProviders); if the Dockerfile's COPY target and the runtime.exs
  # config block are allowed to spell it independently they can drift apart
  # into a green build that ships a corpus nothing reads.
  @adr_priv_subdir Platform.Responsibilities.ContextProviders.adr_priv_subdir()

  @copy_line "COPY docs/decisions priv/#{@adr_priv_subdir}"
  @release_line "RUN mix release"
  @config_line "config :platform, :adr_dir,"

  # Assertion (c) is an EXACT-LITERAL set, not a regex. A regex like
  # ~r/^docs/ is exactly the thing a future edit slips past: `docs/`,
  # `**/docs`, `./docs` and `docs/decisions` all exclude the corpus and only
  # one of them starts with a bare `docs`. Enumerating the spellings means a
  # new one has to be invented to evade this, rather than merely typed.
  @docs_excluding_literals [
    "docs",
    "docs/",
    "/docs",
    "/docs/",
    "./docs",
    "docs/*",
    "docs/**",
    "**/docs",
    "**/docs/**",
    "docs/decisions",
    "docs/decisions/",
    "/docs/decisions",
    "**/docs/decisions",
    "docs/decisions/*",
    "docs/decisions/**"
  ]

  setup_all do
    for path <- [@dockerfile, @dockerignore, @ci_workflow, @runtime_config] do
      assert File.exists?(path),
             "expected #{Path.relative_to(path, @repo_root)} to exist relative to the repo root " <>
               "resolved from __DIR__ (#{@repo_root}); if the tree moved, fix the walk, do not " <>
               "hardcode a path"
    end

    %{
      dockerfile: File.read!(@dockerfile),
      dockerignore: File.read!(@dockerignore),
      ci: File.read!(@ci_workflow),
      runtime_config: File.read!(@runtime_config)
    }
  end

  describe "runtime.exs points the provider at the packaged corpus" do
    test "resolves the path from the app dir and the shared subdir constant", %{
      runtime_config: runtime_config
    } do
      assert runtime_config =~ "Application.app_dir(:platform,",
             """
             config/runtime.exs never calls Application.app_dir(:platform, ...).

             Packaging the corpus into the image is only half the fix:
             ContextProviders.adr_dir/0 walks ancestors for a literal
             docs/decisions directory, which no release has. Without a config
             key pointing at the packaged copy the index stays
             :adr_dir_unreachable and the bytes are dead weight.
             """

      assert runtime_config =~ "ContextProviders.adr_priv_subdir()",
             "config/runtime.exs must derive the priv subdir from " <>
               "ContextProviders.adr_priv_subdir/0"

      refute runtime_config =~ ~s("#{@adr_priv_subdir}"),
             """
             config/runtime.exs contains the literal "#{@adr_priv_subdir}".

             That is a second hand-typed copy of a name the Dockerfile also
             spells. Two copies drift; derive it from
             ContextProviders.adr_priv_subdir/0 instead.
             """
    end

    test "writes the key only inside an existence guard", %{runtime_config: runtime_config} do
      raw = String.split(runtime_config, "\n")
      config_lines = Enum.filter(raw, &String.contains?(&1, @config_line))

      assert length(config_lines) == 1,
             "expected exactly one `#{@config_line}` line, found #{length(config_lines)}"

      [line] = config_lines

      refute String.starts_with?(line, @config_line),
             """
             `#{@config_line}` sits at top level in config/runtime.exs — it is
             written unconditionally.

             adr_dir/0 deliberately does NOT fall back when the key is set, so
             an unconditional key pointing at a priv/ directory that only
             exists inside a release image makes every dev and test run
             resolve :adr_dir_unreachable. The key must be nested inside a
             File.dir?/1 guard.
             """

      index = Enum.find_index(raw, &String.contains?(&1, @config_line))
      preceding = Enum.slice(raw, max(index - 12, 0), min(index, 12))

      assert Enum.any?(preceding, &String.contains?(&1, "File.dir?")),
             """
             No File.dir?/1 check in the 12 lines above `#{@config_line}`.

             The existence check is the load-bearing part: when nothing
             resolves, runtime.exs must write NO key at all so dev and test
             keep the ancestor walk.
             """
    end
  end

  describe "the Dockerfile packages the ADR corpus" do
    test "every image Dockerfile is found, core's among them" do
      # Positive control for the two cases below, which iterate this list.
      assert @dockerfile in @image_dockerfiles
      assert length(@image_dockerfiles) >= 2
    end

    test "every image Dockerfile copies docs/decisions into priv/adr_decisions" do
      for path <- @image_dockerfiles do
        assert @copy_line in lines(File.read!(path)),
               "#{Path.relative_to(path, @repo_root)} has no `#{@copy_line}` line."
      end
    end

    test "every image Dockerfile copies the corpus before `mix release`" do
      for path <- @image_dockerfiles do
        text = File.read!(path)
        rel = Path.relative_to(path, @repo_root)

        assert line_number!(text, @copy_line) < line_number!(text, @release_line),
               "#{rel}: `#{@copy_line}` is at or below `#{@release_line}`; the release " <>
                 "snapshots priv/ before the corpus lands."
      end
    end

    test "copies docs/decisions into priv/adr_decisions", %{dockerfile: dockerfile} do
      assert @copy_line in lines(dockerfile),
             """
             apps/platform/Dockerfile has no `#{@copy_line}` line.

             Without it the release image ships no ADR corpus and
             Platform.Responsibilities.ContextProviders.adr_dir/0 resolves
             {:error, :adr_dir_unreachable} in production — the drift check
             then reports zero decisions instead of failing.
             """
    end

    test "copies the corpus before `mix release` snapshots priv/", %{dockerfile: dockerfile} do
      copy_at = line_number!(dockerfile, @copy_line)
      release_at = line_number!(dockerfile, @release_line)

      assert copy_at < release_at,
             """
             `#{@copy_line}` is on line #{copy_at}, at or below `#{@release_line}` on line #{release_at}.

             `mix release` snapshots priv/ as it runs. A copy landing after it
             lands only in the build stage's working tree, which the runtime
             stage never reads — the image builds green and ships nothing.
             """
    end

    test "re-roots its build-stage sources under apps/platform", %{dockerfile: dockerfile} do
      dockerfile_lines = lines(dockerfile)

      for dir <- ~w(config assets priv lib) do
        assert "COPY apps/platform/#{dir} #{dir}" in dockerfile_lines,
               """
               Expected `COPY apps/platform/#{dir} #{dir}`.

               The build context is the repo root (see ci.yml), so an
               app-relative `COPY #{dir} #{dir}` resolves against the root and
               fails or copies the wrong tree.
               """
      end

      assert "COPY apps/platform/mix.exs apps/platform/mix.lock ./" in dockerfile_lines
    end
  end

  describe ".dockerignore keeps the corpus in the build context" do
    test "lives at the repo root, where Docker actually reads it" do
      refute File.exists?(Path.join(@repo_root, "apps/platform/.dockerignore")),
             """
             apps/platform/.dockerignore still exists.

             Docker reads ONLY the ignore file at the build context root, and
             the context is now the repo root. An app-level file is inert but
             looks authoritative — a trap for the next editor, who will add an
             exclusion there and watch it do nothing.
             """
    end

    test "excludes nothing that would remove docs from the context", %{
      dockerignore: dockerignore
    } do
      entries = ignore_entries(dockerignore)
      offending = Enum.filter(entries, &(&1 in @docs_excluding_literals))

      assert offending == [],
             """
             .dockerignore excludes the ADR corpus via #{inspect(offending)}.

             `#{@copy_line}` would then copy nothing, with no error — the exact
             silent degradation this packaging exists to close.
             """
    end

    test "still excludes the build artefacts the app-level file used to", %{
      dockerignore: dockerignore
    } do
      entries = ignore_entries(dockerignore)

      for entry <- [
            "**/_build",
            "**/deps",
            ".git",
            "**/.elixir_ls",
            "erl_crash.dump",
            "**/*.beam",
            "apps/platform/priv/static/cache_manifest.json",
            "apps/platform/test"
          ] do
        assert entry in entries,
               "the root .dockerignore dropped `#{entry}`, which the deleted " <>
                 "apps/platform/.dockerignore carried — the build context now " <>
                 "ships it to the daemon"
      end
    end
  end

  describe "CI builds from the repo root" do
    test "every docker build step uses the root context and the app's Dockerfile", %{ci: ci} do
      entries = lines(ci)

      build_steps = Enum.count(entries, &(&1 == "uses: docker/build-push-action@v7"))

      assert build_steps >= 2,
             "expected at least the main and feature-branch build steps, found #{build_steps}; " <>
               "if a step was renamed, update this test rather than weakening it"

      assert Enum.count(entries, &(&1 == "context: .")) == build_steps,
             """
             Not every docker/build-push-action step uses `context: .`.

             docs/decisions/ is at the repo root. With `context: apps/platform`
             it is physically outside the context and NO Dockerfile edit can
             reach it.
             """

      files =
        entries
        |> Enum.filter(&String.starts_with?(&1, "file: "))
        |> Enum.map(&String.replace_prefix(&1, "file: ", ""))

      assert length(files) == build_steps,
             "a root context without an explicit `file:` makes Docker look for " <>
               "./Dockerfile, which does not exist"

      assert "apps/platform/Dockerfile" in files,
             "no build step builds the without-modules image from apps/platform/Dockerfile"

      for file <- files do
        assert Path.join(@repo_root, file) in @image_dockerfiles,
               "`file: #{file}` is not an image Dockerfile under apps/*/, so the corpus " <>
                 "assertions above never read it"
      end
    end
  end

  defp lines(text) do
    text |> String.split("\n") |> Enum.map(&String.trim/1)
  end

  # Ignore-file semantics: blank lines and `#` comments are not patterns.
  defp ignore_entries(text) do
    text
    |> lines()
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  defp line_number!(text, needle) do
    index =
      text
      |> lines()
      |> Enum.find_index(&(&1 == needle))

    assert index, "expected a `#{needle}` line in the Dockerfile"
    index + 1
  end
end
