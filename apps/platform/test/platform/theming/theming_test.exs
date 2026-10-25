defmodule Platform.ThemingTest do
  @moduledoc """
  `Platform.Theming` (task 01a1557a-fe9b stage 1): every write refuses a
  non-admin and an external user, `publish/2` refuses a failing pair, the
  ledger floors its ratios, and `list_published_for_user/1` is scoped by
  membership.

  Named mutations, each recorded in the stage commit: (a) drop the
  `root_admin?` check from `publish/2` and "publish refuses ..." goes red;
  (b) round the ledger ratio instead of flooring it, and the 4.497 fixture
  shows 4.50 and passes, so "a 4.497 ratio reads 4.49 and fails" goes red.

  Stage 6 mutation: drop the carried overrides from `PresetParser.masters/2`
  (return the master keys only), and Burrow sand light's duplicate fails
  Purple 4.46, Brick 4.46 and Lime 4.49 on raised, so "every preset's
  unmodified duplicate passes ..." goes red.
  """
  use Platform.DataCase, async: true

  import Platform.TenancyFixtures

  alias Platform.Design.WcagContrast, as: W
  alias Platform.ExternalUserFixtures, as: X
  alias Platform.Theming
  alias Platform.Theming.Ledger
  alias Platform.Theming.OrgTheme
  alias Platform.Theming.Presets

  defp hex(r, g, b), do: "#" <> Base.encode16(<<r, g, b>>, case: :lower)

  setup do
    root = Platform.Tenancy.get_org!(acme_org_id())

    tenant =
      Platform.Tenancy.get_org!(tenant_org_id("theming-#{System.unique_integer([:positive])}"))

    admin = root_admin!()

    member = X.create_user!()
    X.plain_member!(member, root)

    guest = X.external_user!(root, allowlist: false)

    # An admin of a tenant org, not of the root: not a root admin.
    tenant_admin = X.create_user!()
    X.plain_member!(tenant_admin, tenant, "admin")

    {:ok, theme} = Theming.create_draft(admin, root.id, %{name: "Root theme"})

    %{
      root: root,
      tenant: tenant,
      admin: admin,
      member: member,
      guest: guest,
      tenant_admin: tenant_admin,
      theme: theme
    }
  end

  describe "authorization" do
    test "every write refuses a non-admin, an external user, a tenant admin and nil", ctx do
      for actor <- [ctx.member, ctx.guest, ctx.tenant_admin, nil] do
        writes = [
          create_draft: fn -> Theming.create_draft(actor, ctx.root.id, %{name: "Nope"}) end,
          update_draft: fn -> Theming.update_draft(actor, ctx.theme, %{default_mode: "light"}) end,
          rename: fn -> Theming.rename(actor, ctx.theme, "Renamed") end,
          duplicate: fn -> Theming.duplicate(actor, ctx.theme) end,
          delete: fn -> Theming.delete(actor, ctx.theme) end,
          publish: fn -> Theming.publish(actor, ctx.theme) end,
          list_org_themes: fn -> Theming.list_org_themes(actor, ctx.root.id) end,
          get_theme: fn -> Theming.get_theme(actor, ctx.theme.id) end
        ]

        for {name, write} <- writes do
          assert write.() == {:error, :unauthorized},
                 "#{name} let #{inspect(actor && actor.id)} through"
        end
      end

      # Nothing moved.
      assert Repo.get!(OrgTheme, ctx.theme.id) == ctx.theme
      assert Repo.aggregate(OrgTheme, :count) == 1
    end

    test "publish refuses a non-admin even when every pair passes", ctx do
      assert Enum.all?(
               Theming.ledger(ctx.theme, "dark") ++ Theming.ledger(ctx.theme, "light"),
               & &1.pass?
             )

      for actor <- [ctx.member, ctx.guest] do
        assert Theming.publish(actor, ctx.theme) == {:error, :unauthorized}
      end

      assert Repo.get!(OrgTheme, ctx.theme.id).status == "draft"
    end

    test "a malformed or unknown id is a miss, not a crash", ctx do
      assert Theming.get_theme(ctx.admin, "not-a-uuid") == {:error, :not_found}
      assert Theming.get_theme(ctx.admin, Ecto.UUID.generate()) == {:error, :not_found}
      assert {:ok, %OrgTheme{}} = Theming.get_theme(ctx.admin, ctx.theme.id)
    end

    test "the root admin can do every write", ctx do
      a = ctx.admin
      assert {:ok, t} = Theming.update_draft(a, ctx.theme, %{default_mode: "light"})
      assert t.default_mode == "light"
      assert {:ok, t} = Theming.rename(a, t, "Renamed")
      assert t.name == "Renamed"
      assert {:ok, copy} = Theming.duplicate(a, t)
      assert copy.name == "Renamed (copy)" and copy.status == "draft"
      assert copy.light == t.light and copy.dark == t.dark and copy.shape == t.shape
      assert {:ok, published} = Theming.publish(a, t)
      assert published.status == "published"
      assert published.published_by_id == a.id
      assert %DateTime{} = published.published_at
      assert {:error, :published} = Theming.update_draft(a, published, %{default_mode: "dark"})
      assert {:ok, _} = Theming.delete(a, copy)
      assert {:ok, [only]} = Theming.list_org_themes(a, ctx.root.id)
      assert only.id == published.id
    end
  end

  describe "a draft" do
    test "is seeded from the Burrow preset and names itself org-<id>", ctx do
      base = Presets.base()
      assert ctx.theme.light == base.light
      assert ctx.theme.dark == base.dark
      assert ctx.theme.shape == base.shape
      assert OrgTheme.preset_id(ctx.theme) == "org-" <> ctx.theme.id
    end

    test "names are unique per org, not across orgs", ctx do
      assert {:error, cs} = Theming.create_draft(ctx.admin, ctx.root.id, %{name: "Root theme"})
      assert {"has already been taken", _} = cs.errors[:org_id] || cs.errors[:name]
      assert {:ok, _} = Theming.create_draft(ctx.admin, ctx.tenant.id, %{name: "Root theme"})
    end

    test "an unknown key on update is refused and nothing is written", ctx do
      bad = Map.put(ctx.theme.light, "faint", hex(1, 2, 3))

      assert {:error, %Ecto.Changeset{}} =
               Theming.update_draft(ctx.admin, ctx.theme, %{light: bad})

      assert Repo.get!(OrgTheme, ctx.theme.id).light == ctx.theme.light
    end
  end

  describe "publish/2 and the ledger" do
    test "publish refuses a failing pair, in either mode, and names it", ctx do
      # Ink the same as the ground: every ink row fails in light.
      light = Map.put(ctx.theme.light, "ink", ctx.theme.light["ground"])
      {:ok, theme} = Theming.update_draft(ctx.admin, ctx.theme, %{light: light})

      assert {:error, {:contrast, rows}} = Theming.publish(ctx.admin, theme)
      assert rows != []
      assert Enum.all?(rows, &(&1.mode == "light" and not &1.pass?))
      assert Enum.any?(rows, &(&1.label == "Primary on base" and &1.ratio == 1.0))
      assert Enum.any?(rows, &(&1.label == "base-content on base-200"))
      assert Repo.get!(OrgTheme, theme.id).status == "draft"
    end

    test "a 4.497 ratio reads 4.49 and fails; it is never rounded up to a pass", ctx do
      surface = ctx.theme.light["surface"]
      teal = teal_at(surface, 4.495, 4.5)
      raw = W.contrast(W.hex(teal), W.hex(surface))
      assert raw >= 4.495 and raw < 4.5

      light = Map.put(ctx.theme.light, "agTeal", teal)
      {:ok, theme} = Theming.update_draft(ctx.admin, ctx.theme, %{light: light})

      row = Enum.find(Theming.ledger(theme, "light"), &(&1.label == "Teal on raised"))
      assert row.ratio == 4.49
      assert row.floor == 4.5
      refute row.pass?

      assert {:error, {:contrast, rows}} = Theming.publish(ctx.admin, theme)
      assert Enum.any?(rows, &(&1.label == "Teal on raised"))
    end

    test "ratios are floored to two decimals" do
      assert Ledger.floor2(4.4999) == 4.49
      assert Ledger.floor2(4.5) == 4.5
      assert Ledger.floor2(7.0) == 7.0
      assert Ledger.floor2(3.019) == 3.01
    end
  end

  describe "a duplicate of a shipped preset (stage 6)" do
    # The editor's Duplicate on an unedited preset: a draft seeded with the
    # preset's light / dark / shape (AdminThemesLive draft_attrs/2).
    defp duplicate_preset!(ctx, preset) do
      {:ok, theme} =
        Theming.create_draft(ctx.admin, ctx.root.id, %{
          name: "#{preset.name} (copy) #{System.unique_integer([:positive])}",
          light: preset.light,
          dark: preset.dark,
          shape: preset.shape
        })

      theme
    end

    test "every preset's unmodified duplicate passes the ledger in both modes and publishes",
         ctx do
      for preset <- Presets.all() do
        theme = duplicate_preset!(ctx, preset)

        for mode <- ["dark", "light"] do
          failing =
            for row <- Theming.ledger(theme, mode), not row.pass?, do: {row.label, row.ratio}

          assert failing == [], "#{preset.id} #{mode}: #{inspect(failing)}"
        end

        assert {:ok, %OrgTheme{status: "published"}} = Theming.publish(ctx.admin, theme)
      end
    end

    test "a duplicate paints every colour slot and --subtle exactly as its preset block", ctx do
      for preset <- Presets.all(), mode <- ["dark", "light"] do
        theme = duplicate_preset!(ctx, preset)
        ours = Platform.Theming.Tokens.variant(theme, mode)
        block = Platform.Theming.Tokens.variant(preset, mode)

        assert ours.colors == block.colors, "#{preset.id} #{mode}"
        assert ours.subtle == block.subtle, "#{preset.id} #{mode}"
      end
    end

    test "Burrow sand light carries its declared agent text colours", ctx do
      sand = Presets.get("burrow-sand")
      declared = sand.variants["light"].colors

      for id <- ~w(purple brick lime) do
        key = "ag" <> String.capitalize(id) <> "Text"
        assert sand.light[key] == declared["--ag-#{id}-text"]
        refute sand.light[key] == declared["--ag-#{id}"]
      end

      # A text override outside the known set is still refused.
      theme = duplicate_preset!(ctx, sand)

      assert {:error, %Ecto.Changeset{}} =
               Theming.update_draft(ctx.admin, theme, %{
                 light: Map.put(sand.light, "agFooText", "#000000")
               })
    end
  end

  describe "list_published_for_user/1" do
    test "returns the published themes of the orgs a person belongs to, and no others", ctx do
      {:ok, root_published} = Theming.publish(ctx.admin, ctx.theme)
      {:ok, _root_draft} = Theming.create_draft(ctx.admin, ctx.root.id, %{name: "Root draft"})

      {:ok, tenant_theme} =
        Theming.create_draft(ctx.admin, ctx.tenant.id, %{name: "Tenant theme"})

      {:ok, tenant_published} = Theming.publish(ctx.admin, tenant_theme)

      tenant_only = X.create_user!()
      X.plain_member!(tenant_only, ctx.tenant)

      ids = fn user -> user |> Theming.list_published_for_user() |> Enum.map(& &1.id) end

      assert ids.(ctx.member) == [root_published.id]
      assert ids.(ctx.guest) == [root_published.id]
      assert ids.(tenant_only) == [tenant_published.id]
      assert ids.(ctx.tenant_admin) == [tenant_published.id]
      assert Enum.sort(ids.(ctx.admin)) == [root_published.id]
      assert ids.(X.create_user!()) == []
      assert Theming.list_published_for_user(nil) == []
    end
  end

  # A teal (blue-green, built from bytes) whose contrast on `ground` lands in
  # [lo, hi). Searched, not typed in, so no colour literal sits in this file.
  defp teal_at(ground, lo, hi) do
    g = W.hex(ground)

    Enum.find_value(0..255, fn r ->
      Enum.find_value(0..255, fn gg ->
        b = min(gg + 16, 255)
        c = hex(div(r, 4), gg, b)
        ratio = W.contrast(W.hex(c), g)
        if ratio >= lo and ratio < hi, do: c
      end)
    end) || flunk("no teal lands in [#{lo}, #{hi}) on #{ground}")
  end
end
