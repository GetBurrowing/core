defmodule PlatformWeb.FilesLiveCodeLineRatchetTest do
  @moduledoc """
  Ratchet `files_live.ex` on CODE lines (task 01a1557a-b5f9 stage 3; the
  orchestrator's decision after the stage-2 audit, which found the file had
  grown from 1,857 to 2,327 raw lines while gaining the Files & Canvases
  browser).

  Same counting rule as `chat_live_code_line_ratchet_test.exs`, and for the
  same reason: a raw `wc -l` cap would price commentary, and the cheapest way
  under it would be to delete the explanations this file carries. Code lines
  only:

    1. drop blank / whitespace-only lines;
    2. drop lines whose first non-whitespace character is `#`;
    3. drop `@moduledoc` / `@doc` heredoc bodies and their delimiters.

  The pin is EXACT in both directions. Growing the file fails with the delta;
  shrinking it fails asking for the pin to come down, so a reduction is
  banked rather than silently spent. Pure, socket-free helpers belong in
  `PlatformWeb.Files.BrowserView` (moved there in this stage), markup in
  `PlatformWeb.Files.BrowserComponents`.

  MEASURED at the end of stage 3: 1,306 code lines (2,305 raw, of which 319
  are comment lines). Its detonation (one code line added) is recorded in
  the stage-3 report.
  """
  use ExUnit.Case, async: true

  @app_root Path.expand("../../..", __DIR__)
  @files_live_path Path.join(@app_root, "lib/platform_web/live/files_live.ex")

  @files_live_code_line_count 1255

  @doc_open ~r/^\s*@(module)?doc\s+"""/

  @doc "Code lines of `path` by the rule in the moduledoc."
  def code_line_count(path) do
    path
    |> lines()
    |> strip_doc_heredocs()
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
    |> length()
  end

  @doc "Raw lines (`wc -l`)."
  def line_count(path), do: path |> lines() |> length()

  @doc "Leading-`#` comment lines."
  def comment_line_count(path),
    do: path |> lines() |> Enum.count(&String.starts_with?(String.trim_leading(&1), "#"))

  defp lines(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> then(fn lines ->
      case List.last(lines) do
        "" -> Enum.drop(lines, -1)
        _ -> lines
      end
    end)
  end

  defp strip_doc_heredocs(lines) do
    {kept, _in_doc?} =
      Enum.reduce(lines, {[], false}, fn line, {kept, in_doc?} ->
        cond do
          in_doc? and String.trim(line) == ~s(""") -> {kept, false}
          in_doc? -> {kept, true}
          Regex.match?(@doc_open, line) -> {kept, true}
          true -> {[line | kept], false}
        end
      end)

    Enum.reverse(kept)
  end

  describe "files_live.ex code-line ratchet" do
    test "the code-line count equals the pin" do
      measured = code_line_count(@files_live_path)
      delta = measured - @files_live_code_line_count

      assert measured == @files_live_code_line_count, """
      FILES_LIVE CODE-LINE RATCHET TRIPPED.
        measured: #{measured} / pinned: #{@files_live_code_line_count} / delta: #{if delta > 0, do: "+"}#{delta}

      Growing: move socket-free helpers to PlatformWeb.Files.BrowserView and
      markup to PlatformWeb.Files.BrowserComponents before adding here.
      Shrinking: lower @files_live_code_line_count to #{measured} in this file.
      """
    end

    test "the rule discriminates: code lines are fewer than raw lines, and comments are many" do
      # A rule degraded to a raw count, or a file stripped of its prose, would
      # make the pin above measure something else while staying green.
      assert code_line_count(@files_live_path) < line_count(@files_live_path)
      assert comment_line_count(@files_live_path) > 200
    end
  end
end
