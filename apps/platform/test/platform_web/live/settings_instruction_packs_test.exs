defmodule PlatformWeb.SettingsInstructionPacksTest do
  use PlatformWeb.ConnCase, async: false
  import Ecto.Query
  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures
  import Platform.InstructionPackFixtures
  alias Platform.{Repo, Sharing, Skills}
  alias Platform.InstructionPacks.{Installer, Manifest, Owner, State}

  setup do
    owner = root_admin!()
    Sharing.get()
    {:ok, _} = Sharing.set(:instruction_updates, true, :system)
    {:ok, _} = Sharing.set(:instruction_updates_stopped, false, :system)
    old = Application.get_env(:platform, :instruction_packs)
    {_, roots} = envelope()
    Application.put_env(:platform, :instruction_packs, trust_roots: roots)
    on_exit(fn -> if old, do: Application.put_env(:platform, :instruction_packs, old), else: Application.delete_env(:platform, :instruction_packs) end)
    %{owner: owner}
  end

  defp conn_for(user), do: build_conn() |> init_test_session(current_user_id: user.id)
  defp open(owner), do: live(conn_for(owner), "/settings?sheet=sharing")
  defp pack(version, previous \\ nil) do
    envelope(manifest(%{"minimum_client_version" => "0.1.0", "version" => version, "previous_digest" => previous,
      "changelog" => "<script>untrusted changelog</script>", "entries" => [%{"type" => "skill_markdown", "target" => "owner-ui", "content" => "published #{version} <script>pack</script>"}]}))
  end
  defp install({e, roots}) do
    {:ok, snapshot} = Installer.consent_snapshot()
    assert {:ok, state} = Installer.install(e, roots, snapshot)
    state
  end
  defp fixture do
    {:ok, skill} = Skills.create_skill(%{name: "Owner UI", content: "my local <script>text</script>"})
    {e, _} = p = pack(1)
    install(p)
    {skill, e}
  end

  test "owner sees registry disclosure and can stop and enable updates", %{owner: owner} do
    {:ok, view, html} = open(owner)
    assert html =~ "New installs receive signed agent instruction updates by default"
    assert html =~ "Exactly what"
    for entry <- Sharing.registry(), do: assert(html =~ entry.title)
    view |> element("button[phx-click=stop]") |> render_click()
    assert Sharing.get().instruction_updates_stopped
    view |> element("button[phx-click=sharing][phx-value-key=instruction_updates]") |> render_click()
    refute Sharing.get().instruction_updates
  end

  test "non-owner forged events cannot mutate install state", %{owner: owner} do
    member = root_admin!()
    Repo.update_all(from(m in Platform.Tenancy.OrgMembership, where: m.user_id == ^member.id), set: [role: "member"])
    {:ok, view, html} = live(conn_for(member), "/settings?sheet=sharing")
    refute html =~ "settings-sharing-sheet\" open"
    refute has_element?(view, "[data-role=settings-sharing]")
    render_click(view, "open_sharing_sheet", %{})
    refute has_element?(view, "#instruction-packs-controls")
    assert {:error, :unauthorized} = Owner.set_sharing("instruction_updates", false, member)
    assert Sharing.get().instruction_updates
    # Revoke privilege after mount: both component events and context must check again.
    {:ok, owner_view, _} = open(owner)
    Repo.delete_all(from(m in Platform.Tenancy.OrgMembership, where: m.user_id == ^owner.id))
    owner_view |> element("button[phx-click=stop]") |> render_click()
    refute Sharing.get().instruction_updates_stopped
    assert render(owner_view) =~ "Only an install owner"
  end

  test "conflict text is escaped and stale decision cannot overwrite newer local edit", %{owner: owner} do
    {skill, _} = fixture()
    {:ok, view, html} = open(owner)
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>pack</script>"
    assert html =~ "Local change preserved"
    assert html =~ "Local version"
    {:ok, _} = Skills.update_skill(skill, %{content: "newer LOCAL sentinel"})
    view |> element("button[phx-value-choice=incoming]") |> render_click()
    assert Skills.get_skill(skill.id).content == "newer LOCAL sentinel"
    assert render(view) =~ "changed since you reviewed it"
    view |> element("button[phx-value-choice=local]") |> render_click()
    refute has_element?(view, "[data-role=pack-conflict]")
    assert Skills.get_skill(skill.id).content == "newer LOCAL sentinel"
  end

  test "published choice pin resume and rollback preserve later edits", %{owner: owner} do
    {skill, e} = fixture()
    {:ok, view, _} = open(owner)
    assert has_element?(view, "button[phx-click=rollback][disabled]")
    view |> element("button[phx-value-choice=incoming]") |> render_click()
    assert Skills.get_skill(skill.id).content =~ "published 1"
    install(pack(2, Manifest.digest(e["manifest"])))
    view |> element("button[phx-click=refresh]") |> render_click()
    view |> element("form[phx-submit=pin]") |> render_submit(%{"pack" => "setup-guide", "version" => "2"})
    assert Repo.get!(State, "setup-guide").pinned_version == 2
    assert render(view) =~ "Pinned to v2"
    view |> element("button[phx-click=resume]") |> render_click()
    assert Repo.get!(State, "setup-guide").pinned_version == nil
    {:ok, _} = Skills.update_skill(Skills.get_skill(skill.id), %{content: "edited after version two"})
    view |> element("button[phx-click=rollback]") |> render_click()
    assert Repo.get!(State, "setup-guide").version == 1
    assert Skills.get_skill(skill.id).content == "edited after version two"
    assert render(view) =~ "Local change preserved"
    assert render(view) =~ "resolve_conflict"
  end

  test "verification and network failures display distinct status without false application", %{owner: owner} do
    fixture()
    state = Repo.get!(State, "setup-guide")
    Repo.update!(Ecto.Changeset.change(state, check_error: "verification"))
    {:ok, view, html} = open(owner)
    assert html =~ "Verification failure"
    refute html =~ "Up to date with"
    Repo.update!(Ecto.Changeset.change(Repo.get!(State, "setup-guide"), check_error: "network"))
    view |> element("button[phx-click=refresh]") |> render_click()
    assert render(view) =~ "Network failure"
  end
end
