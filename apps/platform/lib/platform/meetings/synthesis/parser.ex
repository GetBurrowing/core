defmodule Platform.Meetings.Synthesis.Parser do
  @moduledoc "Typed, grounded meeting findings. Model refs resolve only against trusted prompt sources."
  alias Platform.Meetings.{SynthesisFinding, IntentPrivacy}
  @block ~r/<meeting-finding\b([^>]*)>([\s\S]*?)<\/meeting-finding>/
  @cite ~r/<cite\b([^>]*)\s*\/>/
  @attr ~r/([\w-]+)\s*=\s*"([^"]*)"/
  @rank %{"low" => 0, "medium" => 1, "high" => 2}

  def ref(%{ref: {kind, id}}), do: "#{kind}:#{id}"

  def parse(text, sources, min_confidence \\ "medium")

  def parse(text, sources, min_confidence) when is_binary(text) do
    # Multiple source records may share a ref but carry different dependency
    # checks. Preserve all of them; none may be bypassed by choosing a title.
    index = Enum.group_by(sources, &ref/1)

    Regex.scan(@block, text)
    |> Enum.flat_map(fn [_, attrs, raw] ->
      attrs = attributes(attrs)

      refs =
        Regex.scan(@cite, raw) |> Enum.map(fn [_, a] -> attributes(a)["ref"] end) |> Enum.uniq()

      citations = Enum.flat_map(refs, &Map.get(index, &1, []))
      covered = citations |> Enum.flat_map(& &1.meeting_ids) |> Enum.uniq() |> Enum.sort()

      sides =
        refs
        |> Enum.flat_map(fn ref ->
          meetings = Map.get(index, ref, []) |> Enum.flat_map(& &1.meeting_ids) |> Enum.uniq()
          if meetings == [], do: [ref], else: meetings
        end)
        |> Enum.uniq()

      named =
        String.split(attrs["meetings"] || Enum.join(covered, ","), ",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.uniq()
        |> Enum.sort()

      body = Regex.replace(@cite, raw, "") |> String.trim()

      valid =
        attrs["kind"] in SynthesisFinding.kinds() and
          Map.get(@rank, attrs["confidence"], -1) >= Map.get(@rank, min_confidence, 3) and
          refs != [] and Enum.all?(refs, &Map.has_key?(index, &1)) and
          named != [] and Enum.all?(named, &(&1 in covered)) and
          (attrs["kind"] != "conflicts_with" or (length(refs) >= 2 and length(sides) >= 2)) and
          body != "" and IntentPrivacy.candid_register(body) == :ok

      if valid,
        do: [
          %{
            kind: attrs["kind"],
            confidence: attrs["confidence"],
            body: body,
            citations: citations,
            meeting_ids: named
          }
        ],
        else: []
    end)
  end

  def parse(_, _, _), do: []
  defp attributes(text), do: Regex.scan(@attr, text) |> Map.new(fn [_, k, v] -> {k, v} end)
end
