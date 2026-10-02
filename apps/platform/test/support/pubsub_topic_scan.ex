defmodule Platform.Test.PubSubTopicScan do
  @moduledoc """
  The PubSub topic-shape scanner behind
  `test/platform/regression/pubsub_topic_inventory_audit_test.exs`, moved here
  verbatim (ADR 0055, task 01a0ee08 stage 3) so a build-time module can run
  the same scan over ITS OWN lib and keep its own inventory: core's inventory
  lists only topics core's lib constructs, and a module's topics are the
  module's to classify. See that test's moduledoc for what the scan is and why
  its anchors make it complete.
  """

  # A topic-shaped string literal: colon-separated lowercase segments, an
  # interpolation, or a literal `*`. Either two-or-more segments, or one-or-more
  # followed by a trailing colon (the prefix half of a `<>` concatenation).
  @segment ~S/(?:[a-z][a-z0-9_]*|\*|\#\{[^"}]*\})/
  @literal_regex Regex.compile!(
                   ~s/"(#{@segment}(?::#{@segment})*:|#{@segment}(?::#{@segment})+)"/
                 )

  # Positions where a topic string can enter the system. A topic that reaches
  # none of these is unreachable by definition, which is what makes scanning
  # these five shapes complete rather than a sample.
  @anchor_regex ~r/(?:def\s+\w*topic\w*|@\w*topic\w*\s|PubSub\.(?:un)?subscribe\(|PubSub\.(?:local_)?broadcast(?:_from)?!?\(|Endpoint\.broadcast!?\(|"topic"\s*=>|\btopic:\s)/

  # Characters after an anchor to search for a literal. Wide enough for the
  # multi-line `Phoenix.PubSub.broadcast(\n @pubsub,\n topic,\n event\n)` form.
  @anchor_window 260

  @doc "Returns `[{shape, relative_path}]` for every topic shape under `lib_root`, deduplicated on shape."
  def topic_shapes(lib_root) do
    lib_sources(lib_root)
    |> Enum.flat_map(fn {relative_path, source} ->
      @anchor_regex
      |> Regex.scan(source, return: :index, capture: :first)
      |> Enum.flat_map(fn [{offset, length}] ->
        source
        |> window(offset + length, @anchor_window)
        |> then(&Regex.scan(@literal_regex, &1, capture: :all_but_first))
        |> Enum.map(fn [raw] -> {normalise(raw), relative_path} end)
      end)
    end)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.sort()
  end

  @doc "Every `.ex` file under `lib_root`, as `{relative_path, source_with_prose_blanked}`."
  def lib_sources(lib_root) do
    Path.wildcard(Path.join(lib_root, "**/*.ex"))
    |> Enum.map(fn path ->
      {Path.relative_to(path, lib_root), path |> File.read!() |> strip_prose()}
    end)
  end

  @doc false
  def window(source, offset, size) do
    binary_part(source, offset, min(size, byte_size(source) - offset))
  end

  defp normalise(raw) do
    raw
    |> String.replace(~r/\#\{[^}]*\}/, "<id>")
    |> then(fn shape -> if String.ends_with?(shape, ":"), do: shape <> "<id>", else: shape end)
  end

  # Blanks out `#` comments and `"""` heredoc bodies, preserving line COUNT.
  #
  # Necessary because moduledocs across lib quote topic strings while
  # explaining them, and a doc mentioning a topic is not a call site. Copied
  # from board_topic_scope_audit_test.exs, which needs it for the same reason.
  defp strip_prose(source) do
    source
    |> String.split("\n")
    |> Enum.map_reduce(false, fn line, in_heredoc? ->
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
end
