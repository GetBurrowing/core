defmodule PlatformWeb.MaskNamesChipTest do
  @moduledoc """
  Task 01a1600d stage 2: the shell's "Names masked" chip
  (`PlatformWeb.Components.MaskNamesChip`), its desktop popover and its phone
  confirm sheet.

  The chip's one rule is that it agrees with the page: present exactly while
  the page renders masked names. Every absence of the chip is paired with a
  render of the same page where it IS present, and every refute of a real
  name has an unmasked control that asserts the name is there.

  Burrow redesign 22 stage 2 deleted the desktop channel rail (its eye toggle
  and mode strip). On /chat the toggle is the Chat list's Options popover
  switch, the page's own masked signal is the list's counts line ("names
  masked"), and the org names reach the document through one channel NAMED
  after each org in @chat_orgs.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.MaskAssertions

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.{Repo, Tasks, Tenancy}
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.MaskNamesLabel

  @chip "#mask-names-chip"
  @chat_orgs ["Vandelay-Ind", "Globex", "Initech"]
  @tenants ~w(initech vandelay_ind globex)
  @machine_attrs ~w(value)
  @zone "America/Chicago"

  defp insert_user(tag, member? \\ false) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "mask-chip-#{tag}-#{n}@example.com",
        name: "Mask Chip #{tag} #{n}",
        oidc_sub: "oidc-mask-chip-#{tag}-#{n}"
      })

    if member? do
      Enum.each(Tenancy.list_orgs(), fn org ->
        role = if org.slug == "acme", do: "admin", else: "member"

        %OrgMembership{}
        |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: role})
        |> Repo.insert!()
      end)
    end

    user
  end

  defp conn_for(user, zone \\ @zone) do
    build_conn()
    |> init_test_session(current_user_id: user.id)
    |> put_connect_params(%{"timezone" => zone})
  end

  defp follow(conn, path) do
    case live(conn, path) do
      {:error, {:live_redirect, %{to: to}}} -> live(conn, to)
      ok -> ok
    end
  end

  defp mount!(user, path, zone \\ @zone) do
    {:ok, view, html} = follow(conn_for(user, zone), path)
    {view, html}
  end

  defp set_until(user, %DateTime{} = until) do
    stored = Repo.get!(User, user.id)

    stored
    |> User.changeset(%{
      preferences:
        Map.put(stored.preferences || %{}, "mask_names_until", DateTime.to_iso8601(until))
    })
    |> Repo.update!()
  end

  defp stored_until(user), do: Accounts.mask_names_until(Accounts.get_user(user.id))

  defp query(html, selector), do: html |> LazyHTML.from_document() |> LazyHTML.query(selector)

  defp chip?(html), do: Enum.count(query(html, @chip)) == 1

  defp chip_label(html), do: html |> query(@chip) |> LazyHTML.attribute("aria-label") |> hd()

  defp masked_line?(html) do
    html
    |> query(~s(#chat-list [data-role="chat-list-counts"]))
    |> LazyHTML.text()
    |> String.trim()
    |> Kernel.==("names masked")
  end

  @mask_switch ~s(#chat-list-popover [data-role="chat-list-pop-option-mask"])

  defp popover_toggle_mask(view) do
    unless has_element?(view, @mask_switch),
      do: view |> element("#list-more") |> render_click()

    view |> element(@mask_switch) |> render_click()
  end

  defp seed_projects do
    for {slug, name} <- [
          {"initech", "Initech Storefront"},
          {"vandelay_ind", "Vandelay-Ind Rollout"},
          {"globex", "Globex Onboarding"}
        ] do
      {:ok, project} =
        Tasks.create_project(%{
          name: name,
          slug: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-"),
          org_id: Tenancy.get_org_by_slug!(slug).id
        })

      project
    end
  end

  defp tasks_names(projects),
    do:
      Enum.map(@tenants, &Tenancy.get_org_by_slug!(&1).name) ++
        @tenants ++ Enum.map(projects, & &1.name)

  defp without_scope_stylesheet(html),
    do: Regex.replace(~r/<style id="org-scope-colors"[^>]*>.*?<\/style>/s, html, "")

  defp expected_until(user, zone \\ @zone),
    do: MaskNamesLabel.until_text(stored_until(user), zone, DateTime.utc_now())

  setup do
    {:ok, _} = Chat.create_space(%{name: "General", slug: "general", kind: "channel"})

    for name <- @chat_orgs do
      slug = String.downcase(name)
      org = Tenancy.get_org_by_slug(String.replace(slug, "-", "_"))

      {:ok, _} =
        Chat.create_space(%{name: name, slug: slug, kind: "channel", org_id: org && org.id})
    end

    :ok
  end

  describe "presence" do
    test "a masked user sees the chip on every shell page; an unmasked user sees none" do
      masked = insert_user("presence-a", true)
      plain = insert_user("presence-b", true)
      set_until(masked, DateTime.add(DateTime.utc_now(), 3600, :second))

      for path <- ~w(/chat /chat/general /tasks /inbox /settings /meetings) do
        {_view, on} = mount!(masked, path)
        {_view, off} = mount!(plain, path)
        assert chip?(on), "#{path}: expected the chip for the masked user"
        refute chip?(off), "#{path}: expected no chip for the unmasked user"
      end
    end

    test "expiry by fixture: past key, no chip and real names; future key, chip and masked" do
      user = insert_user("expiry")

      set_until(user, DateTime.add(DateTime.utc_now(), -1, :second))
      {_view, html} = mount!(user, "/chat")
      refute chip?(html)
      for name <- @chat_orgs, do: assert_name_anywhere(html, name)

      set_until(user, DateTime.add(DateTime.utc_now(), 3600, :second))
      {_view, html} = mount!(user, "/chat")
      assert chip?(html)
      for name <- @chat_orgs, do: refute_name_anywhere(html, name)
    end

    test "the chip and the page still agree after the key expires mid-session" do
      user = insert_user("mid-session")
      until = DateTime.add(DateTime.utc_now(), 4, :second)
      set_until(user, until)

      {view, html} = mount!(user, "/chat")
      assert chip?(html)
      for name <- @chat_orgs, do: refute_name_anywhere(html, name)

      # Let the stored instant pass, then force a re-render through an
      # unrelated shell event. The page was seeded masked at mount and stays
      # masked, so the chip must stay too: it reads `@mask_names?`, never a
      # clock or the record.
      wait_ms = max(DateTime.diff(until, DateTime.utc_now(), :millisecond) + 500, 0)
      Process.sleep(wait_ms)
      refute Accounts.mask_names?(Accounts.get_user(user.id))

      html = render_hook(view, "close_theme_picker", %{})
      assert chip?(html)
      for name <- @chat_orgs, do: refute_name_anywhere(html, name)
    end
  end

  describe "agreement on one page" do
    test "/chat: the list's mask switch shows and hides the chip in the same render" do
      user = insert_user("agree-chat")
      {view, html} = mount!(user, "/chat")
      refute chip?(html)
      for name <- @chat_orgs, do: assert_name_anywhere(html, name)

      html = popover_toggle_mask(view)

      assert chip?(html)
      assert masked_line?(html)
      assert chip_label(html) =~ "Names masked #{expected_until(user)}."
      assert html =~ "· #{expected_until(user)}"
      for name <- @chat_orgs, do: refute_name_anywhere(html, name)

      html = popover_toggle_mask(view)

      refute chip?(html)
      refute masked_line?(html)
      for name <- @chat_orgs, do: assert_name_anywhere(html, name)
    end

    test "/tasks: the rail's toggle shows and hides the chip in the same render" do
      projects = seed_projects()
      user = insert_user("agree-tasks", true)
      {view, html} = mount!(user, "/tasks")
      refute chip?(html)
      for name <- tasks_names(projects), do: assert_name_anywhere(html, name)

      html =
        view |> element("[data-role=rail-mask-toggle]") |> render_click(%{"masked" => "true"})

      assert chip?(html)
      assert chip_label(html) =~ "Names masked #{expected_until(user)}."
      masked = without_scope_stylesheet(html)
      for name <- tasks_names(projects), do: refute_name_anywhere(masked, name, @machine_attrs)

      html =
        view |> element("[data-role=rail-mask-toggle]") |> render_click(%{"masked" => "false"})

      refute chip?(html)
      for name <- tasks_names(projects), do: assert_name_anywhere(html, name)
    end

    test "/settings: the switch shows and hides the chip in the same render" do
      user = insert_user("agree-settings")
      {view, html} = mount!(user, "/settings")
      refute chip?(html)

      html = view |> element("[data-role=settings-mask-names]") |> render_click()
      assert chip?(html)
      assert has_element?(view, "[data-role=settings-mask-names][aria-checked=true]")
      assert chip_label(html) =~ "Names masked #{expected_until(user)}."

      html = view |> element("[data-role=settings-mask-names]") |> render_click()
      refute chip?(html)
      assert has_element?(view, "[data-role=settings-mask-names][aria-checked=false]")
    end
  end

  describe "a tap never unmasks" do
    test "/chat: the chip opens the confirm; only Turn off unmasks" do
      user = insert_user("tap")
      {:ok, _} = Accounts.put_mask_names(user.id, true)
      before = stored_until(user)
      {view, html} = mount!(user, "/chat")
      assert html |> query(@chip) |> LazyHTML.attribute("aria-expanded") == ["false"]

      html = view |> element(@chip) |> render_click()
      assert html |> query(@chip) |> LazyHTML.attribute("aria-expanded") == ["true"]
      assert html |> query("#mask-names-sheet") |> LazyHTML.attribute("data-open") == ["true"]
      assert stored_until(user) == before
      assert masked_line?(html)
      for name <- @chat_orgs, do: refute_name_anywhere(html, name)

      # Positive control: the observation above can see an unmask.
      html =
        view
        |> element("#mask-names-popover [data-role=mask-chip-turn-off]")
        |> render_click()

      assert stored_until(user) == nil
      refute chip?(html)
      for name <- @chat_orgs, do: assert_name_anywhere(html, name)
    end

    test "/inbox: the sheet's Turn off unmasks through the shell" do
      user = insert_user("tap-inbox")
      {:ok, _} = Accounts.put_mask_names(user.id, true)
      {view, _html} = mount!(user, "/inbox")
      view |> element(@chip) |> render_click()

      html =
        view |> element("#mask-names-sheet [data-role=mask-chip-turn-off]") |> render_click()

      assert stored_until(user) == nil
      refute chip?(html)
    end

    test "close_mask_chip closes without writing" do
      user = insert_user("close")
      {:ok, _} = Accounts.put_mask_names(user.id, true)
      before = stored_until(user)
      {view, _html} = mount!(user, "/inbox")

      html = view |> element(@chip) |> render_click()
      assert html |> query(@chip) |> LazyHTML.attribute("aria-expanded") == ["true"]

      html = render_hook(view, "close_mask_chip", %{})
      assert html |> query(@chip) |> LazyHTML.attribute("aria-expanded") == ["false"]
      assert stored_until(user) == before
      assert chip?(html)
    end
  end

  describe "copy" do
    test "the accessible name says when masking ends and what the chip opens" do
      user = insert_user("copy")
      {:ok, _} = Accounts.put_mask_names(user.id, true)
      {_view, html} = mount!(user, "/inbox")
      label = chip_label(html)
      assert label =~ "Names masked until"
      assert label =~ "Open mask settings"
      assert label == "Names masked #{expected_until(user)}. Open mask settings"
      assert html =~ "Names are masked in Chat and Tasks on all your devices"
    end

    test "'tomorrow' appears when the end is past local midnight" do
      user = insert_user("tomorrow")
      now = DateTime.utc_now()
      until = DateTime.add(now, 11 * 3600, :second)
      set_until(user, until)

      # Some whole-hour zone has its midnight inside the next 11 hours: the
      # offsets span 26 hours. Pick the first one where it does.
      zone =
        Enum.find(Enum.map(-12..14, &etc_zone/1), fn zone ->
          {:ok, local_now} = DateTime.shift_zone(now, zone)
          {:ok, local_until} = DateTime.shift_zone(until, zone)
          Date.compare(DateTime.to_date(local_until), DateTime.to_date(local_now)) == :gt
        end)

      assert zone
      {_view, html} = mount!(user, "/inbox", zone)
      assert chip_label(html) =~ "tomorrow"

      # Control: a zone where both instants share a date reads no "tomorrow".
      same_day =
        Enum.find(Enum.map(-12..14, &etc_zone/1), fn zone ->
          {:ok, local_now} = DateTime.shift_zone(now, zone)
          {:ok, local_until} = DateTime.shift_zone(until, zone)
          Date.compare(DateTime.to_date(local_until), DateTime.to_date(local_now)) == :eq
        end)

      assert same_day
      {_view, html} = mount!(user, "/inbox", same_day)
      refute chip_label(html) =~ "tomorrow"
    end

    # `Etc/GMT+5` is UTC-5 (POSIX sign).
    defp etc_zone(0), do: "Etc/UTC"
    defp etc_zone(offset) when offset > 0, do: "Etc/GMT-#{offset}"
    defp etc_zone(offset), do: "Etc/GMT+#{-offset}"
  end

  describe "guards over the chip, popover and sheet" do
    setup do
      user = insert_user("guards")
      {:ok, _} = Accounts.put_mask_names(user.id, true)
      {view, _} = mount!(user, "/inbox")
      html = view |> element(@chip) |> render_click()

      roots =
        for selector <- ~w(#mask-names-chip-root #mask-names-sheet) do
          [root] = html |> query(selector) |> Enum.to_list()
          root
        end

      %{html: html, roots: roots}
    end

    test "no hover utility, no status colour, no opacity text, no tiny text", %{roots: roots} do
      classes =
        roots
        |> Enum.flat_map(&(&1 |> LazyHTML.query("[class]") |> LazyHTML.attribute("class")))

      # Anti-vacuity: the scan reads the chip's and the sheet's own classes.
      assert length(classes) > 10
      assert Enum.any?(classes, &(&1 =~ "rounded-selector"))
      assert Enum.any?(classes, &(&1 =~ "sheet-panel"))

      tokens = classes |> Enum.flat_map(&String.split/1)

      for token <- tokens do
        refute String.contains?(token, "hover:"), "hover utility: #{token}"
        refute token in ~w(text-error text-warning text-info bg-warning bg-error bg-info)
        refute String.starts_with?(token, "text-base-content/"), "opacity text: #{token}"

        case Regex.run(~r/^text-\[(\d+)px\]$/, token) do
          [_, px] -> assert String.to_integer(px) >= 12
          nil -> :ok
        end
      end
    end

    # The 44px target, pinned as geometry (task 01a1600d stage 4). A unit test
    # cannot call elementFromPoint, so this reads the classes the browser
    # lays out from: the bar's height and bottom border, the pill's height and
    # border, and the `before:` box's insets (measured from the pill's PADDING
    # box). The box must start inside the viewport, end inside the bar (so it
    # covers nothing in the page header below and needs no z-index), and span
    # 44px. The browser measurement itself is in the stage-4 report.
    test "the chip's tap target is 44px tall and inside the bar", %{html: html} do
      shell =
        "../../../lib/platform_web/components/layouts/shell.html.heex"
        |> Path.expand(__DIR__)
        |> File.read!()

      [bar] = Regex.run(~r/id="phone-top-bar"\s+class="([^"]*)"/, shell, capture: :all_but_first)
      bar_px = spacing_px(bar, "h")
      bar_border = if bar =~ ~r/(^|\s)border-b(\s|$)/, do: 1, else: 0

      [button] = html |> query(@chip) |> LazyHTML.attribute("class")
      pill_px = spacing_px(button, "h")
      pill_border = if button =~ ~r/(^|\s)border(\s|$)/, do: 1, else: 0
      assert {bar_px, pill_px} == {44.0, 28.0}

      pill_top = (bar_px - bar_border - pill_px) / 2
      box_top = pill_top + pill_border - inset_px(button, "top")
      box_bottom = pill_top + pill_px - pill_border + inset_px(button, "bottom")

      assert box_top >= 0, "the box starts #{-box_top}px above the viewport"
      assert box_bottom <= bar_px, "the box ends #{box_bottom - bar_px}px below the bar"
      assert box_bottom - box_top >= 44, "target #{box_bottom - box_top}px < 44px"

      # The bar's last pixel row is hit-tested to the positioned <main> below
      # unless the chip's root is raised above it and above the sticky z-20
      # page headers (#tasks-page-header).
      [root] = html |> query("#mask-names-chip-root") |> LazyHTML.attribute("class")
      assert [_, z] = Regex.run(~r/(?:^|\s)z-(\d+)(?:\s|$)/, root)
      assert String.to_integer(z) > 20
    end

    test "the chip button carries no shadow", %{html: html} do
      [class] = html |> query(@chip) |> LazyHTML.attribute("class")
      assert class =~ "bg-base-200"
      refute class =~ "shadow"
    end

    test "navigate links carry no phx-click; the Settings link is found", %{roots: roots} do
      for root <- roots do
        links = root |> LazyHTML.query("[data-phx-link]") |> Enum.to_list()
        assert length(links) == 1

        for link <- links do
          assert LazyHTML.attribute(link, "data-role") == ["mask-chip-settings"]
          assert LazyHTML.attribute(link, "href") == ["/settings"]
          assert LazyHTML.attribute(link, "phx-click") == []
        end
      end
    end

    test "the sheet swipes to dismiss AND its handle is the Close button", %{html: html} do
      assert html |> query("#mask-names-sheet") |> LazyHTML.attribute("data-swipe-dismiss") ==
               ["true"]

      assert html
             |> query(~s(#mask-names-sheet .sheet-handle-button[aria-label="Close"]))
             |> Enum.count() == 1

      assert html |> query("#mask-names-sheet") |> LazyHTML.attribute("class") |> hd() =~
               "lg:hidden"
    end
  end

  # Tailwind spacing (`h-7`, `before:-inset-y-2`) is 4px a step; an arbitrary
  # value (`before:-top-[5px]`) is read as written.
  defp spacing_px(class, prefix) do
    case Regex.run(~r/(?:^|\s)#{prefix}-(\d+(?:\.\d+)?)(?:\s|$)/, class) do
      [_, n] -> String.to_float(if(n =~ ".", do: n, else: n <> ".0")) * 4
      nil -> flunk("no #{prefix}-N in #{inspect(class)}")
    end
  end

  defp inset_px(class, side) do
    axis = if side in ["top", "bottom"], do: "y", else: "x"

    cond do
      m = Regex.run(~r/before:-#{side}-\[(\d+(?:\.\d+)?)px\]/, class) ->
        m |> List.last() |> Float.parse() |> elem(0)

      m = Regex.run(~r/before:-#{side}-(\d+(?:\.\d+)?)(?:\s|$)/, class) ->
        (m |> List.last() |> Float.parse() |> elem(0)) * 4

      m = Regex.run(~r/before:-inset-#{axis}-(\d+(?:\.\d+)?)(?:\s|$)/, class) ->
        (m |> List.last() |> Float.parse() |> elem(0)) * 4

      true ->
        0.0
    end
  end
end
