defmodule Platform.Chat.SidebarTest do
  @moduledoc """
  Stage 2 (chat sidebar v2): the channel_sections org-default layer +
  Fabrikam-admin-gated curation writes. Verifies the migration seeded one section
  per org, and that every write authorizes through `Tenancy.fabrikam_admin?/1`.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Audit
  alias Platform.Chat
  alias Platform.Chat.PinnedSpaces
  alias Platform.Chat.Section
  alias Platform.Chat.Sidebar
  alias Platform.Chat.Space
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "sidebar-test-#{n}@example.com",
          name: "Sidebar Test #{n}",
          oidc_sub: "oidc-sidebar-#{n}"
        },
        overrides
      )

    %User{} |> User.changeset(attrs) |> Repo.insert!()
  end

  defp membership!(user, org, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: role})
    |> Repo.insert!()
  end

  defp admin_user! do
    user = create_user!()
    membership!(user, Tenancy.get_org_by_slug!("fabrikam"), "admin")
    user
  end

  defp member_user! do
    user = create_user!()
    membership!(user, Tenancy.get_org_by_slug!("fabrikam"), "member")
    user
  end

  defp channel!(attrs \\ %{}) do
    default = %{
      name: "C",
      slug: "sec-test-#{System.unique_integer([:positive])}",
      kind: "channel"
    }

    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  # A direct message is the same `chat_spaces` row as a channel with a
  # different `kind`. The pin store must not be able to tell them apart.
  defp dm!(attrs \\ %{}) do
    channel!(Map.merge(%{kind: "dm", is_direct: true, name: nil, slug: nil}, attrs))
  end

  # Three pins in a known order, one of them a DM, and the order asserted
  # before any test builds on it. The premise the reorder work rests on is
  # that `chat_pinned_spaces` round-trips in the order written; asserting it
  # here means a regression in the WRITE side cannot masquerade as a
  # regression in the reorder.
  defp three_pins(user) do
    [a, b, c] = [channel!(), dm!(), channel!()]

    for space <- [a, b, c], do: {:ok, _} = Sidebar.set_space_pinned(user.id, space.id, true)

    assert Sidebar.list_pinned_space_ids(user.id) == [a.id, b.id, c.id]
    {a, b, c}
  end

  # In-memory fixtures for the pure resolve/3 tests (no DB needed).
  defp sec(id, org_id, pos), do: %Section{id: id, org_id: org_id, name: id, position: pos}
  defp chan(id, org_id), do: %Space{id: id, org_id: org_id, kind: "channel"}

  # The seeded default section for an org (one per org, per the migration).
  defp section_for!(org) do
    Enum.find(Sidebar.list_default_sections(), &(&1.org_id == org.id)) ||
      raise "no default section seeded for org #{org.slug}"
  end

  # Channel ids resolved into one section. Returns nil rather than [] when the
  # section is absent from the resolver output, so "section vanished" cannot
  # read as "section is empty".
  defp section_channel_ids(resolved, section_id) do
    case Enum.find(resolved, &(&1.section.id == section_id)) do
      nil -> nil
      entry -> Enum.map(entry.channels, & &1.id)
    end
  end

  defp resolve_fixture do
    sections = [sec("sA", "oA", 0), sec("sB", "oB", 1)]
    channels = [chan("c1", "oA"), chan("c2", "oA"), chan("c3", "oB")]
    {sections, channels}
  end

  # ── Seed + read ──────────────────────────────────────────────────────────

  describe "list_default_sections/0 (migration seed)" do
    test "seeds one section per org, ordered by position" do
      sections = Sidebar.list_default_sections()

      assert length(sections) == length(Tenancy.list_orgs())
      assert Enum.all?(sections, &(is_binary(&1.org_id) and is_binary(&1.name)))

      positions = Enum.map(sections, & &1.position)
      assert positions == Enum.sort(positions)

      # color is the scope token in CSS form, e.g. fabrikam -> "fabrikam", wayne_tech -> "wayne-tech"
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      fabrikam_section = Enum.find(sections, &(&1.org_id == fabrikam.id))
      assert fabrikam_section.color == "fabrikam"
    end
  end

  # ── Archived orgs drop out of the rendered sidebar (task 019f4eaa) ───────

  describe "archived orgs vs the sidebar" do
    # Marlowe, walking the review: scheduling Paragon for deletion hid its
    # channels but LEFT its section header in the sidebar, sitting above an
    # empty "No channels yet" placeholder — the org read as half-deleted.
    # The org cascade hides projects and chat_spaces; a section is its own row
    # in channel_sections and the cascade never touches it, so the RENDER path
    # has to filter.

    test "an archived org's section is dropped from the rendered sidebar" do
      admin = admin_user!()
      paragon = Tenancy.get_org_by_slug!("paragon")
      {:ok, _} = Tenancy.archive_org(admin, paragon)

      refute Enum.any?(Sidebar.list_active_default_sections(), &(&1.org_id == paragon.id))
      # resolve_for_user/2 returns %{section:, channels:} wrappers, not sections.
      refute Enum.any?(Sidebar.resolve_for_user(nil, []), &(&1.section.org_id == paragon.id))

      # Active orgs are untouched.
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      assert Enum.any?(Sidebar.list_active_default_sections(), &(&1.org_id == fabrikam.id))
      assert Enum.any?(Sidebar.resolve_for_user(nil, []), &(&1.section.org_id == fabrikam.id))
    end

    test "a deletion-scheduled org's section is dropped too (schedule stamps archived_at)" do
      admin = admin_user!()
      soylent = Tenancy.get_org_by_slug!("soylent")
      {:ok, _} = Tenancy.schedule_org_deletion(admin, soylent)

      refute Enum.any?(Sidebar.list_active_default_sections(), &(&1.org_id == soylent.id))
    end

    test "list_default_sections/0 STILL returns all rows — the data API stays unfiltered" do
      # Curation writes and the admin editor need the full set; only the render
      # path filters. Mirrors Tenancy.list_tenants/0 vs list_active_tenants_unscoped/0.
      admin = admin_user!()
      paragon = Tenancy.get_org_by_slug!("paragon")
      {:ok, _} = Tenancy.archive_org(admin, paragon)

      assert Enum.any?(Sidebar.list_default_sections(), &(&1.org_id == paragon.id))
    end

    test "restoring the org brings its section back" do
      admin = admin_user!()
      paragon = Tenancy.get_org_by_slug!("paragon")

      {:ok, archived} = Tenancy.archive_org(admin, paragon)
      refute Enum.any?(Sidebar.list_active_default_sections(), &(&1.org_id == paragon.id))

      # Nothing about the section row ever changed, so restore is free.
      {:ok, _} = Tenancy.unarchive_org(admin, archived)
      assert Enum.any?(Sidebar.list_active_default_sections(), &(&1.org_id == paragon.id))
    end
  end

  # ── Admin-gated writes ───────────────────────────────────────────────────

  describe "rename_section/3" do
    test "Fabrikam admin renames a section" do
      admin = admin_user!()
      section = hd(Sidebar.list_default_sections())

      assert {:ok, updated} = Sidebar.rename_section(admin, section.id, "Brand & Social")
      assert updated.name == "Brand & Social"
    end

    test "non-admin is rejected and nothing changes" do
      member = member_user!()
      section = hd(Sidebar.list_default_sections())

      assert {:error, :unauthorized} = Sidebar.rename_section(member, section.id, "Nope")
      assert Repo.get!(Platform.Chat.Section, section.id).name == section.name
    end
  end

  describe "recolor_section/3" do
    test "Fabrikam admin recolors a section" do
      admin = admin_user!()
      section = hd(Sidebar.list_default_sections())

      assert {:ok, updated} = Sidebar.recolor_section(admin, section.id, "paragon")
      assert updated.color == "paragon"
    end
  end

  describe "reorder_sections/2" do
    test "Fabrikam admin sets positions from an ordered id list; unknown ids skipped" do
      admin = admin_user!()
      ids = Sidebar.list_default_sections() |> Enum.map(& &1.id) |> Enum.reverse()

      assert {:ok, count} = Sidebar.reorder_sections(admin, ids ++ [Ecto.UUID.generate()])
      assert count == length(ids)

      reordered = Sidebar.list_default_sections() |> Enum.map(& &1.id)
      assert reordered == ids
    end

    test "non-admin is rejected" do
      member = member_user!()
      ids = Sidebar.list_default_sections() |> Enum.map(& &1.id)
      assert {:error, :unauthorized} = Sidebar.reorder_sections(member, ids)
    end
  end

  describe "reassign_channel/3" do
    test "Fabrikam admin sets the channel's org_id (global identity move)" do
      admin = admin_user!()
      sxi = Tenancy.get_org_by_slug!("sxi")
      space = channel!()

      assert {:ok, updated} = Sidebar.reassign_channel(admin, space.id, sxi.id)
      assert updated.org_id == sxi.id
    end

    test "missing channel returns :not_found" do
      admin = admin_user!()
      sxi = Tenancy.get_org_by_slug!("sxi")
      assert {:error, :not_found} = Sidebar.reassign_channel(admin, Ecto.UUID.generate(), sxi.id)
    end

    test "non-admin is rejected and org_id is unchanged" do
      member = member_user!()
      sxi = Tenancy.get_org_by_slug!("sxi")
      space = channel!()

      assert {:error, :unauthorized} = Sidebar.reassign_channel(member, space.id, sxi.id)
      assert is_nil(Chat.get_space(space.id).org_id)
    end
  end

  # ── Stage 3: pure resolver ───────────────────────────────────────────────

  describe "resolve/3 (pure merge)" do
    test "empty prefs: sections in position order, channels grouped by org_id" do
      {sections, channels} = resolve_fixture()

      assert [%{section: %{id: "sA"}, channels: a}, %{section: %{id: "sB"}, channels: b}] =
               Sidebar.resolve(sections, channels, %{})

      assert Enum.map(a, & &1.id) == ["c1", "c2"]
      assert Enum.map(b, & &1.id) == ["c3"]
    end

    test "chat_section_order reorders, skips unknown ids, appends unplaced sections" do
      {sections, channels} = resolve_fixture()
      prefs = %{"chat_section_order" => ["sB", "ghost"]}

      assert [%{section: %{id: "sB"}}, %{section: %{id: "sA"}}] =
               Sidebar.resolve(sections, channels, prefs)
    end

    test "chat_hidden_sections drops the section and its channels" do
      {sections, channels} = resolve_fixture()
      prefs = %{"chat_hidden_sections" => ["sA"]}

      assert [%{section: %{id: "sB"}, channels: b}] = Sidebar.resolve(sections, channels, prefs)
      assert Enum.map(b, & &1.id) == ["c3"]
    end

    test "chat_channel_order moves a channel into a non-default section and out of its default" do
      {sections, channels} = resolve_fixture()
      # user pulls c1 (default sA) into sB, ahead of c3
      prefs = %{"chat_channel_order" => %{"sB" => ["c1", "c3"]}}

      assert [%{section: %{id: "sA"}, channels: a}, %{section: %{id: "sB"}, channels: b}] =
               Sidebar.resolve(sections, channels, prefs)

      assert Enum.map(a, & &1.id) == ["c2"]
      assert Enum.map(b, & &1.id) == ["c1", "c3"]
    end

    test "stale channel ids are skipped; new channels append to their default section" do
      {sections, channels} = resolve_fixture()
      # user order references a deleted channel (cX) before c3; c2 is new (unplaced)
      prefs = %{"chat_channel_order" => %{"sB" => ["cX", "c3"]}}

      assert [%{section: %{id: "sA"}, channels: a}, %{section: %{id: "sB"}, channels: b}] =
               Sidebar.resolve(sections, channels, prefs)

      assert Enum.map(a, & &1.id) == ["c1", "c2"]
      assert Enum.map(b, & &1.id) == ["c3"]
    end

    test "channel with unknown org_id falls back to the first section" do
      {sections, _} = resolve_fixture()
      orphan = chan("c9", "no-such-org")

      assert [%{section: %{id: "sA"}, channels: a}, %{section: %{id: "sB"}, channels: b}] =
               Sidebar.resolve(sections, [orphan], %{})

      assert Enum.map(a, & &1.id) == ["c9"]
      assert b == []
    end
  end

  # ── Collapse is a flag, not a filter (task 019fd80f) ─────────────────────

  describe "resolve/3 vs chat_collapsed_sections" do
    test "no pref: every section resolves collapsed? false" do
      {sections, channels} = resolve_fixture()

      assert [%{collapsed?: false}, %{collapsed?: false}] =
               Sidebar.resolve(sections, channels, %{})
    end

    test "a collapsed section still renders, keeps its place and keeps its channels" do
      {sections, channels} = resolve_fixture()
      prefs = %{"chat_collapsed_sections" => ["sA"]}

      assert [
               %{section: %{id: "sA"}, channels: a, collapsed?: true},
               %{section: %{id: "sB"}, channels: b, collapsed?: false}
             ] = Sidebar.resolve(sections, channels, prefs)

      # The load-bearing difference from hide: the channels are STILL here, so
      # the render can count new activity inside a folded section.
      assert Enum.map(a, & &1.id) == ["c1", "c2"]
      assert Enum.map(b, & &1.id) == ["c3"]
    end

    test "collapse and hide are independent overrides on the same section" do
      {sections, channels} = resolve_fixture()
      prefs = %{"chat_collapsed_sections" => ["sA"], "chat_hidden_sections" => ["sA"]}

      # Hide still wins on presence — but only because hide filters and collapse
      # does not. Collapsing must never be able to remove a section.
      assert [%{section: %{id: "sB"}}] = Sidebar.resolve(sections, channels, prefs)

      assert [%{section: %{id: "sA"}, collapsed?: true}, %{section: %{id: "sB"}}] =
               Sidebar.resolve(sections, channels, %{"chat_collapsed_sections" => ["sA"]})
    end

    test "a collapsed id naming a section that no longer exists is skipped, not raised" do
      # Deleting or archiving an org must never require a cleanup pass over
      # preferences JSONB — the stale id is just a MapSet miss.
      {sections, channels} = resolve_fixture()
      prefs = %{"chat_collapsed_sections" => ["ghost", "sB"]}

      assert [
               %{section: %{id: "sA"}, collapsed?: false},
               %{section: %{id: "sB"}, collapsed?: true}
             ] = Sidebar.resolve(sections, channels, prefs)
    end
  end

  # ── Stage 3: preference writes ───────────────────────────────────────────

  describe "preference writes + reset" do
    test "put_section_order / set_section_hidden round-trip into users.preferences" do
      user = create_user!()

      assert {:ok, _} = Sidebar.put_section_order(user.id, ["s2", "s1"])
      assert {:ok, _} = Sidebar.set_section_hidden(user.id, "s3", true)

      prefs = Accounts.get_user_preferences(user.id)
      assert prefs["chat_section_order"] == ["s2", "s1"]
      assert prefs["chat_hidden_sections"] == ["s3"]

      assert {:ok, _} = Sidebar.set_section_hidden(user.id, "s3", false)
      assert Accounts.get_user_preferences(user.id)["chat_hidden_sections"] == []
    end

    test "put_channel_order moves a channel out of other sections (single placement)" do
      user = create_user!()
      {:ok, _} = Sidebar.put_channel_order(user.id, "sA", ["c1", "c2"])
      {:ok, _} = Sidebar.put_channel_order(user.id, "sB", ["c1"])

      cco = Accounts.get_user_preferences(user.id)["chat_channel_order"]
      assert cco["sA"] == ["c2"]
      assert cco["sB"] == ["c1"]
    end

    test "reset_to_default clears all five override keys" do
      user = create_user!()
      {:ok, _} = Sidebar.put_section_order(user.id, ["s1"])
      {:ok, _} = Sidebar.put_channel_order(user.id, "sA", ["c1"])
      {:ok, _} = Sidebar.set_section_hidden(user.id, "s2", true)
      {:ok, _} = Sidebar.set_section_collapsed(user.id, "s3", true)
      {:ok, _} = Sidebar.set_space_pinned(user.id, "sp1", true)

      assert {:ok, _} = Sidebar.reset_to_default(user.id)

      prefs = Accounts.get_user_preferences(user.id)
      assert is_nil(prefs["chat_section_order"])
      assert prefs["chat_channel_order"] == %{}
      assert prefs["chat_hidden_sections"] == []
      assert prefs["chat_collapsed_sections"] == []
      assert prefs["chat_pinned_spaces"] == []
    end

    test "set_section_collapsed round-trips true then false" do
      user = create_user!()

      assert {:ok, _} = Sidebar.set_section_collapsed(user.id, "s1", true)
      assert Accounts.get_user_preferences(user.id)["chat_collapsed_sections"] == ["s1"]

      # Idempotent: the caller posts the desired state, so a double-fire from a
      # render race must not re-expand.
      assert {:ok, _} = Sidebar.set_section_collapsed(user.id, "s1", true)
      assert Accounts.get_user_preferences(user.id)["chat_collapsed_sections"] == ["s1"]

      assert {:ok, _} = Sidebar.set_section_collapsed(user.id, "s1", false)
      assert Accounts.get_user_preferences(user.id)["chat_collapsed_sections"] == []
    end

    test "set_section_collapsed leaves the other three preference keys untouched" do
      # The obvious wrong implementation writes the whole preferences map and
      # clobbers a sibling key. Hide in particular must survive: collapse and
      # hide are separate features on the same section.
      user = create_user!()
      {:ok, _} = Sidebar.put_section_order(user.id, ["s2", "s1"])
      {:ok, _} = Sidebar.put_channel_order(user.id, "sA", ["c1", "c2"])
      {:ok, _} = Sidebar.set_section_hidden(user.id, "s9", true)

      assert {:ok, _} = Sidebar.set_section_collapsed(user.id, "s1", true)

      prefs = Accounts.get_user_preferences(user.id)
      assert prefs["chat_section_order"] == ["s2", "s1"]
      assert prefs["chat_channel_order"] == %{"sA" => ["c1", "c2"]}
      assert prefs["chat_hidden_sections"] == ["s9"]
      assert prefs["chat_collapsed_sections"] == ["s1"]

      # And the reverse direction: hiding must not drop the collapse.
      assert {:ok, _} = Sidebar.set_section_hidden(user.id, "s8", true)
      assert Accounts.get_user_preferences(user.id)["chat_collapsed_sections"] == ["s1"]
    end

    test "set_section_collapsed no-ops for an id that isn't a real user" do
      assert {:error, :not_found} =
               Sidebar.set_section_collapsed(Ecto.UUID.generate(), "s1", true)
    end
  end

  # ── Pinned conversations (task 019fd80f stage 1) ─────────────────────────
  #
  # The store is keyed to a SPACE, with no `kind` restriction anywhere. The
  # Pinned block holds channels and direct messages in one list, and both are
  # `chat_spaces` rows differing only by `kind`.

  describe "pinned conversations (chat_pinned_spaces)" do
    test "set_space_pinned round-trips pin then unpin" do
      user = create_user!()
      space = channel!()

      assert {:ok, _} = Sidebar.set_space_pinned(user.id, space.id, true)
      assert Sidebar.list_pinned_space_ids(user.id) == [space.id]
      assert Sidebar.pinned_space_ids(user.id) == MapSet.new([space.id])

      assert {:ok, _} = Sidebar.set_space_pinned(user.id, space.id, false)
      assert Sidebar.list_pinned_space_ids(user.id) == []
      assert Sidebar.pinned_space_ids(user.id) == MapSet.new()
    end

    test "a DM round-trips identically to a channel" do
      # Anti-vacuity for the whole stage. An implementation that filters on
      # `kind` in the schema, the setter or the read passes every
      # channel-only test here and silently breaks the block for people.
      user = create_user!()
      chan = channel!()
      dm = dm!()

      assert {:ok, _} = Sidebar.set_space_pinned(user.id, chan.id, true)
      assert {:ok, _} = Sidebar.set_space_pinned(user.id, dm.id, true)

      assert Sidebar.list_pinned_space_ids(user.id) == [chan.id, dm.id]

      assert {:ok, _} = Sidebar.set_space_pinned(user.id, chan.id, false)
      assert Sidebar.list_pinned_space_ids(user.id) == [dm.id]

      assert {:ok, _} = Sidebar.set_space_pinned(user.id, dm.id, false)
      assert Sidebar.list_pinned_space_ids(user.id) == []

      # And the reverse pin order, so neither kind depends on going first.
      assert {:ok, _} = Sidebar.set_space_pinned(user.id, dm.id, true)
      assert {:ok, _} = Sidebar.set_space_pinned(user.id, chan.id, true)
      assert Sidebar.list_pinned_space_ids(user.id) == [dm.id, chan.id]
    end

    test "a group DM pins the same way a two-person DM does" do
      user = create_user!()
      group = channel!(%{kind: "group", name: "Crew"})

      assert {:ok, _} = Sidebar.set_space_pinned(user.id, group.id, true)
      assert Sidebar.list_pinned_space_ids(user.id) == [group.id]
    end

    test "order is most-recently-pinned last" do
      user = create_user!()
      [a, b, c] = [channel!(), dm!(), channel!()]

      {:ok, _} = Sidebar.set_space_pinned(user.id, a.id, true)
      {:ok, _} = Sidebar.set_space_pinned(user.id, b.id, true)
      {:ok, _} = Sidebar.set_space_pinned(user.id, c.id, true)

      assert Sidebar.list_pinned_space_ids(user.id) == [a.id, b.id, c.id]
    end

    test "re-pinning an already-pinned space is idempotent and keeps its position" do
      # The caller posts the desired state, so a double-fire from a render
      # race must neither duplicate the row nor shuffle the block.
      user = create_user!()
      [a, b] = [channel!(), channel!()]

      {:ok, _} = Sidebar.set_space_pinned(user.id, a.id, true)
      {:ok, _} = Sidebar.set_space_pinned(user.id, b.id, true)

      assert {:ok, _} = Sidebar.set_space_pinned(user.id, a.id, true)
      assert Sidebar.list_pinned_space_ids(user.id) == [a.id, b.id]
    end

    test "unpinning a space that was never pinned is a no-op, not an error" do
      user = create_user!()

      assert {:ok, _} = Sidebar.set_space_pinned(user.id, Ecto.UUID.generate(), false)
      assert Sidebar.list_pinned_space_ids(user.id) == []
    end

    test "a pinned id naming a space that no longer exists does not raise on read" do
      # Deleting a space must never require a cleanup pass over preferences
      # JSONB. The read tolerates the stale id; resolving it against the
      # loaded space list drops it (see PinnedSpaces.partition/2).
      user = create_user!()
      live = channel!()
      ghost = Ecto.UUID.generate()

      {:ok, _} = Sidebar.set_space_pinned(user.id, ghost, true)
      {:ok, _} = Sidebar.set_space_pinned(user.id, live.id, true)

      assert Sidebar.list_pinned_space_ids(user.id) == [ghost, live.id]

      assert PinnedSpaces.partition([live], Sidebar.list_pinned_space_ids(user.id)) ==
               {[live], []}
    end

    test "set_space_pinned leaves the other four preference keys untouched" do
      # The obvious wrong implementation rewrites the whole preferences map
      # and clobbers a sibling key.
      user = create_user!()
      {:ok, _} = Sidebar.put_section_order(user.id, ["s2", "s1"])
      {:ok, _} = Sidebar.put_channel_order(user.id, "sA", ["c1", "c2"])
      {:ok, _} = Sidebar.set_section_hidden(user.id, "s9", true)
      {:ok, _} = Sidebar.set_section_collapsed(user.id, "s7", true)

      assert {:ok, _} = Sidebar.set_space_pinned(user.id, "sp1", true)

      prefs = Accounts.get_user_preferences(user.id)
      assert prefs["chat_section_order"] == ["s2", "s1"]
      assert prefs["chat_channel_order"] == %{"sA" => ["c1", "c2"]}
      assert prefs["chat_hidden_sections"] == ["s9"]
      assert prefs["chat_collapsed_sections"] == ["s7"]
      assert prefs["chat_pinned_spaces"] == ["sp1"]

      # And the reverse direction: the sibling writers must not drop the pin.
      assert {:ok, _} = Sidebar.set_section_hidden(user.id, "s8", true)
      assert {:ok, _} = Sidebar.set_section_collapsed(user.id, "s6", true)
      assert Accounts.get_user_preferences(user.id)["chat_pinned_spaces"] == ["sp1"]
    end

    test "reads are empty for a user with no pins and for an unknown user" do
      user = create_user!()

      assert Sidebar.list_pinned_space_ids(user.id) == []
      assert Sidebar.pinned_space_ids(user.id) == MapSet.new()
      assert Sidebar.list_pinned_space_ids(Ecto.UUID.generate()) == []
      assert Sidebar.pinned_space_ids(nil) == MapSet.new()
    end

    test "set_space_pinned no-ops for an id that isn't a real user" do
      # Anonymous chat sessions carry a generated UUID matching no row.
      assert {:error, :not_found} =
               Sidebar.set_space_pinned(Ecto.UUID.generate(), Ecto.UUID.generate(), true)
    end
  end

  # ── Reordering the Pinned block (task 019fe987) ──────────────────────────
  #
  # Reordering is a REWRITE of `chat_pinned_spaces`, which the describe above
  # establishes is already an ordered list. No new preference key and no
  # position column. Every test here asserts the PERSISTED order after the
  # call, never that the call returned `{:ok, _}`: a setter that accepts its
  # arguments and writes nothing satisfies the return shape on every path.
  describe "move_pinned_space/3" do
    test "moves a pin to a new index and the list reads back in the new order" do
      user = create_user!()
      {a, b, c} = three_pins(user)

      # Last to first. Predicted: [c, a, b].
      assert {:ok, _} = Sidebar.move_pinned_space(user.id, c.id, 0)
      assert Sidebar.list_pinned_space_ids(user.id) == [c.id, a.id, b.id]

      # And back to the middle. The index names a slot in the list with `c`
      # already removed, so 1 puts it between `a` and `b`. Predicted:
      # [a, c, b].
      assert {:ok, _} = Sidebar.move_pinned_space(user.id, c.id, 1)
      assert Sidebar.list_pinned_space_ids(user.id) == [a.id, c.id, b.id]
    end

    test "moving to the tail index appends rather than raising" do
      # `length(rest)` is a legal destination, not an off-by-one: it is how
      # "put this at the bottom of the block" arrives.
      user = create_user!()
      {a, b, c} = three_pins(user)

      assert {:ok, _} = Sidebar.move_pinned_space(user.id, a.id, 2)
      assert Sidebar.list_pinned_space_ids(user.id) == [b.id, c.id, a.id]
    end

    test "a DM reorders identically to a channel" do
      # Anti-vacuity for the mixed block. A `kind` check anywhere in the
      # reorder path passes every channel-only assertion here and silently
      # refuses to move people, who are the rows with the longest labels and
      # the ones a user most wants at the top.
      user = create_user!()
      {a, b, c} = three_pins(user)

      assert {:ok, _} = Sidebar.move_pinned_space(user.id, b.id, 0)
      assert Sidebar.list_pinned_space_ids(user.id) == [b.id, a.id, c.id]
    end

    test "an id that is not pinned leaves the list unchanged and does not raise" do
      user = create_user!()
      {a, b, c} = three_pins(user)
      stranger = channel!()

      assert {:ok, _} = Sidebar.move_pinned_space(user.id, stranger.id, 0)
      assert Sidebar.list_pinned_space_ids(user.id) == [a.id, b.id, c.id]

      assert {:ok, _} = Sidebar.move_pinned_space(user.id, Ecto.UUID.generate(), 1)
      assert Sidebar.list_pinned_space_ids(user.id) == [a.id, b.id, c.id]
    end

    test "an out-of-range index leaves the list unchanged and does not raise" do
      # `List.insert_at/3` accepts both of these silently: a negative index
      # counts from the end, and any index past the tail appends. Either would
      # relocate a pin on a payload that means nothing.
      user = create_user!()
      {a, b, c} = three_pins(user)

      assert {:ok, _} = Sidebar.move_pinned_space(user.id, a.id, -1)
      assert Sidebar.list_pinned_space_ids(user.id) == [a.id, b.id, c.id]

      assert {:ok, _} = Sidebar.move_pinned_space(user.id, a.id, 3)
      assert Sidebar.list_pinned_space_ids(user.id) == [a.id, b.id, c.id]
    end

    test "a stale pinned id keeps its slot while a live pin moves around it" do
      # Pin ids outlive the spaces they name (PinnedSpaces states the
      # skip-unknown property in its moduledoc), so the stored list can hold
      # ids the block never renders. A reorder must not double as a cleanup
      # pass over preferences.
      user = create_user!()
      ghost = Ecto.UUID.generate()
      [a, b] = [channel!(), channel!()]

      for id <- [a.id, ghost, b.id], do: {:ok, _} = Sidebar.set_space_pinned(user.id, id, true)
      assert Sidebar.list_pinned_space_ids(user.id) == [a.id, ghost, b.id]

      assert {:ok, _} = Sidebar.move_pinned_space(user.id, b.id, 0)
      assert Sidebar.list_pinned_space_ids(user.id) == [b.id, a.id, ghost]
    end

    test "reordering leaves the other four preference keys untouched" do
      # The obvious wrong implementation rewrites the whole preferences map
      # and clobbers a sibling key.
      user = create_user!()
      {:ok, _} = Sidebar.put_section_order(user.id, ["s2", "s1"])
      {:ok, _} = Sidebar.put_channel_order(user.id, "sA", ["c1", "c2"])
      {:ok, _} = Sidebar.set_section_hidden(user.id, "s9", true)
      {:ok, _} = Sidebar.set_section_collapsed(user.id, "s7", true)
      {a, b, c} = three_pins(user)

      assert {:ok, _} = Sidebar.move_pinned_space(user.id, c.id, 0)

      prefs = Accounts.get_user_preferences(user.id)
      assert prefs["chat_section_order"] == ["s2", "s1"]
      assert prefs["chat_channel_order"] == %{"sA" => ["c1", "c2"]}
      assert prefs["chat_hidden_sections"] == ["s9"]
      assert prefs["chat_collapsed_sections"] == ["s7"]
      assert prefs["chat_pinned_spaces"] == [c.id, a.id, b.id]
    end

    test "no-ops for an id that isn't a real user" do
      # Anonymous chat sessions carry a generated UUID matching no row.
      assert {:error, :not_found} =
               Sidebar.move_pinned_space(Ecto.UUID.generate(), Ecto.UUID.generate(), 0)
    end
  end

  # ── Admin reassignment vs personal arrangement (task 019fd76a stage 3) ───
  #
  # Design decision 1a used to prune the reassigned channel out of every
  # user's `chat_channel_order`, so an admin move silently rearranged a
  # sidebar the user had arranged by hand. Reversed on 2026-08-06.
  #
  # The two tests below are a PAIR and neither is optional. The first alone
  # is satisfied by an implementation that ignores admin reassignment
  # entirely; the second alone is satisfied by the old prune-everything
  # behaviour. Only together do they pin the split.

  describe "reassign_channel/3 vs per-user placement (decision 1a, REVERSED)" do
    test "a user's explicit placement survives the admin move" do
      admin = admin_user!()
      member = create_user!()
      from_org = Tenancy.get_org_by_slug!("sxi")
      to_org = Tenancy.get_org_by_slug!("paragon")
      chosen = section_for!(Tenancy.get_org_by_slug!("fabrikam"))

      channel = channel!(%{name: "Wharfside"})
      {:ok, channel} = Chat.assign_space_org(channel, from_org.id)

      # The member drags the channel into a section of their own choosing,
      # one that belongs to NEITHER org in the move, so a resolver that
      # re-derived placement from org_id could not accidentally agree.
      {:ok, _} = Sidebar.put_channel_order(member.id, chosen.id, [channel.id])

      assert {:ok, moved} = Sidebar.reassign_channel(admin, channel.id, to_org.id)
      assert moved.org_id == to_org.id

      resolved = Sidebar.resolve_for_user(member.id, [moved])
      assert section_channel_ids(resolved, chosen.id) == [channel.id]
      assert section_channel_ids(resolved, section_for!(to_org).id) == []
      assert section_channel_ids(resolved, section_for!(from_org).id) == []

      # The stored preference, not only the resolver's reading of it. A prune
      # that ran plus a resolver that re-placed the channel by luck is a
      # different bug with the same visible symptom.
      cco = Accounts.get_user_preferences(member.id)["chat_channel_order"]
      assert cco[chosen.id] == [channel.id]
    end

    test "a user who never placed the channel sees it follow the org" do
      admin = admin_user!()
      bystander = create_user!()
      from_org = Tenancy.get_org_by_slug!("sxi")
      to_org = Tenancy.get_org_by_slug!("paragon")

      channel = channel!(%{name: "Copperline"})
      {:ok, channel} = Chat.assign_space_org(channel, from_org.id)

      before = Sidebar.resolve_for_user(bystander.id, [channel])
      assert section_channel_ids(before, section_for!(from_org).id) == [channel.id]
      assert section_channel_ids(before, section_for!(to_org).id) == []

      assert {:ok, moved} = Sidebar.reassign_channel(admin, channel.id, to_org.id)

      resolved = Sidebar.resolve_for_user(bystander.id, [moved])
      assert section_channel_ids(resolved, section_for!(to_org).id) == [channel.id]
      assert section_channel_ids(resolved, section_for!(from_org).id) == []

      # No override was invented on the user's behalf to achieve it.
      assert (Accounts.get_user_preferences(bystander.id)["chat_channel_order"] || %{}) == %{}
    end
  end

  describe "prune_channel_from_overrides/1 (kept, no longer wired to reassign)" do
    test "clears the channel out of every user's order when called directly" do
      member = create_user!()
      other = create_user!()
      section = section_for!(Tenancy.get_org_by_slug!("fabrikam"))

      pruned = channel!(%{name: "Tollgate"})
      keeper = channel!(%{name: "Ninebark"})

      {:ok, _} = Sidebar.put_channel_order(member.id, section.id, [pruned.id, keeper.id])
      {:ok, _} = Sidebar.put_channel_order(other.id, section.id, [keeper.id])

      assert :ok = Sidebar.prune_channel_from_overrides(pruned.id)

      assert Accounts.get_user_preferences(member.id)["chat_channel_order"][section.id] ==
               [keeper.id]

      assert Accounts.get_user_preferences(other.id)["chat_channel_order"][section.id] ==
               [keeper.id]
    end
  end

  # ── Audit trail for the identity move (task 019fd76a stage 3) ────────────
  #
  # `chat_spaces.org_id` is updated in place and keeps no history, so the
  # audit row is the ONLY durable record that an admin moved the channel.
  # The failure this pins is silent: drop
  # `[:platform, :chat, :channel_reassigned]` from `TelemetryHandler`
  # `@chat_events` and the emit still succeeds, nothing raises, and the row
  # simply never appears. So assert the persisted row, not just the event.

  describe "reassign_channel/3 audit trail" do
    setup do
      # The sanctioned form. The boot-attached handler is VM-global, and the
      # copy-pasted `on_exit(fn -> detach(); attach() end)` idiom is what
      # task 019f9d80 traced five leaked handlers to.
      Platform.TelemetryHelpers.ensure_boot_handler!(Platform.Chat.TelemetryHandler)
      :ok
    end

    test "a confirmed move persists a bridged audit row carrying BOTH org ids" do
      admin = admin_user!()
      from_org = Tenancy.get_org_by_slug!("sxi")
      to_org = Tenancy.get_org_by_slug!("paragon")

      channel = channel!(%{name: "Rookery"})
      {:ok, channel} = Chat.assign_space_org(channel, from_org.id)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :chat, :channel_reassigned]
        ])

      assert {:ok, _} = Sidebar.reassign_channel(admin, channel.id, to_org.id)

      assert_receive {[:platform, :chat, :channel_reassigned], ^ref, _measurements, meta}
      assert meta.space_id == channel.id
      assert meta.actor_id == admin.id
      assert meta.from_org_id == from_org.id
      assert meta.to_org_id == to_org.id

      # A count-only assertion here would pass with empty metadata, which is
      # the whole reason the row exists.
      assert [event] = Audit.list(event_type: "chat.channel.reassigned", resource_id: channel.id)
      assert event.actor_id == admin.id
      assert event.actor_type == "user"
      assert event.resource_type == "chat_space"
      assert event.action == "channel_reassigned"
      assert event.metadata["space_id"] == channel.id
      assert event.metadata["from_org_id"] == from_org.id
      assert event.metadata["to_org_id"] == to_org.id
    end

    test "a rejected move writes no audit row" do
      member = member_user!()
      to_org = Tenancy.get_org_by_slug!("paragon")
      channel = channel!(%{name: "Sedgewick"})

      assert {:error, :unauthorized} = Sidebar.reassign_channel(member, channel.id, to_org.id)
      assert [] = Audit.list(event_type: "chat.channel.reassigned", resource_id: channel.id)
    end
  end

  # ── UUID boundary (task 019fa129 stage 4) ────────────────────────────────
  # The 16-character case is the load-bearing one: `Ecto.UUID.cast/1` accepts
  # any 16-byte binary, so a test built from "higgins" alone is green against
  # the bug these guards fix.
  describe "UUID boundary: section updates" do
    test "renaming a nonexistent 16-character section id reports :not_found" do
      # `section_id` is a phx-value- param off the sidebar rename event.
      admin = admin_user!()

      assert {:error, :not_found} = Sidebar.rename_section(admin, "higginshigginsxx", "New name")
      assert {:error, :not_found} = Sidebar.rename_section(admin, "higgins", "New name")
      assert {:error, :not_found} = Sidebar.recolor_section(admin, "higginshigginsxx", "#fff")
    end
  end

  # ── ensure_default_section/1 (task 01a00910 stage 2) ─────────────────────

  describe "ensure_default_section/1" do
    defp sections_for(org_id), do: Repo.all(from(s in Section, where: s.org_id == ^org_id))

    defp create_org!(slug) do
      {:ok, org} =
        Tenancy.create_org(admin_user!(), %{
          name: "Ensure Section #{System.unique_integer([:positive])}",
          slug: slug
        })

      org
    end

    test "creating an org yields exactly one section owned by that org" do
      org = create_org!("ensuresec#{System.unique_integer([:positive])}")

      assert [section] = sections_for(org.id)
      assert section.org_id == org.id
      assert section.name == org.name
    end

    test "the new section is NOT at the lowest position, so a fallback cannot impersonate it" do
      # `fallback_section_id/1` picks the lowest-`position` section. If a newly
      # created org's section landed there, every grouping assertion in this
      # task would pass by accident.
      org = create_org!("ensurepos#{System.unique_integer([:positive])}")

      [section] = sections_for(org.id)
      min_position = Repo.one(from(s in Section, select: min(s.position)))

      assert length(Sidebar.list_default_sections()) > 1
      assert section.position > min_position
    end

    test "calling it a second time yields one row, not two" do
      org = create_org!("ensuretwice#{System.unique_integer([:positive])}")

      assert {:ok, again} = Sidebar.ensure_default_section(org)
      assert [section] = sections_for(org.id)
      assert again.id == section.id
    end

    test "an underscore org slug produces a hyphen-form colour token" do
      # Org slugs are stored underscore-form (`wayne_tech`); section colour
      # tokens and the `.bg-<token>-dot` CSS classes are hyphen-form.
      org = create_org!("wayne_tech_#{System.unique_integer([:positive])}")

      assert [section] = sections_for(org.id)
      assert section.color == String.replace(org.slug, "_", "-")
      refute String.contains?(section.color, "_")
    end

    test "a failed section insert rolls the org back — no half-made org" do
      admin = admin_user!()

      assert {:error, %Ecto.Changeset{}} =
               Tenancy.create_org(admin, %{name: nil, slug: "nosuchorg"})

      refute Repo.exists?(from(o in Tenancy.Org, where: o.slug == "nosuchorg"))
    end
  end
end
