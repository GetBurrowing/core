defmodule Platform.Regression.BurrowDocsPackagingTest do
  @moduledoc """
  The Burrow Docs corpus (`docs/burrow/`) is at the repo root, outside the
  app. `Platform.Org.BurrowDocs` reads it at compile time, and in a release
  build there is no repo root to walk to, so every image Dockerfile must copy
  it into the app's `priv/` before compiling and before `mix release`
  (task 01a10a44 stage 1). Mirrors `Platform.Regression.ADRCorpusPackagingTest`.

  What this file catches:

    1. The `COPY docs/burrow priv/burrow_docs` line is dropped from an image
       Dockerfile. `BurrowDocs.Source.resolve!/1` would then fail that build,
       but only when the image is built; this fails on the source first.
    2. The COPY drifts below `RUN mix compile` or `RUN mix release`.
    3. `.dockerignore` grows an entry that excludes `docs/burrow`, so the COPY
       copies nothing.

  Asserted against the files AS TEXT.
  """
  use ExUnit.Case, async: true

  alias Platform.Org.BurrowDocs.Source

  @repo_root Path.expand("../../../../..", __DIR__)

  # Globbed, never listed, so a new image Dockerfile cannot skip these checks.
  @image_dockerfiles Path.wildcard(Path.join(@repo_root, "apps/*/Dockerfile"))
  @core_dockerfile Path.join(@repo_root, "apps/platform/Dockerfile")
  @dockerignore Path.join(@repo_root, ".dockerignore")
  @gitignore Path.join(@repo_root, ".gitignore")

  # Derived from the module that reads it, never retyped.
  @copy_line "COPY docs/burrow priv/#{Source.priv_subdir()}"
  @compile_line "RUN mix compile"
  @release_line "RUN mix release"

  # Exact-literal spellings that would remove the corpus from the build
  # context. A regex is what a future edit slips past; see the ADR test.
  @excluding_literals [
    "docs",
    "docs/",
    "/docs",
    "/docs/",
    "./docs",
    "docs/*",
    "docs/**",
    "**/docs",
    "**/docs/**",
    "docs/burrow",
    "docs/burrow/",
    "/docs/burrow",
    "**/docs/burrow",
    "docs/burrow/*",
    "docs/burrow/**",
    "**/*.md",
    "*.md"
  ]

  test "every image Dockerfile is found, core's among them" do
    # Positive control for the loops below.
    assert @core_dockerfile in @image_dockerfiles
    assert length(@image_dockerfiles) >= 2
  end

  test "every image Dockerfile copies docs/burrow into priv/burrow_docs" do
    for path <- @image_dockerfiles do
      assert @copy_line in lines(File.read!(path)),
             """
             #{Path.relative_to(path, @repo_root)} has no `#{@copy_line}` line.

             Platform.Org.BurrowDocs compiles the corpus in from priv/#{Source.priv_subdir()}
             inside a release build; without the copy that build has no docs.
             """
    end
  end

  test "every image Dockerfile copies the corpus before `mix compile` and `mix release`" do
    for path <- @image_dockerfiles do
      text = File.read!(path)
      rel = Path.relative_to(path, @repo_root)
      copy_at = line_number!(text, @copy_line, rel)

      assert copy_at < line_number!(text, @compile_line, rel),
             "#{rel}: `#{@copy_line}` is at or below `#{@compile_line}`; the module " <>
               "compiles before the corpus lands."

      assert copy_at < line_number!(text, @release_line, rel),
             "#{rel}: `#{@copy_line}` is at or below `#{@release_line}`."
    end
  end

  test ".dockerignore excludes nothing that would remove docs/burrow from the context" do
    offending =
      @dockerignore
      |> File.read!()
      |> ignore_entries()
      |> Enum.filter(&(&1 in @excluding_literals))

    assert offending == [],
           ".dockerignore excludes the Burrow Docs corpus via #{inspect(offending)}; " <>
             "`#{@copy_line}` would copy nothing."
  end

  test ".gitignore keeps the build-time copy out of the repo" do
    assert "apps/platform/priv/#{Source.priv_subdir()}/" in lines(File.read!(@gitignore)),
           "a committed priv/#{Source.priv_subdir()} would win resolution over docs/burrow " <>
             "in every checkout and drift from it"
  end

  test "the corpus the copy reads exists in the repo" do
    assert Source.markdown_files(Path.join(@repo_root, "docs/burrow")) != []
  end

  defp lines(text), do: text |> String.split("\n") |> Enum.map(&String.trim/1)

  defp ignore_entries(text) do
    text
    |> lines()
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  defp line_number!(text, needle, rel) do
    index = text |> lines() |> Enum.find_index(&(&1 == needle))
    assert index, "expected a `#{needle}` line in #{rel}"
    index + 1
  end
end
