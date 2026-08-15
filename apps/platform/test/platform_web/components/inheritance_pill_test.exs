defmodule PlatformWeb.Components.InheritancePillTest do
  @moduledoc """
  Unit tests for the inheritance-provenance pill.

  Covers the 3 visual states (`:inherited`, `:defined_here`, `:overridden`),
  aria-label per state, click-target gating on `@fabrikam_admin?`, and the
  non-admin tooltip.

  Uses `Platform.DataCase` (not `ExUnit.Case`) because the underlying
  `Platform.Tenancy.effective_value/4` resolver walks `parent_org_id` via
  `Repo.get/2` — without a DB-backed Org, the `:inherited` and
  `:overridden` paths can't be exercised end-to-end.

  Seeded orgs (`fabrikam`, `soylent`, `wayne_tech`, `sxi`, `paragon`) come from
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

  defp lookup_inherited(soylent_id, fabrikam_id) do
    # Soylent has no value; Fabrikam defines it. Resolver walks up.
    build_lookup(%{{fabrikam_id, :my_skill} => "fabrikam-default"})
    |> tap(fn _ -> :ok end)
    |> ignore(soylent_id)
  end

  # Tiny passthrough — keeps `soylent_id` referenced (suppress
  # "variable unused" warnings without dropping it from the signature).
  defp ignore(fun, _), do: fun

  defp lookup_defined_here(soylent_id) do
    # Soylent defines locally; Fabrikam doesn't. Resolver finds it on the org.
    build_lookup(%{{soylent_id, :my_skill} => "soylent-local"})
  end

  defp lookup_overridden(soylent_id, fabrikam_id) do
    # Both define it. Resolver returns :overridden because the value at
    # `org` is set AND an ancestor also defines it.
    build_lookup(%{
      {soylent_id, :my_skill} => "soylent-local",
      {fabrikam_id, :my_skill} => "fabrikam-default"
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
      fabrikam_admin?={@fabrikam_admin?}
    />
    """)
  end

  # ── Setup ─────────────────────────────────────────────────────────────

  setup do
    fabrikam = Tenancy.get_org_by_slug!("fabrikam")
    soylent = Tenancy.get_org_by_slug!("soylent")

    {:ok,
     fabrikam: fabrikam,
     soylent: soylent,
     base_assigns: %{
       org: soylent,
       scope: :soylent,
       record_key: :my_skill,
       default: nil,
       fabrikam_admin?: false
     }}
  end

  # ── State rendering ───────────────────────────────────────────────────

  describe "defined_here state" do
    test "renders the \"Defined here\" label", ctx do
      assigns =
        Map.put(ctx.base_assigns, :lookup_fn, lookup_defined_here(ctx.soylent.id))

      html = render_pill(assigns)
      assert html =~ "Defined here"
    end

    test "applies the inheritance-pill--defined modifier class", ctx do
      assigns =
        Map.put(ctx.base_assigns, :lookup_fn, lookup_defined_here(ctx.soylent.id))

      html = render_pill(assigns)
      assert html =~ "inheritance-pill--defined"
    end

    test "carries the scope accent color (text-soylent)", ctx do
      assigns =
        Map.put(ctx.base_assigns, :lookup_fn, lookup_defined_here(ctx.soylent.id))

      html = render_pill(assigns)
      assert html =~ "text-soylent"
    end

    test "renders as a non-interactive <span>, not a <button>", ctx do
      assigns =
        Map.put(ctx.base_assigns, :lookup_fn, lookup_defined_here(ctx.soylent.id))

      html = render_pill(assigns)
      refute html =~ "<button"
      assert html =~ "<span"
    end

    test "carries aria-label \"Defined here\"", ctx do
      assigns =
        Map.put(ctx.base_assigns, :lookup_fn, lookup_defined_here(ctx.soylent.id))

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
          lookup_overridden(ctx.soylent.id, ctx.fabrikam.id)
        )

      html = render_pill(assigns)
      assert html =~ "Overridden"
    end

    test "applies the inheritance-pill--overridden modifier class", ctx do
      assigns =
        Map.put(
          ctx.base_assigns,
          :lookup_fn,
          lookup_overridden(ctx.soylent.id, ctx.fabrikam.id)
        )

      html = render_pill(assigns)
      assert html =~ "inheritance-pill--overridden"
    end

    test "carries the scope accent color", ctx do
      assigns =
        Map.put(
          ctx.base_assigns,
          :lookup_fn,
          lookup_overridden(ctx.soylent.id, ctx.fabrikam.id)
        )

      html = render_pill(assigns)
      assert html =~ "text-soylent"
    end

    test "carries aria-label \"Overridden from {parent}\"", ctx do
      assigns =
        Map.put(
          ctx.base_assigns,
          :lookup_fn,
          lookup_overridden(ctx.soylent.id, ctx.fabrikam.id)
        )

      html = render_pill(assigns)
      assert html =~ ~s(aria-label="Overridden from Fabrikam")
    end
  end

  describe "inherited state" do
    test "renders the \"Inherited from {parent}\" label", ctx do
      assigns =
        Map.put(
          ctx.base_assigns,
          :lookup_fn,
          lookup_inherited(ctx.soylent.id, ctx.fabrikam.id)
        )

      html = render_pill(assigns)
      assert html =~ "Inherited from Fabrikam"
    end

    test "applies the inheritance-pill--inherited modifier class", ctx do
      assigns =
        Map.put(
          ctx.base_assigns,
          :lookup_fn,
          lookup_inherited(ctx.soylent.id, ctx.fabrikam.id)
        )

      html = render_pill(assigns)
      assert html =~ "inheritance-pill--inherited"
    end

    test "does NOT carry the scope accent color (inherited is muted)", ctx do
      assigns =
        Map.put(
          ctx.base_assigns,
          :lookup_fn,
          lookup_inherited(ctx.soylent.id, ctx.fabrikam.id)
        )

      html = render_pill(assigns)
      refute html =~ "text-soylent"
    end

    test "carries aria-label \"Inherited from {parent}\"", ctx do
      assigns =
        Map.put(
          ctx.base_assigns,
          :lookup_fn,
          lookup_inherited(ctx.soylent.id, ctx.fabrikam.id)
        )

      html = render_pill(assigns)
      assert html =~ ~s(aria-label="Inherited from Fabrikam")
    end
  end

  # ── Click-target gating ───────────────────────────────────────────────

  describe "click-target gating on @fabrikam_admin?" do
    test "inherited + fabrikam_admin? true renders as a clickable <button>", ctx do
      assigns =
        ctx.base_assigns
        |> Map.put(:lookup_fn, lookup_inherited(ctx.soylent.id, ctx.fabrikam.id))
        |> Map.put(:fabrikam_admin?, true)

      html = render_pill(assigns)
      assert html =~ "<button"
      assert html =~ ~s(phx-click="open_override_dialog")
    end

    test "inherited + fabrikam_admin? false renders as a non-interactive <span>", ctx do
      assigns =
        ctx.base_assigns
        |> Map.put(:lookup_fn, lookup_inherited(ctx.soylent.id, ctx.fabrikam.id))
        |> Map.put(:fabrikam_admin?, false)

      html = render_pill(assigns)
      refute html =~ "<button"
    end

    test "defined_here + fabrikam_admin? true is STILL non-interactive (nothing to override)",
         ctx do
      assigns =
        ctx.base_assigns
        |> Map.put(:lookup_fn, lookup_defined_here(ctx.soylent.id))
        |> Map.put(:fabrikam_admin?, true)

      html = render_pill(assigns)
      refute html =~ "<button"
    end

    test "overridden + fabrikam_admin? true is non-interactive (already overridden)", ctx do
      assigns =
        ctx.base_assigns
        |> Map.put(:lookup_fn, lookup_overridden(ctx.soylent.id, ctx.fabrikam.id))
        |> Map.put(:fabrikam_admin?, true)

      html = render_pill(assigns)
      refute html =~ "<button"
    end
  end

  describe "non-admin tooltip" do
    test "inherited + fabrikam_admin? false carries the permission tooltip text", ctx do
      assigns =
        ctx.base_assigns
        |> Map.put(:lookup_fn, lookup_inherited(ctx.soylent.id, ctx.fabrikam.id))
        |> Map.put(:fabrikam_admin?, false)

      html = render_pill(assigns)
      assert html =~ "Only Fabrikam admins can override"
    end

    test "non-admin tooltip uses cursor-not-allowed to signal disabled affordance", ctx do
      assigns =
        ctx.base_assigns
        |> Map.put(:lookup_fn, lookup_inherited(ctx.soylent.id, ctx.fabrikam.id))
        |> Map.put(:fabrikam_admin?, false)

      html = render_pill(assigns)
      assert html =~ "cursor-not-allowed"
    end

    test "defined_here state does NOT show the permission tooltip", ctx do
      assigns =
        ctx.base_assigns
        |> Map.put(:lookup_fn, lookup_defined_here(ctx.soylent.id))
        |> Map.put(:fabrikam_admin?, false)

      html = render_pill(assigns)
      refute html =~ "Only Fabrikam admins can override"
    end
  end

  # ── Cyberdyne, the sixth scope (task 019ffe9d) ───────────────────────
  #
  # Stage 3 appended `:cyberdyne` to this component's `:scope` attr
  # `values:` list and added the `"cyberdyne" -> :cyberdyne` clause to
  # `scope_from_org/1`, but added no render coverage here — so nothing
  # pinned that the pill actually accents with the cyberdyne token.
  # This component has NO production call site (it is referenced only by
  # its own moduledoc example and this file), so a browser cannot observe
  # it; a render test is the only available evidence.
  #
  # The org is created AT RUNTIME through `Tenancy.create_org/2`, never by
  # extending the seed migration: `tenancy_test.exs`, `projects_test.exs`
  # and `federation/tool_surface_org_filters_test.exs` all assert the exact
  # five-org SEEDED set, and a sixth seeded org would turn them red.
  describe "cyberdyne scope" do
    setup do
      admin = create_fabrikam_admin!()
      {:ok, cyberdyne} = Tenancy.create_org(admin, %{name: "Cyberdyne", slug: "cyberdyne"})
      {:ok, cyberdyne: cyberdyne}
    end

    test "defined_here accents with the cyberdyne token", ctx do
      assigns = %{
        org: ctx.cyberdyne,
        scope: :cyberdyne,
        record_key: :my_skill,
        default: nil,
        fabrikam_admin?: false,
        lookup_fn: build_lookup(%{{ctx.cyberdyne.id, :my_skill} => "cyberdyne-local"})
      }

      html = render_pill(assigns)

      assert html =~ "text-cyberdyne"
      assert html =~ "Defined here"
    end

    test "overridden accents with the cyberdyne token", ctx do
      assigns = %{
        org: ctx.cyberdyne,
        scope: :cyberdyne,
        record_key: :my_skill,
        default: nil,
        fabrikam_admin?: false,
        lookup_fn:
          build_lookup(%{
            {ctx.cyberdyne.id, :my_skill} => "cyberdyne-local",
            {ctx.fabrikam.id, :my_skill} => "fabrikam-default"
          })
      }

      html = render_pill(assigns)

      assert html =~ "text-cyberdyne"
    end

    test "the cyberdyne accent is the token Tenancy publishes, not a literal", ctx do
      # Guards against the accent and the scope registry drifting apart:
      # `accent_class/2` delegates to `Tenancy.scope_color/1`.
      assert Tenancy.scope_color(:cyberdyne) == "text-cyberdyne"

      html =
        render_pill(%{
          org: ctx.cyberdyne,
          scope: :cyberdyne,
          record_key: :my_skill,
          default: nil,
          fabrikam_admin?: false,
          lookup_fn: build_lookup(%{{ctx.cyberdyne.id, :my_skill} => "v"})
        })

      assert html =~ Tenancy.scope_color(:cyberdyne)
    end

    test "inherited resolves cyberdyne's parent to the fabrikam accent, not cyberdyne's", ctx do
      # A tenant inherits from the root, so the SOURCE org here is Fabrikam.
      # `:inherited` renders no accent at all (`accent_class(:inherited, _)`
      # is nil) — asserted so a future accent-on-inherited change has to
      # come past this test.
      html =
        render_pill(%{
          org: ctx.cyberdyne,
          scope: :cyberdyne,
          record_key: :my_skill,
          default: nil,
          fabrikam_admin?: false,
          lookup_fn: build_lookup(%{{ctx.fabrikam.id, :my_skill} => "fabrikam-default"})
        })

      assert html =~ "Inherited from Fabrikam"
      refute html =~ "text-cyberdyne"
    end

    test "creating cyberdyne at runtime leaves the seeded five untouched", ctx do
      # The sibling suites assert the exact five-org seeded set; this pins
      # that a runtime create does not join it.
      slugs = Tenancy.list_orgs() |> Enum.map(& &1.slug) |> Enum.sort()
      assert slugs == ~w(paragon soylent fabrikam wayne_tech sxi cyberdyne)
      assert ctx.cyberdyne.parent_org_id == ctx.fabrikam.id
      assert Tenancy.tier(ctx.cyberdyne) == :tenant
    end
  end

  # Fabrikam-admin actor — `Tenancy.create_org/2` refuses anyone else.
  defp create_fabrikam_admin! do
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
      org_id: Tenancy.get_org_by_slug!("fabrikam").id,
      role: "admin"
    })
    |> Platform.Repo.insert!()

    user
  end
end
