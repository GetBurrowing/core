defmodule PlatformWeb.ChatLiveSectionGroupingTest do
  @moduledoc """
  Unit tests for `PlatformWeb.ChatLive.channel_sections/3` — the data-shape
  helper that backs the sectioned-rail sidebar (chat plan v2 Stage 1).

  These tests use bare `%Space{}` structs rather than going through `Chat`
  context inserts because the helper is a pure function over its inputs.

  Task 01a00910 stage 3 changed what "its inputs" means: bucketing now keys off
  the space's `org_id` resolved against the orgs table, not against the channel's
  own slug, so the helper reads orgs once per call and the case needs a
  sandboxed DB connection. The `channel/2` fixture below therefore resolves the
  org whose slug matches the name it is handed, which keeps every assertion in
  this file testing what it always meant — "a Soylent channel buckets under
  Soylent" — rather than the slug coincidence that used to implement it.
  """

  use Platform.DataCase, async: true

  alias Platform.Chat.Space
  alias PlatformWeb.ChatLive

  # Bucket keys are runtime-derived (one per org) as of stage 3, so the
  # expected key set comes from the same public helper the template uses
  # rather than a second hardcoded list that could drift from it.
  defp sub_org_keys, do: ChatLive.sub_org_order()

  # Org slugs are stored underscore-form; these fixture names are the CSS
  # hyphen form, matching how the rest of the UI spells them.
  defp org_id_for(name) do
    slug = name |> to_string() |> String.downcase() |> String.replace("-", "_")

    case Platform.Tenancy.get_org_by_slug(slug) do
      %{id: id} -> id
      nil -> nil
    end
  end

  defp channel(slug, attrs \\ %{}) do
    %Space{
      id: Map.get(attrs, :id, Ecto.UUID.generate()),
      name: Map.get(attrs, :name, slug),
      slug: slug,
      kind: Map.get(attrs, :kind, "channel"),
      org_id: Map.get(attrs, :org_id, org_id_for(slug)),
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

  describe "channel_sections/3 — sub-org bucketing by org_id" do
    test "a channel in the Soylent org lands in the Soylent bucket" do
      ch = channel("soylent")

      result = ChatLive.channel_sections([ch], [])

      assert result.sub_orgs["Soylent"] == [ch]
      assert result.sub_orgs["Fabrikam"] == []
    end

    test "a channel in the Wayne-Tech org (slug `wayne_tech`) lands in the Wayne-Tech bucket" do
      ch = channel("wayne-tech")

      result = ChatLive.channel_sections([ch], [])

      assert result.sub_orgs["Wayne-Tech"] == [ch]
      assert result.sub_orgs["Fabrikam"] == []
    end

    test "a channel in the SXI org lands in the SXI bucket" do
      ch = channel("sxi")

      result = ChatLive.channel_sections([ch], [])

      assert result.sub_orgs["SXI"] == [ch]
      assert result.sub_orgs["Fabrikam"] == []
    end

    test "a channel with no resolvable org falls through to the Fabrikam default" do
      ch = channel("general")

      result = ChatLive.channel_sections([ch], [])

      assert result.sub_orgs["Fabrikam"] == [ch]
    end

    test "a channel whose org cannot be resolved falls through to Fabrikam" do
      # `soylent-news` names no org, so the fixture leaves org_id nil and the
      # channel takes the explicit default-bucket clause. Nothing about the
      # channel's own slug is consulted any more — this used to pass because
      # slug matching was exact rather than prefix, and it now passes for the
      # stronger reason that slugs are not read at all.
      ch = channel("soylent-news")

      result = ChatLive.channel_sections([ch], [])

      assert result.sub_orgs["Fabrikam"] == [ch]
      assert result.sub_orgs["Soylent"] == []
    end

    test "the channel's own slug casing is irrelevant — the org decides" do
      # Same Soylent org, a channel slug in a different case. Before stage 3
      # this exercised case-insensitive slug matching; now it proves the
      # bucket is chosen without looking at the slug at all.
      ch = channel("SOYLENT")

      result = ChatLive.channel_sections([ch], [])

      assert result.sub_orgs["Soylent"] == [ch]
    end
  end

  describe "channel_sections/3 — empty buckets + shape stability" do
    test "the Paragon bucket is empty when no Paragon-org channel exists" do
      channels = [channel("soylent"), channel("general")]

      result = ChatLive.channel_sections(channels, [])

      assert result.sub_orgs["Paragon"] == []
    end

    test "sub_orgs map preserves a key per org even when most buckets are empty" do
      result = ChatLive.channel_sections([], [])

      assert Map.keys(result.sub_orgs) |> Enum.sort() == sub_org_keys()
      assert Enum.all?(sub_org_keys(), fn key -> result.sub_orgs[key] == [] end)
    end

    test "sub_orgs map preserves a key per org when only some are populated" do
      result = ChatLive.channel_sections([channel("soylent")], [])

      assert Map.keys(result.sub_orgs) |> Enum.sort() == sub_org_keys()
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
      assert Enum.all?(sub_org_keys(), fn key -> result.sub_orgs[key] == [] end)
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

  # ── Task 01a00910 stage 1: bucket by org_id, not by slug ────────────────
  #
  # `channel_scope/1` is private; its output reaches the outside world only
  # through `channel_sections/5`'s `sub_orgs` / `hidden_sub_orgs` maps. These
  # fixtures read the bucket through `hidden_sub_orgs` (the map that feeds the
  # hidden-channels drawer at chat_live.html.heex:1213 and :1243 — the ONLY
  # template surface `channel_scope/1` reaches; the main org rail comes from
  # `Platform.Chat.Sidebar`, see sidebar_org_fallback_test.exs). Marking the
  # channel hidden is what moves it into that map.
  #
  # C and D are expected to FAIL on unmodified main and to pass after the
  # stage-3 org_id rewrite. E records TODAY's `org_id: nil` behaviour so that
  # rewrite cannot change it by accident.
  describe "channel_sections/5 — bucketing must key off org_id, not slug" do
    defp org_channel(slug, org_id) do
      %Space{
        id: Ecto.UUID.generate(),
        name: slug,
        slug: slug,
        kind: "channel",
        org_id: org_id,
        is_direct: false
      }
    end

    defp hidden_bucket_of(ch) do
      result = ChatLive.channel_sections([ch], [], MapSet.new(), MapSet.new([ch.id]), %{})

      Enum.find_value(result.hidden_sub_orgs, fn {bucket, spaces} ->
        if Enum.any?(spaces, &(&1.id == ch.id)), do: bucket
      end)
    end

    test "Fixture C: a channel slugged `bug-reports` under the SXI org buckets under SXI" do
      sxi = Platform.Tenancy.get_org_by_slug!("sxi")
      ch = org_channel("bug-reports", sxi.id)

      assert hidden_bucket_of(ch) == "SXI",
             "channel with org_id = SXI bucketed by its slug instead of its org"
    end

    test "Fixture D: a channel slugged `cyberdyne` under the Fabrikam org buckets under Fabrikam" do
      fabrikam = Platform.Tenancy.get_org_by_slug!("fabrikam")
      ch = org_channel("cyberdyne", fabrikam.id)

      assert hidden_bucket_of(ch) == "Fabrikam",
             "slug match beat org_id: a Fabrikam channel slugged `cyberdyne` " <>
               "was filed under Cyberdyne"
    end

    test "Fixture E: a channel with org_id: nil keeps today's Fabrikam fallback" do
      # Deliberate pin of existing behaviour, not an aspiration. Personal /
      # unscoped spaces must keep landing in the default tenant bucket after
      # the stage-3 rewrite.
      ch = org_channel("unscoped-thing", nil)

      assert hidden_bucket_of(ch) == "Fabrikam"
    end
  end

  # ── Task 01a00910 stage 3: the SECOND consumer ──────────────────────────
  #
  # `bucket_from_slug/1` (the SectionReorder hook's slug -> bucket-name
  # translation) read the same `@sub_org_slug_to_bucket` attribute that
  # `channel_scope/1` did. Fixing only `channel_scope` would have left this
  # path on the stale hardcoded list with every test above still green. The
  # attribute is now deleted outright, so no reader can go stale; these
  # assertions cover the behaviour the deletion had to preserve.
  describe "bucket_from_slug/1 — derived from the orgs table" do
    test "resolves a CSS-form slug to the org's display name" do
      sxi = Platform.Tenancy.get_org_by_slug!("sxi")

      assert ChatLive.bucket_from_slug("sxi") == sxi.name
    end

    test "resolves an underscore-slugged org through its hyphen CSS token" do
      # The one org that catches a missing `_` -> `-` normalization.
      wayne_tech = Platform.Tenancy.get_org_by_slug!("wayne_tech")

      assert ChatLive.bucket_from_slug("wayne-tech") == wayne_tech.name
    end

    test "an org created after this code shipped resolves with no code change" do
      # The point of the whole stage: a brand-new org must bucket without
      # anyone editing a literal list. `Newclient` deliberately has no scope
      # colour token, so it also exercises `sub_org_scope_atom/1`'s nil path.
      fabrikam = Platform.Tenancy.get_org_by_slug!("fabrikam")

      org =
        Platform.Repo.insert!(
          Platform.Tenancy.Org.changeset(%Platform.Tenancy.Org{}, %{
            name: "Newclient",
            slug: "new_client",
            parent_org_id: fabrikam.id
          })
        )

      assert ChatLive.bucket_from_slug("new-client") == "Newclient"
      assert "Newclient" in ChatLive.sub_org_order()

      ch = org_channel("anything-at-all", org.id)
      assert hidden_bucket_of(ch) == "Newclient"
    end

    test "an unknown slug resolves to nil" do
      assert ChatLive.bucket_from_slug("not-an-org") == nil
      assert ChatLive.bucket_from_slug(nil) == nil
    end
  end
end
