defmodule PlatformWeb.Components.InheritancePillTest do
  @moduledoc """
  Unit tests for the inheritance-provenance pill.

  Covers the 3 visual states (`:inherited`, `:defined_here`, `:overridden`),
  aria-label per state, click-target gating on `@root_admin?`, and the
  non-admin tooltip.

  Uses `Platform.DataCase` (not `ExUnit.Case`) because the underlying
  `Platform.Tenancy.effective_value/4` resolver walks `parent_org_id` via
  `Repo.get/2` — without a DB-backed Org, the `:inherited` and
  `:overridden` paths can't be exercised end-to-end.

  Seeded orgs (`acme`, `initech`, `vandelay_ind`, `globex`, `hooli`) come from
  the `20260519143620_seed_root_orgs.exs` migration that DataCase pulls in.
  """
  use Platform.DataCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PlatformWeb.Components.InheritancePill

  alias Platform.Tenancy

  # ── Lookup builders ──────────────────────────────────────────────────
  #
  # Closure-over-a-map lookup functions, mirroring the pattern in
  # `tenancy_test.exs`. Storage-agnostic exactly like the resolver's
  # contract.

  defp build_lookup(values_by_org_id) do
    fn %Platform.Tenancy.Org{id: org_id}, key ->
      case Map.fetch(values_by_org_id, {org_id, key}) do
        {:ok, value} -> {:ok, value}
        :error -> :error
      end
    end
  end

  defp lookup_inherited(initech_id, acme_id) do
    # Initech has no value; Acme defines it. Resolver walks up.
    build_lookup(%{{acme_id, :my_skill} => "acme-default"})
    |> tap(fn _ -> :ok end)
    |> ignore(initech_id)
  end

  # Tiny passthrough — keeps `initech_id` referenced (suppress
  # "variable unused" warnings without dropping it from the signature).
  defp ignore(fun, _), do: fun

  defp lookup_defined_here(initech_id) do
    # Initech defines locally; Acme doesn't. Resolver finds it on the org.
    build_lookup(%{{initech_id, :my_skill} => "initech-local"})
  end

  defp lookup_overridden(initech_id, acme_id) do
    # Both define it. Resolver returns :overridden because the value at
    # `org` is set AND an ancestor also defines it.
    build_lookup(%{
      {initech_id, :my_skill} => "initech-local",
      {acme_id, :my_skill} => "acme-default"
    })
  end

  defp render_pill(assigns) do
    rendered_to_string(~H"""
    <.inheritance_pill
      org={@org}
      scope={@scope}
      record_key={@record_key}
      default={@default}
      lookup_fn={@lookup_fn}
      root_admin?={@root_admin?}
    />
    """)
  end

  # ── Setup ─────────────────────────────────────────────────────────────

  setup do
    acme = Tenancy.get_org_by_slug!("acme")
    initech = Tenancy.get_org_by_slug!("initech")

    {:ok,
     acme: acme,
     initech: initech,
     base_assigns: %{
       org: initech,
       scope: initech.slug,
       record_key: :my_skill,
       default: nil,
       root_admin?: false
     }}
  end

  # ── State rendering ───────────────────────────────────────────────────

  describe "defined_here state" do
    test "renders the \"Defined here\" label", ctx do
      assigns =
        Map.put(ctx.base_assigns, :lookup_fn, lookup_defined_here(ctx.initech.id))

      html = render_pill(assigns)
      assert html =~ "Defined here"
    end

    test "applies the inheritance-pill--defined modifier class", ctx do
      assigns =
        Map.put(ctx.base_assigns, :lookup_fn, lookup_defined_here(ctx.initech.id))

      html = render_pill(assigns)
      assert html =~ "inheritance-pill--defined"
    end

    test "carries the scope accent color (from the org row, via data-scope)", ctx do
      assigns =
        Map.put(ctx.base_assigns, :lookup_fn, lookup_defined_here(ctx.initech.id))

      html = render_pill(assigns)
      assert html =~ "scope-fill-text"
      assert html =~ ~s(data-scope="#{ctx.initech.slug}")
    end

    test "renders as a non-interactive <span>, not a <button>", ctx do
      assigns =
        Map.put(ctx.base_assigns, :lookup_fn, lookup_defined_here(ctx.initech.id))

      html = render_pill(assigns)
      refute html =~ "<button"
      assert html =~ "<span"
    end

    test "carries aria-label \"Defined here\"", ctx do
      assigns =
        Map.put(ctx.base_assigns, :lookup_fn, lookup_defined_here(ctx.initech.id))

      html = render_pill(assigns)
      assert html =~ ~s(aria-label="Defined here")
    end
  end

  describe "overridden state" do
    test "renders the \"Overridden\" label", ctx do
      assigns =
        Map.put(
          ctx.base_assigns,
          :lookup_fn,
          lookup_overridden(ctx.initech.id, ctx.acme.id)
        )

      html = render_pill(assigns)
      assert html =~ "Overridden"
    end

    test "applies the inheritance-pill--overridden modifier class", ctx do
      assigns =
        Map.put(
          ctx.base_assigns,
          :lookup_fn,
          lookup_overridden(ctx.initech.id, ctx.acme.id)
        )

      html = render_pill(assigns)
      assert html =~ "inheritance-pill--overridden"
    end

    test "carries the scope accent color", ctx do
      assigns =
        Map.put(
          ctx.base_assigns,
          :lookup_fn,
          lookup_overridden(ctx.initech.id, ctx.acme.id)
        )

      html = render_pill(assigns)
      assert html =~ "scope-fill-text"
      assert html =~ ~s(data-scope="#{ctx.initech.slug}")
    end

    test "carries aria-label \"Overridden from {parent}\"", ctx do
      assigns =
        Map.put(
          ctx.base_assigns,
          :lookup_fn,
          lookup_overridden(ctx.initech.id, ctx.acme.id)
        )

      html = render_pill(assigns)
      assert html =~ ~s(aria-label="Overridden from Acme")
    end
  end

  describe "inherited state" do
    test "renders the \"Inherited from {parent}\" label", ctx do
      assigns =
        Map.put(
          ctx.base_assigns,
          :lookup_fn,
          lookup_inherited(ctx.initech.id, ctx.acme.id)
        )

      html = render_pill(assigns)
      assert html =~ "Inherited from Acme"
    end

    test "applies the inheritance-pill--inherited modifier class", ctx do
      assigns =
        Map.put(
          ctx.base_assigns,
          :lookup_fn,
          lookup_inherited(ctx.initech.id, ctx.acme.id)
        )

      html = render_pill(assigns)
      assert html =~ "inheritance-pill--inherited"
    end

    test "does NOT carry the scope accent color (inherited is muted)", ctx do
      assigns =
        Map.put(
          ctx.base_assigns,
          :lookup_fn,
          lookup_inherited(ctx.initech.id, ctx.acme.id)
        )

      html = render_pill(assigns)
      refute html =~ "scope-fill-text"
      refute html =~ "data-scope="
    end

    test "carries aria-label \"Inherited from {parent}\"", ctx do
      assigns =
        Map.put(
          ctx.base_assigns,
          :lookup_fn,
          lookup_inherited(ctx.initech.id, ctx.acme.id)
        )

      html = render_pill(assigns)
      assert html =~ ~s(aria-label="Inherited from Acme")
    end
  end

  # ── Click-target gating ───────────────────────────────────────────────

  describe "click-target gating on @root_admin?" do
    test "inherited + root_admin? true renders as a clickable <button>", ctx do
      assigns =
        ctx.base_assigns
        |> Map.put(:lookup_fn, lookup_inherited(ctx.initech.id, ctx.acme.id))
        |> Map.put(:root_admin?, true)

      html = render_pill(assigns)
      assert html =~ "<button"
      assert html =~ ~s(phx-click="open_override_dialog")
    end

    test "inherited + root_admin? false renders as a non-interactive <span>", ctx do
      assigns =
        ctx.base_assigns
        |> Map.put(:lookup_fn, lookup_inherited(ctx.initech.id, ctx.acme.id))
        |> Map.put(:root_admin?, false)

      html = render_pill(assigns)
      refute html =~ "<button"
    end

    test "defined_here + root_admin? true is STILL non-interactive (nothing to override)",
         ctx do
      assigns =
        ctx.base_assigns
        |> Map.put(:lookup_fn, lookup_defined_here(ctx.initech.id))
        |> Map.put(:root_admin?, true)

      html = render_pill(assigns)
      refute html =~ "<button"
    end

    test "overridden + root_admin? true is non-interactive (already overridden)", ctx do
      assigns =
        ctx.base_assigns
        |> Map.put(:lookup_fn, lookup_overridden(ctx.initech.id, ctx.acme.id))
        |> Map.put(:root_admin?, true)

      html = render_pill(assigns)
      refute html =~ "<button"
    end
  end

  describe "non-admin tooltip" do
    test "inherited + root_admin? false carries the permission tooltip text", ctx do
      assigns =
        ctx.base_assigns
        |> Map.put(:lookup_fn, lookup_inherited(ctx.initech.id, ctx.acme.id))
        |> Map.put(:root_admin?, false)

      html = render_pill(assigns)
      assert html =~ "Only root-org admins can override"
    end

    test "non-admin tooltip uses cursor-not-allowed to signal disabled affordance", ctx do
      assigns =
        ctx.base_assigns
        |> Map.put(:lookup_fn, lookup_inherited(ctx.initech.id, ctx.acme.id))
        |> Map.put(:root_admin?, false)

      html = render_pill(assigns)
      assert html =~ "cursor-not-allowed"
    end

    test "defined_here state does NOT show the permission tooltip", ctx do
      assigns =
        ctx.base_assigns
        |> Map.put(:lookup_fn, lookup_defined_here(ctx.initech.id))
        |> Map.put(:root_admin?, false)

      html = render_pill(assigns)
      refute html =~ "Only root-org admins can override"
    end
  end

  # ── Wonka, the sixth scope (task 019ffe9d) ───────────────────────
  #
  # Stage 3 appended `"wonka"` to this component's `:scope` attr
  # `values:` list and added the `"wonka" -> "wonka"` clause to
  # `scope_from_org/1`, but added no render coverage here — so nothing
  # pinned that the pill actually accents with the wonka token.
  # This component has NO production call site (it is referenced only by
  # its own moduledoc example and this file), so a browser cannot observe
  # it; a render test is the only available evidence.
  #
  # The org is created AT RUNTIME through `Tenancy.create_org/2`, never by
  # extending the seed migration: `tenancy_test.exs`, `projects_test.exs`
  # and `federation/tool_surface_org_filters_test.exs` all assert the exact
  # five-org SEEDED set, and a sixth seeded org would turn them red.
  describe "wonka scope" do
    setup do
      admin = create_acme_admin!()
      {:ok, wonka} = Tenancy.create_org(admin, %{name: "Wonka", slug: "wonka"})
      {:ok, wonka: wonka}
    end

    test "defined_here accents with the wonka token", ctx do
      assigns = %{
        org: ctx.wonka,
        scope: "wonka",
        record_key: :my_skill,
        default: nil,
        root_admin?: false,
        lookup_fn: build_lookup(%{{ctx.wonka.id, :my_skill} => "wonka-local"})
      }

      html = render_pill(assigns)

      assert html =~ "scope-fill-text"
      assert html =~ ~s(data-scope="wonka")
      assert html =~ "Defined here"
    end

    test "overridden accents with the wonka token", ctx do
      assigns = %{
        org: ctx.wonka,
        scope: "wonka",
        record_key: :my_skill,
        default: nil,
        root_admin?: false,
        lookup_fn:
          build_lookup(%{
            {ctx.wonka.id, :my_skill} => "wonka-local",
            {ctx.acme.id, :my_skill} => "acme-default"
          })
      }

      html = render_pill(assigns)

      assert html =~ "scope-fill-text"
      assert html =~ ~s(data-scope="wonka")
    end

    test "the wonka accent comes from its org row through data-scope, not a class", ctx do
      # Task 01a14dd9 stage 2 deleted `Tenancy.scope_color/1` and the per-slug
      # `text-<slug>` classes it returned. The accent is a slug-agnostic class
      # plus the org's own `data-scope`, which `ScopeColorStyles` colours from
      # the row, so a runtime org is accented with no deploy.
      html =
        render_pill(%{
          org: ctx.wonka,
          scope: "wonka",
          record_key: :my_skill,
          default: nil,
          root_admin?: false,
          lookup_fn: build_lookup(%{{ctx.wonka.id, :my_skill} => "v"})
        })

      assert html =~ ~s(data-scope="wonka")
      refute html =~ "text-wonka"
    end

    test "inherited resolves wonka's parent to the acme accent, not wonka's", ctx do
      # A tenant inherits from the root, so the SOURCE org here is Acme.
      # `:inherited` renders no accent at all (`accent_class(:inherited, _)`
      # is nil) — asserted so a future accent-on-inherited change has to
      # come past this test.
      html =
        render_pill(%{
          org: ctx.wonka,
          scope: "wonka",
          record_key: :my_skill,
          default: nil,
          root_admin?: false,
          lookup_fn: build_lookup(%{{ctx.acme.id, :my_skill} => "acme-default"})
        })

      assert html =~ "Inherited from Acme"
      refute html =~ "scope-fill-text"
      refute html =~ "data-scope="
    end

    test "creating wonka at runtime leaves the seeded five untouched", ctx do
      # The sibling suites assert the exact five-org seeded set; this pins
      # that a runtime create does not join it.
      slugs = Tenancy.list_orgs() |> Enum.map(& &1.slug) |> Enum.sort()
      assert slugs == ~w(acme globex hooli initech vandelay_ind wonka)
      assert ctx.wonka.parent_org_id == ctx.acme.id
      assert Tenancy.tier(ctx.wonka) == :tenant
    end
  end

  # Acme-admin actor — `Tenancy.create_org/2` refuses anyone else.
  defp create_acme_admin! do
    n = System.unique_integer([:positive])

    user =
      %Platform.Accounts.User{}
      |> Platform.Accounts.User.changeset(%{
        email: "inheritance-pill-#{n}@example.com",
        name: "Inheritance Pill #{n}",
        oidc_sub: "oidc-inheritance-pill-#{n}"
      })
      |> Platform.Repo.insert!()

    %Platform.Tenancy.OrgMembership{}
    |> Platform.Tenancy.OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("acme").id,
      role: "admin"
    })
    |> Platform.Repo.insert!()

    user
  end
end
