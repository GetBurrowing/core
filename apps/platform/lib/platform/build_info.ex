defmodule Platform.BuildInfo do
  @moduledoc """
  Reports the git commit the running release was built from (task 01a089d5).

  The commit travels INSIDE the artifact as `priv/build_commit`, written by
  `apps/platform/Dockerfile` from the `GIT_SHA` build arg before `mix release`
  snapshots `priv/`. It is deliberately not a runtime env var: an env var can
  be overridden by the container's EnvironmentFile and shows up in
  `podman inspect .Config.Env` alongside the secrets. No `git` subprocess and
  no `mix.exs` version is consulted.

  `commit/0` never raises and never returns an empty string; anything short
  of a readable, non-blank file yields `"unknown"`.
  """

  @unknown "unknown"

  @doc """
  The build commit. `Application.get_env(:platform, :build_commit)` wins when
  set (test injection seam); otherwise `priv/build_commit` inside the app dir
  is read via `commit_from_file/1`.
  """
  @spec commit() :: String.t()
  def commit do
    case Application.get_env(:platform, :build_commit) do
      nil -> commit_from_file(Application.app_dir(:platform, "priv/build_commit"))
      value -> value
    end
  end

  @doc """
  Reads a build-commit file. A missing or unreadable path, an empty file, or a
  whitespace-only file all yield `"unknown"`; surrounding whitespace (e.g. a
  trailing newline) is trimmed.
  """
  @spec commit_from_file(Path.t()) :: String.t()
  def commit_from_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> @unknown
          sha -> sha
        end

      {:error, _} ->
        @unknown
    end
  end
end
