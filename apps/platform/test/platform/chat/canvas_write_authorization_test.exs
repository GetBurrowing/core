defmodule Platform.Chat.CanvasWriteAuthorizationTest do
  @moduledoc """
  Stage 2 of task 019e2c4b — canvas WRITE authorization, at the seams that
  callers actually reach.

  `Platform.Chat.CanvasAccessTest` covers the rule itself. This module covers
  the three doors in front of it:

    * `Chat.patch_canvas/3` and `Chat.update_canvas/3` — the context functions
    * `Chat.Canvas.ToolHandlers.patch/2` — the MCP `canvas_patch` tool, which
      reaches `Canvas.Server.apply_patches/3` WITHOUT going through
      `Chat.patch_canvas/3` and was therefore the actual hole

  The load-bearing assertion in every "rejected" case is that the canvas
  document is UNCHANGED afterwards. A denial that still writes is not a denial.
  """

  use Platform.DataCase, async: false

  import Platform.ExternalUserFixtures

  alias Ecto.UUID
  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.Canvas.ToolHandlers
  alias Platform.Tasks
  alias Platform.Tasks.CanvasAttachments
  alias Platform.Tenancy

  setup do
    %{org_a: Tenancy.get_org_by_slug!("globex")}
  end

  # ── Builders ──────────────────────────────────────────────────────────────

  defp space!(attrs) do
    n = System.unique_integer([:positive, :monotonic])
    default = %{name: "CW Space #{n}", slug: "cw-space-#{n}", kind: "channel"}
    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  defp document do
    %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{"gap" => 12},
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
  end

  # The author is a throwaway participant distinct from any actor under test —
  # an author who happened to be the actor would hand the case a free grant.
  defp canvas!(space) do
    author = add_user!(space.id, create_user!().id)

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => author.id,
        "title" => "CW Canvas #{System.unique_integer([:positive])}",
        "document" => document()
      })

    canvas
  end

  defp rename_op, do: [{:set_props, "h", %{"value" => "Rewritten", "level" => 2}}]

  defp patch_args(canvas_id) do
    %{
      "canvas_id" => canvas_id,
      "base_revision" => 1,
      "operations" => [["set_props", "h", %{"value" => "Rewritten", "level" => 2}]]
    }
  end

  # Reads the PERSISTED row. Correct for denial assertions — nothing should
  # have been written — but not for success assertions: `apply_patches/3`
  # persists asynchronously, so a fresh read can still show the old document.
  defp heading_value(canvas_id) do
    Chat.get_canvas(canvas_id).document["root"]["children"]
    |> List.first()
    |> get_in(["props", "value"])
  end

  # Reads the canvas server's authoritative in-memory document. Use this to
  # assert a write LANDED.
  defp served_heading_value(canvas_id) do
    {:ok, %{document: document}} = CanvasServer.describe(canvas_id)

    document["root"]["children"]
    |> List.first()
    |> get_in(["props", "value"])
  end

  defp task_in!(org) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "CW Project #{System.unique_integer([:positive])}",
        org_id: org.id
      })

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "CW Task"})
    task
  end

  # ── Chat.patch_canvas/3 ───────────────────────────────────────────────────

  describe "Chat.patch_canvas/3" do
    test "a space participant patches successfully", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      user = create_user!()
      add_user!(space.id, user.id)
      on_exit(fn -> CanvasServer.stop(canvas.id) end)

      assert {:ok, _updated} = Chat.patch_canvas({:user, user.id}, canvas, rename_op())
      assert served_heading_value(canvas.id) == "Rewritten"
    end

    test "an agent participant patches successfully", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      agent_id = UUID.generate()
      add_agent!(space.id, agent_id)
      on_exit(fn -> CanvasServer.stop(canvas.id) end)

      assert {:ok, _updated} = Chat.patch_canvas({:agent, agent_id}, canvas, rename_op())
      assert served_heading_value(canvas.id) == "Rewritten"
    end

    test "the :system actor patches successfully — today's behavior preserved", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      on_exit(fn -> CanvasServer.stop(canvas.id) end)

      assert {:ok, _updated} = Chat.patch_canvas(:system, canvas, rename_op())
      assert served_heading_value(canvas.id) == "Rewritten"
    end

    test "an :org_reader is rejected and the document is untouched", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      user = create_user!()
      plain_member!(user, org_a)

      assert {:error, :forbidden} = Chat.patch_canvas({:user, user.id}, canvas, rename_op())
      assert heading_value(canvas.id) == "Original"
    end

    test "a :task_reader is rejected and the document is untouched", %{org_a: org_a} do
      # The incident shape: canvas in an execution space, attached to a task
      # whose project org the viewer belongs to.
      canvas = canvas!(space!(%{kind: "execution", org_id: nil}))
      task = task_in!(org_a)

      {:ok, _} =
        CanvasAttachments.attach_canvas(:system, task.id, canvas.id,
          attached_by: %{kind: "user", id: UUID.generate()}
        )

      user = create_user!()
      plain_member!(user, org_a)

      assert {:error, :forbidden} = Chat.patch_canvas({:user, user.id}, canvas, rename_op())
      assert heading_value(canvas.id) == "Original"
    end

    test "a stranger with no grant at all is rejected", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))

      assert {:error, :forbidden} =
               Chat.patch_canvas({:user, create_user!().id}, canvas, rename_op())

      assert heading_value(canvas.id) == "Original"
    end

    test "an unidentified actor is rejected", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))

      assert {:error, :forbidden} = Chat.patch_canvas(nil, canvas, rename_op())
      assert heading_value(canvas.id) == "Original"
    end

    # Ordering matters for the error a caller sees: a member writing into an
    # archived space should hear about the archive, not about permissions.
    test "the archived-space rejection fires AHEAD of the authorization check", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      user = create_user!()
      add_user!(space.id, user.id)
      {:ok, _} = Chat.archive_space(space)

      assert {:error, :space_archived} = Chat.patch_canvas({:user, user.id}, canvas, rename_op())

      # And it still wins for an actor who would ALSO have failed authz —
      # proving the order is the archive check, not a coincidence of outcome.
      assert {:error, :space_archived} =
               Chat.patch_canvas({:user, create_user!().id}, canvas, rename_op())
    end
  end

  # ── Chat.update_canvas/3 ──────────────────────────────────────────────────

  describe "Chat.update_canvas/3" do
    test "a space participant updates the title", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      user = create_user!()
      add_user!(space.id, user.id)

      assert {:ok, updated} =
               Chat.update_canvas({:user, user.id}, canvas, %{"title" => "Renamed"})

      assert updated.title == "Renamed"
    end

    test "the :system actor updates the title", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))

      assert {:ok, updated} = Chat.update_canvas(:system, canvas, %{"title" => "Renamed"})
      assert updated.title == "Renamed"
    end

    test "an :org_reader is rejected and the title is untouched", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      user = create_user!()
      plain_member!(user, org_a)

      assert {:error, :forbidden} =
               Chat.update_canvas({:user, user.id}, canvas, %{"title" => "Renamed"})

      assert Chat.get_canvas(canvas.id).title == canvas.title
    end

    test "the archived-space rejection fires AHEAD of the authorization check", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      {:ok, _} = Chat.archive_space(space)

      assert {:error, :space_archived} =
               Chat.update_canvas({:user, create_user!().id}, canvas, %{"title" => "Renamed"})
    end
  end

  # ── MCP canvas_patch ──────────────────────────────────────────────────────
  #
  # This handler reaches `Canvas.Server.apply_patches/3` directly, so it is NOT
  # covered by the `Chat.patch_canvas/3` gate above. Before stage 2 it ignored
  # its context entirely and would patch any canvas id in any space in any org.

  describe "ToolHandlers.patch/2 — the MCP canvas_patch tool" do
    test "a participating agent still writes", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      agent_id = UUID.generate()
      add_agent!(space.id, agent_id)
      on_exit(fn -> CanvasServer.stop(canvas.id) end)

      assert {:ok, payload} =
               ToolHandlers.patch(patch_args(canvas.id), %{agent_id: agent_id})

      assert payload.revision == 2
      assert served_heading_value(canvas.id) == "Rewritten"
    end

    test "a participating user still writes", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      user = create_user!()
      add_user!(space.id, user.id)
      on_exit(fn -> CanvasServer.stop(canvas.id) end)

      assert {:ok, _payload} = ToolHandlers.patch(patch_args(canvas.id), %{user_id: user.id})
      assert served_heading_value(canvas.id) == "Rewritten"
    end

    test "an agent in ANOTHER space cannot patch by canvas id", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      other_space = space!(%{org_id: org_a.id})
      agent_id = UUID.generate()
      add_agent!(other_space.id, agent_id)

      assert {:error, payload} = ToolHandlers.patch(patch_args(canvas.id), %{agent_id: agent_id})
      assert payload.recoverable == false
      assert payload.error =~ "Access denied"
      assert heading_value(canvas.id) == "Original"
    end

    test "an org member who is not in the space cannot patch", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      user = create_user!()
      plain_member!(user, org_a)

      assert {:error, payload} = ToolHandlers.patch(patch_args(canvas.id), %{user_id: user.id})
      assert payload.error =~ "does not confer write access"
      assert heading_value(canvas.id) == "Original"
    end

    test "a caller with no identity is rejected rather than treated as :system", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))

      assert {:error, payload} = ToolHandlers.patch(patch_args(canvas.id), %{})
      assert payload.recoverable == false
      assert heading_value(canvas.id) == "Original"
    end

    test "an unknown canvas id reports not-found, not access-denied" do
      assert {:error, payload} =
               ToolHandlers.patch(patch_args(UUID.generate()), %{agent_id: UUID.generate()})

      assert payload.error =~ "not found"
    end

    # Shape errors are raised before the gate so a malformed call hears about
    # its shape, and so the denial cannot be probed with junk operations.
    test "a malformed operation is still reported as a shape error", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))

      args = %{
        "canvas_id" => canvas.id,
        "base_revision" => 1,
        "operations" => [["upsert_node", "whatever"]]
      }

      assert {:error, payload} = ToolHandlers.patch(args, %{})
      assert payload.error =~ "unrecognized"
    end
  end
end
