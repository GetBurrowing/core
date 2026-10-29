defmodule Platform.Prototypes.PublishTest do
  use Platform.DataCase, async: false

  import Platform.PrototypeFixtures
  import Platform.TenancyFixtures

  alias Platform.Prototypes
  alias Platform.Prototypes.Storage

  setup do
    scratch = scratch_storage!("prototype_publish_test")

    set_settings!(%{
      enabled: true,
      who_may_publish: "members",
      max_files: 500,
      max_bundle_bytes: 26_214_400,
      retention_days: 90
    })

    org_id = tenant_org_id("proto-pub-#{System.unique_integer([:positive])}")
    agent = agent!()
    {:ok, scratch: scratch, org_id: org_id, agent: agent}
  end

  defp publish(agent, attrs, input, owner \\ nil),
    do: Prototypes.publish(agent_publisher(agent, owner), attrs, input)

  test "publish creates v1 then v2; v1's manifest and bytes are untouched", ctx do
    assert {:ok, %{prototype: p, version: v1}} =
             publish(ctx.agent, %{org_id: ctx.org_id, name: "Demo"}, {:files, bundle_files("v1")})

    assert v1.version == 1
    assert p.latest_version == 1
    assert Prototypes.url(p.id, 1) == "/proto/#{p.id}/1/"

    assert {:ok, %{prototype: p2, version: v2}} =
             publish(ctx.agent, %{prototype: p}, {:files, bundle_files("v2")})

    assert v2.version == 2
    assert p2.latest_version == 2

    v1_again = Prototypes.get_live_version(p.id, 1)
    assert v1_again.manifest == v1.manifest
    index = Enum.find(v1_again.manifest, &(&1["path"] == "index.html"))
    assert index["content_type"] == "text/html"
    assert index["storage_key"] == "prototypes/#{p.id}/1/index.html"
    assert {:ok, bytes} = Storage.read(index["storage_key"])
    assert bytes =~ "v1"
  end

  test "a zip publishes like a file map", ctx do
    bin = zip([%{name: "index.html", data: "<p>zip</p>"}, %{name: "a/b.js", data: "1"}])

    assert {:ok, %{version: v}} =
             publish(ctx.agent, %{org_id: ctx.org_id, name: "Zip"}, {:zip, bin})

    assert Enum.map(v.manifest, & &1["path"]) |> Enum.sort() == ["a/b.js", "index.html"]
  end

  describe "refusals write nothing to storage" do
    test "disabled", ctx do
      set_settings!(%{enabled: false})

      assert {:error, {:prototypes_disabled, _}} =
               publish(ctx.agent, %{org_id: ctx.org_id, name: "X"}, {:files, bundle_files()})

      assert stored_prototype_files(ctx.scratch) == []
    end

    test "over the byte cap and over the file cap", ctx do
      set_settings!(%{max_bundle_bytes: 50})

      assert {:error, {:bundle_too_large, _}} =
               publish(ctx.agent, %{org_id: ctx.org_id, name: "X"}, {:files, bundle_files()})

      set_settings!(%{max_bundle_bytes: 26_214_400, max_files: 2})

      assert {:error, {:too_many_files, _}} =
               publish(ctx.agent, %{org_id: ctx.org_id, name: "X"}, {:files, bundle_files()})

      assert stored_prototype_files(ctx.scratch) == []
    end

    test "zip traversal, zip bomb and a missing index.html", ctx do
      evil = zip([%{name: "index.html", data: "ok"}, %{name: "../x", data: "evil"}])

      assert {:error, {:invalid_path, _}} =
               publish(ctx.agent, %{org_id: ctx.org_id, name: "X"}, {:zip, evil})

      abs = zip([%{name: "index.html", data: "ok"}, %{name: "/etc/x", data: "evil"}])

      assert {:error, {:invalid_path, _}} =
               publish(ctx.agent, %{org_id: ctx.org_id, name: "X"}, {:zip, abs})

      bomb = zip([%{name: "index.html", data: :binary.copy(<<0>>, 2_000_000), declared: 10}])

      assert {:error, {:bundle_too_large, _}} =
               publish(ctx.agent, %{org_id: ctx.org_id, name: "X"}, {:zip, bomb})

      assert {:error, {:missing_entry, _}} =
               publish(
                 ctx.agent,
                 %{org_id: ctx.org_id, name: "X"},
                 {:files, %{"a.js" => %{"content" => "1"}}}
               )

      assert stored_prototype_files(ctx.scratch) == []
      assert Platform.Repo.aggregate(Platform.Prototypes.Prototype, :count) == 0
    end

    test "policy: admins refuses an ownerless agent; agents_only refuses a user", ctx do
      set_settings!(%{who_may_publish: "admins"})

      assert {:error, {:publish_not_allowed, _}} =
               publish(ctx.agent, %{org_id: ctx.org_id, name: "X"}, {:files, bundle_files()})

      member = user!()
      member!(member, ctx.org_id, "member")

      assert {:error, {:publish_not_allowed, _}} =
               publish(
                 ctx.agent,
                 %{org_id: ctx.org_id, name: "X"},
                 {:files, bundle_files()},
                 member
               )

      assert stored_prototype_files(ctx.scratch) == []

      # Positive control: an agent owned by an org admin is admitted.
      admin = user!()
      member!(admin, ctx.org_id, "admin")

      assert {:ok, _} =
               publish(
                 ctx.agent,
                 %{org_id: ctx.org_id, name: "X"},
                 {:files, bundle_files()},
                 admin
               )

      set_settings!(%{who_may_publish: "agents_only"})

      assert {:error, {:publish_not_allowed, _}} =
               Prototypes.publish(
                 %{kind: :user, user: admin},
                 %{org_id: ctx.org_id, name: "Y"},
                 {:files, bundle_files()}
               )

      set_settings!(%{who_may_publish: "members"})
      outsider = user!()

      assert {:error, {:publish_not_allowed, _}} =
               Prototypes.publish(
                 %{kind: :user, user: outsider},
                 %{org_id: ctx.org_id, name: "Y"},
                 {:files, bundle_files()}
               )
    end
  end

  test "rollback repoints latest without copying; a removed version is refused", ctx do
    {:ok, %{prototype: p}} =
      publish(ctx.agent, %{org_id: ctx.org_id, name: "R"}, {:files, bundle_files("v1")})

    {:ok, %{prototype: p}} = publish(ctx.agent, %{prototype: p}, {:files, bundle_files("v2")})
    files_before = stored_prototype_files(ctx.scratch)

    assert {:ok, p} = Prototypes.rollback(agent_publisher(ctx.agent), p, 1)
    assert p.latest_version == 1
    assert stored_prototype_files(ctx.scratch) == files_before

    # The next publish is v3, never a reused 2.
    {:ok, %{version: v3}} = publish(ctx.agent, %{prototype: p}, {:files, bundle_files("v3")})
    assert v3.version == 3

    Prototypes.get_live_version(p.id, 2)
    |> Ecto.Changeset.change(removed_at: DateTime.utc_now())
    |> Platform.Repo.update!()

    assert {:error, {:version_not_found, _}} =
             Prototypes.rollback(agent_publisher(ctx.agent), p, 2)
  end

  describe "embed_html/2 (task 01a18834 stage 1)" do
    test "returns a live version's entry bytes, and :not_found once retention removed it", ctx do
      {:ok, %{prototype: p}} =
        publish(ctx.agent, %{org_id: ctx.org_id, name: "H"}, {:files, bundle_files("v1")})

      {:ok, %{prototype: p}} = publish(ctx.agent, %{prototype: p}, {:files, bundle_files("v2")})

      assert {:ok, html} = Prototypes.embed_html(p.id, 2)
      assert html == bundle_files("v2")["index.html"]["content"]
      assert {:ok, v1} = Prototypes.embed_html(p.id, 1)
      assert v1 =~ "<!-- v1 -->"
      refute v1 == html

      Prototypes.get_live_version(p.id, 2)
      |> Ecto.Changeset.change(removed_at: DateTime.utc_now())
      |> Platform.Repo.update!()

      assert Prototypes.embed_html(p.id, 2) == {:error, :not_found}
      assert Prototypes.embed_html(p.id, 9) == {:error, :not_found}
      assert Prototypes.embed_html("not-a-uuid", 1) == {:error, :not_found}
      assert Prototypes.embed_html(p.id, "1") == {:error, :not_found}
    end
  end

  describe "version_at/2 (task 01a18834 stage 2)" do
    test "the newest version inserted at or before the instant, removed ones included", ctx do
      {:ok, %{prototype: p, version: v1}} =
        publish(ctx.agent, %{org_id: ctx.org_id, name: "At"}, {:files, bundle_files("v1")})

      {:ok, %{prototype: p, version: v2}} =
        publish(ctx.agent, %{prototype: p}, {:files, bundle_files("v2")})

      v2
      |> Ecto.Changeset.change(removed_at: DateTime.utc_now())
      |> Platform.Repo.update!()

      assert Prototypes.version_at(p.id, DateTime.add(v1.inserted_at, -1, :second)) == nil
      assert Prototypes.version_at(p.id, v1.inserted_at) == 1
      assert Prototypes.version_at(p.id, DateTime.add(v2.inserted_at, -1, :microsecond)) == 1
      assert Prototypes.version_at(p.id, v2.inserted_at) == 2
      assert Prototypes.version_at(p.id, DateTime.add(v2.inserted_at, 1, :hour)) == 2
      assert Prototypes.version_at("not-a-uuid", DateTime.utc_now()) == nil
      assert Prototypes.version_at(Ecto.UUID.generate(), DateTime.utc_now()) == nil
    end
  end
end
