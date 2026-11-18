defmodule PlatformWeb.GoalsTabBarMarkerGuardTest do
  @moduledoc """
  Source guard (task 01a1ecb3 stage 1): every text-entry field under
  `apps/goals/lib/platform_web/live` carries `data-hides-tab-bar`.

  core's app.css hides the phone's glass rail and zeroes its clearance under
  `:root:has([data-hides-tab-bar]:focus)` (beside the ComposeInput rule), so a
  focused Goals field with the keyboard up is not painted over by the rail. A
  field without the marker keeps the rail on screen over it; this guard makes
  that a red test rather than a phone-only bug.

  Text entry means every `<textarea` and every `<input` whose `type` is not
  one of `@non_text` (an `<input` with no `type` is text). A positive control
  over planted source proves the scan can see a missing marker.
  """
  use ExUnit.Case, async: true

  @live Path.expand("../../lib/platform_web/live", __DIR__)
  @non_text ~w(hidden checkbox radio submit button reset image file range color)

  # Every `<input ...>` / `<textarea ...>` opening tag in `src`, with its line.
  # The tag ends at the first `>` outside `{...}` and quotes: an attribute
  # expression such as `id={"q-" <> @id}` holds a `>` that is not the tag's end.
  defp fields(src) do
    ~r/<(input|textarea)\b/
    |> Regex.scan(src, return: :index)
    |> Enum.map(fn [{at, _} | _] ->
      rest = binary_part(src, at, byte_size(src) - at)
      tag = binary_part(rest, 0, tag_end(rest, 1, 0, nil))
      line = src |> binary_part(0, at) |> String.split("\n") |> length()
      {line, tag}
    end)
  end

  defp tag_end(s, i, _depth, _quote) when i >= byte_size(s), do: byte_size(s)

  defp tag_end(s, i, depth, quote) do
    case {:binary.at(s, i), quote} do
      {q, q} -> tag_end(s, i + 1, depth, nil)
      {_, q} when q != nil -> tag_end(s, i + 1, depth, q)
      {?", nil} -> tag_end(s, i + 1, depth, ?")
      {?{, nil} -> tag_end(s, i + 1, depth + 1, nil)
      {?}, nil} -> tag_end(s, i + 1, depth - 1, nil)
      {?>, nil} when depth == 0 -> i + 1
      _ -> tag_end(s, i + 1, depth, nil)
    end
  end

  defp text_entry?(tag) do
    cond do
      tag =~ ~r/^<textarea\b/ -> true
      match = Regex.run(~r/\btype="([a-z]+)"/, tag) -> Enum.at(match, 1) not in @non_text
      true -> true
    end
  end

  defp unmarked(src) do
    for {line, tag} <- fields(src),
        text_entry?(tag),
        not (tag =~ ~r/\bdata-hides-tab-bar\b/),
        do: line
  end

  test "the scan sees a missing marker and skips non-text inputs (positive control)" do
    planted = """
    <input type="hidden" name="a" value="1" />
    <input
      type="text"
      name="b"
    />
    <input type="checkbox" name="c" />
    <textarea name="d"></textarea>
    <input name="e" data-hides-tab-bar />
    <input id={"q-" <> @id} name="f" data-hides-tab-bar />
    <input id={"q-" <> @id} name="g" />
    """

    assert unmarked(planted) == [2, 7, 10]
  end

  test "every Goals text input and textarea carries data-hides-tab-bar" do
    files = Path.wildcard(Path.join(@live, "*.ex"))
    assert files != []

    scanned =
      for file <- files, {_line, tag} <- fields(File.read!(file)), text_entry?(tag), do: tag

    # Anti-vacuity: the Goals text fields that exist today (New goal box,
    # log value, brief question) are all seen.
    assert length(scanned) >= 3

    missing =
      for file <- files, line <- unmarked(File.read!(file)), do: "#{Path.basename(file)}:#{line}"

    assert missing == [],
           "text fields without data-hides-tab-bar (the phone rail stays over them " <>
             "with the keyboard up): #{inspect(missing)}"
  end
end
