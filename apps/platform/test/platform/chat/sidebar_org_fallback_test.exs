defmodule Platform.Chat.SidebarOrgFallbackTest do
  @moduledoc """
  Task 01a00910 stage 1 — pin the org-rail misfiling to its actual code path.

  The ticket blamed `PlatformWeb.ChatLive.channel_scope/1`. The org rail does
  not render from there: it renders from `Platform.Chat.Sidebar.resolve_for_user/2`,
  which already groups by `org_id` correctly. The real defect is that NOTHING
  creates a `channel_sections` row — the only rows in the table are the ones
  the `20260604000100_create_channel_sections` migration seeded, and
  `Platform.Tenancy.Lifecycle.create_org/2` inserts an `Org` and stops. So an
  org created after that date has no section, and `default_section_id/3` falls
  through `fallback_section_id/1` to the LOWEST-`position` section — which in
  production is Acme.

  Fixture A below is expected to FAIL against unmodified main and to pass once
  stage 2 creates the section row at org-creation time. Fixture B is the
  negative control: it asserts the resolver keys off `org_id` and never off the
  channel's slug, and it is expected to pass both before and after the fix.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Sidebar
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "org-fallback-#{n}@example.com",
          name: "Org Fallback #{n}",
          oidc_sub: "oidc-org-fallback-#{n}"
        },
        overrides
      )

    %User{} |> User.changeset(attrs) |> Repo.insert!()
  end

  defp admin_user! do
    user = create_user!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("acme").id,
      role: "admin"
    })
    |> Repo.insert!()

    user
  end

  defp channel!(attrs) do
    default = %{
      name: "C",
      slug: "org-fallback-#{System.unique_integer([:positive])}",
      kind: "channel"
    }

    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  # The resolved section a given channel landed in, or nil.
  defp section_holding(resolved, channel_id) do
    Enum.find_value(resolved, fn %{section: section, channels: channels} ->
      if Enum.any?(channels, &(&1.id == channel_id)), do: section
    end)
  end

  # ── Fixture A: an org with no channel_sections row ──────────────────────

  describe "resolve_for_user/2 — org created after the seed migration" do
    test "a channel resolves under a section owned by its OWN org" do
      admin = admin_user!()
      viewer = create_user!()

      {:ok, org} =
        Tenancy.create_org(admin, %{
          name: "Wonka Fallback #{System.unique_integer([:positive])}",
          slug: "wbfallback#{System.unique_integer([:positive])}"
        })

      channel = channel!(%{org_id: org.id, slug: "general-#{System.unique_integer([:positive])}"})

      resolved = Sidebar.resolve_for_user(viewer.id, [channel])
      section = section_holding(resolved, channel.id)

      assert section, "channel did not resolve into any section at all"

      assert section.org_id == org.id,
             """
             Channel (org_id=#{org.id}) resolved into a section owned by a
             DIFFERENT org (section.org_id=#{section.org_id}, name=#{inspect(section.name)},
             position=#{section.position}).

             This is the Wonka symptom: `Tenancy.Lifecycle.create_org/2`
             never wrote a `channel_sections` row for the new org, so
             `Sidebar.default_section_id/3` fell through to
             `fallback_section_id/1` — the lowest-`position` section.
             """
    end
  end

  # ── Fixture B (negative): slug must never beat org_id ───────────────────

  describe "resolve_for_user/2 — a channel slug that collides with an org slug" do
    test "a channel slugged `globex` under a different org resolves under ITS org" do
      viewer = create_user!()

      globex = Tenancy.get_org_by_slug!("globex")
      hooli = Tenancy.get_org_by_slug!("hooli")

      channel = channel!(%{org_id: hooli.id, slug: "globex"})

      resolved = Sidebar.resolve_for_user(viewer.id, [channel])
      section = section_holding(resolved, channel.id)

      assert section, "channel did not resolve into any section at all"

      assert section.org_id == hooli.id,
             "slug-shaped grouping leaked: channel slugged `globex` under Hooli " <>
               "resolved into section org_id=#{section.org_id}"

      refute section.org_id == globex.id,
             "channel slugged `globex` was grouped by its SLUG rather than its org_id"
    end
  end
end
