defmodule Platform.People.PageGuard do
  @moduledoc """
  Deterministic markdown guard for people pages.

  `enforce/2` takes the tier (`:card` or `:private`) and the page markdown
  and returns markdown that obeys the page grammar plus counts of what was
  removed. It is pure and idempotent: `enforce(enforce(x)) == enforce(x)`.

  Why markdown and not a struct: the Historian-role holder is a native or
  federated runtime whose dispatch is fire-and-forget, so no output handler
  runs. The agent writes pages itself through the memory tools, and the only
  thing we can enforce deterministically is the text that reaches
  `Wiki.upsert_page/3`.

  ## Grammar

      ---
      tier: card | private
      name: ...
      aliases: ...
      user_id: ...
      relation: ...
      organisation: ...
      role: ...
      last_seen: ...
      readers: [subject, admins]      # private only, inserted when missing
      subject_user_id: ...            # private only, inserted when missing
      ---

      ## Role
      ## Current projects
      ## Interactions
      - <YYYY-MM-DD> <kind>: <title> [cite: <ref>]
      ## Perspectives
      - <statement> — own words [cite: <ref>]
      ## Agents

  ## Rules

    * any line where `Platform.People.Privacy.trait_language?/1` is true is
      dropped; an Interactions bullet keeps its date, kind, title and cite and
      loses only the free text after the title;
    * a Perspectives bullet without BOTH `own words` and `[cite: ...]` is
      dropped;
    * a `:card` never carries `## Perspectives` or `## Interactions`, and
      never carries `readers:` / `subject_user_id:`;
    * `Platform.People.Privacy.scrub/1` runs last over everything.
  """

  alias Platform.People.Privacy

  @card_forbidden_sections ["perspectives", "interactions"]
  @private_readers "readers: [subject, admins]"

  @interaction_bullet ~r/\A-\s+(?<date>\d{4}-\d{2}-\d{2})\s+(?<kind>[^:]+?):\s*(?<rest>.*)\z/u
  @cite ~r/\[cite:\s*[^\]]*\]/u
  @title_separator ~r/\s+(?:—|–|-|;)\s+/u

  @type tier :: :card | :private
  @type counts :: %{
          dropped_trait_lines: non_neg_integer(),
          dropped_uncited_perspectives: non_neg_integer(),
          dropped_card_sections: non_neg_integer(),
          redactions: non_neg_integer()
        }

  @doc "Enforces the page grammar for `tier` on `markdown`."
  @spec enforce(tier(), String.t()) :: {String.t(), counts()}
  def enforce(tier, markdown) when tier in [:card, :private] and is_binary(markdown) do
    {frontmatter, body} = split_frontmatter(markdown)
    frontmatter = fix_frontmatter(tier, frontmatter)

    {body_lines, counts} = walk_body(tier, String.split(body, "\n"))

    assembled =
      (["---"] ++ frontmatter ++ ["---", ""] ++ trim_blank_edges(body_lines))
      |> Enum.join("\n")
      |> String.trim_trailing()
      |> Kernel.<>("\n")

    {scrubbed, report} = Privacy.scrub(assembled)
    redactions = Enum.reduce(report, 0, fn %{count: n}, acc -> acc + n end)

    {scrubbed, Map.put(counts, :redactions, redactions)}
  end

  # -- frontmatter ------------------------------------------------------------

  defp split_frontmatter(markdown) do
    lines = markdown |> String.replace("\r\n", "\n") |> String.split("\n")

    case lines do
      ["---" | rest] ->
        case Enum.split_while(rest, &(String.trim(&1) != "---")) do
          {fm, ["---" | body]} -> {Enum.map(fm, &String.trim_trailing/1), Enum.join(body, "\n")}
          _ -> {[], markdown}
        end

      _ ->
        {[], markdown}
    end
  end

  defp fix_frontmatter(tier, lines) do
    lines =
      lines
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.reject(&key?(&1, "tier"))

    lines = ["tier: #{tier}" | lines]

    case tier do
      :card ->
        Enum.reject(lines, fn line -> key?(line, "readers") or key?(line, "subject_user_id") end)

      :private ->
        lines
        |> ensure_line("readers", @private_readers)
        |> ensure_line("subject_user_id", "subject_user_id: #{value_of(lines, "user_id")}")
    end
  end

  defp ensure_line(lines, key, line) do
    if Enum.any?(lines, &key?(&1, key)), do: lines, else: lines ++ [line]
  end

  defp key?(line, key), do: String.starts_with?(String.trim_leading(line), key <> ":")

  defp value_of(lines, key) do
    case Enum.find(lines, &key?(&1, key)) do
      nil -> ""
      line -> line |> String.split(":", parts: 2) |> Enum.at(1, "") |> String.trim()
    end
  end

  # -- body -------------------------------------------------------------------

  defp walk_body(tier, lines) do
    initial = %{
      section: nil,
      skipping: false,
      out: [],
      counts: %{dropped_trait_lines: 0, dropped_uncited_perspectives: 0, dropped_card_sections: 0}
    }

    state = Enum.reduce(lines, initial, &step(tier, &1, &2))
    {Enum.reverse(state.out), state.counts}
  end

  defp step(tier, line, state) do
    line = String.trim_trailing(line)

    case section_name(line) do
      {:ok, name} ->
        if tier == :card and name in @card_forbidden_sections do
          state
          |> Map.put(:section, name)
          |> Map.put(:skipping, true)
          |> bump(:dropped_card_sections)
        else
          %{state | section: name, skipping: false, out: [line | state.out]}
        end

      :none ->
        if state.skipping, do: state, else: keep_or_drop(line, state)
    end
  end

  defp section_name(line) do
    case Regex.run(~r/\A##\s+(.+?)\s*\z/u, line) do
      [_, name] -> {:ok, String.downcase(name)}
      _ -> :none
    end
  end

  defp keep_or_drop(line, state) do
    cond do
      String.trim(line) == "" ->
        emit(state, line)

      Privacy.trait_language?(line) ->
        drop_trait(line, state)

      state.section == "perspectives" and bullet?(line) and not own_words_cited?(line) ->
        bump(state, :dropped_uncited_perspectives)

      true ->
        emit(state, line)
    end
  end

  defp drop_trait(line, state) do
    state = bump(state, :dropped_trait_lines)

    case state.section == "interactions" and Regex.named_captures(@interaction_bullet, line) do
      %{"date" => date, "kind" => kind, "rest" => rest} ->
        cite = cite_of(rest)
        title = rest |> String.replace(@cite, "") |> String.trim() |> title_of()

        if title != "" and not Privacy.trait_language?(title) do
          emit(state, Enum.join(["- #{date} #{kind}: #{title}" | List.wrap(cite)], " "))
        else
          state
        end

      _ ->
        state
    end
  end

  defp title_of(text) do
    text |> String.split(@title_separator, parts: 2) |> List.first() |> String.trim()
  end

  defp cite_of(text) do
    case Regex.run(@cite, text) do
      [cite] -> cite
      _ -> nil
    end
  end

  defp bullet?(line), do: String.starts_with?(String.trim_leading(line), "- ")

  defp own_words_cited?(line) do
    String.contains?(line, "own words") and Regex.match?(@cite, line)
  end

  defp emit(state, line), do: %{state | out: [line | state.out]}
  defp bump(state, key), do: update_in(state, [:counts, key], &(&1 + 1))

  defp trim_blank_edges(lines) do
    lines
    |> Enum.drop_while(&(String.trim(&1) == ""))
    |> Enum.reverse()
    |> Enum.drop_while(&(String.trim(&1) == ""))
    |> Enum.reverse()
  end
end
