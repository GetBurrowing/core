defmodule Platform.People.Staleness do
  @moduledoc """
  Which people profiles are missing, stale or unreconciled. Pure: takes the
  appearances, the roster and the index names, returns a report. No
  database, no clock unless `opts[:now]` is given.

  `compute/4` resolves every appearance's `raw_name` against the roster with
  `Platform.People.Identity.resolve/3` and buckets the result:

    * `resolved` — `[%{slug, name, appearances}]`, one per matched card;
    * `review` — `[%{raw_name, candidates}]`, names the resolver found
      ambiguous;
    * `no_profile` — raw names that matched nobody;
    * `stale` — `[%{slug, page_updated_at, last_seen_at}]`: cards whose
      `updated_at` is EARLIER than the latest appearance of that person, plus
      every `legacy: true` card regardless of appearances;
    * `index_only` — names bolded in the index that resolve to no card.

  Appearances by agents (`kind: :agent`) are not people and are skipped.
  `opts[:staleness_days]` bounds the lookback: an appearance older than that
  many days before `opts[:now]` (default `DateTime.utc_now/0`) does not count
  towards staleness.
  """

  alias Platform.People.Identity

  @type report :: %{
          resolved: [%{slug: String.t(), name: String.t(), appearances: [map()]}],
          review: [%{raw_name: String.t(), candidates: [String.t()]}],
          no_profile: [String.t()],
          stale: [
            %{
              slug: String.t(),
              page_updated_at: DateTime.t() | nil,
              last_seen_at: DateTime.t() | nil
            }
          ],
          index_only: [String.t()]
        }

  @doc """
  Options:

    * `:staleness_days` — only appearances within this many days of `:now`
      count (default: unbounded);
    * `:now` — reference clock for `:staleness_days` (default `DateTime.utc_now/0`);
    * `:threshold` — passed to `Identity.resolve/3`.
  """
  @spec compute([map()], [map()], %{names: [String.t()]} | [String.t()], keyword()) :: report()
  def compute(appearances, roster, index_names, opts \\ [])
      when is_list(appearances) and is_list(roster) do
    resolve_opts = Keyword.take(opts, [:threshold])
    cutoff = cutoff(opts)
    by_slug = Map.new(roster, &{&1.slug, &1})

    {resolved, review, no_profile} =
      appearances
      |> Enum.reject(&(Map.get(&1, :kind) == :agent))
      |> Enum.filter(&within_lookback?(&1, cutoff))
      |> Enum.reduce({%{}, %{}, []}, fn appearance, {res, rev, none} ->
        case Identity.resolve(appearance.raw_name, roster, resolve_opts) do
          {:match, slug} ->
            {Map.update(res, slug, [appearance], &[appearance | &1]), rev, none}

          {:ambiguous, slugs} ->
            {res, Map.put_new(rev, appearance.raw_name, slugs), none}

          :unknown ->
            {res, rev, [appearance.raw_name | none]}
        end
      end)

    resolved_list =
      resolved
      |> Enum.map(fn {slug, apps} ->
        %{slug: slug, name: Map.fetch!(by_slug, slug).name, appearances: Enum.reverse(apps)}
      end)
      |> Enum.sort_by(& &1.slug)

    %{
      resolved: resolved_list,
      review:
        review
        |> Enum.map(fn {raw_name, candidates} ->
          %{raw_name: raw_name, candidates: candidates}
        end)
        |> Enum.sort_by(& &1.raw_name),
      no_profile: no_profile |> Enum.reverse() |> Enum.uniq(),
      stale: stale(roster, resolved),
      index_only: index_only(index_names, roster, resolve_opts)
    }
  end

  # ── stale ────────────────────────────────────────────────────────────────

  defp stale(roster, resolved) do
    roster
    |> Enum.flat_map(fn card ->
      last_seen = card |> appearances_for(resolved) |> latest_at()

      cond do
        Map.get(card, :legacy, false) ->
          [%{slug: card.slug, page_updated_at: card_updated_at(card), last_seen_at: last_seen}]

        stale?(card_updated_at(card), last_seen) ->
          [%{slug: card.slug, page_updated_at: card_updated_at(card), last_seen_at: last_seen}]

        true ->
          []
      end
    end)
    |> Enum.sort_by(& &1.slug)
  end

  defp appearances_for(card, resolved), do: Map.get(resolved, card.slug, [])

  defp card_updated_at(card), do: Map.get(card, :updated_at)

  # A card with no timestamp but a sighting is stale; a card with no
  # sighting is never stale on this axis.
  defp stale?(_updated_at, nil), do: false
  defp stale?(nil, %DateTime{}), do: true

  defp stale?(%DateTime{} = updated_at, %DateTime{} = last_seen),
    do: DateTime.compare(updated_at, last_seen) == :lt

  defp latest_at(appearances) do
    appearances
    |> Enum.map(&Map.get(&1, :at))
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> Enum.max(DateTime, fn -> nil end)
  end

  # ── index ────────────────────────────────────────────────────────────────

  defp index_only(%{names: names}, roster, resolve_opts),
    do: index_only(names, roster, resolve_opts)

  defp index_only(names, roster, resolve_opts) when is_list(names) do
    names
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&match?({:match, _}, Identity.resolve(&1, roster, resolve_opts)))
    |> Enum.uniq()
  end

  defp index_only(_, _, _), do: []

  # ── lookback ─────────────────────────────────────────────────────────────

  defp cutoff(opts) do
    case Keyword.get(opts, :staleness_days) do
      days when is_integer(days) and days > 0 ->
        opts
        |> Keyword.get_lazy(:now, &DateTime.utc_now/0)
        |> DateTime.add(-days * 86_400, :second)

      _ ->
        nil
    end
  end

  defp within_lookback?(_appearance, nil), do: true

  defp within_lookback?(%{at: %DateTime{} = at}, cutoff), do: DateTime.compare(at, cutoff) != :lt
  defp within_lookback?(_appearance, _cutoff), do: true
end
