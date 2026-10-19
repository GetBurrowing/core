defmodule PlatformWeb.ChatLiveSectionReorderTest do
  @moduledoc """
  Drag-reorder + per-user persistence tests for the sectioned channel rail
  (chat plan v2 Stage 3).

  Coverage:
    * Default order = alphabetical when no preference saved
    * Saved preference rehydrates on mount (persisted as section IDS)
    * `section_reordered` event persists section IDS to
      `users.preferences["chat_section_order"]`
    * Pinned + DMs are NOT reorderable — drag handle absent on those
      sections (drag handle class no longer rendered on them)
    * Partial saved orders are honored skip-unknown/append-by-position;
      a bogus (non-id) order falls back to the position default
    * A personally-reordered user keeps their slot after an admin RENAME
      (id-keyed order is rename-proof — audit finding #3)
    * Pure-function `compute_reorder/3` semantics

  Stage 3 stores `chat_section_order` as a list of section IDS (not names): IDs
  are stable across admin rename/recolor, so a personal arrangement survives
  both. Pure-function `compute_reorder/3` is also exercised here rather than in
  the grouping test file because reorder is the operation under test.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Sidebar
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.ChatLive

  # ── Test-data helpers ──────────────────────────────────────────────────

  defp insert_user(suffix) do
    Repo.insert!(%User{
      email: "reorder_#{suffix}@example.com",
      name: "Reorder Test #{suffix}",
      oidc_sub: "oidc-reorder-#{suffix}",
      avatar_url: nil
    })
  end

  # An Acme (root-org) admin actor — `Sidebar.*` writes gate on
  # `Tenancy.root_admin?/1`, which checks for an admin membership in the
  # parentless root org.
  defp make_acme_admin(suffix) do
    user = insert_user(suffix)

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("acme").id,
      role: "admin"
    })
    |> Repo.insert!()

    user
  end

  defp authenticated_conn(conn, user) do
    init_test_session(conn, current_user_id: user.id)
  end

  defp create_channel(slug) do
    {:ok, ch} =
      Chat.create_space(%{
        name: String.capitalize(slug),
        slug: slug,
        kind: "channel"
      })

    ch
  end

  # Same `live_following_redirect` pattern as chat_live_section_render_test.
  defp live_following_redirect(conn) do
    case live(conn, ~p"/chat") do
      {:error, {:live_redirect, %{to: path}}} -> live(conn, path)
      ok -> ok
    end
  end

  defp desktop_sidebar(html) do
    case Regex.run(~r/<aside[^>]*id="chat-sidebar".*?<\/aside>/s, html) do
      [match] -> match
      _ -> ""
    end
  end

  # The `section_reordered` event is now keyed by section `id` (not the `color`
  # slug) — color became an admin-editable, non-unique attribute in Stage 6, so
  # drag identity can't safely derive from it. These helpers resolve the seeded
  # section id from its color slug / name so the test drives the same id the
  # SectionReorder hook now sends from `data-section-id`.
  defp section_id_for_slug(slug) do
    case Enum.find(Sidebar.list_default_sections(), &(&1.color == slug)) do
      %{id: id} -> id
      _ -> nil
    end
  end

  # ── Default order ──────────────────────────────────────────────────────

  describe "default section order" do
    test "alphabetical when no preference is saved", %{conn: conn} do
      user = insert_user("default")
      conn = authenticated_conn(conn, user)
      create_channel("general")
      {:ok, _view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      offsets =
        for label <- ["Acme", "Globex", "Hooli", "Initech", "Vandelay-Ind"] do
          {label, :binary.match(sidebar, label) |> elem(0)}
        end

      indices = Enum.map(offsets, fn {_, off} -> off end)

      assert indices == Enum.sort(indices),
             "Default order should be alphabetical, got #{inspect(offsets)}"
    end
  end

  # ── Mount-time hydration ───────────────────────────────────────────────

  describe "saved preference hydration" do
    # Stage 3 persists `chat_section_order` as a list of section IDS (audit
    # finding #3 — IDs are stable across admin rename/recolor; names are not).
    # So these tests seed/expect ids, mapping slug→id via `section_id_for_slug`.
    test "non-default order rehydrates on mount", %{conn: conn} do
      user = insert_user("hydrate")
      # Globex first → Hooli last (intentionally non-alphabetical), by id.
      saved_slugs = ["globex", "acme", "initech", "vandelay-ind", "hooli"]
      saved_order = Enum.map(saved_slugs, &section_id_for_slug/1)
      {:ok, _} = Accounts.update_user_preference(user.id, :chat_section_order, saved_order)

      conn = authenticated_conn(conn, user)
      create_channel("general")
      {:ok, _view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      # The rendered NAME labels should appear in the saved id order.
      labels = ["Globex", "Acme", "Initech", "Vandelay-Ind", "Hooli"]

      offsets =
        for label <- labels do
          {label, :binary.match(sidebar, label) |> elem(0)}
        end

      indices = Enum.map(offsets, fn {_, off} -> off end)

      assert indices == Enum.sort(indices),
             "Saved id order should drive render order; got #{inspect(offsets)}"
    end

    test "a partial saved order places its sections first, appends the rest by position",
         %{conn: conn} do
      user = insert_user("partial")
      # A partial (not full) order is HONORED skip-unknown/append-unplaced by the
      # id-keyed resolver (`Sidebar.order_sections/2`): the named sections come
      # first in saved order, the rest follow in `Section.position` order.
      partial = ["globex", "hooli"] |> Enum.map(&section_id_for_slug/1)
      {:ok, _} = Accounts.update_user_preference(user.id, :chat_section_order, partial)

      conn = authenticated_conn(conn, user)
      create_channel("general")
      {:ok, _view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      globex_idx = :binary.match(sidebar, "Globex") |> elem(0)
      hooli_idx = :binary.match(sidebar, "Hooli") |> elem(0)
      initech_idx = :binary.match(sidebar, "Initech") |> elem(0)

      # Globex then Hooli lead (the saved order); the remaining sections follow.
      assert globex_idx < hooli_idx, "Globex should lead per the saved partial order"

      assert hooli_idx < initech_idx,
             "Saved sections precede the position-appended remainder"
    end

    test "bogus (non-id) saved order falls back to position default", %{conn: conn} do
      user = insert_user("bogus_order")
      # Genuinely poisoned pref — none of these are real section ids, so the
      # id-keyed resolver skips them all and falls back to position order.
      {:ok, _} =
        Accounts.update_user_preference(
          user.id,
          :chat_section_order,
          ["nope-1", "nope-2", "nope-3"]
        )

      conn = authenticated_conn(conn, user)
      create_channel("general")
      {:ok, _view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      offsets =
        for label <- ["Acme", "Globex", "Hooli", "Initech", "Vandelay-Ind"] do
          {label, :binary.match(sidebar, label) |> elem(0)}
        end

      indices = Enum.map(offsets, fn {_, off} -> off end)

      assert indices == Enum.sort(indices),
             "A non-id saved order should fall back to the seeded position order, got #{inspect(offsets)}"
    end
  end

  # ── section_reordered event ────────────────────────────────────────────

  describe "section_reordered event" do
    test "reorder updates assigns AND persists to user preferences", %{conn: conn} do
      user = insert_user("event")
      conn = authenticated_conn(conn, user)
      create_channel("general")
      {:ok, view, _html} = live_following_redirect(conn)

      # Move Initech to Globex's slot (drop-above semantics — Initech lands
      # where Globex was, Globex shifts down one). Keyed by section id (Stage 6).
      render_hook(view, "section_reordered", %{
        "from" => section_id_for_slug("initech"),
        "to" => section_id_for_slug("globex")
      })

      # In-memory: rendered HTML reflects new order. Initech should now
      # appear AFTER Acme (its new slot is at Globex's original index) but
      # BEFORE Globex (which shifted down to fill what was after it).
      html = render(view)
      sidebar = desktop_sidebar(html)

      acme_idx = :binary.match(sidebar, "Acme") |> elem(0)
      globex_idx = :binary.match(sidebar, "Globex") |> elem(0)
      initech_idx = :binary.match(sidebar, "Initech") |> elem(0)

      # New order: Acme, Initech, Globex, Hooli, Vandelay-Ind
      assert acme_idx < initech_idx,
             "Expected Initech after Acme, got Initech at #{initech_idx} and Acme at #{acme_idx}"

      assert initech_idx < globex_idx,
             "Expected Globex after Initech (drop-above semantics), got Initech at #{initech_idx} and Globex at #{globex_idx}"

      # Persisted: re-fetch user and assert preferences blob updated. The order
      # is stored as section IDS (audit finding #3), so assert against the id
      # sequence for the expected new order: Acme, Initech, Globex, Hooli,
      # Vandelay-Ind.
      updated_user = Repo.get!(User, user.id)
      saved = updated_user.preferences["chat_section_order"]

      expected_ids =
        ["acme", "initech", "globex", "hooli", "vandelay-ind"]
        |> Enum.map(&section_id_for_slug/1)

      assert saved == expected_ids
    end

    test "drop on self is a no-op", %{conn: conn} do
      user = insert_user("noop")
      conn = authenticated_conn(conn, user)
      create_channel("general")
      {:ok, view, _html} = live_following_redirect(conn)

      acme_id = section_id_for_slug("acme")
      render_hook(view, "section_reordered", %{"from" => acme_id, "to" => acme_id})

      # No persisted change.
      updated_user = Repo.get!(User, user.id)
      # `update_user_preference/3` was never called → preferences stays at
      # default %{}.
      assert updated_user.preferences == %{} or
               Map.get(updated_user.preferences, "chat_section_order") == nil
    end

    test "unknown section id is ignored", %{conn: conn} do
      user = insert_user("bogus")
      conn = authenticated_conn(conn, user)
      create_channel("general")
      {:ok, view, _html} = live_following_redirect(conn)

      # A bogus `from` id resolves to no section → the reorder is a no-op.
      render_hook(view, "section_reordered", %{
        "from" => "not-a-real-section-id",
        "to" => section_id_for_slug("acme")
      })

      updated_user = Repo.get!(User, user.id)

      assert updated_user.preferences == %{} or
               Map.get(updated_user.preferences, "chat_section_order") == nil
    end
  end

  # ── Pinned + DMs NOT reorderable ───────────────────────────────────────

  describe "Pinned + DMs are not reorderable" do
    test "DMs section has data-section-reorderable=false and no drag handle", %{conn: conn} do
      user = insert_user("dms")
      conn = authenticated_conn(conn, user)
      create_channel("general")
      {:ok, _view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      # Pull just the DMs section out so we don't accidentally hit a
      # sub-org's drag handle in the assertion.
      [dms_section] =
        Regex.run(
          ~r/<section[^>]*data-section-key="dms".*?<\/section>/s,
          sidebar
        ) || [""]

      assert dms_section =~ ~s(data-section-reorderable="false")

      refute dms_section =~ "channel-section-drag-handle",
             "DMs section should NOT render a drag handle (locked to top)"
    end

    test "sub-org sections have data-section-reorderable=true and a drag handle", %{conn: conn} do
      user = insert_user("suborg")
      conn = authenticated_conn(conn, user)
      create_channel("general")
      {:ok, _view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      [hooli_section] =
        Regex.run(
          ~r/<section[^>]*data-section-key="Hooli".*?<\/section>/s,
          sidebar
        ) || [""]

      assert hooli_section =~ ~s(data-section-reorderable="true")
      assert hooli_section =~ ~s(data-section-slug="hooli")
      assert hooli_section =~ "channel-section-drag-handle"
    end

    test "Vandelay-Ind uses lowercased slug 'vandelay-ind'", %{conn: conn} do
      user = insert_user("vandelay-ind")
      conn = authenticated_conn(conn, user)
      create_channel("general")
      {:ok, _view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      assert sidebar =~ ~s(data-section-slug="vandelay-ind")
    end

    test "Pinned + DMs not affected by sub-org reorder", %{conn: conn} do
      user = insert_user("rail_order")
      conn = authenticated_conn(conn, user)
      create_channel("general")
      {:ok, view, _html} = live_following_redirect(conn)

      render_hook(view, "section_reordered", %{
        "from" => section_id_for_slug("hooli"),
        "to" => section_id_for_slug("globex")
      })

      html = render(view)
      sidebar = desktop_sidebar(html)

      # DMs header still renders before all sub-orgs.
      dms_idx = :binary.match(sidebar, "Direct Messages") |> elem(0)
      globex_idx = :binary.match(sidebar, "Globex") |> elem(0)
      hooli_idx = :binary.match(sidebar, "Hooli") |> elem(0)

      assert dms_idx < globex_idx
      assert dms_idx < hooli_idx
    end
  end

  # ── Personal order survives an admin rename (audit finding #3) ──────────
  #
  # Regression: personal `chat_section_order` used to be keyed by section NAME,
  # validated against a hardcoded name permutation. When an admin renamed a
  # section, a personally-reordered user's saved order still held the OLD name,
  # so the renamed section matched nothing and was dumped to the rail's TAIL —
  # the user's layout silently broke with no action on their part. ID-keying
  # makes the saved order rename-proof.

  describe "personal order survives an admin rename" do
    test "a renamed section keeps its personal slot, not dumped to the tail",
         %{conn: conn} do
      user = insert_user("rename_survive")
      create_channel("general")

      # The user personally puts Acme SECOND, after Globex (non-default;
      # default is alphabetical, so Acme would normally sit first).
      personal_order =
        ["globex", "acme", "hooli", "initech", "vandelay-ind"]
        |> Enum.map(&section_id_for_slug/1)

      {:ok, _} = Accounts.update_user_preference(user.id, :chat_section_order, personal_order)

      # Sanity: before the rename, Acme renders second, between Globex and
      # Hooli.
      conn1 = authenticated_conn(conn, user)
      {:ok, _v1, html1} = live_following_redirect(conn1)
      sidebar1 = desktop_sidebar(html1)
      acme_idx1 = :binary.match(sidebar1, "Acme") |> elem(0)
      hooli_idx1 = :binary.match(sidebar1, "Hooli") |> elem(0)
      globex_idx1 = :binary.match(sidebar1, "Globex") |> elem(0)

      assert globex_idx1 < acme_idx1 and acme_idx1 < hooli_idx1,
             "Acme should render second from the personal order"

      # An admin renames the Acme section (id unchanged). Use the Sidebar API
      # directly with an Acme admin actor so the rename actually lands.
      acme_section_id = section_id_for_slug("acme")
      admin = make_acme_admin("rename_survive_admin")
      {:ok, _} = Sidebar.rename_section(admin, acme_section_id, "Acme HQ")

      # The user re-mounts. The renamed section must STILL render second (its
      # id is unchanged in the saved order): not dumped to the bottom, and not
      # back in its alphabetical default slot (first).
      conn2 = authenticated_conn(build_conn(), user)
      {:ok, _v2, html2} = live_following_redirect(conn2)
      sidebar2 = desktop_sidebar(html2)

      acme_hq_idx = :binary.match(sidebar2, "Acme HQ") |> elem(0)
      hooli_idx2 = :binary.match(sidebar2, "Hooli") |> elem(0)
      globex_idx2 = :binary.match(sidebar2, "Globex") |> elem(0)

      assert acme_hq_idx < hooli_idx2,
             "Renamed section must keep its personal slot (second), not fall to the tail"

      assert globex_idx2 < acme_hq_idx,
             "Renamed section must not fall back to its alphabetical default slot (first)"
    end
  end

  # ── Pure-function compute_reorder/3 ────────────────────────────────────

  describe "compute_reorder/3" do
    test "moves item to target's slot (drop-above semantics, target shifts down)" do
      order = ["A", "B", "C", "D", "E"]
      # Move B to D's slot → after removing B: A, C, D, E; insert B at D's
      # index (2) → A, C, B, D, E. Standard "drop above target" reorder.
      assert ChatLive.compute_reorder(order, "B", "D") == ["A", "C", "B", "D", "E"]
    end

    test "moves later item earlier" do
      order = ["A", "B", "C", "D", "E"]
      # Move D to B's slot → after removing D: A, B, C, E; insert D at B's
      # index (1) → A, D, B, C, E.
      assert ChatLive.compute_reorder(order, "D", "B") == ["A", "D", "B", "C", "E"]
    end

    test "drop on self is a no-op" do
      order = ["A", "B", "C"]
      assert ChatLive.compute_reorder(order, "B", "B") == order
    end

    test "unknown slug returns input unchanged" do
      order = ["A", "B", "C"]
      assert ChatLive.compute_reorder(order, "Z", "B") == order
      assert ChatLive.compute_reorder(order, "A", "Z") == order
    end
  end

  # ── Fail-soft when user row vanishes between mount and event ──────────
  #
  # If the user_id pinned in the LiveView assigns no longer maps to a row
  # (account deletion mid-session, embedded surface with a synthetic UUID),
  # `update_user_preference/3` returns `{:error, :not_found}` and the
  # event handler still flips `:section_order` in-memory so the UI stays
  # responsive. Persistence is best-effort by design.

  describe "fail-soft on missing user row" do
    test "reorder still updates in-memory order when user has been deleted", %{conn: conn} do
      user = insert_user("vanishing")
      conn = authenticated_conn(conn, user)
      create_channel("general")
      {:ok, view, _html} = live_following_redirect(conn)

      # Capture section ids while the seeded sections are present (they are
      # not deleted with the user — only the user row goes away).
      initech_id = section_id_for_slug("initech")
      globex_id = section_id_for_slug("globex")

      # Delete the user row out from under the LV. The session still
      # carries the now-stale user_id.
      Repo.delete!(user)

      render_hook(view, "section_reordered", %{"from" => initech_id, "to" => globex_id})

      html = render(view)
      sidebar = desktop_sidebar(html)

      # In-memory order still applied: Acme, Initech, Globex, Hooli, Vandelay-Ind.
      acme_idx = :binary.match(sidebar, "Acme") |> elem(0)
      initech_idx = :binary.match(sidebar, "Initech") |> elem(0)
      globex_idx = :binary.match(sidebar, "Globex") |> elem(0)

      assert acme_idx < initech_idx
      assert initech_idx < globex_idx
    end
  end

  # ── Accounts.update_user_preference/3 helper ──────────────────────────

  describe "Accounts.update_user_preference/3" do
    test "upserts a single key into the preferences map" do
      user = insert_user("acct1")

      {:ok, updated} =
        Accounts.update_user_preference(user.id, :chat_section_order, ["Globex", "Acme"])

      assert updated.preferences == %{"chat_section_order" => ["Globex", "Acme"]}

      # Idempotent — overwriting the same key works.
      {:ok, updated2} =
        Accounts.update_user_preference(user.id, :chat_section_order, ["Acme", "Globex"])

      assert updated2.preferences == %{"chat_section_order" => ["Acme", "Globex"]}
    end

    test "merges into existing preferences without clobbering siblings" do
      user = insert_user("acct2")

      {:ok, _} = Accounts.update_user_preference(user.id, "theme", "dark")
      {:ok, updated} = Accounts.update_user_preference(user.id, :chat_section_order, ["Globex"])

      assert updated.preferences == %{
               "theme" => "dark",
               "chat_section_order" => ["Globex"]
             }
    end

    test "returns {:error, :not_found} for unknown user" do
      assert {:error, :not_found} =
               Accounts.update_user_preference(
                 Ecto.UUID.generate(),
                 :chat_section_order,
                 ["Hooli"]
               )
    end

    test "get_user_preferences/1 returns %{} for unknown user" do
      assert Accounts.get_user_preferences(Ecto.UUID.generate()) == %{}
      assert Accounts.get_user_preferences(nil) == %{}
    end
  end
end
