defmodule PlatformWeb.CommandPalette.SourcesTest do
  @moduledoc """
  `PlatformWeb.CommandPalette.Sources.load/1` (Burrow redesign 23, stage 1):
  the modules follow the sidebar, a guest sees only what their own list
  shows, a canvas outside the viewer's spaces is absent, and a masked
  channel is labelled (and so ranked) by its placeholder.
  """
  use PlatformWeb.ConnCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Access.Scope
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.ChatLive
  alias PlatformWeb.CommandPalette.{Rank, Sources}
  alias PlatformWeb.Components.Sidebar

  defp n, do: System.unique_integer([:positive])

  defp user!(role, org_id) do
    k = n()

    user =
      Repo.insert!(%User{
        email: "cmdk-#{k}@example.com",
        name: "Cmdk #{k}",
        oidc_sub: "cmdk-#{k}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role})
    |> Repo.insert!()

    user
  end

  defp guest!(org_id) do
    k = n()

    user =
      Repo.insert!(%User{
        email: "cmdk-g-#{k}@example.com",
        name: "Guest #{k}",
        oidc_sub: "cmdk-g-#{k}"
      })

    {:ok, _} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org_id})
    user
  end

  defp channel!(name, opts \\ []) do
    attrs = Map.merge(%{name: name, slug: "cmdk-ch-#{n()}", kind: "channel"}, Map.new(opts))
    {:ok, ch} = Chat.create_space(attrs)
    ch
  end

  defp join!(space, user) do
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp canvas!(space, title) do
    {:ok, author} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Author",
        joined_at: DateTime.utc_now()
      })

    {:ok, canvas} =
      Chat.create_canvas(%{"space_id" => space.id, "created_by" => author.id, "title" => title})

    canvas
  end

  defp scope(user), do: Scope.for_user(Accounts.get_user(user.id))

  defp load(user, opts \\ []) do
    Sources.load(%{
      access_scope: scope(user),
      user: user,
      user_id: user.id,
      root_user: Keyword.get(opts, :root_user, false),
      mask_names?: Keyword.get(opts, :mask_names?, false)
    })
  end

  defp of_kind(items, kind), do: Enum.filter(items, &(&1.kind == kind))

  defp ids(items, kind),
    do: items |> of_kind(kind) |> Enum.map(&String.replace_prefix(&1.id, "#{kind}:", ""))

  describe "modules" do
    test "are Sidebar.rows/2, tabs then More, then Settings, for root and a restricted Scope" do
      root = user!("admin", acme_org_id())
      guest = guest!(tenant_org_id("cmdk-guest-#{n()}"))

      modules =
        for user <- [root, guest] do
          {tabs, more} = Sidebar.rows(scope(user), false)

          expected =
            Enum.map(tabs ++ more, &{&1.label, &1.path}) ++ [{"Settings", "/settings"}]

          got = user |> load() |> of_kind("module") |> Enum.map(&{&1.label, &1.path})
          assert got == expected
          got
        end

      # Non-vacuous: the restricted Scope really is denied a module root has.
      [root_modules, guest_modules] = modules
      assert length(guest_modules) < length(root_modules)
    end

    test "Sources order: modules, spaces, direct, canvases, settings, archived" do
      user = user!("admin", acme_org_id())
      home = channel!("Cmdk Home")
      join!(home, user)
      canvas!(home, "Cmdk canvas")
      {:ok, _} = Chat.archive_space(channel!("Cmdk Old"))

      kinds = user |> load() |> Enum.map(& &1.kind) |> Enum.dedup()
      assert kinds == ~w(module space canvas settings archived)
    end
  end

  describe "a guest" do
    setup do
      org_id = tenant_org_id("cmdk-guest-#{n()}")
      guest = guest!(org_id)
      allowed = channel!("Cmdk Guest Allowed", org_id: org_id)
      join!(allowed, guest)
      internal = channel!("Cmdk Internal Only")
      {:ok, archived} = Chat.archive_space(channel!("Cmdk Retired"))

      # The Agents space: a goal-carrying channel the guest even belongs to.
      # The list pane still never shows a guest its row.
      previous = Application.get_env(:platform, :agents_goal_surface)
      Application.put_env(:platform, :agents_goal_surface, true)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:platform, :agents_goal_surface),
          else: Application.put_env(:platform, :agents_goal_surface, previous)
      end)

      agents = channel!("Cmdk Agents", goal: "Ship the palette")
      join!(agents, guest)

      %{guest: guest, allowed: allowed, internal: internal, archived: archived, agents: agents}
    end

    test "sees its allowlisted channel and no internal channel, Agents space, archived or Admin",
         ctx do
      assert %{space: %{id: agents_id}} = Platform.Chat.Sidebar.agents_rail_block()
      assert agents_id == ctx.agents.id

      items = load(ctx.guest)
      spaces = ids(items, "space")

      assert ctx.allowed.id in spaces
      refute ctx.internal.id in spaces
      refute ctx.agents.id in spaces
      assert of_kind(items, "archived") == []
      refute "settings:admin" in Enum.map(items, & &1.id)

      # Positive control: an internal root sees every one of them.
      root = user!("admin", acme_org_id())
      root_items = load(root, root_user: true)
      root_spaces = ids(root_items, "space")

      assert ctx.internal.id in root_spaces
      assert ctx.agents.id in root_spaces
      assert ctx.archived.id in ids(root_items, "archived")
      assert "settings:admin" in Enum.map(root_items, & &1.id)
    end

    test "a canvas in a space the viewer isn't in is absent", ctx do
      seen = canvas!(ctx.allowed, "Cmdk seen canvas")
      unseen = canvas!(ctx.internal, "Cmdk unseen canvas")

      canvases = ids(load(ctx.guest), "canvas")
      assert seen.id in canvases
      refute unseen.id in canvases
    end
  end

  test "a DM between two other people, and its canvas, are absent" do
    viewer = user!("member", acme_org_id())
    a = user!("member", acme_org_id())
    b = user!("member", acme_org_id())
    {:ok, dm} = Chat.find_or_create_dm(a.id, "user", b.id)
    other = canvas!(dm, "Cmdk private canvas")

    {:ok, mine} = Chat.find_or_create_dm(viewer.id, "user", a.id)

    items = load(viewer)
    assert mine.id in ids(items, "direct")
    refute dm.id in ids(items, "direct")
    refute other.id in ids(items, "canvas")

    # And the DM row is named as the list row names it.
    [row] = items |> of_kind("direct") |> Enum.filter(&(&1.id == "direct:#{mine.id}"))
    assert row.label == a.name
  end

  describe "masking" do
    setup do
      user = user!("admin", acme_org_id())
      globex = Tenancy.get_org_by_slug("globex") || raise "seeded globex org missing"
      channel = channel!("Globex", org_id: globex.id)
      %{user: user, channel: channel}
    end

    test "on: a sub-org channel is the list pane's placeholder and its real name finds nothing",
         ctx do
      items = load(ctx.user, mask_names?: true)
      [row] = Enum.filter(items, &(&1.id == "space:#{ctx.channel.id}"))

      placeholder =
        ChatLive.masked_space_name(
          %{
            sidebar_sections: Platform.Chat.Sidebar.resolve_for_user(ctx.user.id, []),
            mask_names?: true,
            revealed_section_ids: MapSet.new()
          },
          "Globex"
        )

      assert placeholder =~ ~r/^workspace-/
      assert row.label == placeholder

      refute row.path =~ ctx.channel.slug
      assert row.path == "/chat/#{ChatLive.space_nav_target(ctx.channel)}"
      assert row.path == "/chat/#{ctx.channel.id}"

      refute ctx.channel.id in (items |> Rank.rank("globex") |> ids("space"))
      assert ctx.channel.id in (items |> Rank.rank(placeholder) |> ids("space"))
    end

    test "off: the real name, and it ranks", ctx do
      items = load(ctx.user)
      [row] = Enum.filter(items, &(&1.id == "space:#{ctx.channel.id}"))

      assert row.label == "Globex"
      assert ctx.channel.id in (items |> Rank.rank("globex") |> ids("space"))
    end
  end
end
