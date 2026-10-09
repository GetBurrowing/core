defmodule Platform.DataMigrations.AddColorLightnessToOrgsTest do
  @moduledoc """
  Regression coverage for `20260921190000_add_color_lightness_to_orgs`
  (task 01a09333-d374 stage 5).

  The six shipped orgs move off their hand-authored `app.css` blocks onto the
  runtime colour path, which colours an org from its ROW. Their hue and
  chroma were already stored (backfilled by `20260911220000_add_color_to_orgs`),
  but the runtime path solves every org at a fixed 72% fill lightness, and
  five of the six ship at another one (soylent 65, cyberdyne 66, wayne-tech
  68, sxi 70, paragon 80). Hue and chroma alone therefore cannot reproduce
  their fills, so the fill lightness becomes data too.

  Drives the migration's `pin_shipped_colours/1` helper against
  `Platform.Repo` inside the sandbox. Migrations run to `:up` before ExUnit
  boots, so the seeded rows are asserted as they stand, and the helper is
  re-run to prove it is unconditional, idempotent and a no-op where a slug
  has no row.
  """
  use Platform.DataCase, async: false

  require Phoenix.LiveViewTest

  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.ScopeColor
  alias PlatformWeb.ChatLive

  import Ecto.Query, only: [from: 2]

  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260921190000_add_color_lightness_to_orgs.exs"
                  ])

  # The fills the six orgs shipped with, PASTED from the per-slug blocks in
  # `app.css` as they stood at 98eb79ab (the `.bg-<slug>-dot` rule of each),
  # before stage 5 deleted the chip utilities. Pasted, not read from the
  # migration: the point is that the migration's numbers reproduce these.
  @shipped_fills %{
    "fabrikam" => "oklch(72% 0.16 50)",
    "soylent" => "oklch(65% 0.20 295)",
    "wayne_tech" => "oklch(68% 0.15 240)",
    "sxi" => "oklch(70% 0.15 162)",
    "paragon" => "oklch(80% 0.16 95)",
    "cyberdyne" => "oklch(66% 0.19 340)"
  }

  # The four shipped tenants `test_helper.exs` seeds into the test database
  # before re-running `pin_shipped_colours/1`. The test database's root is
  # the neutral `acme` fixture (task 01a116de stage 4), so the historical
  # `fabrikam` pin has no row here; "fabrikam is painted when its row exists" below
  # inserts one. Cyberdyne was created through the admin panel on installs
  # that have it, so it is not in a fresh test database either.
  @seeded ~w(soylent wayne_tech sxi paragon)

  setup_all do
    Code.require_file(@migration_path)
    :ok
  end

  defp colour(slug) do
    Repo.one!(
      from(o in Org,
        where: o.slug == ^slug,
        select: {o.color_hue, o.color_chroma, o.color_lightness}
      )
    )
  end

  defp pinned(slug) do
    {^slug, hue, chroma, lightness} =
      Enum.find(migration().shipped(), &(elem(&1, 0) == slug))

    {hue, chroma, lightness}
  end

  defp tenant!(slug, attrs) do
    %Org{}
    |> Org.changeset(
      Map.merge(
        %{name: "Org #{slug}", slug: slug, parent_org_id: Tenancy.get_root_org().id},
        attrs
      )
    )
    |> Repo.insert!()
  end

  describe "the pinned values" do
    test "cover the six shipped orgs, plus the hyphen spelling of wayne-tech" do
      slugs = migration().shipped() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      assert slugs ==
               Enum.sort(~w(fabrikam soylent wayne_tech wayne-tech sxi paragon cyberdyne))

      assert pinned("wayne-tech") == pinned("wayne_tech")
    end

    test "reproduce each org's SHIPPED fill, which hue and chroma alone cannot" do
      for {slug, shipped} <- @shipped_fills do
        {hue, chroma, lightness} = pinned(slug)
        fill = ScopeColor.derive(hue, chroma, lightness).fill

        assert painted(fill) == painted(shipped),
               "#{slug}: pinned values paint #{fill}, app.css shipped #{shipped}"
      end

      # And the reason the column exists: at the runtime path's default fill
      # lightness, five of the six fills move. If this ever stops holding,
      # the column is no longer needed and should be questioned.
      moved =
        @shipped_fills
        |> Enum.filter(fn {slug, shipped} ->
          {hue, chroma, _lightness} = pinned(slug)
          painted(ScopeColor.derive(hue, chroma).fill) != painted(shipped)
        end)
        |> Enum.map(&elem(&1, 0))

      assert Enum.sort(moved) == Enum.sort(~w(soylent wayne_tech sxi paragon cyberdyne))
    end
  end

  describe "after the migration ran" do
    test "every seeded shipped org carries exactly the pinned hue, chroma and lightness" do
      for slug <- @seeded do
        assert colour(slug) == pinned(slug), slug
      end
    end

    test "an org outside the six has no lightness, so it renders at the default fill" do
      acme = tenant!("acme_#{System.unique_integer([:positive])}", %{color_hue: 200})

      assert Repo.get!(Org, acme.id).color_lightness == nil
    end

    test "the test database's root is outside the six, so it carries no pinned colour" do
      root = Tenancy.get_root_org()

      assert root.slug == "acme"
      assert {root.color_hue, root.color_lightness} == {nil, nil}
    end
  end

  describe "pin_shipped_colours/1" do
    test "writes UNCONDITIONALLY: a stored hue for one of the six is overwritten" do
      # Any hue stored for these six was masked by the legacy CSS override,
      # so nobody ever saw it; preserving today's appearance means writing
      # the shipped values over it.
      {1, _} =
        Repo.update_all(from(o in Org, where: o.slug == "sxi"),
          set: [color_hue: 10, color_chroma: 0.2, color_lightness: 0.5]
        )

      migration().pin_shipped_colours(Repo)

      assert colour("sxi") == pinned("sxi")
    end

    test "is idempotent: a second run changes nothing" do
      migration().pin_shipped_colours(Repo)
      first = Map.new(@seeded, &{&1, colour(&1)})

      migration().pin_shipped_colours(Repo)

      assert Map.new(@seeded, &{&1, colour(&1)}) == first
    end

    test "no-ops for a slug with no row, and creates nothing" do
      assert Tenancy.get_org_by_slug("cyberdyne") == nil

      counts = migration().pin_shipped_colours(Repo)

      assert counts["cyberdyne"] == 0
      assert counts["wayne-tech"] == 0
      assert counts["sxi"] == 1
      assert Tenancy.get_org_by_slug("cyberdyne") == nil
    end

    test "paints a fabrikam row when one exists (the pin is keyed on the historical slug)" do
      assert Tenancy.get_org_by_slug("fabrikam") == nil
      tenant!("fabrikam", %{color_hue: 12, color_chroma: 0.15})

      counts = migration().pin_shipped_colours(Repo)

      assert counts["fabrikam"] == 1
      assert colour("fabrikam") == {50, 0.16, 0.72}
      assert colour("fabrikam") == pinned("fabrikam")
    end

    test "colours a cyberdyne row an operator created with a hue of their own" do
      tenant!("cyberdyne", %{color_hue: 12, color_chroma: 0.15})

      migration().pin_shipped_colours(Repo)

      assert colour("cyberdyne") == pinned("cyberdyne")
    end

    test "leaves every other org alone" do
      other = tenant!("northwind_#{System.unique_integer([:positive])}", %{color_hue: 200})

      migration().pin_shipped_colours(Repo)

      assert colour(other.slug) == {200, nil, nil}
    end
  end

  describe "the chat surfaces' data-scope names a stored row" do
    test "every scope the chat rail and header resolve from an org row emits a stored slug" do
      # The chat rail drawer and both chat header pills resolve their chip's
      # scope from the org ROW through `ChatLive.org_scope/1` (task 01a0938b
      # stage 1): the six shipped slugs keep their atoms, every other org
      # passes its stored slug as a binary. It used to be two closed six-name
      # maps, which gave a runtime org no pill at all. Since 01a09333 stage 5
      # the chip's colour depends on the `data-scope` it emits naming a row
      # the stylesheet has a rule for; a mismatch (`wayne-tech` against a
      # `wayne_tech` row) is an uncoloured chip and no error. Held against the
      # rows in the database, not the migration's table, which lists both
      # wayne-tech spellings.
      stored_rows = Repo.all(from(o in Org, select: o.slug))
      stored = MapSet.new(stored_rows)

      # The six shipped slugs still land on exactly the component's atoms, so
      # the header's `@scope_filter == header_scope` active state keeps working.
      # The root org is the exception since task 01a116de stage 3: it has no
      # compiled atom and takes the binary path like any runtime org.
      assert ChatLive.org_scope("fabrikam") == "fabrikam"

      atoms = Enum.map(~w(paragon soylent wayne_tech sxi cyberdyne), &ChatLive.org_scope/1)

      assert atoms |> Enum.uniq() |> Enum.sort() ==
               Enum.sort(PlatformWeb.Components.ScopePill.scopes())

      # Every shipped atom but Cyberdyne (below) has a row to be coloured by.
      for atom <- atoms, atom != :cyberdyne do
        assert Atom.to_string(atom) in stored, "no stored row for #{inspect(atom)}"
      end

      for slug <- stored_rows do
        scope = ChatLive.org_scope(slug)

        html =
          Phoenix.LiveViewTest.render_component(&PlatformWeb.Components.ScopePill.scope_pill/1,
            scope: scope
          )

        [_, data_scope] = Regex.run(~r/data-scope="([^"]+)"/, html)
        assert data_scope in stored, "#{slug} (#{inspect(scope)}) emits data-scope=#{data_scope}"

        # A runtime org's binary scope must name its own row, not a sibling's.
        if is_binary(scope), do: assert(data_scope == slug)

        if is_atom(scope), do: assert(Tenancy.get_org_by_slug(data_scope).color_lightness)
      end

      # Cyberdyne has no row in a fresh database (installs create it in the
      # admin panel); its atom emits the one spelling the migration pins.
      html =
        Phoenix.LiveViewTest.render_component(&PlatformWeb.Components.ScopePill.scope_pill/1,
          scope: :cyberdyne
        )

      assert html =~ ~s(data-scope="cyberdyne")
      assert pinned("cyberdyne")
    end
  end

  describe "the lightness guards" do
    test "the changeset refuses a lightness outside (0, 1)" do
      for bad <- [0.0, 1.0, 1.5, -0.1] do
        changeset =
          Org.changeset(%Org{}, %{name: "Bad", slug: "bad_l", color_lightness: bad})

        refute changeset.valid?, "accepted color_lightness #{bad}"
        assert changeset.errors[:color_lightness]
      end

      assert Org.changeset(%Org{}, %{name: "Ok", slug: "ok_l", color_lightness: 0.8}).valid?
    end

    test "the CHECK constraint refuses a raw write the changeset never saw" do
      assert_raise Postgrex.Error, ~r/orgs_color_lightness_range/, fn ->
        Repo.update_all(from(o in Org, where: o.slug == "sxi"), set: [color_lightness: 1.5])
      end
    end
  end

  defp painted(color), do: ScopeColor.composite_painted(color, 1.0, "#000000").hex

  # Loaded at runtime by `Code.require_file/1`, so named dynamically: a
  # literal call would warn at compile time that the module is undefined.
  defp migration, do: Module.concat(Platform.Repo.Migrations, AddColorLightnessToOrgs)
end
