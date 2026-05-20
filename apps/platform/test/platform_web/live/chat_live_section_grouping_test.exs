defmodule PlatformWeb.ChatLiveSectionGroupingTest do
  @moduledoc """
  Unit tests for `PlatformWeb.ChatLive.channel_sections/3` — the data-shape
  helper that backs the sectioned-rail sidebar (chat plan v2 Stage 1).

  These tests use bare `%Space{}` structs rather than going through `Chat`
  context inserts because the helper is a pure function over its inputs; it
  doesn't touch the DB. That keeps this suite fast and async-safe.
  """

  use ExUnit.Case, async: true

  alias Platform.Chat.Space
  alias PlatformWeb.ChatLive

  @sub_org_keys ["Paragon", "Soylent", "Fabrikam", "Wayne-Tech", "SXI"]

  defp channel(slug, attrs \\ %{}) do
    %Space{
      id: Map.get(attrs, :id, Ecto.UUID.generate()),
      name: Map.get(attrs, :name, slug),
      slug: slug,
      kind: Map.get(attrs, :kind, "channel"),
      is_direct: false
    }
  end

  defp dm(attrs \\ %{}) do
    %Space{
      id: Map.get(attrs, :id, Ecto.UUID.generate()),
      name: Map.get(attrs, :name, nil),
      slug: Map.get(attrs, :slug, nil),
      kind: Map.get(attrs, :kind, "dm"),
      is_direct: true
    }
  end

  describe "channel_sections/3 — sub-org bucketing by slug" do
    test "channel slug `soylent` lands in the Soylent bucket" do
      ch = channel("soylent")

      result = ChatLive.channel_sections([ch], [])

      assert result.sub_orgs["Soylent"] == [ch]
      assert result.sub_orgs["Fabrikam"] == []
    end

    test "channel slug `wayne-tech` lands in the Wayne-Tech bucket" do
      ch = channel("wayne-tech")

      result = ChatLive.channel_sections([ch], [])

      assert result.sub_orgs["Wayne-Tech"] == [ch]
      assert result.sub_orgs["Fabrikam"] == []
    end

    test "channel slug `sxi` lands in the SXI bucket" do
      ch = channel("sxi")

      result = ChatLive.channel_sections([ch], [])

      assert result.sub_orgs["SXI"] == [ch]
      assert result.sub_orgs["Fabrikam"] == []
    end

    test "channel slug `general` falls through to the Fabrikam catch-all" do
      ch = channel("general")

      result = ChatLive.channel_sections([ch], [])

      assert result.sub_orgs["Fabrikam"] == [ch]
    end

    test "prefix-but-not-exact slug `soylent-news` falls through to Fabrikam" do
      # Sub-org matching is exact (case-insensitive) on the slug — prefix
      # matches like `soylent-news` are intentionally NOT considered part
      # of the Soylent bucket. If product later wants prefix-grouping
      # (e.g. `soylent-*` → Soylent), update `channel_scope/1` and this
      # test together; until then, exact-only.
      ch = channel("soylent-news")

      result = ChatLive.channel_sections([ch], [])

      assert result.sub_orgs["Fabrikam"] == [ch]
      assert result.sub_orgs["Soylent"] == []
    end

    test "matching is case-insensitive (`SOYLENT` still matches Soylent)" do
      ch = channel("SOYLENT")

      result = ChatLive.channel_sections([ch], [])

      assert result.sub_orgs["Soylent"] == [ch]
    end
  end

  describe "channel_sections/3 — empty buckets + shape stability" do
    test "Paragon bucket is empty when no Paragon-named channel exists" do
      channels = [channel("soylent"), channel("general")]

      result = ChatLive.channel_sections(channels, [])

      assert result.sub_orgs["Paragon"] == []
    end

    test "sub_orgs map preserves all 5 keys even when most buckets are empty" do
      result = ChatLive.channel_sections([], [])

      assert Map.keys(result.sub_orgs) |> Enum.sort() == @sub_org_keys
      assert Enum.all?(@sub_org_keys, fn key -> result.sub_orgs[key] == [] end)
    end

    test "sub_orgs map preserves all 5 keys when only some are populated" do
      result = ChatLive.channel_sections([channel("soylent")], [])

      assert Map.keys(result.sub_orgs) |> Enum.sort() == @sub_org_keys
    end

    test "returns top-level :pinned, :dms, :sub_orgs keys" do
      result = ChatLive.channel_sections([], [])

      assert Map.has_key?(result, :pinned)
      assert Map.has_key?(result, :dms)
      assert Map.has_key?(result, :sub_orgs)
    end
  end

  describe "channel_sections/3 — DM handling" do
    test "DM goes into :dms regardless of any slug" do
      conversation = dm()

      result = ChatLive.channel_sections([], [conversation])

      assert result.dms == [conversation]
      # And nothing in sub_orgs.
      assert Enum.all?(@sub_org_keys, fn key -> result.sub_orgs[key] == [] end)
    end

    test "group conversation goes into :dms" do
      group = dm(%{kind: "group"})

      result = ChatLive.channel_sections([], [group])

      assert result.dms == [group]
    end

    test "DMs and channels coexist without cross-contamination" do
      ch = channel("soylent")
      conversation = dm()

      result = ChatLive.channel_sections([ch], [conversation])

      assert result.dms == [conversation]
      assert result.sub_orgs["Soylent"] == [ch]
    end
  end

  describe "channel_sections/3 — pinned channels (Stage 1 forward-compat)" do
    test "pinned non-DM channel goes into :pinned and is NOT duplicated in its sub-org bucket" do
      # Stage 1 decision: pinned channels appear in :pinned ONLY (the chat-rail
      # v2 spec says "Pinned + DMs locked at top, then sub-org sections" — we
      # read that as "above," not "duplicated"). If product flips this, change
      # the helper's `Enum.split_with/2` to `Enum.partition`-then-keep-both and
      # update this assertion.
      ch = channel("soylent")
      pinned_ids = MapSet.new([ch.id])

      result = ChatLive.channel_sections([ch], [], pinned_ids)

      assert result.pinned == [ch]
      assert result.sub_orgs["Soylent"] == []
    end

    test "non-pinned channels still bucket normally when pinned set is non-empty" do
      pinned_ch = channel("soylent")
      other_ch = channel("sxi")
      pinned_ids = MapSet.new([pinned_ch.id])

      result = ChatLive.channel_sections([pinned_ch, other_ch], [], pinned_ids)

      assert result.pinned == [pinned_ch]
      assert result.sub_orgs["SXI"] == [other_ch]
      assert result.sub_orgs["Soylent"] == []
    end

    test "default (no pinned_channel_ids arg) returns an empty :pinned list" do
      # The default arg lets every existing call site keep working until
      # channel-level pinning ships. Verify the contract.
      result = ChatLive.channel_sections([channel("soylent")], [])

      assert result.pinned == []
    end
  end
end
