defmodule Platform.Regression.AttentionBroadcastFunnelAuditTest do
  @moduledoc """
  Source-scan guard: `Platform.Federation.AttentionDispatch` is the ONLY module
  under `apps/platform/lib` that may call
  `PlatformWeb.Endpoint.broadcast(topic, "attention", payload)`.

  ## What this defends

  Task 019fb90f made "a dispatch names a space; put the target agent in a
  writable posture there" an invariant by hanging it off the one primitive every
  dispatch surface already shares. Meetings, the TaskRouter, the chat responder
  and the dead-letter drain have almost nothing in common — different resolution
  chains, different telemetry, different failure vocabularies — but all of them
  end at an `"attention"` broadcast on `runtime:<runtime_id>`, because that is
  the topic `PlatformWeb.RuntimeChannel.join/3` matches.

  A helper anyone could forget to call would be a convention. What makes it a
  chokepoint is that the invite and the delivery live in the same function, so a
  new dispatcher cannot skip the first without also skipping the second. This
  test is what keeps that true: without it, half-application is invisible — the
  suite stays green while one surface quietly goes back to broadcasting raw, and
  the agents it dispatches are dead on arrival again.

  ## Scan and subtract, never a whitelist

  The offender set is computed as *every* file that matches, minus the one
  allowed file. It is deliberately NOT a comparison against a remembered list of
  known call sites.

  That is not a stylistic preference; the list-based form was tried and failed
  in this very task. Stage 3's own description surveyed six sites across four
  files. There were seven, across five: nobody counted
  `lib/platform/federation/dead_letter_replay.ex`. A test asserting "the matches
  are exactly these six" is satisfied by any site the author forgot, because a
  forgotten site is never in the expected list to begin with — the assertion
  would have gone green over a real hole. Subtracting a single allowed file has
  no such blind spot.

  ## Non-vacuity

  A source scan that silently matches nothing is worse than no scan, so
  `@allowed_file` is asserted to MATCH, not merely to be excused. That anchor
  catches the failure this scanner is most likely to suffer: a bug in the
  comment/heredoc stripping below that blinds the whole walk, which would
  otherwise present as a permanently-passing test.

  Cheap by construction — `Path.wildcard` + `File.read!` + regex, no DB, no
  PubSub — so it runs in the default `mix test` set alongside its peers in
  `test/platform/regression/`.
  """

  use ExUnit.Case, async: true

  @lib_root Path.expand("../../../lib", __DIR__)
  @allowed_file "platform/federation/attention_dispatch.ex"

  # A call to `Endpoint.broadcast/3` (or the `broadcast!` / `broadcast_from`
  # family) whose EVENT argument is the literal `"attention"`. Matching on the
  # event string rather than on the module is what makes the guard about the
  # invariant: an alias, a `PlatformWeb.` prefix or none, a rebound `topic`
  # variable — none of them matter, because all of them still put an attention
  # frame on the wire.
  #
  # `/s` plus a topic class that excludes parentheses, rather than a
  # line-oriented match: today every call site fits on one line, and a guard
  # that only sees one-liners would be defeated by nothing more devious than
  # `mix format` wrapping a long call. Excluding `()` from the topic argument
  # keeps the span bounded to a single call's parentheses.
  @broadcast_regex ~r/Endpoint\.broadcast[!\w]*\(\s*[^()]*?"attention"/s

  describe "attention broadcasts" do
    test "only Platform.Federation.AttentionDispatch broadcasts \"attention\"" do
      offenders =
        scan()
        |> Enum.reject(fn {relative_path, _lines} -> relative_path == @allowed_file end)

      assert offenders == [], format_offenders(offenders)
    end

    test "the scan actually sees the funnel itself (non-vacuity anchor)" do
      matched = Enum.map(scan(), fn {relative_path, _lines} -> relative_path end)

      assert @allowed_file in matched, """
      The source scan found NO `Endpoint.broadcast(_, "attention", _)` call in
      #{@allowed_file}, which is the one file that is supposed to have one.

      That means the scanner is blind, not that the codebase is clean — the
      offender assertion above is passing vacuously and would keep passing if
      every dispatcher in the tree started broadcasting raw. Fix the scanner
      (most likely @broadcast_regex or the comment/heredoc stripping in
      strip_prose/1) before trusting anything else in this file.

      Files the scan DID match: #{inspect(matched)}
      """
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  # Returns `[{relative_path, line_numbers}]` for every file under
  # `apps/platform/lib` containing at least one attention broadcast, sorted.
  defp scan do
    Path.wildcard(Path.join(@lib_root, "**/*.ex"))
    |> Enum.reduce([], fn absolute_path, acc ->
      stripped = absolute_path |> File.read!() |> strip_prose()

      lines =
        @broadcast_regex
        |> Regex.scan(stripped, return: :index, capture: :first)
        |> Enum.map(fn [{offset, _len}] -> line_number(stripped, offset) end)

      case lines do
        [] -> acc
        _ -> [{Path.relative_to(absolute_path, @lib_root), lines} | acc]
      end
    end)
    |> Enum.sort()
  end

  # Blanks out `#` comments and `"""` heredoc bodies, preserving line COUNT so
  # the failure message can cite real line numbers.
  #
  # Necessary because the funnel's own moduledoc quotes the primitive it
  # forbids, and any module documenting *why* it routes through the funnel is
  # likely to quote it too. Without stripping, writing an accurate comment about
  # this rule would break the rule's own test — a guard nobody can explain in
  # prose is a guard that gets deleted.
  #
  # Blanking rather than dropping is the point: the newlines survive, so byte
  # offsets still map to source line numbers.
  defp strip_prose(source) do
    source
    |> String.split("\n")
    |> Enum.map_reduce(false, fn line, in_heredoc? ->
      # An even count of `"""` on a line opens and closes within it and leaves
      # the state unchanged; an odd count toggles. Either way the line is prose.
      delimiters = length(String.split(line, ~s("""))) - 1
      next? = if rem(delimiters, 2) == 1, do: not in_heredoc?, else: in_heredoc?

      cond do
        in_heredoc? or delimiters > 0 -> {"", next?}
        String.starts_with?(String.trim_leading(line), "#") -> {"", next?}
        true -> {line, next?}
      end
    end)
    |> elem(0)
    |> Enum.join("\n")
  end

  # Byte offset -> 1-based line number. `:binary.matches/2` rather than
  # `String.split/2` because a regex offset is a BYTE offset and can land
  # mid-codepoint, which would make a String function raise on an otherwise
  # healthy file.
  defp line_number(source, offset) do
    length(:binary.matches(binary_part(source, 0, offset), "\n")) + 1
  end

  defp format_offenders(offenders) do
    body =
      Enum.map_join(offenders, "\n", fn {path, lines} ->
        "  lib/#{path} — line(s) #{Enum.map_join(lines, ", ", &Integer.to_string/1)}"
      end)

    """
    The following module(s) call `Endpoint.broadcast(_, "attention", _)`
    directly. Route it through `Platform.Federation.AttentionDispatch.broadcast/3`
    instead:

    #{body}

    Why this is not a style rule: the funnel puts the target agent in a
    writable posture in the space the dispatch names — and COMMITS that invite
    — before the signal leaves. A runtime can act on an attention within
    milliseconds, and its first move is typically a tool call against the space
    it was just told about. A dispatcher that broadcasts directly delivers a
    signal the receiving agent cannot act on: it can read the request and
    cannot post a message or create a canvas in the space it was asked to work
    in, with no error raised anywhere a human sees it.

    The call takes the space and the agent as OPTIONS, so nothing is added to
    the wire payload:

        AttentionDispatch.broadcast(runtime_id, payload,
          space_id: <the space this dispatch names, or nil>,
          agent_id: <agent struct, id, or slug>,
          source: <:task_router | :agent_responder | :meeting_scribe | ...>
        )

    `space_id: nil` is a first-class value for dispatches that legitimately
    name no space — it becomes a clean `:no_space_named` skip and the broadcast
    still goes out. An invite refusal NEVER blocks delivery.
    """
  end
end
