defmodule PlatformWeb.ChatLiveNavTargetTest do
  @moduledoc """
  Coverage for `PlatformWeb.ChatLive.space_nav_target/1` and the sidebar
  link-emission behavior it drives (task `019edd8e-8a61-7c0a-8cc0-ba5725123347`
  Stage 1, v2 fix).

  Why this matters:
    * v1 (PR #441) made Chat.get_space_by_slug/2 org-aware, but every
      sidebar link still emitted the slug for org-scoped channels. The
      URL handler then resolved the active org from the user's primary
      membership (Fabrikam for multi-org users), so clicking the Soylent-
      section General sidebar entry still routed to Fabrikam's General.
    * v2 closes the gap: for any space with a non-nil :org_id, the
      sidebar emits /chat/<space_id> (UUID-form). The URL handler's
      existing valid_uuid? && Chat.get_space/1 fallback then resolves
      it deterministically without org disambiguation.

  These tests assert:
    1. `space_nav_target/1` returns id for org-scoped, slug for org-less
       (with id fallback when slug is nil).
    2. Sidebar render with two same-slug org-scoped Generals emits two
       distinct UUID hrefs, NOT `/chat/general`.
    3. Direct UUID navigation lands on the right tenant General without
       any session active-org plumbing.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.ChatLive

  describe "space_nav_target/1 (unit)" do
    test "org-scoped space returns the space id" do
      space = %{org_id: "org-uuid", id: "space-uuid", slug: "general"}
      assert ChatLive.space_nav_target(space) == "space-uuid"
    end

    test "org-less space with slug returns the slug" do
      space = %{org_id: nil, id: "space-uuid", slug: "announcements"}
      assert ChatLive.space_nav_target(space) == "announcements"
    end

    test "org-less space without a slug falls back to the id" do
      # DM-shape: org_id nil and no slug column populated.
      space = %{org_id: nil, id: "space-uuid", slug: nil}
      assert ChatLive.space_nav_target(space) == "space-uuid"
    end

    test "missing org_id key (older fixtures) falls back to slug or id" do
      # The map-pattern signature must not crash on plain maps that
      # don't carry `:org_id`. `Map.get(:org_id)` is nil → org-less
      # branch is taken.
      assert ChatLive.space_nav_target(%{id: "x", slug: "y"}) == "y"
      assert ChatLive.space_nav_target(%{id: "x", slug: nil}) == "x"
    end
  end

  describe "sidebar link emission for org-scoped channels" do
    setup %{conn: conn} do
      # Three tenant Generals — the canonical reproduction triple.
      fabrikam_general = ensure_general_for_org("fabrikam")
      soylent_general = ensure_general_for_org("soylent")
      sxi_general = ensure_general_for_org("sxi")

      # User is a member of all three orgs (multi-org admin shape).
      user = create_user!("multi-org-nav")
      membership!(user, Tenancy.get_org_by_slug!("fabrikam"))
      membership!(user, Tenancy.get_org_by_slug!("soylent"))
      membership!(user, Tenancy.get_org_by_slug!("sxi"))

      conn = init_test_session(conn, current_user_id: user.id)

      %{
        conn: conn,
        user: user,
        fabrikam_general: fabrikam_general,
        soylent_general: soylent_general,
        sxi_general: sxi_general
      }
    end

    test "each tenant's General is linked by its UUID, not the colliding slug", %{
      conn: conn,
      fabrikam_general: k,
      soylent_general: g,
      sxi_general: s
    } do
      # Land on the bare /chat — landing redirect should pick the first
      # channel; mount the sidebar render either way.
      {:ok, _view, html} = live(conn, ~p"/chat/#{k.id}")

      # Each tenant General must be linked by its UUID. The pre-v2 bug
      # would emit `/chat/general` for all three (colliding) — that link
      # MUST NOT appear for any org-scoped channel.
      assert html =~ "/chat/#{k.id}"
      assert html =~ "/chat/#{g.id}"
      assert html =~ "/chat/#{s.id}"

      # The bare slug-form must not be linked for any of the three
      # org-scoped Generals. (We allow it elsewhere — e.g. if a legacy
      # org-less channel still uses it — but never for these rows.)
      refute html =~ ~s|href="/chat/general"|
    end

    test "direct UUID navigation mounts the clicked tenant's General", %{
      conn: conn,
      fabrikam_general: k,
      soylent_general: g,
      sxi_general: s
    } do
      {:ok, _view, html_g} = live(conn, ~p"/chat/#{g.id}")

      # Composer's `data-draft-key="chat-draft:<space.id>"` is the most
      # precise observable signal of which space actually mounted.
      assert html_g =~ "data-draft-key=\"chat-draft:#{g.id}\""
      refute html_g =~ "data-draft-key=\"chat-draft:#{k.id}\""

      {:ok, _view, html_s} = live(conn, ~p"/chat/#{s.id}")
      assert html_s =~ "data-draft-key=\"chat-draft:#{s.id}\""
      refute html_s =~ "data-draft-key=\"chat-draft:#{k.id}\""
    end
  end

  # ---- helpers ----

  defp create_user!(suffix) do
    Repo.insert!(%User{
      email: "nav_target_#{suffix}@example.com",
      name: "Nav Target #{suffix}",
      oidc_sub: "oidc-nav-target-#{suffix}"
    })
  end

  defp membership!(user, org) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "member"})
    |> Repo.insert!()
  end

  defp ensure_general_for_org(org_slug) do
    org = Tenancy.get_org_by_slug!(org_slug)

    case Chat.list_spaces(kind: "channel")
         |> Enum.find(&(&1.org_id == org.id and &1.slug == "general")) do
      %Chat.Space{} = space ->
        space

      nil ->
        {:ok, space} =
          Chat.create_space(%{
            name: "General",
            slug: "general",
            kind: "channel",
            org_id: org.id
          })

        space
    end
  end
end
