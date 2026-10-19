defmodule Platform.DataMigrations.AddColorLightnessToOrgsTest do
  @moduledoc """
  Regression coverage for `20260921190000_add_color_lightness_to_orgs`
  (task 01a09333-d374 stage 5).

  The six shipped orgs move off their hand-authored `app.css` blocks onto the
  runtime colour path, which colours an org from its ROW. Their hue and
  chroma were already stored (backfilled by `20260911220000_add_color_to_orgs`),
  but the runtime path solves every org at a fixed 72% fill lightness, and
  five of the six ship at another one (initech 65, wonka 66, vandelay-ind
  68, globex 70, hooli 80). Hue and chroma alone therefore cannot reproduce
  their fills, so the fill lightness becomes data too.

  Drives the migration's `pin_shipped_colours/1` helper against
  `Platform.Repo` inside the sandbox. Migrations run to `:up` before ExUnit
  boots, so the seeded rows are asserted as they stand, and the helper is
  re-run to prove it is unconditional, idempotent and a no-op where a slug
  has no row.

  Since task 01a14dd9 stage 3 every pinned row is keyed by the sha256 of its
  slug, and this file names the rows by the placeholder slugs
  `Platform.Tenancy.HistoricalRootSlug` maps those digests to. At that
  stage's tip `test_helper.exs` still seeded the shipped tenants under their
  stored slugs, and this file's digest lookups proved that the digest
  predicates select the same rows the slug literals did. Since stage 4 the
  test database seeds the tenants under their PLACEHOLDER slugs, and
  `test_helper.exs` paints them by passing the relabelled rows through the
  helper's optional `rows` argument. A seeded org is therefore looked up by
  its placeholder slug (`seeded_colour/1`), and the digest arm itself is
  driven with a slug this file owns ("paints a legacy row when one exists").
  """
  use Platform.DataCase, async: false

  require Phoenix.LiveViewTest

  alias Platform.Regression.InstallIdentityScanner, as: Scanner
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.HistoricalRootSlug
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
    "legacy" => "oklch(72% 0.16 50)",
    "initech" => "oklch(65% 0.20 295)",
    "vandelay_ind" => "oklch(68% 0.15 240)",
    "globex" => "oklch(70% 0.15 162)",
    "hooli" => "oklch(80% 0.16 95)",
    "wonka" => "oklch(66% 0.19 340)"
  }

  # The four shipped tenants `test_helper.exs` seeds into the test database,
  # under their placeholder slugs, before re-running `pin_shipped_colours/2`
  # with the relabelled rows. The test database's root is
  # the neutral `acme` fixture (task 01a116de stage 4), so the historical
  # `legacy` pin has no row here; "legacy is painted when its row exists" below
  # inserts one. Wonka was created through the admin panel on installs
  # that have it, so it is not in a fresh test database either.
  @seeded ~w(initech vandelay_ind globex hooli)

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

  defp by_slug(placeholder), do: from(o in Org, where: o.slug == ^placeholder)

  defp rows_by_slug(placeholder), do: Repo.aggregate(by_slug(placeholder), :count)

  # The colour of the seeded row stored under the placeholder slug. Exactly
  # one such row must exist.
  defp seeded_colour(placeholder) do
    Repo.one!(
      from(o in by_slug(placeholder),
        select: {o.color_hue, o.color_chroma, o.color_lightness}
      )
    )
  end

  # The shipped rows relabelled onto the placeholder slugs, as
  # `test_helper.exs` passes them.
  defp relabelled, do: HistoricalRootSlug.relabel(migration().shipped())

  # The migration pins the root's row under the original operator's slug;
  # this file calls it `legacy` (Platform.Tenancy.HistoricalRootSlug).
  defp pinned(slug) do
    {^slug, hue, chroma, lightness} =
      Enum.find(HistoricalRootSlug.relabel(migration().shipped()), &(elem(&1, 0) == slug))

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
    test "cover the six shipped orgs, plus the hyphen spelling of vandelay-ind" do
      rows = migration().shipped()
      slugs = rows |> HistoricalRootSlug.relabel() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      assert slugs ==
               Enum.sort(~w(legacy initech vandelay_ind vandelay-ind globex hooli wonka))

      # Every row is keyed by a digest, never by a slug (task 01a14dd9 stage 3).
      assert Enum.all?(rows, &match?({{:sha256, _}, _, _, _}, &1))

      # The root row really is the historical root: it is keyed by the
      # sha256 of a slug the install-identity guard denies, so the migration
      # matches that slug without spelling it (task 01a14b9e stage 5). The
      # tenant term digests are on that list too since task 01a14dd9 stage 5;
      # the guard's TENANT AND CLIENT DIGESTS test asserts them.
      assert {:sha256, hex} = HistoricalRootSlug.from_rows(rows)
      assert Scanner.listed_digest?(hex)

      assert pinned("vandelay-ind") == pinned("vandelay_ind")
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

      assert Enum.sort(moved) == Enum.sort(~w(initech vandelay_ind globex hooli wonka))
    end
  end

  describe "after the migration ran" do
    test "every seeded shipped org carries exactly the pinned hue, chroma and lightness" do
      # Each seeded shipped org is stored once under its placeholder slug and
      # carries the values pinned under its record's digest.
      for slug <- @seeded do
        assert rows_by_slug(slug) == 1, "#{slug}: expected one row at its slug"
        assert seeded_colour(slug) == pinned(slug), slug
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
        Repo.update_all(by_slug("globex"),
          set: [color_hue: 10, color_chroma: 0.2, color_lightness: 0.5]
        )

      migration().pin_shipped_colours(Repo, relabelled())

      assert seeded_colour("globex") == pinned("globex")
    end

    test "is idempotent: a second run changes nothing" do
      migration().pin_shipped_colours(Repo, relabelled())
      first = Map.new(@seeded, &{&1, seeded_colour(&1)})

      migration().pin_shipped_colours(Repo, relabelled())

      assert Map.new(@seeded, &{&1, seeded_colour(&1)}) == first
    end

    test "no-ops for a slug with no row, and creates nothing" do
      assert rows_by_slug("wonka") == 0

      counts = migration().pin_shipped_colours(Repo, relabelled())

      assert counts["wonka"] == 0
      assert counts["vandelay-ind"] == 0
      assert counts["globex"] == 1
      assert rows_by_slug("wonka") == 0
    end

    test "paints a legacy row when one exists (the pin is keyed on the historical slug's digest)" do
      # The shipped root arm matches by the sha256 of the slug. Drive that
      # same arm with a slug this test owns: a row whose slug hashes to the
      # key is painted, and a row whose slug does not is left alone.
      {:sha256, _} = HistoricalRootSlug.from_rows(migration().shipped())

      {_, hue, chroma, lightness} =
        List.keyfind(migration().shipped(), HistoricalRootSlug.key("legacy"), 0)

      root = "legacy-root-#{System.unique_integer([:positive])}"
      tenant!(root, %{color_hue: 12, color_chroma: 0.15})
      bystander = tenant!(root <> "-other", %{color_hue: 12, color_chroma: 0.15})
      key = {:sha256, Scanner.digest(root)}

      counts = migration().pin_colours(Repo, [{key, hue, chroma, lightness}])

      assert counts == %{key => 1}
      assert colour(root) == {50, 0.16, 0.72}
      assert colour(root) == pinned("legacy")
      assert colour(bystander.slug) == {12, 0.15, nil}
    end

    test "colours a wonka row an operator created with a hue of their own" do
      # The shipped rows are keyed by digest, so a row this test can create is
      # one under the placeholder slug, reached by passing the relabelled rows
      # through the optional `rows` argument (task 01a14dd9 stage 3).
      tenant!("wonka", %{color_hue: 12, color_chroma: 0.15})

      counts = migration().pin_shipped_colours(Repo, relabelled())

      assert counts["wonka"] == 1
      assert colour("wonka") == pinned("wonka")
    end

    test "rows defaults to the migration's own shipped rows" do
      assert migration().pin_shipped_colours(Repo) ==
               migration().pin_shipped_colours(Repo, migration().shipped())

      assert Enum.sort(Map.keys(migration().pin_shipped_colours(Repo))) ==
               migration().shipped() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
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
      # scope from the org ROW through `ChatLive.org_scope/1`. Since task
      # 01a14dd9 stage 2 that is the stored slug BINARY for every org (the five
      # compiled sibling atoms are gone). The chip's colour depends on the
      # `data-scope` it emits naming a row the stylesheet has a rule for; a
      # mismatch (a hyphen spelling against an underscore row) is an
      # uncoloured chip and no error. Held against the rows in the database.
      stored_rows = Repo.all(from(o in Org, select: o.slug))
      stored = MapSet.new(stored_rows)

      assert ChatLive.org_scope("legacy") == "legacy"

      for slug <- stored_rows do
        scope = ChatLive.org_scope(slug)
        assert scope == slug, "#{slug} resolves to #{inspect(scope)}"

        html =
          Phoenix.LiveViewTest.render_component(&PlatformWeb.Components.ScopePill.scope_pill/1,
            scope: scope
          )

        [_, data_scope] = Regex.run(~r/data-scope="([^"]+)"/, html)
        assert data_scope in stored, "#{slug} (#{inspect(scope)}) emits data-scope=#{data_scope}"
        assert data_scope == slug
      end

      # A section's colour token (`css_slug/1`) resolves back to the same row,
      # for every row including the shipped ones whose slug carries `_`.
      index = Tenancy.scope_token_index(Repo.all(Org))

      for slug <- stored_rows do
        assert index[Tenancy.css_slug(slug)].slug == slug
      end

      # Every pinned row the migration ships (some have no row in a fresh
      # database; installs create them in the admin panel) still resolves to
      # its own stored spelling, so its pinned colour is the one painted.
      for {slug, _h, _c, _l} <- HistoricalRootSlug.relabel(migration().shipped()) do
        assert ChatLive.org_scope(slug) == slug
      end
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
        Repo.update_all(by_slug("globex"), set: [color_lightness: 1.5])
      end
    end
  end

  defp painted(color), do: ScopeColor.composite_painted(color, 1.0, "#000000").hex

  # Loaded at runtime by `Code.require_file/1`, so named dynamically: a
  # literal call would warn at compile time that the module is undefined.
  defp migration, do: Module.concat(Platform.Repo.Migrations, AddColorLightnessToOrgs)
end
