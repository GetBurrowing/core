defmodule Platform.Experiments.Policies.RandomBucketsTest do
  @moduledoc """
  The bucketing must be a pure function of the subject's identity, and the
  split must actually track the weights.

  Both properties are easy to assert vacuously. A determinism test that never
  reaches the bucketing decision passes under a coin flip; a distribution
  test with a wide tolerance passes under any implementation at all. The
  tolerances below are therefore tight enough that a deliberately skewed
  bucketing fails them — see the anti-vacuity note on
  `distribution over 10_000 subjects`.
  """

  use ExUnit.Case, async: true

  alias Platform.Experiments.Policies.RandomBuckets
  alias Platform.Experiments.Subject

  @experiment_id "3a2b1c00-0000-4000-8000-000000000001"
  @equal [{"control", 1}, {"treatment", 1}]
  @three_to_one [{"control", 3}, {"treatment", 1}]

  defp subject(id, attributes \\ %{}), do: Subject.new("task", id, attributes)

  defp opts(variants),
    do: [experiment_id: @experiment_id, variants: variants]

  # 10_000 distinct, stable subject ids. Derived rather than random so a
  # failure is reproducible: a distribution failure investigated against a
  # different population every run is not investigable.
  defp subject_ids(count) do
    Enum.map(1..count, fn i ->
      hex = i |> Integer.to_string(16) |> String.pad_leading(12, "0")
      "00000000-0000-4000-8000-" <> hex
    end)
  end

  defp shares(variants, count) do
    ids = subject_ids(count)

    tally =
      Enum.reduce(ids, %{}, fn id, acc ->
        {:ok, slug} = RandomBuckets.assign(subject(id), opts(variants))
        Map.update(acc, slug, 1, &(&1 + 1))
      end)

    Map.new(tally, fn {slug, n} -> {slug, n / count * 100} end)
  end

  describe "determinism" do
    test "the same subject buckets identically across 100 calls" do
      subject = subject("11111111-1111-4111-8111-111111111111")

      results =
        Enum.map(1..100, fn _ -> RandomBuckets.assign(subject, opts(@equal)) end)

      assert [single] = Enum.uniq(results)
      assert {:ok, slug} = single
      assert slug in ["control", "treatment"]
    end

    test "a rebuilt but equal subject buckets identically" do
      # Identity, not struct identity: the caller reconstructs the subject on
      # every dispatch and must not get a different arm for doing so.
      a = subject("22222222-2222-4222-8222-222222222222", %{project_id: "p1"})
      b = subject("22222222-2222-4222-8222-222222222222", %{epic_id: "e1"})

      assert RandomBuckets.assign(a, opts(@equal)) == RandomBuckets.assign(b, opts(@equal))
    end

    test "the bucket matches values pinned in source, so it survives a fresh BEAM" do
      # These slugs were computed once and written down. A pin in source is
      # the only assertion that can fail if the hash is replaced with
      # something that is stable WITHIN a run but not across runs — a
      # per-process seed, a term hash whose salt changes, an ETS cache.
      # Comparing two calls in the same process cannot detect any of those.
      assert RandomBuckets.assign(
               subject("11111111-1111-4111-8111-111111111111"),
               opts(@equal)
             ) == {:ok, "treatment"}

      assert RandomBuckets.assign(
               subject("33333333-3333-4333-8333-333333333333"),
               opts(@equal)
             ) == {:ok, "treatment"}

      # Both arms are pinned. Pins that all named the same slug would stay
      # green under a bucketing that had collapsed to a constant.
      assert RandomBuckets.assign(
               subject("55555555-5555-4555-8555-555555555555"),
               opts(@equal)
             ) == {:ok, "control"}
    end

    test "the same subject buckets differently across experiments" do
      # If the experiment id were not mixed in, a subject in the treatment
      # arm of one experiment would be in the treatment arm of every
      # experiment, and the arms would correlate across the whole programme.
      subject = subject("55555555-5555-4555-8555-555555555555")

      slugs =
        Enum.map(1..50, fn i ->
          {:ok, slug} =
            RandomBuckets.assign(subject,
              experiment_id: "experiment-#{i}",
              variants: @equal
            )

          slug
        end)

      assert Enum.uniq(slugs) |> length() == 2
    end
  end

  describe "distribution over 10_000 subjects" do
    # ANTI-VACUITY: this tolerance was shown to reject a skewed bucketing.
    # Replacing the hash reduction with one returning the first variant ~90%
    # of the time reddens both tests below. Widening the tolerance past a few
    # points would make them pass under that skew and prove nothing.
    @tolerance 2.0

    test "equal weights split near 50/50" do
      shares = shares(@equal, 10_000)

      assert_in_delta shares["control"], 50.0, @tolerance
      assert_in_delta shares["treatment"], 50.0, @tolerance
    end

    test "3:1 weights split near 75/25" do
      shares = shares(@three_to_one, 10_000)

      assert_in_delta shares["control"], 75.0, @tolerance
      assert_in_delta shares["treatment"], 25.0, @tolerance
    end

    test "a zero-weight variant is never assigned" do
      shares = shares([{"control", 1}, {"dark", 0}], 10_000)

      refute Map.has_key?(shares, "dark")
      assert shares["control"] == 100.0
    end
  end

  describe "no variants" do
    test "an empty variant list is :no_opinion, not a bucket" do
      assert RandomBuckets.assign(subject("66666666-6666-4666-8666-666666666666"), opts([])) ==
               :no_opinion
    end

    test "variants that all have zero weight are :no_opinion" do
      assert RandomBuckets.assign(
               subject("66666666-6666-4666-8666-666666666666"),
               opts([{"a", 0}, {"b", 0}])
             ) == :no_opinion
    end
  end
end
