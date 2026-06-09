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

    test "reset_to_default clears all three override keys" do
      user = create_user!()
      {:ok, _} = Sidebar.put_section_order(user.id, ["s1"])
      {:ok, _} = Sidebar.put_channel_order(user.id, "sA", ["c1"])
      {:ok, _} = Sidebar.set_section_hidden(user.id, "s2", true)

      assert {:ok, _} = Sidebar.reset_to_default(user.id)

      prefs = Accounts.get_user_preferences(user.id)
      assert is_nil(prefs["chat_section_order"])
      assert prefs["chat_channel_order"] == %{}
      assert prefs["chat_hidden_sections"] == []
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
end
