defmodule Platform.BuildInfoTest do
  @moduledoc """
  `Platform.BuildInfo.commit_from_file/1` against real files (task 01a089d5),
  plus a drift alarm on the Dockerfile ordering that makes the file exist in
  the release at all. The Dockerfile assertions read TEXT: they detect the
  write being removed or moved below `mix release`, and cannot prove an image
  was built — that evidence is the task's e2e review.
  """

  use ExUnit.Case, async: true

  alias Platform.BuildInfo

  @sha_a "0123456789abcdef0123456789abcdef01234567"
  @sha_b "fedcba9876543210fedcba9876543210fedcba98"

  @app_root Path.expand("../..", __DIR__)
  @dockerfile Path.join(@app_root, "Dockerfile")

  defp tmp_file(contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "build_info_test_#{System.unique_integer([:positive])}"
      )

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "commit_from_file/1" do
    test "returns the sha in the file, and two files with different shas differ" do
      a = tmp_file(@sha_a)
      b = tmp_file(@sha_b)

      assert BuildInfo.commit_from_file(a) == @sha_a
      assert BuildInfo.commit_from_file(b) == @sha_b
      refute BuildInfo.commit_from_file(a) == BuildInfo.commit_from_file(b)
    end

    test "trims a trailing newline" do
      assert BuildInfo.commit_from_file(tmp_file(@sha_a <> "\n")) == @sha_a
    end

    test "missing path yields unknown" do
      missing = Path.join(System.tmp_dir!(), "build_info_test_missing_#{System.unique_integer()}")
      refute File.exists?(missing)
      assert BuildInfo.commit_from_file(missing) == "unknown"
    end

    test "empty file yields unknown" do
      assert BuildInfo.commit_from_file(tmp_file("")) == "unknown"
    end

    test "whitespace-only file yields unknown" do
      assert BuildInfo.commit_from_file(tmp_file(" \n\t\n")) == "unknown"
    end
  end

  describe "Dockerfile ordering guard" do
    test "ARG GIT_SHA precedes the priv/build_commit write, which precedes mix release" do
      lines = @dockerfile |> File.read!() |> String.split("\n")

      arg =
        Enum.find_index(lines, &Regex.match?(~r/^ARG GIT_SHA\b/, &1)) ||
          flunk("no `ARG GIT_SHA` line in #{@dockerfile}")

      write =
        Enum.find_index(lines, &Regex.match?(~r/^RUN .*> priv\/build_commit\s*$/, &1)) ||
          flunk("no `priv/build_commit` write in #{@dockerfile}")

      release =
        Enum.find_index(lines, &Regex.match?(~r/^RUN mix release\b/, &1)) ||
          flunk("no `RUN mix release` line in #{@dockerfile}")

      assert arg < write,
             "`ARG GIT_SHA` (line #{arg + 1}) must precede the priv/build_commit write (line #{write + 1})"

      assert write < release,
             "the priv/build_commit write (line #{write + 1}) must precede `RUN mix release` (line #{release + 1}) — the release snapshots priv/"
    end

    test "the write maps an absent build arg to unknown and the runtime stage labels the image" do
      text = File.read!(@dockerfile)
      assert text =~ ~s|printf '%s' "${GIT_SHA:-unknown}" > priv/build_commit|
      assert text =~ ~s|LABEL org.opencontainers.image.revision="${GIT_SHA:-unknown}"|
    end
  end
end
