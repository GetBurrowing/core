defmodule Platform.Chat.SidebarTest do
  @moduledoc """
  Stage 2 (chat sidebar v2): the channel_sections org-default layer +
  Fabrikam-admin-gated curation writes. Verifies the migration seeded one section
  per org, and that every write authorizes through `Tenancy.fabrikam_admin?/1`.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts
  alias Platform.Accounts.User
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

  # In-memory fixtures for the pure resolve/3 tests (no DB needed).
  defp sec(id, org_id, pos), do: %Section{id: id, org_id: org_id, name: id, position: pos}
  defp chan(id, org_id), do: %Space{id: id, org_id: org_id, kind: "channel"}

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

  describe "reassign_channel/3 prunes per-user placement (decision 1a)" do
    test "admin reassign removes the channel from a user's chat_channel_order" do
      admin = admin_user!()
      member = create_user!()
      space = channel!()
      sxi = Tenancy.get_org_by_slug!("sxi")

      # member personally placed the channel somewhere
      {:ok, _} = Sidebar.put_channel_order(member.id, "some-section", [space.id, "other"])

      assert {:ok, _} = Sidebar.reassign_channel(admin, space.id, sxi.id)

      cco = Accounts.get_user_preferences(member.id)["chat_channel_order"]
      assert cco["some-section"] == ["other"]
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
end
