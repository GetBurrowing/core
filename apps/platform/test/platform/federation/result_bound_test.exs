defmodule Platform.Federation.ResultBoundTest do
  @moduledoc """
  Guards for the transport size bound introduced by task 01a049de.

  ## What a weak version of this file would look like

  A file that only asserted "the capped payload is smaller than the uncapped
  one" would pass against a `fit/2` that returned `"{}"` for every input, and
  against one that sliced the encoded JSON mid-token. Both are worse than no
  cap. So the assertions here are, in order of what they are actually worth:

    1. **The output parses.** `Jason.decode!/1` on every capped result,
       including the degenerate ones. This is the property the naive
       implementation (`String.slice` on the encoded string) breaks, and it is
       the one the ticket singles out.
    2. **A small payload is returned UNTOUCHED.** The positive control. Without
       it, a `fit/2` that destroyed every response would satisfy every
       size assertion in this file.
    3. **The kept records are a PREFIX of the input, with their fields intact.**
       Truncation must drop whole records off the tail, never mangle the ones
       it keeps.
    4. Size, last — because it is the assertion that is easiest to satisfy
       wrongly.
  """

  use ExUnit.Case, async: true

  alias Platform.Federation.ResultBound

  # RESTATED, not read back from `ResultBound`. An earlier revision of this
  # file asserted `length(rows) == ResultBound.default_limit()`, which is true
  # by construction: mutating the module attribute from 50 to 1 moved the
  # expectation with the implementation and the whole suite stayed green. That
  # surviving mutant is why these four are literals — the test pins the
  # contract, it does not ask the code what the contract is.
  @max_result_bytes 100_000
  @snippet_chars 500
  @default_limit 50
  @max_limit 500

  test "the module's published constants are the ones this file pins" do
    # The one place the implementation is allowed to be read back — so that a
    # deliberate change to a bound fails HERE, loudly and in one place, instead
    # of silently weakening every assertion in the file.
    assert ResultBound.max_result_bytes() == @max_result_bytes
    assert ResultBound.snippet_chars() == @snippet_chars
    assert ResultBound.default_limit() == @default_limit
    assert ResultBound.max_limit() == @max_limit
  end

  defp big_row(i, chars) do
    %{id: "row-#{i}", title: "Row #{i}", body: String.duplicate("x", chars)}
  end

  describe "fit/2 — the whole-payload backstop" do
    test "POSITIVE CONTROL: a small payload is returned byte-identical and complete" do
      data = [big_row(1, 10), big_row(2, 10), big_row(3, 10)]

      assert {:ok, json} = ResultBound.fit(data)

      # Not "smaller than before" — IDENTICAL to a plain encode, and carrying
      # every record with every field. A cap that fired here would be a bug,
      # and this is the test that would catch a change that broke rendering
      # entirely while making every size assertion greener.
      assert json == Jason.encode!(data)

      decoded = Jason.decode!(json)
      assert length(decoded) == 3
      assert Enum.map(decoded, & &1["id"]) == ["row-1", "row-2", "row-3"]
      assert Enum.all?(decoded, &(String.length(&1["body"]) == 10))
      assert Enum.all?(decoded, &(&1["title"] != nil))
    end

    test "an oversized list is truncated, still parses, and keeps a prefix intact" do
      data = for i <- 1..500, do: big_row(i, 1_000)
      assert byte_size(Jason.encode!(data)) > @max_result_bytes

      assert {:truncated, json, note} = ResultBound.fit(data)

      # (1) It parses. A mid-structure cut fails here.
      decoded = Jason.decode!(json)
      assert is_list(decoded)

      # (4) It fits.
      assert byte_size(json) <= @max_result_bytes

      # (3) What survived is an intact PREFIX — same order, full records, no
      # half-serialized tail row.
      assert length(decoded) > 0
      assert length(decoded) < 500
      assert Enum.map(decoded, & &1["id"]) == Enum.map(1..length(decoded), &"row-#{&1}")
      assert Enum.all?(decoded, &(String.length(&1["body"]) == 1_000))

      assert note =~ "truncated"
      assert note =~ "#{500 - length(decoded)}"
    end

    test "an oversized :items envelope drops from items and keeps sibling keys truthful" do
      items = for i <- 1..500, do: big_row(i, 1_000)
      data = %{task_id: "t-1", count: 500, items: items}

      assert {:truncated, json, _note} = ResultBound.fit(data)

      decoded = Jason.decode!(json)
      assert byte_size(json) <= @max_result_bytes

      # The envelope survives and `count` still reports the TRUE total, not the
      # returned length. A cap that rewrote `count` to match what it returned
      # would erase the only evidence that anything was dropped.
      assert decoded["task_id"] == "t-1"
      assert decoded["count"] == 500
      assert length(decoded["items"]) < 500
      assert length(decoded["items"]) > 0
    end

    test "a single record larger than the cap is returned whole rather than corrupted" do
      data = %{id: "x", blob: String.duplicate("y", @max_result_bytes * 2)}

      assert {:truncated, json, note} = ResultBound.fit(data)

      # There is no list to shorten. Returning a truthful oversized answer beats
      # returning a broken one — this must still parse.
      assert Jason.decode!(json)["id"] == "x"
      assert note =~ "no list"
    end

    test "an empty list and an empty envelope are not mangled" do
      assert {:ok, json} = ResultBound.fit([])
      assert Jason.decode!(json) == []

      assert {:ok, json} = ResultBound.fit(%{count: 0, items: []})
      assert Jason.decode!(json) == %{"count" => 0, "items" => []}
    end
  end

  describe "snippet/3" do
    test "POSITIVE CONTROL: a short field keeps its exact value and is flagged untruncated" do
      row = ResultBound.snippet(%{description: "short"}, :description)

      assert row.description == "short"
      assert row.description_truncated == false
      assert row.description_length == 5
    end

    test "a long field is previewed and reports its ORIGINAL length" do
      original = String.duplicate("z", 5_000)
      row = ResultBound.snippet(%{description: original}, :description)

      assert String.length(row.description) == @snippet_chars
      assert row.description_truncated == true
      # The marker is the size of what was truncated away, not of the preview.
      # Reporting the preview's length would make the field useless for
      # deciding whether to go and fetch the record.
      assert row.description_length == 5_000
      assert String.starts_with?(original, row.description)
    end

    test "a nil or non-binary field is left alone and gains no markers" do
      assert ResultBound.snippet(%{description: nil}, :description) == %{description: nil}
      assert ResultBound.snippet(%{description: 42}, :description) == %{description: 42}
    end
  end

  describe "page/2" do
    test "defaults, clamping, and garbage coercion" do
      assert ResultBound.page(%{}) == {@default_limit, 0}
      assert ResultBound.page(%{"limit" => 10, "offset" => 5}) == {10, 5}

      # Over the maximum is clamped, NOT refused — a caller that used to get an
      # unbounded list must keep getting an answer.
      assert ResultBound.page(%{"limit" => 10_000}) == {@max_limit, 0}

      # MCP arguments arrive as JSON, so integers may show up as strings.
      assert ResultBound.page(%{"limit" => "25", "offset" => "7"}) == {25, 7}

      # Garbage falls back rather than raising.
      assert ResultBound.page(%{"limit" => "abc", "offset" => -3}) ==
               {@default_limit, 0}

      assert ResultBound.page(%{"limit" => 0}) == {@default_limit, 0}
    end
  end
end
