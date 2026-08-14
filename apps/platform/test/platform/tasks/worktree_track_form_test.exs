defmodule Platform.Tasks.WorktreeTrackFormTest do
  @moduledoc """
  Git-level proof for task 01a001ac stage 5.

  The dispatch prompt now renders

      git worktree add ../worktrees/<slug> --track -b task/<slug> origin/task/<slug>

  instead of the CREATE form `-b task/<slug> origin/<default>`. The whole point
  is that the track form FAILS when the pre-created ref is absent, rather than
  silently minting a local branch the executor can then push under any name it
  likes — the exact freedom that let task 01a00161 push `task/ext-app-badge`
  instead of its recorded branch.

  This asserts against real `git`, not against our own rendering: the loudness
  is a property of git's behaviour, and a test that only re-read the prompt
  string would prove nothing about it.
  """
  use ExUnit.Case, async: true

  @branch "task/01a001ac-0ad8-7ece-bea6-2c524238fb86"

  setup do
    root = temp_dir("worktree-track")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, clone: seed_repo(root)}
  end

  test "the track form exits NON-ZERO when origin/<branch> is absent, and creates nothing", %{
    root: root,
    clone: clone
  } do
    dest = Path.join(root, "wt-missing")

    {output, code} =
      System.cmd(
        "git",
        ["worktree", "add", dest, "--track", "-b", @branch, "origin/#{@branch}"],
        cd: clone,
        stderr_to_stdout: true
      )

    assert code != 0, "expected a loud failure, got exit 0 with:\n#{output}"
    refute File.dir?(dest), "the worktree directory must not exist after a failed add"

    # And — the anti-vacuity half — no LOCAL branch was minted either. A local
    # branch left behind would be pushable, which is the whole bug.
    {branches, 0} = System.cmd("git", ["branch", "--list", @branch], cd: clone)
    assert String.trim(branches) == ""
  end

  test "the same track form SUCCEEDS once the ref exists on the remote", %{
    root: root,
    clone: clone
  } do
    # Positive control: if the command failed unconditionally, the test above
    # would prove nothing about the absent ref specifically.
    git!(clone, ["push", "origin", "HEAD:refs/heads/#{@branch}"])
    git!(clone, ["fetch", "origin"])

    dest = Path.join(root, "wt-present")

    {output, code} =
      System.cmd(
        "git",
        ["worktree", "add", dest, "--track", "-b", @branch, "origin/#{@branch}"],
        cd: clone,
        stderr_to_stdout: true
      )

    assert code == 0, output
    assert File.dir?(dest)

    {head, 0} = System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], cd: dest)
    assert String.trim(head) == @branch
  end

  defp seed_repo(root) do
    bare = Path.join(root, "bare.git")
    clone = Path.join(root, "clone")

    git!(nil, ["init", "--bare", "--initial-branch=main", bare])

    seed = Path.join(root, "seed")
    File.mkdir_p!(seed)
    git!(seed, ["init", "--initial-branch=main"])
    git!(seed, ["config", "user.email", "test@suite.local"])
    git!(seed, ["config", "user.name", "Test"])
    File.write!(Path.join(seed, "README.md"), "# track form\n")
    git!(seed, ["add", "."])
    git!(seed, ["commit", "-m", "init"])
    git!(seed, ["remote", "add", "origin", bare])
    git!(seed, ["push", "origin", "main"])

    git!(nil, ["clone", bare, clone])
    git!(clone, ["config", "user.email", "test@suite.local"])
    git!(clone, ["config", "user.name", "Suite Bot"])

    clone
  end

  defp git!(cd, args) do
    opts = if cd, do: [cd: cd, stderr_to_stdout: true], else: [stderr_to_stdout: true]
    {output, code} = System.cmd("git", args, opts)
    assert code == 0, "git #{Enum.join(args, " ")} failed:\n#{output}"
    output
  end

  defp temp_dir(prefix) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.system_time(:nanosecond)}-#{suffix}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
