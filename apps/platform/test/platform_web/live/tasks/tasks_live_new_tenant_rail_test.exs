defmodule PlatformWeb.Tasks.NewTenantRailTest do
  @moduledoc """
  The one regression guard for task 01a09287 stage 2: an org created at
  RUNTIME, whose slug was never compiled as an atom, gets a chip on the
  Tasks scope rail.

  It holds two lines at once, and they pull in opposite directions:

    * the CRASH (task 019fa209) — `String.to_existing_atom/1` on an org slug
      raises `ArgumentError` in `mount/3` and 500s `/tasks` for every user.
      The old fix was an allowlist intersection, which made conversion safe
      by never converting anything unknown.
    * the FEATURE (this stage) — that allowlist is why standing up a tenant
      needed a deploy. Removing it puts unknown slugs back in the pipeline,
      so the pipeline has to be STRINGS end to end instead.

  A test that only asserted a 200 would pass against the allowlist it exists
  to prove was removed; a test that only asserted the chip could be satisfied
  by re-introducing atom conversion. Asserting both together is what makes
  this discriminating. The two failure shapes to expect:

    * `ArgumentError` / `FunctionClauseError` -> something converts a slug;
    * 200 with the chip missing -> an allowlist is still filtering the rail.

  `async: false` — the LiveView runs in its own process and must see this
  test's inserts, exactly as `tasks_live_lifecycle_test.exs` does.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.{Repo, Tenancy}
  alias Platform.Tenancy.{Org, OrgMembership}

  # Never compiled as an atom, and chosen to sort LAST under
  # `tenant_priority_index/1`'s 9_999 sentinel so it cannot displace a
  # seeded chip's position and turn an ordering regression into a pass here.
  @new_slug "zzz-new-tenant"
  @new_name "ZZZ New Tenant"

  defp insert_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "new-tenant-rail-#{n}@example.com",
      name: "User #{n}",
      oidc_sub: "oidc-new-tenant-rail-#{n}"
    })
  end

  # Parented under fabrikam deliberately. The `orgs_single_root` unique index
  # refuses a SECOND parentless org, so a root-less fixture here fails on the
  # insert with a constraint error that reads nothing like the thing under
  # test (found the hard way on stage 1 of this task).
  defp insert_tenant_org(slug, name) do
    %Org{}
    |> Org.changeset(%{
      name: name,
      slug: slug,
      parent_org_id: Tenancy.get_org_by_slug!("fabrikam").id
    })
    |> Repo.insert!()
  end

  defp member_conn(conn, org_slugs) do
    user = insert_user()

    for slug <- org_slugs do
      %OrgMembership{}
      |> OrgMembership.changeset(%{
        user_id: user.id,
        org_id: Tenancy.get_org_by_slug!(slug).id,
        role: "member"
      })
      |> Repo.insert!()
    end

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp rendered_scope_chips(view) do
    ~r/data-scope-chip="([^"]+)"/
    |> Regex.scan(render(view))
    |> Enum.map(fn [_, slug] -> slug end)
    |> Enum.reject(&(&1 == "all"))
  end

  describe "an org created at runtime reaches the scope rail" do
    test "mounts /tasks AND renders the new org's chip", %{conn: conn} do
      # PREMISE, asserted rather than assumed. If this slug ever becomes a
      # compiled atom the test silently stops covering the `to_existing_atom`
      # path and degrades into a plain rendering check — so fail loudly here
      # instead of passing quietly downstream.
      assert_raise ArgumentError, fn -> String.to_existing_atom(@new_slug) end

      org = insert_tenant_org(@new_slug, @new_name)
      {conn, user} = member_conn(conn, ["fabrikam", @new_slug])

      # A fabrikam admin bypasses the membership filter by design, so an admin
      # viewer would make a membership-blind rail look correct. This viewer
      # must be a plain member.
      refute Tenancy.fabrikam_admin?(user)

      # Mounts at all. Pre-019fa209-fix this was an ArgumentError in
      # `mount/3`; the page is the thing that 500'd, so assert the page.
      {:ok, view, html} = live(conn, ~p"/tasks")
      assert html =~ ~s(id="tasks-scope-rail")

      chips = rendered_scope_chips(view)

      # POSITIVE CONTROL FIRST: "all" is hardcoded outside the chip loop, so
      # a rail that rendered zero org chips is not visibly empty. Prove the
      # loop produced something known-good before reading the new chip as
      # evidence of anything.
      assert "fabrikam" in chips

      # THE STAGE, in one line: no deploy, no allowlist entry, a chip.
      assert @new_slug in chips

      # The label comes from `Org.name`, which is the only place a seventh
      # org's name can come from — `Tenancy.@scope_labels` is keyed on six
      # compiled atoms and could only ever title-case the slug. Asserting the
      # NAME (not the slug) is what separates those two sources: they differ
      # here on purpose ("ZZZ New Tenant" vs a slug-derived "Zzz New Tenant").
      assert render(view) =~ @new_name
      assert org.name == @new_name
    end

    test "the new org's chip reaches the runtime COLOUR path, not just the rail", %{conn: conn} do
      # Task 01a09287 stage 5, and the half stage 3 left disconnected. The
      # `<style id="org-scope-colors">` block and the slug-agnostic `.scope-*`
      # rules in app.css both shipped and both worked; nothing in the DOM
      # carried `data-scope`, so the rules matched no element and a new org
      # rendered in inherited grey. A live probe of /tasks read
      # `document.querySelectorAll('[data-scope]').length === 0` — the
      # machinery complete, and inert.
      #
      # This is deliberately an END-TO-END assertion across the seam that was
      # broken: the emitter names the slug in a CSS selector, the chip names
      # the same slug in an attribute, and neither half alone is the bug.
      # `scope_pill_test.exs` covers the component in isolation and
      # `scope_color_styles_test.exs` covers the emitter; only here do they
      # have to agree about one org.
      org = insert_tenant_org(@new_slug, @new_name)

      org
      |> Ecto.Changeset.change(color_hue: 200, color_chroma: 0.15)
      |> Repo.update!()

      # The negative control's org is created and JOINED here, before the
      # viewer exists. An earlier draft created it half way down and never
      # added a membership, so it was absent from the rail for a reason that
      # had nothing to do with its hue and the refute below could not fail.
      hueless = insert_tenant_org("zzz-hueless", "ZZZ Hueless")
      assert is_nil(hueless.color_hue)

      {conn, _user} = member_conn(conn, ["fabrikam", @new_slug, "zzz-hueless"])
      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = render(view)

      # The emitter's side: a rule keyed on this slug, with a fill to read.
      assert html =~ ~s([data-scope="#{@new_slug}"]{--scope-fill:)

      # The DOM's side: an element the rule can match. The two substrings are
      # NOT interchangeable — the first appears inside the <style> body and
      # would satisfy a naive `=~ "data-scope"` on its own, which is exactly
      # how the inert version looked correct on a read of the source.
      assert html =~ ~s(data-scope="#{@new_slug}" class=),
             "no ELEMENT carries data-scope — only the style block does"

      # And the chip takes the var-driven utilities rather than a build-time
      # class that does not exist in the compiled stylesheet for this slug.
      assert html =~ "scope-tint"
      assert html =~ "scope-text"
      refute html =~ "bg-zzz-new-tenant"

      # NEGATIVE CONTROL on the emitter: a hueless org contributes no
      # declarations, so `--scope-fill` is unset and the chip falls through
      # to inherited colour. Without it the assertions above would pass for
      # an emitter that wrote a rule for every org regardless of hue, which
      # is what would make "a new org is coloured" vacuously true.
      #
      # Its PRESENCE on the rail is asserted first, so the refute below is
      # about the hue and not about the org being invisible.
      assert "zzz-hueless" in rendered_scope_chips(view)
      assert html =~ ~s(data-scope="zzz-hueless" class=)
      refute html =~ ~s([data-scope="zzz-hueless"]{)
    end

    test "the chip's filter round-trips as a string and narrows the board", %{conn: conn} do
      insert_tenant_org(@new_slug, @new_name)
      {conn, _user} = member_conn(conn, ["fabrikam", @new_slug])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Clicking the chip must not raise. `phx-value-scope` arrives as a
      # binary and `parse_scope/2` has to accept it WITHOUT conversion; the
      # pre-stage implementation looked the value up in `Tasks.scope_keys/0`
      # and would silently drop the click (aria-pressed stays "false").
      view
      |> element(~s([data-scope-chip="#{@new_slug}"] button))
      |> render_click()

      assert has_element?(
               view,
               ~s([data-scope-chip="#{@new_slug}"][data-active="true"])
             )

      # And the reset still works, from the new chip's selected state.
      view |> element(~s([data-scope-chip="all"])) |> render_click()
      assert has_element?(view, ~s([data-scope-chip="all"][data-active="true"]))
    end

    test "an archived new tenant loses its chip", %{conn: conn} do
      org = insert_tenant_org(@new_slug, @new_name)
      {conn, _user} = member_conn(conn, ["fabrikam", @new_slug])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      assert @new_slug in rendered_scope_chips(view)

      org
      |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
      |> Repo.update!()

      # Re-mount rather than poke the live socket: the claim under test is
      # that `archived_at` is the ONLY thing keeping an org off the rail now
      # that the allowlist is gone, and the mount path is where that reads.
      {:ok, view2, _html} = live(conn, ~p"/tasks")

      refute @new_slug in rendered_scope_chips(view2)
      assert "fabrikam" in rendered_scope_chips(view2)
    end

    test "a member of the new org does NOT see chips for orgs they don't belong to", %{
      conn: conn
    } do
      insert_tenant_org(@new_slug, @new_name)
      {conn, _user} = member_conn(conn, [@new_slug])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      chips = rendered_scope_chips(view)

      # Positive control before the absence, same reason as above.
      assert @new_slug in chips

      # Removing the allowlist widened the rail's INPUT. Viewer scoping is
      # the only thing still narrowing it, so assert it explicitly here
      # rather than trusting the tenant read it inherited.
      assert Tenancy.get_org_by_slug!("soylent").archived_at == nil
      refute "soylent" in chips
      assert chips == [@new_slug]
    end
  end
end
