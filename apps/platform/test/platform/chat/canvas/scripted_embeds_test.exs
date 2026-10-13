defmodule Platform.Chat.Canvas.ScriptedEmbedsTest do
  @moduledoc """
  `scripts: true` embeds run as canvas-owned single-file prototypes (task
  01a1316b-677a stage 1): the stamp on every write path, the version reuse
  rules, forged refs, the settings gate, restore, retention, the refusal of
  `prototype_publish` / `prototype_rollback`, and the sealed serve route.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.PrototypeFixtures
  import Platform.TenancyFixtures

  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.Canvas.ToolHandlers
  alias Platform.Chat.CanvasDocument
  alias Platform.Prototypes
  alias Platform.Prototypes.Prototype
  alias Platform.Prototypes.Purger
  alias Platform.Prototypes.Version
  alias Platform.Repo

  @counter_v1 """
  <!doctype html><html><body><button id="inc">+</button><span id="n">0</span>
  <script>document.getElementById('inc').onclick=()=>{const n=document.getElementById('n');n.textContent=+n.textContent+1}</script>
  </body></html>
  """

  @counter_v2 String.replace(@counter_v1, ">+</button>", ">add</button>")

  setup do
    prev_sync = Application.get_env(:platform, :canvas_persist_sync)
    Application.put_env(:platform, :canvas_persist_sync, true)
    on_exit(fn -> Application.put_env(:platform, :canvas_persist_sync, prev_sync) end)

    scratch_storage!("scripted_embeds_test")
    set_settings!(%{enabled: true, who_may_publish: "admins", retention_days: 90})

    org_id = tenant_org_id("scripted-embed-#{System.unique_integer([:positive])}")
    space = space!(org_id)
    author = participant!(space)

    {:ok, org_id: org_id, space: space, author: author}
  end

  defp space!(org_id) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{name: "SE #{n}", slug: "se-#{n}", kind: "channel", org_id: org_id})

    space
  end

  defp participant!(space, type \\ "agent") do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: type,
        participant_id: Ecto.UUID.generate(),
        display_name: "Author",
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp embed(id, srcdoc, extra \\ %{}),
    do: %{
      "id" => id,
      "type" => "embed",
      "props" => Map.merge(%{"srcdoc" => srcdoc, "scripts" => true}, extra)
    }

  defp text(id, value),
    do: %{"id" => id, "type" => "text", "props" => %{"value" => value}, "children" => []}

  defp doc(children) do
    CanvasDocument.new() |> put_in(["root", "children"], children)
  end

  defp create!(ctx, children) do
    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => ctx.space.id,
        "created_by" => ctx.author.id,
        "title" => "Scripted",
        "document" => doc(children)
      })

    on_exit(fn -> CanvasServer.stop(canvas.id) end)
    canvas
  end

  defp node_props(canvas_id, node_id) do
    {:ok, %{document: doc}} = CanvasServer.describe(canvas_id)
    CanvasDocument.get_node(doc, node_id)["props"]
  end

  defp ref(canvas_id, node_id), do: node_props(canvas_id, node_id)["prototype_ref"]

  defp versions(prototype_id),
    do:
      Repo.all(from(v in Version, where: v.prototype_id == ^prototype_id, select: v.version))
      |> Enum.sort()

  defp apply_ops(canvas_id, ops) do
    {:ok, %{revision: rev}} = CanvasServer.describe(canvas_id)
    CanvasServer.apply_patches(canvas_id, ops, rev, %{type: "agent", id: "a"})
  end

  describe "stamping" do
    test "create publishes v1 and stamps the ref, in the stored row and its version", ctx do
      canvas = create!(ctx, [embed("e1", @counter_v1)])

      stored = Chat.get_canvas(canvas.id)
      ref = CanvasDocument.get_node(stored.document, "e1")["props"]["prototype_ref"]

      assert %{"prototype_id" => id, "version" => 1, "sha256" => sha} = ref
      assert sha == Prototypes.sha256_hex(@counter_v1)

      prototype = Prototypes.get_prototype(id)
      assert prototype.canvas_id == canvas.id
      assert prototype.canvas_node_id == "e1"
      assert prototype.org_id == ctx.org_id
      assert Prototype.canvas_owned?(prototype)

      [row] = Prototypes.list_versions(prototype)
      assert [%{"path" => "index.html", "content_type" => "text/html"}] = row.manifest
      assert row.published_by["kind"] == "canvas_embed"

      # The history row for revision 1 carries the stamped document, so a
      # later restore of it points at this version.
      [history] = Platform.Chat.Canvas.Versions.list_for_canvas(canvas.id)

      assert get_in(history.document, ["root", "children", Access.at(0), "props", "prototype_ref"]) ==
               ref

      # who_may_publish is "admins" and the author is an agent participant
      # with no owner: the canvas write is the authorization, not the policy.
      assert ref(canvas.id, "e1") == ref
    end

    test "re-patching identical HTML creates no version; changed HTML creates v2", ctx do
      canvas = create!(ctx, [embed("e1", @counter_v1)])
      %{"prototype_id" => id} = ref(canvas.id, "e1")

      assert {:ok, _} = apply_ops(canvas.id, [{:set_props, "e1", %{"srcdoc" => @counter_v1}}])
      assert ref(canvas.id, "e1")["version"] == 1
      assert versions(id) == [1]

      # Same check after a server restart, when the verified-ref cache is
      # empty and the lookup has to go to the database.
      CanvasServer.stop(canvas.id)
      assert {:ok, _} = apply_ops(canvas.id, [{:set_props, "e1", %{"height" => 300}}])
      assert ref(canvas.id, "e1")["version"] == 1
      assert versions(id) == [1]

      assert {:ok, _} = apply_ops(canvas.id, [{:set_props, "e1", %{"srcdoc" => @counter_v2}}])
      assert %{"prototype_id" => ^id, "version" => 2} = ref(canvas.id, "e1")
      assert versions(id) == [1, 2]

      # v1 is still there to serve.
      assert %Version{} = Prototypes.get_live_version(id, 1)
    end

    test "a forged ref on a scripted embed is overwritten with the node's own", ctx do
      canvas = create!(ctx, [embed("e1", @counter_v1)])
      own = ref(canvas.id, "e1")

      other = create!(ctx, [embed("x", "<p>other</p><script>1</script>")])
      forged = ref(other.id, "x")
      assert forged["prototype_id"] != own["prototype_id"]

      assert {:ok, _} = apply_ops(canvas.id, [{:set_props, "e1", %{"prototype_ref" => forged}}])
      assert ref(canvas.id, "e1") == own

      # Also on a cold server (no cache) and on create.
      CanvasServer.stop(canvas.id)
      assert {:ok, _} = apply_ops(canvas.id, [{:set_props, "e1", %{"prototype_ref" => forged}}])
      assert ref(canvas.id, "e1") == own

      fresh = create!(ctx, [embed("e1", @counter_v1, %{"prototype_ref" => forged})])
      fresh_ref = ref(fresh.id, "e1")
      assert fresh_ref["prototype_id"] not in [forged["prototype_id"], own["prototype_id"]]
    end

    test "a ref on a non-scripted embed is stripped on create and on patch", ctx do
      forged = %{"prototype_id" => Ecto.UUID.generate(), "version" => 1, "sha256" => "x"}

      plain = %{
        "id" => "p1",
        "type" => "embed",
        "props" => %{"srcdoc" => "<p>static</p>", "prototype_ref" => forged}
      }

      canvas = create!(ctx, [plain])
      refute Map.has_key?(node_props(canvas.id, "p1"), "prototype_ref")

      refute Map.has_key?(
               CanvasDocument.get_node(Chat.get_canvas(canvas.id).document, "p1")["props"],
               "prototype_ref"
             )

      assert {:ok, _} = apply_ops(canvas.id, [{:set_props, "p1", %{"prototype_ref" => forged}}])
      refute Map.has_key?(node_props(canvas.id, "p1"), "prototype_ref")

      # Turning scripts off strips the ref of a formerly scripted node too.
      scripted = create!(ctx, [embed("e1", "<p>x</p>")])
      assert ref(scripted.id, "e1")

      assert {:ok, _} =
               apply_ops(scripted.id, [{:set_props, "e1", %{"scripts" => false}}])

      refute Map.has_key?(node_props(scripted.id, "e1"), "prototype_ref")
    end

    test "create_canvas_with_message and update_canvas stamp too", ctx do
      {:ok, canvas, _message} =
        Chat.create_canvas_with_message(ctx.space.id, ctx.author.id, %{
          "title" => "M",
          "document" => doc([embed("e1", @counter_v1)])
        })

      on_exit(fn -> CanvasServer.stop(canvas.id) end)

      assert %{"version" => 1} =
               CanvasDocument.get_node(canvas.document, "e1")["props"]["prototype_ref"]

      {:ok, updated} =
        Chat.update_canvas(:system, canvas, %{"document" => doc([embed("e1", @counter_v2)])})

      assert %{"version" => 2} =
               CanvasDocument.get_node(updated.document, "e1")["props"]["prototype_ref"]
    end

    test "canvas.restore to an old revision points back at that revision's version", ctx do
      canvas = create!(ctx, [embed("e1", @counter_v1)])
      {:ok, %{document: rev1_doc}} = CanvasServer.describe(canvas.id)

      assert {:ok, _} = apply_ops(canvas.id, [{:set_props, "e1", %{"srcdoc" => @counter_v2}}])
      assert ref(canvas.id, "e1")["version"] == 2

      assert {:ok, _} = apply_ops(canvas.id, [{:replace_document, rev1_doc}])
      assert ref(canvas.id, "e1")["version"] == 1
      assert versions(ref(canvas.id, "e1")["prototype_id"]) == [1, 2]
    end
  end

  describe "settings and org" do
    test "disabled: a new or changed scripted node is refused, other edits still work", ctx do
      canvas = create!(ctx, [embed("e1", @counter_v1), text("t", "hello")])
      %{"prototype_id" => id} = ref(canvas.id, "e1")

      set_settings!(%{enabled: false})

      assert {:error, %{code: "prototypes_disabled"}} =
               apply_ops(canvas.id, [{:set_props, "e1", %{"srcdoc" => @counter_v2}}])

      assert {:error, %{code: "prototypes_disabled"}} =
               apply_ops(canvas.id, [{:append_child, "root", embed("e2", "<b>new</b>")}])

      assert versions(id) == [1]
      assert node_props(canvas.id, "e1")["srcdoc"] == @counter_v1

      # Unrelated node: fine, warm and cold.
      assert {:ok, _} = apply_ops(canvas.id, [{:set_props, "t", %{"value" => "edited"}}])
      CanvasServer.stop(canvas.id)
      assert {:ok, _} = apply_ops(canvas.id, [{:set_props, "t", %{"value" => "again"}}])
      assert node_props(canvas.id, "t")["value"] == "again"
      assert ref(canvas.id, "e1")["version"] == 1

      # Create is refused and leaves no canvas behind.
      before = Repo.aggregate(Platform.Chat.Canvas, :count)

      assert {:error, %{code: "prototypes_disabled"}} =
               Chat.create_canvas(%{
                 "space_id" => ctx.space.id,
                 "created_by" => ctx.author.id,
                 "document" => doc([embed("e1", "<i>x</i>")])
               })

      assert Repo.aggregate(Platform.Chat.Canvas, :count) == before
    end

    test "canvas.create and canvas.patch surface the code, recoverable", ctx do
      context = %{space_id: ctx.space.id, agent_participant_id: ctx.author.id, agent_id: nil}
      set_settings!(%{enabled: false})

      assert {:error, %{code: "prototypes_disabled", recoverable: true, error: msg}} =
               ToolHandlers.create(
                 %{"space_id" => ctx.space.id, "document" => doc([embed("e1", "<i>x</i>")])},
                 context
               )

      assert msg =~ "/admin/prototypes"
    end

    test "a space with no org cannot hold a scripted embed", _ctx do
      {:ok, orgless} =
        Chat.create_space(%{
          name: "No org",
          slug: "se-noorg-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      assert orgless.org_id == nil
      p = participant!(orgless)

      assert {:error, %{code: "scripted_embed_requires_org"}} =
               Chat.create_canvas(%{
                 "space_id" => orgless.id,
                 "created_by" => p.id,
                 "document" => doc([embed("e1", "<i>x</i>")])
               })

      # A plain embed in the same space is untouched by the stamp.
      assert {:ok, _} =
               Chat.create_canvas(%{
                 "space_id" => orgless.id,
                 "created_by" => p.id,
                 "document" =>
                   doc([%{"id" => "p", "type" => "embed", "props" => %{"srcdoc" => "<p>x</p>"}}])
               })
    end
  end

  describe "prototype tools against a canvas-owned prototype" do
    test "publish and rollback are refused with canvas_owned", ctx do
      canvas = create!(ctx, [embed("e1", @counter_v1)])
      prototype = Prototypes.get_prototype(ref(canvas.id, "e1")["prototype_id"])
      agent = agent!()

      assert {:error, {:canvas_owned, _}} =
               Prototypes.publish(
                 agent_publisher(agent),
                 %{prototype: prototype},
                 {:files, bundle_files("hostile")}
               )

      assert {:error, {:canvas_owned, _}} =
               Prototypes.rollback(agent_publisher(agent), prototype, 1)

      assert {:error, %{code: :canvas_owned, recoverable: false}} =
               Prototypes.Tools.execute(
                 "prototype.publish",
                 %{"prototype_id" => prototype.id, "files" => bundle_files("hostile")},
                 %{agent_id: agent.id, agent_home_org: :root}
               )

      assert versions(prototype.id) == [1]
    end
  end

  describe "retention" do
    setup ctx do
      canvas = create!(ctx, [embed("e1", @counter_v1)])
      assert {:ok, _} = apply_ops(canvas.id, [{:set_props, "e1", %{"srcdoc" => @counter_v2}}])
      %{"prototype_id" => id} = ref(canvas.id, "e1")

      old = DateTime.add(DateTime.utc_now(), -100, :day)
      Repo.update_all(from(v in Version, where: v.prototype_id == ^id), set: [inserted_at: old])

      {:ok, canvas: canvas, prototype_id: id}
    end

    defp removed(id),
      do:
        Repo.all(from(v in Version, where: v.prototype_id == ^id, order_by: v.version))
        |> Enum.map(&{&1.version, not is_nil(&1.removed_at)})

    test "a live canvas keeps every version however old", ctx do
      assert {:ok, 0} = Purger.sweep()
      assert removed(ctx.prototype_id) == [{1, false}, {2, false}]
    end

    test "after a soft delete the ordinary rule applies", ctx do
      {:ok, _} = Chat.delete_canvas(Chat.get_canvas(ctx.canvas.id))
      assert {:ok, 1} = Purger.sweep()
      assert removed(ctx.prototype_id) == [{1, true}, {2, false}]
    end
  end

  describe "serving" do
    test "the embed's version serves sealed to an org member", ctx do
      canvas = create!(ctx, [embed("e1", @counter_v1)])
      %{"prototype_id" => id, "version" => 1} = ref(canvas.id, "e1")

      member = user!("Viewer")
      member!(member, ctx.org_id)

      conn =
        build_conn() |> init_test_session(current_user_id: member.id) |> get("/proto/#{id}/1/")

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      assert location =~ ~r{^/proto/#{id}/1/g/[^/]+/index\.html$}

      served = get(build_conn(), location)
      assert response(served, 200) == @counter_v1
      [csp] = get_resp_header(served, "content-security-policy")
      assert csp =~ "sandbox allow-scripts;"
      assert csp =~ "connect-src 'none'"
      refute csp =~ "allow-same-origin"
    end
  end
end
