defmodule Platform.Org.BurrowDocs.Source do
  @moduledoc """
  Compile-time source resolution for `Platform.Org.BurrowDocs`.

  The Burrow Docs corpus lives at the repo root in `docs/burrow/`. A release
  image has no repo root to walk to, so the Dockerfile copies the corpus into
  the app's `priv/burrow_docs` before `mix release` (see
  `Platform.Regression.BurrowDocsPackagingTest`). This module picks between
  the two:

    1. `apps/platform/priv/burrow_docs` when it exists (the release build);
    2. otherwise `docs/burrow` at the repo root (a dev or test checkout).

  It lives in its own module, rather than as private functions of
  `BurrowDocs`, because `BurrowDocs` calls it from its module body at compile
  time, when its own functions do not exist yet. Keeping it a plain function
  of its inputs also makes the zero-docs raise testable without a build.

  ## Fails loudly, on purpose

  `resolve!/1` raises when no candidate holds a single `.md` file. The contrast
  is `Platform.Responsibilities.ContextProviders.adr_dir/0`, which resolves at
  runtime and fails soft by design. Product docs are the other way round: an
  empty corpus is always a packaging slip, and shipping it would prune every
  `burrow/page/*` row on the next boot. A failed build is the cheaper outcome.
  """

  @priv_subdir "burrow_docs"

  @doc "The subdirectory of the app's `priv/` the Dockerfile copies the corpus into."
  @spec priv_subdir() :: String.t()
  def priv_subdir, do: @priv_subdir

  @doc """
  The default candidate directories, in preference order, resolved from this
  file's location rather than configured.
  """
  @spec default_candidates() :: [Path.t()]
  def default_candidates do
    [
      Path.expand("../../../../priv/#{@priv_subdir}", __DIR__),
      Path.expand("../../../../../../docs/burrow", __DIR__)
    ]
  end

  @doc """
  Returns `{dir, files}` for the first candidate directory that exists, where
  `files` is the sorted list of top-level `*.md` paths in it.

  Raises when no candidate exists, or when the chosen one holds no `.md`
  file. A present-but-empty first candidate does NOT fall through to the next:
  if the release build copied an empty directory, that is the slip to report.
  """
  @spec resolve!([Path.t()]) :: {Path.t(), [Path.t()]}
  def resolve!(candidates \\ default_candidates()) do
    case Enum.find(candidates, &File.dir?/1) do
      nil ->
        raise ArgumentError,
              "Burrow Docs source not found: none of #{inspect(candidates)} exists. " <>
                "The release build must copy docs/burrow into priv/#{@priv_subdir} " <>
                "before `mix release`."

      dir ->
        case markdown_files(dir) do
          [] ->
            raise ArgumentError,
                  "Burrow Docs source #{dir} contains no .md files. Refusing to compile " <>
                    "an empty product docs corpus."

          files ->
            {dir, files}
        end
    end
  end

  @doc "Sorted top-level `*.md` files in `dir`."
  @spec markdown_files(Path.t()) :: [Path.t()]
  def markdown_files(dir) do
    dir
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.sort()
  end
end
