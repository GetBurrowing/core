defmodule Platform.Experiments.Policies.RandomBuckets do
  @moduledoc """
  Weighted assignment across an experiment's variants. Task 019fe6b9, ADR-0048.

  ## The bucket is a hash of the subject, never a random draw

  The bucket is derived from `:crypto.hash(:sha256, {experiment_id,
  subject.type, subject.id})` reduced modulo the total weight. It never
  reads `:rand`, `:erlang.unique_integer/0`, `System.monotonic_time/0`, or
  any other per-call source of entropy. Two calls for the same subject in
  different processes, on different nodes, on different days, return the same
  slug.

  Why that matters, since a random draw would look equally correct in a
  test that only checks the split: stickiness is normally held by the
  assignment ROW, and the unique index on `(experiment_id, subject_type,
  subject_id)` is what enforces it. A hash-derived bucket makes stickiness
  additionally RECOVERABLE — if a row is ever lost, restored from an older
  backup, or never written because a write failed, the same subject
  re-resolves to the same variant.

  Under a random draw that same subject silently switches variant mid-flight.
  That contamination is undetectable downstream: both the old rows and the
  new rows are individually well-formed, no metric can see that one subject
  contributed to two arms, and the experiment quietly reports a difference
  between two populations that overlap.

  The hash makes the weights meaningful too: a variant with weight 0 gets no
  bucket at all rather than an occasional one.

  ## Variants arrive in `opts`, not from the database

  `opts[:variants]` is the variant list and `opts[:experiment_id]` the
  experiment. The policy performs no queries — it is a pure function of its
  arguments, which is what lets the distribution be tested over 10_000
  subjects without touching a table.
  """

  @behaviour Platform.Experiments.Policy

  alias Platform.Experiments.Policy
  alias Platform.Experiments.Subject
  alias Platform.Experiments.Variant

  @doc """
  Buckets the subject by hash across `opts[:variants]`.

  Options:
  - `:experiment_id` (required) — mixed into the hash so the same subject can
    land in different arms of different experiments. Without it every
    experiment would bucket every subject identically, and a subject in the
    treatment arm of one experiment would be in the treatment arm of all of
    them.
  - `:variants` (required) — `[%Variant{}]`, `[{slug, weight}]` or
    `[%{slug: slug, weight: weight}]`.
  - `:exclude` — see `Platform.Experiments.Policy.excluded?/2`.

  Returns `:no_opinion` when there are no variants with positive weight:
  there is no honest bucket to name, and inventing one would put a subject
  in an arm the experiment does not have.
  """
  @impl Platform.Experiments.Policy
  @spec assign(Subject.t(), keyword()) :: Policy.result()
  def assign(%Subject{} = subject, opts) do
    case Policy.excluded?(subject, opts) do
      {:excluded, _reason} = excluded ->
        excluded

      false ->
        opts
        |> Keyword.get(:variants, [])
        |> Enum.map(&normalise/1)
        |> Enum.filter(fn {_slug, weight} -> weight > 0 end)
        |> bucket(subject, Keyword.get(opts, :experiment_id))
    end
  end

  defp bucket([], _subject, _experiment_id), do: :no_opinion

  defp bucket(weighted, subject, experiment_id) do
    total = Enum.reduce(weighted, 0, fn {_slug, weight}, acc -> acc + weight end)
    {:ok, pick(weighted, rem(digest(experiment_id, subject), total))}
  end

  # A cumulative walk, so a variant's share of the buckets is exactly its
  # share of the total weight.
  defp pick([{slug, weight} | rest], point) do
    if point < weight, do: slug, else: pick(rest, point - weight)
  end

  # SHA-256 over the subject identity. The first 64 bits are ample and the
  # avalanche property is what buys the tight distribution tolerance the
  # tests assert; `:erlang.phash2/2` would also be deterministic but its
  # spread over adjacent structured terms is weaker.
  defp digest(experiment_id, %Subject{type: type, id: id}) do
    <<int::unsigned-integer-size(64), _rest::binary>> =
      :crypto.hash(:sha256, :erlang.term_to_binary({experiment_id, type, id}))

    int
  end

  defp normalise(%Variant{slug: slug, weight: weight}), do: {slug, weight}
  defp normalise(%{slug: slug, weight: weight}), do: {slug, weight}
  defp normalise({slug, weight}) when is_binary(slug) and is_integer(weight), do: {slug, weight}
end
