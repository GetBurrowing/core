defmodule Platform.Prototypes.ToolsTest do
  @moduledoc "The `prototype` bundle end-to-end through `ToolSurface.execute/3`."

  use Platform.DataCase, async: false

  import Platform.PrototypeFixtures
  import Platform.TenancyFixtures

  import Ecto.Query, only: [from: 2]

  alias Platform.Chat
  alias Platform.Federation.ToolSurface
  alias Platform.Prototypes

  setup do
    scratch = scratch_storage!("prototype_tools_test")
    set_settings!(%{enabled: true, who_may_publish: "members"})
    org_a = tenant_org_id("proto-tool-a-#{System.unique_integer([:positive])}")
    org_b = tenant_org_id("proto-tool-b-#{System.unique_integer([:positive])}")
    root_agent = agent!(%{"org_id" => acme_org_id()})
    tenant_agent = agent!(%{"org_id" => org_a})
    {:ok, scratch: scratch, org_a: org_a, org_b: org_b, root: root_agent, tenant: tenant_agent}
  end

  defp ctx_for(agent), do: %{agent_id: agent.id}

  defp publish(agent, args), do: ToolSurface.execute("prototype_publish", args, ctx_for(agent))

  test "the bundle is listed and grantable, and not a default" do
    names = ToolSurface.list_tools(["prototype"]) |> Enum.map(& &1.name)
    assert names == ["prototype_publish", "prototype_versions", "prototype_rollback"]
    assert "prototype" in Platform.Access.RuntimeProfiles.valid_modules()
    refute "prototype" in Platform.Agents.AgentRuntime.default_tool_profile()
  end

  test "publish with a file map, then versions and rollback", ctx do
    assert {:ok, r1} =
             publish(ctx.tenant, %{
               "org_id" => ctx.org_a,
               "name" => "T",
               "files" => bundle_files()
             })

    assert r1.version == 1
    assert r1.url == "/proto/#{r1.prototype_id}/1/"

    assert {:ok, r2} =
             publish(ctx.tenant, %{
               "prototype_id" => r1.prototype_id,
               "files" => bundle_files("v2")
             })

    assert r2.version == 2

    assert {:ok, list} =
             ToolSurface.execute(
               "prototype_versions",
               %{"prototype_id" => r1.prototype_id},
               ctx_for(ctx.tenant)
             )

    assert Enum.map(list.versions, & &1.version) == [2, 1]
    assert list.total == 2 and list.has_more == false

    assert {:ok, %{latest_version: 1}} =
             ToolSurface.execute(
               "prototype_rollback",
               %{"prototype_id" => r1.prototype_id, "version" => 1},
               ctx_for(ctx.tenant)
             )
  end

  test "a tenant agent cannot publish into, or see, another org's prototypes", ctx do
    assert {:error, %{code: :unauthorized}} =
             publish(ctx.tenant, %{
               "org_id" => ctx.org_b,
               "name" => "X",
               "files" => bundle_files()
             })

    assert stored_prototype_files(ctx.scratch) == []

    {:ok, r} =
      publish(ctx.root, %{"org_id" => ctx.org_b, "name" => "B", "files" => bundle_files()})

    assert {:error, %{code: :not_found}} =
             ToolSurface.execute(
               "prototype_versions",
               %{"prototype_id" => r.prototype_id},
               ctx_for(ctx.tenant)
             )

    assert {:error, %{code: :not_found}} =
             publish(ctx.tenant, %{"prototype_id" => r.prototype_id, "files" => bundle_files()})
  end

  test "disabled install refuses with a code", ctx do
    set_settings!(%{enabled: false})

    assert {:error, %{code: :prototypes_disabled, recoverable: false}} =
             publish(ctx.tenant, %{
               "org_id" => ctx.org_a,
               "name" => "X",
               "files" => bundle_files()
             })
  end

  test "publish from a zip attachment in a space the agent is in; org from the space", ctx do
    {:ok, space} =
      Chat.create_space(%{
        name: "Proto Space",
        slug: "proto-#{System.unique_integer([:positive])}",
        kind: "channel",
        org_id: ctx.org_a
      })

    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: ctx.tenant.id,
        display_name: "Proto Agent",
        joined_at: DateTime.utc_now()
      })

    zip = zip([%{name: "index.html", data: "<p>zipped</p>"}])

    {:ok, att} =
      ToolSurface.execute(
        "attachment_upload_inline",
        %{
          "space_id" => space.id,
          "filename" => "bundle.zip",
          "content_type" => "application/zip",
          "data_base64" => Base.encode64(zip)
        },
        ctx_for(ctx.tenant)
      )

    assert {:ok, r} =
             publish(ctx.tenant, %{
               "space_id" => space.id,
               "name" => "Zipped",
               "zip_attachment_id" => att.id
             })

    p = Platform.Prototypes.get_prototype(r.prototype_id)
    assert p.org_id == ctx.org_a
    assert p.space_id == space.id
  end

  # ── Read tools (task 01a18da0 stage 1) ─────────────────────────────────

  defmodule SpyStorage do
    @moduledoc false
    # Delegates to LocalDisk and reports every read to the test that armed it,
    # so a refusal can be shown to have touched no storage.
    alias Platform.Chat.AttachmentStorage.Adapter.LocalDisk

    def persist(key, data), do: LocalDisk.persist(key, data)
    def delete(key), do: LocalDisk.delete(key)

    def read_stream(key) do
      case Application.get_env(:platform, :prototype_read_spy) do
        pid when is_pid(pid) -> send(pid, {:storage_read, key})
        _ -> :ok
      end

      LocalDisk.read_stream(key)
    end
  end

  defp read(tool, args, context), do: ToolSurface.execute(tool, args, context)

  defp spy_storage! do
    prev = Application.get_env(:platform, :attachment_storage_adapter)
    Application.put_env(:platform, :attachment_storage_adapter, SpyStorage)
    Application.put_env(:platform, :prototype_read_spy, self())

    on_exit(fn ->
      Application.delete_env(:platform, :prototype_read_spy)

      if prev,
        do: Application.put_env(:platform, :attachment_storage_adapter, prev),
        else: Application.delete_env(:platform, :attachment_storage_adapter)
    end)
  end

  defp deny!(agent, permission, resource),
    do:
      {:ok, _} =
        Platform.Access.Grants.deny(%{
          principal: {:agent, agent.id},
          permission: permission,
          resource: resource
        })

  # A not_found envelope names the id it was asked for; compare two with
  # that id taken out.
  defp scrub({:error, envelope}, id),
    do:
      {:error,
       Map.new(envelope, fn
         {k, v} when is_binary(v) -> {k, String.replace(v, id, "<ID>")}
         kv -> kv
       end)}

  defp random_envelope(tool, args, context) do
    id = Platform.Types.UUIDv7.generate()
    scrub(read(tool, Map.put(args, "prototype_id", id), context), id)
  end

  describe "prototype_files / prototype_file_get" do
    setup ctx do
      owner = user!("Proto Reader Owner")
      member!(owner, ctx.org_a)

      {:ok, space} =
        Chat.create_space(%{
          name: "Proto Read Space",
          slug: "proto-read-#{System.unique_integer([:positive])}",
          kind: "channel",
          org_id: ctx.org_a
        })

      {:ok, participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: owner.id,
          display_name: "Owner",
          joined_at: DateTime.utc_now()
        })

      png = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 255, 254, 1>>
      svg = ~s(<svg xmlns="http://www.w3.org/2000/svg"><rect width="1" height="1"/></svg>)

      files =
        bundle_files("read-v1")
        |> Map.put("img/logo.png", %{"content_base64" => Base.encode64(png)})
        |> Map.put("img/mark.svg", %{"content" => svg})

      {:ok, %{prototype: proto, version: v1}} =
        Prototypes.publish(
          agent_publisher(ctx.root),
          %{org_id: ctx.org_a, space_id: space.id, name: "Readable"},
          {:files, files}
        )

      {:ok, %{version: v2}} =
        Prototypes.publish(
          agent_publisher(ctx.root),
          %{prototype: Prototypes.get_prototype(proto.id)},
          {:files, Map.put(bundle_files("read-v2"), "secret.txt", %{"content" => "v2 only"})}
        )

      canvas =
        Repo.insert!(%Platform.Chat.Canvas{
          space_id: space.id,
          created_by: participant.id,
          title: "Proto canvas"
        })

      {:ok, %{"prototype_id" => embed_id}} =
        Prototypes.publish_embed(%{
          org_id: ctx.org_a,
          space_id: space.id,
          canvas_id: canvas.id,
          node_id: "embed-read",
          html: "<!doctype html><p>embed</p>"
        })

      reader = agent!(%{"org_id" => ctx.org_a})
      outsider = agent!(%{"org_id" => ctx.org_b})
      outsider_owner = user!("Outsider Owner")
      member!(outsider_owner, ctx.org_b)

      {:ok,
       owner: owner,
       space: space,
       canvas: canvas,
       proto: proto,
       v1: v1,
       v2: v2,
       png: png,
       svg: svg,
       files: files,
       embed_id: embed_id,
       reader: reader,
       reader_ctx: reader_context!(reader, owner),
       outsider_ctx: reader_context!(outsider, outsider_owner)}
    end

    test "both tools are in the DEFAULT context_read bundle under prototypes.read" do
      names = ToolSurface.list_tools(["context_read"]) |> Enum.map(& &1.name)
      assert "prototype_files" in names and "prototype_file_get" in names
      assert "context_read" in Platform.Agents.AgentRuntime.default_tool_profile()

      for name <- ~w(prototype_files prototype_file_get) do
        assert Platform.Access.ToolPermissions.for_tool(name) == "prototypes.read"
      end

      assert "prototypes.read" in Platform.Access.ToolPermissions.bundle_permissions(
               "context_read"
             )
    end

    test "a default-profile runtime is authorized; a MODULE-level prototypes.read removal is refused by tool authorization",
         ctx do
      runtime = Platform.Federation.get_runtime_by_runtime_id(ctx.reader_ctx.runtime_id)
      assert Platform.Access.Tools.authorize("prototype_files", runtime) == :ok
      assert Platform.Access.Tools.authorize("prototype_file_get", runtime) == :ok

      {:ok, _} =
        Platform.Access.RuntimeProfiles.restrict(
          runtime,
          runtime
          |> Platform.Access.RuntimeProfiles.restrictions()
          |> Map.delete("prototypes.read")
        )

      assert Platform.Access.Tools.authorize("prototype_files", runtime) == {:error, :forbidden}

      assert Platform.Access.Tools.authorize("prototype_file_get", runtime) ==
               {:error, :forbidden}

      # The rest of context_read is untouched by that restriction.
      assert Platform.Access.Tools.authorize("canvas_get", runtime) == :ok
    end

    test "prototype_files lists every manifest file of the latest version by default", ctx do
      assert {:ok, env} =
               read("prototype_files", %{"prototype_id" => ctx.proto.id}, ctx.reader_ctx)

      assert env.version == 2 and env.latest_version == 2
      assert env.entry_path == "index.html"
      assert env.has_more == false
      assert env.total == length(ctx.v2.manifest)

      assert Enum.sort_by(env.files, & &1.path) ==
               ctx.v2.manifest
               |> Enum.map(
                 &%{
                   path: &1["path"],
                   byte_size: &1["byte_size"],
                   sha256: &1["sha256"],
                   content_type: &1["content_type"]
                 }
               )
               |> Enum.sort_by(& &1.path)

      assert env.total_bytes == Enum.sum(Enum.map(env.files, & &1.byte_size))
      assert env.total_bytes == ctx.v2.total_bytes
    end

    test "prototype_files on an explicit older version", ctx do
      assert {:ok, env} =
               read(
                 "prototype_files",
                 %{"prototype_id" => ctx.proto.id, "version" => 1},
                 ctx.reader_ctx
               )

      assert env.version == 1 and env.latest_version == 2
      assert env.total == 6
      assert Enum.map(env.files, & &1.path) |> Enum.sort() == Enum.sort(Map.keys(ctx.files))
      assert env.total_bytes == ctx.v1.total_bytes
      refute "secret.txt" in Enum.map(env.files, & &1.path)
    end

    test "prototype_file_get: text inline and binary base64 round-trip the published bytes",
         ctx do
      for {path, expected} <- [
            {"index.html", ctx.files["index.html"]["content"]},
            {"app.js", ctx.files["app.js"]["content"]},
            {"app.css", ctx.files["app.css"]["content"]},
            {"img/mark.svg", ctx.svg}
          ] do
        assert {:ok, r} =
                 read(
                   "prototype_file_get",
                   %{"prototype_id" => ctx.proto.id, "version" => 1, "path" => path},
                   ctx.reader_ctx
                 )

        assert r.content == expected, path
        refute Map.has_key?(r, :content_base64)
        assert r.sha256 == Prototypes.sha256_hex(expected)
        assert r.byte_size == byte_size(expected)
        assert r.version == 1 and r.path == path
      end

      assert {:ok, png} =
               read(
                 "prototype_file_get",
                 %{"prototype_id" => ctx.proto.id, "version" => 1, "path" => "img/logo.png"},
                 ctx.reader_ctx
               )

      refute Map.has_key?(png, :content)
      assert Base.decode64!(png.content_base64) == ctx.png
      assert png.sha256 == Prototypes.sha256_hex(ctx.png)
      assert png.content_type == "image/png"
    end

    test "prototype_file_get defaults to latest", ctx do
      assert {:ok, r} =
               read(
                 "prototype_file_get",
                 %{"prototype_id" => ctx.proto.id, "path" => "secret.txt"},
                 ctx.reader_ctx
               )

      assert r.version == 2 and r.content == "v2 only"
    end

    test "a retention-removed or unknown version is version_not_found", ctx do
      Repo.update_all(
        from(v in Platform.Prototypes.Version, where: v.id == ^ctx.v1.id),
        set: [removed_at: DateTime.utc_now()]
      )

      for args <- [
            %{"prototype_id" => ctx.proto.id, "version" => 1},
            %{"prototype_id" => ctx.proto.id, "version" => 99}
          ] do
        assert {:error, %{code: :version_not_found, recoverable: true}} =
                 read("prototype_files", args, ctx.reader_ctx)

        assert {:error, %{code: :version_not_found}} =
                 read("prototype_file_get", Map.put(args, "path", "index.html"), ctx.reader_ctx)
      end
    end

    test "a chat.read deny on the prototype's space reads exactly like an unknown id", ctx do
      args = %{"prototype_id" => ctx.proto.id}
      fargs = Map.put(args, "path", "index.html")
      assert {:ok, _} = read("prototype_files", args, ctx.reader_ctx)
      assert {:ok, _} = read("prototype_file_get", fargs, ctx.reader_ctx)

      deny!(ctx.reader, "chat.read", ctx.space)

      for {tool, a} <- [{"prototype_files", args}, {"prototype_file_get", fargs}] do
        denied = read(tool, a, ctx.reader_ctx)
        assert {:error, %{code: :not_found}} = denied
        assert scrub(denied, ctx.proto.id) == random_envelope(tool, a, ctx.reader_ctx)
        refute inspect(denied) =~ "index.html"
      end
    end

    test "a canvas.read deny on the prototype's canvas reads exactly like an unknown id", ctx do
      args = %{"prototype_id" => ctx.embed_id}
      fargs = Map.put(args, "path", "index.html")

      assert {:ok, %{content: "<!doctype html><p>embed</p>"}} =
               read("prototype_file_get", fargs, ctx.reader_ctx)

      deny!(ctx.reader, "canvas.read", ctx.canvas)

      for {tool, a} <- [{"prototype_files", args}, {"prototype_file_get", fargs}] do
        denied = read(tool, a, ctx.reader_ctx)
        assert {:error, %{code: :not_found}} = denied
        assert scrub(denied, ctx.embed_id) == random_envelope(tool, a, ctx.reader_ctx)
      end

      # The deny names the canvas only: the space-scoped bundle still reads.
      assert {:ok, _} = read("prototype_files", %{"prototype_id" => ctx.proto.id}, ctx.reader_ctx)
    end

    test "an agent of another tenant org reads exactly like an unknown id", ctx do
      args = %{"prototype_id" => ctx.proto.id}
      fargs = Map.put(args, "path", "index.html")

      for {tool, a} <- [{"prototype_files", args}, {"prototype_file_get", fargs}] do
        denied = read(tool, a, ctx.outsider_ctx)
        assert {:error, %{code: :not_found}} = denied
        assert scrub(denied, ctx.proto.id) == random_envelope(tool, a, ctx.outsider_ctx)
      end
    end

    test "no resolvable caller scope fails closed as not_found", ctx do
      args = %{"prototype_id" => ctx.proto.id}
      ctx_no_runtime = %{agent_id: ctx.reader.id}
      denied = read("prototype_files", args, ctx_no_runtime)
      assert {:error, %{code: :not_found}} = denied

      assert scrub(denied, ctx.proto.id) ==
               random_envelope("prototype_files", args, ctx_no_runtime)
    end

    test "forged and traversal paths are refused without a storage read", ctx do
      spy_storage!()

      # Positive control: the spy sees a legitimate read.
      assert {:ok, _} =
               read(
                 "prototype_file_get",
                 %{"prototype_id" => ctx.proto.id, "version" => 1, "path" => "index.html"},
                 ctx.reader_ctx
               )

      assert_received {:storage_read, _}

      for path <- [
            "../2/secret.txt",
            "../4/index.html",
            "/etc/passwd",
            "a/../index.html",
            "index.html%00",
            "index.html" <> <<0>>,
            "./index.html",
            "a\\..\\index.html",
            "img\\logo.png",
            "secret.txt",
            ""
          ] do
        result =
          read(
            "prototype_file_get",
            %{"prototype_id" => ctx.proto.id, "version" => 1, "path" => path},
            ctx.reader_ctx
          )

        assert {:error, %{code: code}} = result, inspect(path)

        assert code in [:invalid_path, :file_not_found, :invalid_argument],
               "#{inspect(path)} -> #{inspect(code)}"

        refute inspect(result) =~ "v2 only"
        refute_received {:storage_read, _}, "#{inspect(path)} reached storage"
      end
    end

    test "a path present only in ANOTHER version's manifest is file_not_found", ctx do
      spy_storage!()

      assert {:error, %{code: :file_not_found, recoverable: true}} =
               read(
                 "prototype_file_get",
                 %{"prototype_id" => ctx.proto.id, "version" => 1, "path" => "secret.txt"},
                 ctx.reader_ctx
               )

      refute_received {:storage_read, _}
    end

    test "stored bytes that do not match the manifest sha256 are storage_failed", ctx do
      entry = Platform.Prototypes.Version.file(ctx.v1, "app.js")
      path = Platform.Chat.AttachmentStorage.Adapter.LocalDisk.path_for(entry["storage_key"])
      File.write!(path, "document.title = 'tampered';")

      assert {:error, %{code: :storage_failed} = env} =
               read(
                 "prototype_file_get",
                 %{"prototype_id" => ctx.proto.id, "version" => 1, "path" => "app.js"},
                 ctx.reader_ctx
               )

      refute inspect(env) =~ "tampered"
    end

    test "a file over the 25 MiB cap is file_too_large before any read", ctx do
      spy_storage!()

      manifest =
        Enum.map(ctx.v1.manifest, fn
          %{"path" => "app.js"} = e -> Map.put(e, "byte_size", 25 * 1024 * 1024 + 1)
          e -> e
        end)

      Repo.update_all(
        from(v in Platform.Prototypes.Version, where: v.id == ^ctx.v1.id),
        set: [manifest: manifest]
      )

      assert {:error, %{code: :file_too_large}} =
               read(
                 "prototype_file_get",
                 %{"prototype_id" => ctx.proto.id, "version" => 1, "path" => "app.js"},
                 ctx.reader_ctx
               )

      refute_received {:storage_read, _}
    end
  end
end
