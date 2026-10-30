defmodule Platform.Social.ClipFixes do
  @moduledoc "Typed fix validation. Transcript text stays runner-local; caption targets are rechecked there."

  def validate(base, attrs) do
    start = base.actual_start_s || base.requested_start_s || base.trim_in_s
    stop = base.actual_end_s || base.requested_end_s || base.trim_out_s

    with true <- is_number(start) and is_number(stop),
         {:ok, fix} <- operation(attrs, start, stop),
         true <- fix["in_s"] >= 0 and fix["out_s"] > fix["in_s"] do
      {:ok, fix}
    else
      false -> {:error, :invalid_range}
      error -> error
    end
  end

  defp operation(%{"operation" => "nudge", "edge" => edge, "delta_s" => delta}, a, b)
       when edge in ["start", "end"] and delta in [-1, 1] do
    {:ok,
     %{
       "operation" => "nudge",
       "edge" => edge,
       "delta_s" => delta,
       "in_s" => if(edge == "start", do: a + delta, else: a),
       "out_s" => if(edge == "end", do: b + delta, else: b)
     }}
  end

  defp operation(%{"operation" => "edit_headline", "headline" => text}, a, b)
       when is_binary(text) do
    text = String.trim(text)

    if String.length(text) in 1..200 and not String.match?(text, ~r/[\r\n\x00-\x1f]/u) do
      text = text |> String.split() |> Enum.join(" ")

      {:ok,
       %{
         "operation" => "edit_headline",
         "in_s" => a,
         "out_s" => b,
         "headline" => %{"consumer" => "edit", "requested_headline" => text}
       }}
    else
      {:error, :invalid_headline}
    end
  end

  defp operation(%{"operation" => "regenerate_headline"}, a, b),
    do: {:ok, %{"operation" => "regenerate_headline", "in_s" => a, "out_s" => b}}

  defp operation(%{"operation" => "alternate_cut"}, a, b),
    do: {:ok, %{"operation" => "alternate_cut", "in_s" => a, "out_s" => b}}

  defp operation(
         %{
           "operation" => "caption_word",
           "position" => pos,
           "original" => original,
           "replacement" => replacement
         },
         a,
         b
       )
       when is_integer(pos) and pos >= 0 and is_binary(original) and is_binary(replacement) do
    if word?(original) and word?(replacement) and original != replacement do
      {:ok,
       %{
         "operation" => "caption_word",
         "in_s" => a,
         "out_s" => b,
         "caption_fixes" => %{
           "position" => pos,
           "original" => original,
           "replacement" => replacement
         }
       }}
    else
      {:error, :invalid_caption_word}
    end
  end

  defp operation(_, _, _), do: {:error, :invalid_fix}
  defp word?(text), do: String.length(text) in 1..100 and not String.match?(text, ~r/\s/u)
end
