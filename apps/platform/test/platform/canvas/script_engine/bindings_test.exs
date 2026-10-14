defmodule Platform.Canvas.ScriptEngine.BindingsTest do
  @moduledoc """
  Task 01a1316b-aab0 stage 1: a canvas handler's host bindings act as the
  handler's PRINCIPAL on its OWNING canvas, and only registered bindings
  exist.

  Anti-vacuity target: replace the principal with `:system` in
  `Bindings.canvas_patch/2`. "a viewer holding only a read grant is refused"
  must then fail, because the write lands.
  """

  use Platform.DataCase, async: false

  import Platform.CodeModeFixtures, only: [insert_agent!: 0, insert_runtime!: 2, bundles: 1]
  import Platform.ExternalUserFixtures

  alias Platform.Canvas.ScriptEngine
  alias Platform.Canvas.ScriptEngine.Bindings
  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Tenancy

  @rename ~s([["set_props", "h", {"value": "Rewritten", "level": 2}]])

  setup do
    org = Tenancy.get_org_by_slug!("sxi")
    space = space!(org)
    canvas = canvas!(space)
    on_exit(fn -> CanvasServer.stop(canvas.id) end)
    %{org: org, space: space, canvas: canvas}
  end

  defp space!(org) do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, space} =
      Chat.create_space(%{
        name: "SE Space #{n}",
        slug: "se-space-#{n}",
        kind: "channel",
        org_id: org.id
      })

    space
  end

  defp canvas!(space) do
    author = add_user!(space.id, create_user!().id)

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => author.id,
        "title" => "SE Canvas #{System.unique_integer([:positive])}",
        "document" => %{
          "version" => 1,
          "revision" => 1,
          "root" => %{
            "id" => "root",
            "type" => "stack",
            "props" => %{},
            "children" => [
              %{
                "id" => "h",
                "type" => "heading",
                "props" => %{"value" => "Original", "level" => 2},
                "children" => []
              }
            ]
          },
          "theme" => %{},
          "bindings" => %{},
          "meta" => %{}
        }
      })

    canvas
  end

  defp user_actor(user), do: %{type: "user", id: user.id, display_name: user.name}

  defp run(source, canvas, actor, extra \\ %{}) do
    ScriptEngine.run(
      %{"name" => "h", "engine" => "js", "source" => source},
      %{"type" => "call", "args" => %{}},
      %{"keys" => %{}, "collections" => %{}},
      Map.merge(%{canvas_id: canvas.id, actor: actor, now: 0}, extra)
    )
  end

  # Records the binding's response (or the error it threw) as ops, so a test
  # can read the kind and code a refusal carried.
  defp probe(call) do
    """
    (e, ctx) => {
      try { const r = #{call}; ctx.set('ok', true); ctx.set('data', r); }
      catch (err) { ctx.set('ok', false); ctx.set('kind', err.kind); ctx.set('code', err.code); }
    }
    """
  end

  defp values(ops), do: Map.new(ops, &{&1["key"], &1["value"]})

  defp served(canvas_id) do
    {:ok, %{document: doc, revision: revision}} = CanvasServer.describe(canvas_id)
    {get_in(doc, ["root", "children", Access.at(0), "props", "value"]), revision}
  end

  defp persisted_heading(canvas_id) do
    Chat.get_canvas(canvas_id).document["root"]["children"]
    |> List.first()
    |> get_in(["props", "value"])
  end

  describe "canvas.patch as a user principal" do
    test "a space member patches the owning canvas and the revision bumps", %{
      space: space,
      canvas: canvas
    } do
      user = create_user!()
      add_user!(space.id, user.id)
      {"Original", before} = served(canvas.id)

      assert {:ok, ops, []} = run(probe("ctx.patch(#{@rename})"), canvas, user_actor(user))
      assert %{"ok" => true, "data" => %{"canvas_id" => id, "revision" => rev}} = values(ops)
      assert id == canvas.id

      assert {"Rewritten", ^rev} = served(canvas.id)
      assert rev > before
    end

    test "a viewer holding only a read grant is refused and the document is unchanged", %{
      org: org,
      canvas: canvas
    } do
      reader = create_user!()
      plain_member!(reader, org)

      # The precondition: the reader CAN read this canvas (org_reader).
      assert {:ok, _canvas, :org_reader} =
               Platform.Chat.CanvasAccess.fetch_for_viewer(canvas.id, {:user, reader.id},
                 audit: false
               )

      {"Original", before} = served(canvas.id)

      assert {:ok, ops, []} = run(probe("ctx.patch(#{@rename})"), canvas, user_actor(reader))
      assert %{"ok" => false, "kind" => "forbidden", "code" => "forbidden"} = values(ops)

      assert {"Original", ^before} = served(canvas.id)
      assert persisted_heading(canvas.id) == "Original"

      # Uncaught, the run ends forbidden.
      assert {:error, "forbidden", _} =
               run("(e, ctx) => { ctx.patch(#{@rename}) }", canvas, user_actor(reader))

      assert {"Original", ^before} = served(canvas.id)
    end

    test "a stranger and a missing actor are refused", %{canvas: canvas} do
      assert {:error, "forbidden", _} =
               run("(e, ctx) => { ctx.patch(#{@rename}) }", canvas, user_actor(create_user!()))

      assert {:error, "forbidden", _} = run("(e, ctx) => { ctx.patch(#{@rename}) }", canvas, nil)
      assert {"Original", _} = served(canvas.id)
    end

    test "a canvas_id argument naming another canvas patches only the owning canvas", %{
      space: space,
      canvas: canvas
    } do
      # The member can write BOTH canvases, so honouring the argument would
      # visibly write the other one.
      other = canvas!(space)
      on_exit(fn -> CanvasServer.stop(other.id) end)
      user = create_user!()
      add_user!(space.id, user.id)
      {"Original", other_before} = served(other.id)

      call = "suite.call('canvas.patch', {canvas_id: '#{other.id}', operations: #{@rename}})"
      assert {:ok, ops, []} = run(probe(call), canvas, user_actor(user))
      assert %{"ok" => true, "data" => %{"canvas_id" => id}} = values(ops)
      assert id == canvas.id

      assert {"Rewritten", _} = served(canvas.id)
      assert {"Original", ^other_before} = served(other.id)
    end

    test "malformed operations are invalid_args and write nothing", %{
      space: space,
      canvas: canvas
    } do
      user = create_user!()
      add_user!(space.id, user.id)

      for call <- ["ctx.patch([])", "ctx.patch([['explode']])", "ctx.patch('nope')"] do
        assert {:ok, ops, []} = run(probe(call), canvas, user_actor(user))
        assert %{"ok" => false, "kind" => "invalid_args"} = values(ops)
      end

      assert {"Original", _} = served(canvas.id)
    end
  end

  describe "canvas.patch as an agent principal" do
    setup %{space: space} do
      agent = insert_agent!()
      add_agent!(space.id, agent.id)
      %{agent: agent, actor: %{type: "agent", id: agent.id, display_name: agent.name}}
    end

    test "a participant agent whose runtime holds canvas.patch patches", %{
      canvas: canvas,
      agent: agent,
      actor: actor
    } do
      {runtime, _token} = insert_runtime!(agent, bundles(["canvas"]))

      assert {:ok, ops, []} =
               run(probe("ctx.patch(#{@rename})"), canvas, actor, %{runtime: runtime})

      assert %{"ok" => true} = values(ops)
      assert {"Rewritten", _} = served(canvas.id)
    end

    test "no runtime is refused", %{canvas: canvas, actor: actor} do
      assert {:ok, ops, []} = run(probe("ctx.patch(#{@rename})"), canvas, actor)
      assert %{"ok" => false, "kind" => "forbidden", "code" => "no_active_runtime"} = values(ops)
      assert {"Original", _} = served(canvas.id)
    end

    test "a runtime without canvas.patch is refused", %{
      canvas: canvas,
      agent: agent,
      actor: actor
    } do
      {runtime, _token} = insert_runtime!(agent, bundles([]))

      assert {:ok, ops, []} =
               run(probe("ctx.patch(#{@rename})"), canvas, actor, %{runtime: runtime})

      assert %{"ok" => false, "kind" => "forbidden", "code" => "forbidden"} = values(ops)
      assert {"Original", _} = served(canvas.id)
    end

    test "another agent's runtime is refused", %{canvas: canvas, actor: actor} do
      {runtime, _token} = insert_runtime!(insert_agent!(), bundles(["canvas"]))

      assert {:ok, ops, []} =
               run(probe("ctx.patch(#{@rename})"), canvas, actor, %{runtime: runtime})

      assert %{"code" => "no_active_runtime"} = values(ops)
      assert {"Original", _} = served(canvas.id)
    end
  end

  describe "the registry" do
    test "canvas.patch is the only binding" do
      assert Bindings.names() == ["canvas.patch"]
    end

    test "unregistered names are forbidden / binding_not_registered", %{
      space: space,
      canvas: canvas
    } do
      user = create_user!()
      add_user!(space.id, user.id)

      for call <- [
            "suite.call('tasks.create', {title: 'x'})",
            "suite.call('chat.post_message', {content: 'x'})",
            "suite.call('suite_run', {script: '1'})",
            "store.set('k', 1)",
            "suite.call('canvas.create', {})"
          ] do
        assert {:ok, ops, []} = run(probe(call), canvas, user_actor(user))

        assert %{"ok" => false, "kind" => "forbidden", "code" => "binding_not_registered"} =
                 values(ops),
               call
      end

      assert {:error, "forbidden", message} =
               run(
                 "(e, ctx) => suite.call('tasks.create', {title: 'x'})",
                 canvas,
                 user_actor(user)
               )

      assert message =~ "binding_not_registered"
    end

    test "11 binding calls end call_limit at max_calls 10, even when caught", %{canvas: canvas} do
      source =
        "(e, ctx) => { for (let i = 0; i < 11; i++) { try { suite.call('x', {}) } catch (_) {} } }"

      assert {:error, "call_limit", _} = run(source, canvas, nil)

      source =
        "(e, ctx) => { for (let i = 0; i < 10; i++) { try { suite.call('x', {}) } catch (_) {} } }"

      assert {:ok, [], []} = run(source, canvas, nil)
    end
  end

  describe "principal/1" do
    test "is derived from the invocation's actor only" do
      assert Bindings.principal(%{actor: %{type: "user", id: "u1"}}) == {:user, "u1"}
      assert Bindings.principal(%{actor: %{"type" => "agent", "id" => "a1"}}) == {:agent, "a1"}
      assert Bindings.principal(%{actor: %{type: "system", id: "x"}}) == nil
      assert Bindings.principal(%{actor: nil}) == nil
      assert Bindings.principal(%{}) == nil
    end
  end
end
