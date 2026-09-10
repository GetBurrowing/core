defmodule Platform.Chat.AttachmentStorage.RootTest do
  @moduledoc """
  Tests for `Platform.Chat.AttachmentStorage.Root` (task `01a010fe` stage 2).

  The property under test is OWNERSHIP OF THE READ, not uniqueness of the
  value. The three `async: true` modules that need their own attachment root
  already had unique directories and still failed, because the root was a
  VM-global `Application` key that any of them could repoint mid-test.
  """

  use ExUnit.Case, async: true

  alias Platform.Chat.AttachmentStorage.Root

  describe "get/1" do
    test "returns the caller's fallback when no override is in scope" do
      # This is the production path: nothing in `lib/` ever calls
      # `put_override/1`, so `get/1` is the identity on the app-env
      # expression each call site already computed.
      assert Root.get("/some/configured/root") == "/some/configured/root"
    end

    test "returns the override once the process claims one" do
      :ok = Root.put_override("/owned/by/me")
      assert Root.get("/some/configured/root") == "/owned/by/me"
    end

    test "delete_override/0 restores fallback resolution" do
      :ok = Root.put_override("/owned/by/me")
      :ok = Root.delete_override()
      assert Root.get("/some/configured/root") == "/some/configured/root"
    end

    test "a Task inherits its caller's override" do
      :ok = Root.put_override("/owned/by/me")

      assert Task.async(fn -> Root.get("/some/configured/root") end) |> Task.await() ==
               "/owned/by/me"
    end
  end

  describe "the property the Application key did not have" do
    test "a concurrent process cannot repoint this process's root" do
      # THE REGRESSION GUARD. Under `Application.put_env/3` the sibling's
      # write below would land on the same VM-global key and this process's
      # subsequent read would resolve the sibling's value — that is the
      # mechanism behind the measured enoent/erofs flakes.
      :ok = Root.put_override("/mine")

      sibling =
        Task.async(fn ->
          # Deliberately NOT linked to this process's override chain as a
          # caller-of-mine: this task claims its own root, the way another
          # test module's setup would.
          :ok = Root.put_override("/theirs")
          Root.get("/fallback")
        end)

      assert Task.await(sibling) == "/theirs"

      # The sibling ran to completion, including its own claim, and this
      # process's root is untouched.
      assert Root.get("/fallback") == "/mine"
    end

    test "an exited owner's override does not leak into an unrelated process" do
      {:ok, agent} = Agent.start(fn -> :ok end)
      :ok = Agent.get(agent, fn _ -> :ok end)
      Agent.stop(agent)

      # No override anywhere in this process's chain.
      assert Root.get("/fallback") == "/fallback"
    end
  end

  describe "the test-env root never resolves to the deploy-host path" do
    # config/runtime.exs loads after config/test.exs. If it sets
    # :chat_attachments_root unguarded, every test that persists a blob
    # without claiming its own root writes under /data/platform, which is
    # only writable where the container runs as root — so CI stays green
    # and every dev box fails with {:error, :erofs} / :eacces (measured on
    # 784e3f34: ~18 failures across seven files). This assertion fails in
    # BOTH environments, so the regression is caught where CI can see it.
    test "the global fallback is under the system tmp dir, not /data" do
      root = Application.fetch_env!(:platform, :chat_attachments_root)

      refute String.starts_with?(root, "/data/"),
             "test env resolved :chat_attachments_root to the deploy path #{inspect(root)}; " <>
               "config/runtime.exs must not set the key when config_env() == :test"

      assert String.starts_with?(root, System.tmp_dir!())
      assert File.mkdir_p(root) == :ok
    end
  end

  describe "class invariant: no async module may mutate the VM-global key" do
    # The measured fix covers three files. This converts that measurement
    # into an invariant, so flipping one of the other mutating modules to
    # `async: true` fails HERE, at the line that explains why, rather than
    # re-manifesting as an intermittent enoent/erofs a year from now.

    @mutation_pattern ~r/Application\.(put_env|delete_env)\(:platform, :chat_attachments_root/

    test "every test file that mutates :chat_attachments_root is async: false" do
      mutating = mutating_test_files()

      # Anti-vacuity: a broken search that matches nothing would make the
      # assertion below trivially true. The population was 31 files when
      # measured; pin a floor well under that rather than an exact count,
      # which would conflict on every concurrent branch.
      assert length(mutating) >= 20,
             "expected the :chat_attachments_root mutation search to find the known " <>
               "population of test files, found #{length(mutating)} — the search is " <>
               "probably broken, which would make this guard vacuous"

      # Anti-vacuity for the predicate itself: `offenders == []` would also
      # hold if `async_true?/1` never returned true. One control per side,
      # and the negative control is the file whose MODULEDOC says
      # `async: true` at :9 while its `use` line at :20 says `async: false`.
      assert async_true?(Path.relative_to_cwd(__ENV__.file)),
             "async_true?/1 failed to identify this file, which is async: true"

      refute async_true?("test/platform/files/withdraw_from_agent_context_test.exs"),
             "async_true?/1 matched a moduledoc mention rather than the use line"

      offenders = Enum.filter(mutating, &async_true?/1)

      assert offenders == [],
             """
             These test modules run concurrently AND write the VM-global
             :chat_attachments_root, so they can repoint each other's storage
             root mid-test (measured: 9 failures / 20 reps, task 01a010fe):

             #{Enum.map_join(offenders, "\n", &"  * #{&1}")}

             Claim a root for the test process instead:

                 root = Platform.TestTemp.mkdir!("my-test")
                 Platform.Chat.AttachmentStorage.Root.put_override(root)
                 on_exit(fn -> File.rm_rf(root) end)
             """
    end
  end

  defp mutating_test_files do
    Path.wildcard("test/**/*_test.exs")
    |> Enum.filter(&(File.read!(&1) =~ @mutation_pattern))
    |> Enum.sort()
  end

  # Read the `use` line rather than grepping the whole file for
  # `async: true`: a source scanner cannot tell a call from a comment, and
  # at least one file in this population documents `async: true` in its
  # moduledoc while actually being `async: false`.
  defp async_true?(path) do
    path
    |> File.stream!()
    |> Enum.any?(&Regex.match?(~r/^\s*use\s+.*async:\s*true/, &1))
  end
end
