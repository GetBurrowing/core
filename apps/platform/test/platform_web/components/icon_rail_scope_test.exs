defmodule PlatformWeb.Components.IconRailScopeTest do
  @moduledoc """
  Task 01a1386d-fb6e stage 1: the shell rail (desktop icon rail, mobile
  bottom rail, More sheet) rendered from the permission registry and
  filtered by the actor's `%Platform.Access.Scope{}` through
  `Platform.Access.module_access?/3`.

    * For every internal actor class with no grants, the Scope path renders
      exactly the tiles the legacy `root_user` path renders, on all three
      surfaces.
    * A guest with no grants sees exactly `[:chat]` on all three; an
      internal member on the same render sees Tasks, Files and Org Memory
      (positive control).
    * A guest holding a `tasks.read` grant still sees no Tasks tile, because
      `:tasks` is not `guest_admissible` yet (task stage 3 flips it).
    * An extension rail item is shown only when the scope holds its
      declared permission.
    * A guest mount of `/chat` renders no Tasks, Files or Admin tile.
    * Every `:shell` live_session runs `{PlatformWeb.LiveAuth, :default}`, so
      the rail never renders without a Scope.

  The actor classes mirror `Platform.Access.EquivalenceTest`'s rows (its
  fixtures are private to that file, so they are rebuilt here the same way).
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Access
  alias Platform.Access.{Grants, Scope}
  alias Platform.Accounts
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.Components.{IconRail, MoreSheet}

  @router PlatformWeb.Router

  setup do
    w = World.external_world()
    root = acme_org_id()
    org_a = w.org_a.id
    org_b = w.org_b.id

    internal = [
      root_admin: human!(fn u -> member!(u, root, "admin") end),
      root_member: human!(fn u -> member!(u, root, "member") end),
      sub_admin: human!(fn u -> member!(u, org_a, "admin") end),
      sub_member: w.int,
      zero_membership: human!(fn _u -> :ok end)
    ]

    guests = [
      ext_member: w.ext,
      ext_admin: human!(fn u -> external!(u, org_a, "admin") end),
      ext_root_admin: human!(fn u -> external!(u, root, "admin") end),
      mixed:
        human!(fn u ->
          external!(u, org_a, "member")
          member!(u, org_b, "member")
        end)
    ]

    {:ok, project} =
      Tasks.create_project(%{
        name: "Rail scope #{System.unique_integer([:positive])}",
        repo_url: "git@github.com:test/rail-scope.git",
        org_id: org_a
      })

    %{w: w, internal: internal, guests: guests, project: project}
  end

  # ── Internal classes: Scope path == legacy path ─────────────────────────

  describe "internal actor classes with no grants" do
    test "the Scope path's keys equal the legacy root_user path's keys on every surface", ctx do
      # `root_user` is bound inside the block, not as a comprehension
      # filter: a `root_user = false` filter would drop every non-root row.
      diffs =
        Enum.flat_map(ctx.internal, fn {row, user} ->
          user = Accounts.get_user(user.id)
          scope = Scope.for_user(user)
          root_user = Tenancy.root_admin_preloaded?(user)
          legacy = %{root_user: root_user}
          via = %{root_user: root_user, access_scope: scope}

          for {surface, legacy_keys, scope_keys} <- [
                {:destinations, legacy_destination_keys(root_user),
                 scope_destination_keys(scope)},
                {:desktop, desktop_keys(legacy), desktop_keys(via)},
                {:mobile, mobile_keys(legacy), mobile_keys(via)},
                {:more_sheet, more_sheet_keys(legacy), more_sheet_keys(via)}
              ],
              legacy_keys != scope_keys,
              do: {row, surface, legacy: legacy_keys, scope: scope_keys}
        end)

      # Positive control: the comparison covered every row, root and not.
      assert length(ctx.internal) == 5
      assert Tenancy.root_admin_preloaded?(Accounts.get_user(ctx.internal[:root_admin].id))

      assert diffs == []
    end

    test "root admin keeps the Admin and Prompts tiles; a sub-org admin does not", ctx do
      root = scope_of(ctx.internal[:root_admin])
      sub = scope_of(ctx.internal[:sub_admin])

      assert :admin in desktop_keys(%{access_scope: root})
      assert :prompts in desktop_keys(%{access_scope: root})
      assert :admin in more_sheet_keys(%{access_scope: root})

      refute :admin in desktop_keys(%{access_scope: sub})
      refute :prompts in desktop_keys(%{access_scope: sub})
      refute :admin in more_sheet_keys(%{access_scope: sub})
    end

    # The zero-membership user carries `files.read` through a `membership_org`
    # rule that resolves to no org. The rail rule is "carries", as member 2's
    # equivalence test pins; a "resolves non-empty" reading would drop Files
    # here and change an internal user's rail.
    test "zero-membership keeps Files although its files.read set is empty", ctx do
      scope = scope_of(ctx.internal[:zero_membership])

      assert Access.permitted_ids(scope, "files.read") == []
      assert Access.holds_anywhere?(scope, "files.read")
      assert :files in desktop_keys(%{access_scope: scope})
    end
  end

  # ── Guests ──────────────────────────────────────────────────────────────

  describe "guests" do
    test "a guest with no grants sees exactly [:chat] on all three surfaces", ctx do
      # Positive control on the same render: the internal member sees the
      # working modules.
      member = scope_of(ctx.internal[:sub_member])
      assert Enum.all?([:tasks, :files, :context], &(&1 in desktop_keys(%{access_scope: member})))
      assert :tasks in mobile_keys(%{access_scope: member})
      assert Enum.all?([:files, :context], &(&1 in more_sheet_keys(%{access_scope: member})))

      diffs =
        for {row, user} <- ctx.guests,
            scope = scope_of(user),
            {surface, keys} <- [
              {:destinations, scope_destination_keys(scope)},
              {:desktop, desktop_keys(%{access_scope: scope, root_user: true})},
              {:mobile, mobile_keys(%{access_scope: scope, root_user: true})}
            ],
            keys != [:chat],
            do: {row, surface, keys}

      assert diffs == []

      # The More sheet lists only the Working and Admin clusters; Chat is in
      # the Live cluster, so a guest's sheet is empty, with no section label
      # over nothing (the member's sheet carries the label: control).
      for {row, user} <- ctx.guests do
        assert more_sheet_keys(%{access_scope: scope_of(user), root_user: true}) == [],
               "#{row} sees More-sheet tiles"

        refute more_sheet_html(%{access_scope: scope_of(user), root_user: true}) =~
                 "more-sheet-section-label"
      end

      assert more_sheet_html(%{access_scope: member}) =~ ">Working</p>"

      # Desktop: no Working eyebrow over an empty cluster for a guest; the
      # member's rail carries it (control).
      assert desktop_html(%{access_scope: member}) =~ "icon-rail-eyebrow\">Working<"

      for {row, user} <- ctx.guests do
        refute desktop_html(%{access_scope: scope_of(user)}) =~ ">Working<",
               "#{row}'s rail renders an empty Working eyebrow"
      end
    end

    test "a guest holding tasks.read on a project still sees no Tasks tile", ctx do
      guest = ctx.w.ext

      {:ok, _} =
        Grants.grant(%{principal: guest, permission: "tasks.read", resource: ctx.project})

      scope = scope_of(guest)

      # The grant is on the Scope and counts as holding tasks.read anywhere
      # (positive control) ...
      assert Access.holds_anywhere?(scope, "tasks.read")
      # ... but `:tasks` is not guest-admissible in this stage.
      refute Access.module_access?(scope, :tasks)
      refute :tasks in desktop_keys(%{access_scope: scope})
      refute :tasks in mobile_keys(%{access_scope: scope})
      refute :tasks in scope_destination_keys(scope)
    end
  end

  # ── module_access?/3 edges ──────────────────────────────────────────────

  describe "module_access?/3" do
    test "fails closed for an unknown key and a nil scope", ctx do
      scope = scope_of(ctx.internal[:root_admin])

      assert Access.module_access?(scope, :chat)
      refute Access.module_access?(scope, :no_such_module)
      refute Access.module_access?(nil, :chat)
      refute Access.holds_anywhere?(nil, "chat.read")
    end

    test "an explicit permission overrides the entry's rail permission", ctx do
      member = scope_of(ctx.internal[:sub_member])

      assert Access.module_access?(member, :tasks)
      refute Access.module_access?(member, :tasks, "tasks.manage")
    end
  end

  # ── Extension rail items ────────────────────────────────────────────────

  describe "an extension rail item" do
    test "is shown only when the scope holds its declared permission" do
      Platform.FixtureExtension.register()

      holding = %Scope{actor: :someone, permissions: %{"fixture.use" => :all}}
      lacking = %Scope{actor: :someone, permissions: %{"chat.read" => :all}}

      # Positive control: the legacy path renders it for everyone.
      assert :fixture in legacy_destination_keys(false)

      assert :fixture in scope_destination_keys(holding)
      assert :fixture in desktop_keys(%{access_scope: holding})
      refute :fixture in scope_destination_keys(lacking)
      refute :fixture in desktop_keys(%{access_scope: lacking})
    end
  end

  # ── A guest's real /chat mount ──────────────────────────────────────────

  describe "a guest mount of /chat/<slug>" do
    test "renders the Chat tile and no Tasks, Files or Admin tile", ctx do
      # Positive control: an internal member's /chat renders those tiles.
      # `/chat/<slug>` of a channel both are in: the plug admits a guest to
      # its own org's channel on the app host, which mounts the `:shell`.
      path = "/chat/#{ctx.w.a.slug}"
      {:ok, _view, member_html} = live(World.login(build_conn(), ctx.w.int.id), path)
      member_tiles = rendered_tiles(member_html)
      assert Enum.all?(~w(tasks files), &(&1 in member_tiles))

      {:ok, _view, html} = live(World.login(build_conn(), ctx.w.ext.id), path)
      tiles = rendered_tiles(html)

      assert "chat" in tiles
      for key <- ~w(tasks files admin context prompts), do: refute(key in tiles)
    end
  end

  # ── Guard: the rail always has a Scope ──────────────────────────────────

  describe "every :shell live_session" do
    test "runs {PlatformWeb.LiveAuth, :default}, so the rail renders with a Scope" do
      sessions =
        for route <- Phoenix.Router.routes(@router),
            {_view, _action, _opts, %{name: name, extra: extra}} <-
              [route.metadata[:phoenix_live_view]],
            extra[:layout] == {PlatformWeb.Layouts, :shell},
            uniq: true,
            do: {name, Enum.map(extra[:on_mount] || [], &hook_id/1)}

      # Positive control: the enumeration finds the shell sessions.
      names = Enum.map(sessions, &elem(&1, 0))
      assert :authenticated in names
      assert :admin in names

      missing =
        for {name, hooks} <- sessions,
            {PlatformWeb.LiveAuth, :default} not in hooks,
            do: {name, hooks}

      assert missing == []
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp hook_id(%{id: id}), do: id
  defp hook_id(other), do: other

  defp scope_of(user), do: user.id |> Accounts.get_user() |> Scope.for_user()

  defp legacy_destination_keys(root_user),
    do: [root_user: root_user] |> IconRail.destinations() |> Enum.map(& &1.key)

  defp scope_destination_keys(scope),
    do: [scope: scope] |> IconRail.destinations() |> Enum.map(& &1.key)

  defp desktop_keys(assigns),
    do:
      assigns
      |> desktop_html()
      |> keys("[data-icon-rail] .icon-rail-tab:not(.icon-rail-tab--child)")

  defp desktop_html(assigns) do
    assigns = Map.merge(%{current_path: "/chat", root_user: false, access_scope: nil}, assigns)

    rendered_to_string(~H"""
    <IconRail.icon_rail
      current_path={@current_path}
      root_user={@root_user}
      access_scope={@access_scope}
    />
    """)
  end

  defp mobile_keys(assigns) do
    assigns = Map.merge(%{current_path: "/chat", root_user: false, access_scope: nil}, assigns)

    rendered_to_string(~H"""
    <IconRail.bottom_rail
      current_path={@current_path}
      root_user={@root_user}
      access_scope={@access_scope}
    />
    """)
    |> keys("[data-bottom-rail] .bottom-nav-tab")
    |> List.delete(:more)
  end

  defp more_sheet_keys(assigns),
    do: assigns |> more_sheet_html() |> keys(".more-sheet-row[data-destination]")

  defp more_sheet_html(assigns) do
    assigns = Map.merge(%{root_user: false, access_scope: nil}, assigns)

    rendered_to_string(~H"""
    <MoreSheet.more_sheet
      open={true}
      root_user={@root_user}
      access_scope={@access_scope}
      current_user={nil}
    />
    """)
  end

  defp keys(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("data-destination")
    |> Enum.map(&String.to_atom/1)
  end

  defp rendered_tiles(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("[data-icon-rail] .icon-rail-tab, [data-bottom-rail] .bottom-nav-tab")
    |> LazyHTML.attribute("data-destination")
    |> Enum.uniq()
  end

  defp human!(fun) do
    user = World.create_user!()
    fun.(user)
    user
  end

  defp member!(user, org_id, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role})
    |> Repo.insert!()
  end

  defp external!(user, org_id, role) do
    {:ok, m} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org_id, role: role})
    m
  end
end
