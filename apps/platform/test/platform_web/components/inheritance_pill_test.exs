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
end
