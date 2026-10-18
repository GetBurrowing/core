defmodule Platform.Chat.MentionBackfill do
  @moduledoc """
  Rewrites legacy `@Display Name` mentions in `chat_messages.content` to the
  bracketed `@[Display Name]` form defined by ADR 0037.

  This module is release-callable via `bin/platform eval` so the backfill can
  run in production. The `Mix.Tasks.Platform.BackfillMentions` task is a thin
  CLI wrapper around `run/1`.

  For each message, looks up the active participants in that message's space,
  then scans `content` for `@`-prefixed spans preceded by whitespace or
  start-of-text. Matches the **longest** participant `display_name` /
  `participant_id` (case-insensitive). Matches are rewritten to
  `@[<canonical display_name>]` so post-migration content uses the
  participant's stored casing.

  ## Idempotency

  Messages whose `content` already contains `@[` are skipped at the query
  level. Re-running is safe.

  ## Usage (release)

      # Dry-run
      bin/platform eval 'Platform.Chat.MentionBackfill.run()'

      # Write changes
      bin/platform eval 'Platform.Chat.MentionBackfill.run(apply: true)'

      # Scoped to one space
      bin/platform eval 'Platform.Chat.MentionBackfill.run(apply: true, space_id: "…")'

      # Cap the batch
      bin/platform eval 'Platform.Chat.MentionBackfill.run(apply: true, limit: 100)'
  """

  import Ecto.Query
  require Logger

  alias Platform.Chat.{Message, Participant}
  alias Platform.Repo

  @type opt ::
          {:apply, boolean()}
          | {:limit, pos_integer()}
          | {:space_id, String.t()}
          | {:log, (String.t() -> any())}

  @doc """
  Runs the backfill. Default mode is dry-run; pass `apply: true` to write.

  Returns `%{scanned: non_neg_integer(), changed: non_neg_integer()}`.
  """
  @spec run([opt()]) :: %{scanned: non_neg_integer(), changed: non_neg_integer()}
  def run(opts \\ []) do
    apply? = Keyword.get(opts, :apply, false)
    limit = Keyword.get(opts, :limit)
    space_id = Keyword.get(opts, :space_id)
    log = Keyword.get(opts, :log, &Logger.info/1)

    log.(
      "[MentionBackfill] mode=#{if apply?, do: "APPLY", else: "DRY RUN"}" <>
        if(space_id, do: " space_id=#{space_id}", else: "") <>
        if(limit, do: " limit=#{limit}", else: "")
    )

    messages = fetch_candidate_messages(space_id, limit)
    log.("[MentionBackfill] scanning #{length(messages)} candidate messages")

    participants_by_space = load_participants_by_space(messages)

    result =
      Enum.reduce(messages, %{scanned: 0, changed: 0}, fn msg, acc ->
        roster = Map.get(participants_by_space, msg.space_id, [])
        new_content = rewrite_content(msg.content, roster)

        if new_content != msg.content do
          log_change(log, msg, new_content)
          if apply?, do: persist(msg, new_content, log)
          %{acc | scanned: acc.scanned + 1, changed: acc.changed + 1}
        else
          %{acc | scanned: acc.scanned + 1}
        end
      end)

    summary =
      if apply? do
        "[MentionBackfill] rewrote #{result.changed} of #{result.scanned} messages"
      else
        "[MentionBackfill] DRY RUN — would rewrite #{result.changed} of #{result.scanned} messages; pass apply: true to write"
      end

    log.(summary)
    result
  end

  # ── Queries ─────────────────────────────────────────────────────────────────

  defp fetch_candidate_messages(space_id, limit) do
    base =
      from(m in Message,
        where: not is_nil(m.content),
        where: m.content_type == "text",
        # Idempotency: skip messages already in the new format.
        where: fragment("position('@[' in ?) = 0", m.content),
        order_by: [asc: m.inserted_at]
      )

    base =
      if is_binary(space_id) and space_id != "",
        do: from(m in base, where: m.space_id == ^space_id),
        else: base

    base = if is_integer(limit) and limit > 0, do: from(m in base, limit: ^limit), else: base

    Repo.all(base)
  end

  defp load_participants_by_space(messages) do
    space_ids = messages |> Enum.map(& &1.space_id) |> Enum.uniq()

    from(p in Participant,
      where: p.space_id in ^space_ids,
      select: %{
        space_id: p.space_id,
        display_name: p.display_name,
        participant_id: p.participant_id
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.space_id)
  end

  # ── Rewrite logic ───────────────────────────────────────────────────────────

  @doc """
  Rewrites legacy `@Name` spans in `content` to `@[Canonical Name]` based on
  `roster` (a list of `%{display_name: _, participant_id: _}` maps).

  Longest-match-wins: with both "Alex" and "Alex Morgan" in the roster,
  `@Alex Morgan hi` resolves to the longer name, and bare `@Alex hey`
  resolves to the shorter.
  """
  @spec rewrite_content(String.t() | nil, [map()]) :: String.t() | nil
  def rewrite_content(content, roster) when is_binary(content) do
    candidates =
      roster
      |> Enum.flat_map(fn p ->
        names = [p.display_name, p.participant_id]

        Enum.filter(names, &(is_binary(&1) and &1 != ""))
        |> Enum.map(&{&1, p.display_name || &1})
      end)
      |> Enum.uniq_by(fn {needle, _} -> String.downcase(needle) end)
      |> Enum.sort_by(fn {needle, _} -> -String.length(needle) end)

    do_rewrite(content, candidates)
  end

  def rewrite_content(content, _), do: content

  defp do_rewrite(content, candidates) do
    Regex.replace(~r/(^|\s)@([^\s@\[\]]+(?:\s+[^\s@\[\]]+)*)/u, content, fn full, lead, tail ->
      case longest_match(tail, candidates) do
        {matched_len, canonical} ->
          remainder = String.slice(tail, matched_len, String.length(tail) - matched_len)
          "#{lead}@[#{canonical}]#{remainder}"

        :no_match ->
          full
      end
    end)
  end

  defp longest_match(tail, candidates) do
    tail_down = String.downcase(tail)

    Enum.find_value(candidates, :no_match, fn {needle, canonical} ->
      needle_down = String.downcase(needle)

      if String.starts_with?(tail_down, needle_down) and
           boundary_ok?(tail, String.length(needle)) do
        {String.length(needle), canonical}
      end
    end)
  end

  defp boundary_ok?(tail, match_len) do
    case String.at(tail, match_len) do
      nil -> true
      ch -> not word_char?(ch)
    end
  end

  defp word_char?(ch) do
    ch =~ ~r/^[\p{L}\p{N}_]$/u
  end

  # ── Persistence / logging ───────────────────────────────────────────────────

  defp persist(msg, new_content, log) do
    msg
    |> Ecto.Changeset.change(%{content: new_content})
    |> Repo.update()
    |> case do
      {:ok, _} -> :ok
      {:error, changeset} -> log.("  ✗ #{msg.id}: #{inspect(changeset.errors)}")
    end
  end

  defp log_change(log, msg, new_content) do
    log.("  msg #{String.slice(msg.id, 0, 8)}:")
    log.("    - #{String.slice(msg.content, 0, 120)}")
    log.("    + #{String.slice(new_content, 0, 120)}")
  end
end
