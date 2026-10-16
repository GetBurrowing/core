defmodule Platform.Tasks.PostCommitTest do
  @moduledoc """
  Task 01a136c1 stage 1 — `Platform.Tasks.PostCommit` scope semantics. Pure
  process-dictionary behaviour; no database.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Platform.Tasks.PostCommit

  defp record(tag), do: fn -> send(self(), {:ran, tag}) end

  defp ran do
    receive do
      {:ran, tag} -> [tag | ran()]
    after
      0 -> []
    end
  end

  test "with no scope open, the thunk runs immediately and its value is returned" do
    refute PostCommit.open?()
    assert :value == PostCommit.run_after_commit(fn -> :value end)
  end

  test "queued thunks run in order, after the function returns {:ok, _}" do
    result =
      PostCommit.scope(fn ->
        PostCommit.run_after_commit(record(1))
        PostCommit.run_after_commit(record(2))
        assert PostCommit.open?()
        assert ran() == [], "a thunk ran before the scope's function returned"
        {:ok, :committed}
      end)

    assert result == {:ok, :committed}
    assert ran() == [1, 2]
    refute PostCommit.open?()
  end

  test "queued thunks are discarded when the function returns anything but {:ok, _}" do
    assert {:error, :rolled_back} ==
             PostCommit.scope(fn ->
               PostCommit.run_after_commit(record(:never))
               {:error, :rolled_back}
             end)

    assert ran() == []
    refute PostCommit.open?()
  end

  test "queued thunks are discarded and the scope closed when the function raises" do
    assert_raise RuntimeError, "boom", fn ->
      PostCommit.scope(fn ->
        PostCommit.run_after_commit(record(:never))
        raise "boom"
      end)
    end

    assert ran() == []
    refute PostCommit.open?()
  end

  test "a nested scope defers to the outermost one" do
    PostCommit.scope(fn ->
      inner =
        PostCommit.scope(fn ->
          PostCommit.run_after_commit(record(:inner))
          {:ok, :inner}
        end)

      assert inner == {:ok, :inner}
      assert ran() == [], "the inner scope flushed before the outer commit"
      {:ok, :outer}
    end)

    assert ran() == [:inner]
  end

  test "an inner commit inside an outer rollback runs nothing" do
    PostCommit.scope(fn ->
      PostCommit.scope(fn ->
        PostCommit.run_after_commit(record(:never))
        {:ok, :inner}
      end)

      {:error, :outer_rolled_back}
    end)

    assert ran() == []
  end

  test "a keyed thunk is queued once per scope; the first one wins" do
    PostCommit.scope(fn ->
      PostCommit.run_after_commit(record(:first), key: :k)
      PostCommit.run_after_commit(record(:second), key: :k)
      PostCommit.run_after_commit(record(:other), key: :other)
      PostCommit.run_after_commit(record(:unkeyed))
      PostCommit.run_after_commit(record(:unkeyed))
      {:ok, nil}
    end)

    assert ran() == [:first, :other, :unkeyed, :unkeyed]
  end

  test "a raising thunk is logged and does not stop the rest" do
    log =
      capture_log(fn ->
        assert {:ok, :done} ==
                 PostCommit.scope(fn ->
                   PostCommit.run_after_commit(fn -> raise "thunk failed" end)
                   PostCommit.run_after_commit(record(:after))
                   {:ok, :done}
                 end)
      end)

    assert log =~ "thunk failed"
    assert ran() == [:after]
  end

  test "a thunk that queues another runs it immediately, the scope being closed" do
    PostCommit.scope(fn ->
      PostCommit.run_after_commit(fn ->
        refute PostCommit.open?()
        PostCommit.run_after_commit(record(:nested))
      end)

      {:ok, nil}
    end)

    assert ran() == [:nested]
  end
end
