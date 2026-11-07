defmodule Platform.InstructionPacks.InstallerTest do
  use Platform.DataCase, async: false
  import Platform.InstructionPackFixtures
  import Platform.TenancyFixtures
  alias Platform.{Repo, Sharing, Skills}
  alias Platform.InstructionPacks.{Entry, Installer, Manifest, Poller, RetainedRelease, State}
  alias Platform.Orchestration.PromptTemplates

  setup do
    publisher = Platform.Feedback.GithubPublisher
    previous = Application.get_env(:platform, publisher)

    Application.put_env(:platform, publisher,
      broker_url: "https://broker.example/api/feedback-broker/v1"
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, publisher, previous),
        else: Application.delete_env(:platform, publisher)
    end)

    Sharing.get()
    {:ok, _} = Sharing.set(:instruction_updates, true, :system)
    {:ok, _} = Sharing.set(:instruction_updates_stopped, false, :system)

    {:ok, template} =
      PromptTemplates.create_template(%{
        name: "Pack test",
        slug: "pack.test",
        content: "local prompt"
      })

    {:ok, skill} = Skills.create_skill(%{name: "Pack fixture", content: "local skill"})
    %{owner: root_admin!(), template: template, skill: skill}
  end

  defp release(version, previous \\ nil, skill \\ "vendor skill", prompt \\ "vendor prompt") do
    m =
      manifest(%{
        "minimum_client_version" => "0.1.0",
        "version" => version,
        "previous_digest" => previous,
        "entries" => [
          %{"type" => "skill_markdown", "target" => "pack-fixture", "content" => skill},
          %{"type" => "prompt_template", "target" => "pack.test", "content" => prompt}
        ]
      })

    envelope(m)
  end

  defp install(e, roots) do
    {:ok, snapshot} = Installer.consent_snapshot()
    Installer.install(e, roots, snapshot)
  end

  defp adopt(owner) do
    for {type, target} <- [{"skill_markdown", "pack-fixture"}, {"prompt_template", "pack.test"}] do
      token = Repo.get_by!(Entry, type: type, target: target) |> Entry.conflict_token()

      assert {:ok, _} =
               Installer.resolve_conflict("setup-guide", type, target, :incoming, token, owner)
    end
  end

  test "pre-existing collisions are local; owner adoption preserves skill identity", %{
    owner: owner,
    skill: skill
  } do
    {e, roots} = release(1)
    assert {:ok, _} = install(e, roots)
    assert Skills.get_skill(skill.id).content == "local skill"
    assert Enum.all?(Repo.all(Entry), &is_nil(&1.effective_version))
    adopt(owner)
    assert Skills.get_skill(skill.id).content == "vendor skill"
    assert {:error, :unauthorized} = Installer.pin("setup-guide", 1, nil)
  end

  test "owner cannot accept incoming text from a stale conflict view", %{owner: owner} do
    {one, roots} = release(1)
    assert {:ok, _} = install(one, roots)
    token = Repo.get_by!(Entry, type: "prompt_template") |> Entry.conflict_token()
    {two, _} = release(2, Manifest.digest(one["manifest"]), "new skill", "new unseen prompt")
    assert {:ok, _} = install(two, roots)

    assert {:error, :stale_conflict} =
             Installer.resolve_conflict(
               "setup-guide",
               "prompt_template",
               "pack.test",
               :incoming,
               token,
               owner
             )

    assert PromptTemplates.get_template_by_slug("pack.test").content == "local prompt"
  end

  test "two stores advance atomically and identical replay preserves history", %{
    owner: owner,
    skill: skill
  } do
    {one, roots} = release(1)
    assert {:ok, _} = install(one, roots)
    adopt(owner)
    {two, _} = release(2, Manifest.digest(one["manifest"]), "skill two", "prompt two")
    assert {:ok, state} = install(two, roots)
    assert Skills.get_skill(skill.id).content == "skill two"
    assert PromptTemplates.get_template_by_slug("pack.test").content == "prompt two"
    assert {:ok, replay} = install(two, roots)
    assert replay.history == state.history
    assert Repo.aggregate(RetainedRelease, :count) == 2
    assert {:error, :stale_release} = install(one, roots)
  end

  test "local-hash comparison preserves local edit and records mixed effective versions", %{
    owner: owner,
    skill: skill
  } do
    {one, roots} = release(1)
    assert {:ok, _} = install(one, roots)
    adopt(owner)
    {:ok, _} = Skills.update_skill(Repo.reload!(skill), %{content: "my private edit"})
    {two, _} = release(2, Manifest.digest(one["manifest"]), "skill two", "prompt two")
    assert {:ok, _} = install(two, roots)
    assert Skills.get_skill(skill.id).content == "my private edit"
    entry = Repo.get_by!(Entry, type: "skill_markdown", target: "pack-fixture")
    assert entry.effective_version == 1

    assert entry.conflict == %{
             "base" => "vendor skill",
             "local" => "my private edit",
             "incoming" => "skill two",
             "incoming_version" => 2
           }

    assert Repo.get_by!(Entry, type: "prompt_template").effective_version == 2
  end

  test "final consent check rejects an in-flight fetch after owner switches off", %{
    owner: owner,
    skill: skill
  } do
    {one, roots} = release(1)
    assert {:ok, _} = install(one, roots)
    adopt(owner)
    {e, _} = release(2, Manifest.digest(one["manifest"]), "must not apply", "must not apply")

    during_fetch = fn conn ->
      {:ok, _} = Sharing.set(:instruction_updates, false, :system)
      Plug.Conn.send_resp(conn, 200, Jason.encode!(e))
    end

    assert {:error, :sharing_changed} =
             Installer.pull("setup-guide", 2, roots, plug: during_fetch)

    assert Repo.get!(State, "setup-guide").version == 1
    assert Repo.aggregate(RetainedRelease, :count) == 1
    assert PromptTemplates.get_template_by_slug("pack.test").content == "vendor prompt"
    assert Skills.get_skill(skill.id).content == "vendor skill"
  end

  test "network failure leaves last good content and history active", %{
    owner: owner,
    skill: skill
  } do
    {one, roots} = release(1)
    assert {:ok, state} = install(one, roots)
    adopt(owner)

    assert {:error, :download_failed} =
             Installer.pull("setup-guide", 2, roots,
               plug: fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end
             )

    assert Repo.get!(State, "setup-guide").history == state.history
    assert Skills.get_skill(skill.id).content == "vendor skill"
    assert Repo.aggregate(RetainedRelease, :count) == 1
  end

  test "stop dominates consent and pin set during fetch prevents advancement", %{owner: owner} do
    {one, roots} = release(1)
    assert {:ok, _} = install(one, roots)
    {:ok, snapshot} = Installer.consent_snapshot()
    assert {:ok, _} = Installer.pin("setup-guide", 1, owner)
    {two, _} = release(2, Manifest.digest(one["manifest"]))
    assert {:error, :pinned} = Installer.install(two, roots, snapshot)
    {:ok, _} = Sharing.set(:instruction_updates_stopped, true, :system)
    assert {:error, :sharing_disabled} = Installer.consent_snapshot()
  end

  test "rollback uses retained signed bytes, preserves later edits, pins old version", %{
    owner: owner,
    skill: skill
  } do
    {one, roots} = release(1)
    assert {:ok, _} = install(one, roots)
    adopt(owner)
    {two, _} = release(2, Manifest.digest(one["manifest"]), "skill two", "prompt two")
    assert {:ok, _} = install(two, roots)
    {:ok, _} = Skills.update_skill(Repo.reload!(skill), %{content: "keep after rollback"})
    assert {:ok, state} = Installer.rollback("setup-guide", 1, roots, owner)
    assert state.pinned_version == 1
    assert state.highest_version == 2
    assert Skills.get_skill(skill.id).content == "keep after rollback"
    assert PromptTemplates.get_template_by_slug("pack.test").content == "vendor prompt"
    assert {:error, :not_previously_applied} = Installer.rollback("setup-guide", 99, roots, owner)
    assert {:ok, _} = Installer.pin("setup-guide", nil, owner)
    assert {:ok, _} = install(two, roots)
  end

  test "missing target refuses whole pack without partial provenance or writes" do
    {e, roots} = release(1)

    changed =
      put_in(
        e["manifest"]["entries"],
        e["manifest"]["entries"] ++
          [%{"type" => "prompt_template", "target" => "missing.target", "content" => "incoming"}]
      )

    {signed, _} = envelope(changed["manifest"])
    assert {:error, :missing_target} = install(signed, roots)
    assert Repo.aggregate(Entry, :count) == 0
    assert Repo.aggregate(RetainedRelease, :count) == 0
    assert Repo.get(State, "setup-guide") == nil
  end

  test "local deletion stays deleted while other target advances", %{owner: owner, skill: skill} do
    {one, roots} = release(1)
    assert {:ok, _} = install(one, roots)
    adopt(owner)
    {:ok, _} = Skills.delete_skill(Repo.reload!(skill))
    {two, _} = release(2, Manifest.digest(one["manifest"]), "skill two", "prompt two")
    assert {:ok, _} = install(two, roots)
    assert Skills.get_skill(skill.id) == nil
    assert Repo.get_by!(Entry, type: "skill_markdown").conflict["local"] == nil
    assert PromptTemplates.get_template_by_slug("pack.test").content == "prompt two"
  end

  test "removed vendor target clears text while preserving skill id and attachments", %{
    owner: owner,
    skill: skill
  } do
    {:ok, attachment} = Skills.attach_skill(skill.id, "task", Ecto.UUID.generate())
    {one, roots} = release(1)
    assert {:ok, _} = install(one, roots)
    adopt(owner)
    {two, _} = release(2, Manifest.digest(one["manifest"]))

    m =
      Map.put(
        two["manifest"],
        "entries",
        Enum.reject(two["manifest"]["entries"], &(&1["type"] == "skill_markdown"))
      )

    {two, _} = envelope(m)
    assert {:ok, _} = install(two, roots)
    assert Skills.get_skill(skill.id).content == ""
    assert Repo.get(Platform.Skills.SkillAttachment, attachment.id).skill_id == skill.id
    assert Repo.get_by!(Entry, type: "skill_markdown").retired
  end

  test "poller discovers real signed packs and off sends no final farewell request" do
    {e, roots} = release(1)
    old = Application.get_env(:platform, :instruction_packs)

    on_exit(fn ->
      if old,
        do: Application.put_env(:platform, :instruction_packs, old),
        else: Application.delete_env(:platform, :instruction_packs)
    end)

    Application.put_env(:platform, :instruction_packs, trust_roots: roots, packs: [])
    receiver = self()

    plug = fn conn ->
      send(receiver, {:pack_request, conn.request_path})

      body =
        case conn.request_path do
          "/api/feedback-broker/v1/instruction-packs" -> Jason.encode!(%{packs: ["setup-guide"]})
          "/api/feedback-broker/v1/instruction-packs/setup-guide/1" -> Jason.encode!(e)
        end

      Plug.Conn.send_resp(conn, 200, body)
    end

    assert :ok = Poller.poll(plug: plug)
    assert_received {:pack_request, "/api/feedback-broker/v1/instruction-packs"}
    assert_received {:pack_request, "/api/feedback-broker/v1/instruction-packs/setup-guide/1"}
    assert Repo.get!(State, "setup-guide").version == 1
    {:ok, _} = Sharing.set(:instruction_updates, false, :system)
    assert :ok = Poller.poll(plug: plug)
    refute_received {:pack_request, _}
  end

  test "retirement preserves a local edit until its owner explicitly accepts removal", %{
    owner: owner,
    skill: skill
  } do
    {one, roots} = release(1)
    assert {:ok, _} = install(one, roots)
    adopt(owner)
    {:ok, _} = Skills.update_skill(Repo.reload!(skill), %{content: "local notes"})
    {two, _} = release(2, Manifest.digest(one["manifest"]))

    m =
      Map.put(
        two["manifest"],
        "entries",
        Enum.reject(two["manifest"]["entries"], &(&1["type"] == "skill_markdown"))
      )

    {two, _} = envelope(m)
    assert {:ok, _} = install(two, roots)
    assert Skills.get_skill(skill.id).content == "local notes"
    token = Repo.get_by!(Entry, type: "skill_markdown") |> Entry.conflict_token()

    assert {:ok, _} =
             Installer.resolve_conflict(
               "setup-guide",
               "skill_markdown",
               "pack-fixture",
               :incoming,
               token,
               owner
             )

    assert Skills.get_skill(skill.id).content == ""
  end
end
