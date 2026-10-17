defmodule Platform.Chat.Canvas.ToolAccessTest do
  @moduledoc """
  Stage 1 of task 019fb01b — the authorization seam the canvas MCP handlers
  route through.

  Three contracts are asserted here, because each one is a place a later stage
  could silently regress:

    * `actor/1` normalizes the federation context map the platform actually
      builds (`mcp_controller.ex` / `runtime_channel.ex`), and yields NO
      principal when the runtime has no linked agent. A nil `agent_id` is a
      reachable state, and it must not fall through to a grant.
    * `fetch_for_read/2` applies the READER's grant set with the WRITER's
      deletion rule. `CanvasAccess.fetch_for_viewer/3` deliberately hands
      soft-deleted canvases back to grant-holders so the LiveView can render
      "removed"; over MCP that would newly serve deleted documents, so the
      seam collapses them to not-found.
    * Denial payloads echo the caller-supplied `canvas_id` and nothing else.
      No title, no `space_id`, no org. The success payload leaks `space_id`
      today and the denial must not inherit it.
  """

  use Platform.DataCase, async: true

  # `except: [canvas!: 2]` — the fixture's `canvas!/2` takes `(space_id,
  # created_by)` and hardcodes the title. These cases need a canvas with a
  # title they can then assert is ABSENT from a denial payload, so the local
  # builder below takes overrides instead.
  import Platform.ExternalUserFixtures, except: [canvas!: 2]

  alias Ecto.UUID
  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Chat.Canvas.ToolAccess
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.CanvasAttachments
  alias Platform.Tenancy

  setup do
    %{org_a: Tenancy.get_org_by_slug!("sxi"), org_b: Tenancy.get_org_by_slug!("soylent")}
  end

  # ── Builders ──────────────────────────────────────────────────────────────

  defp space!(attrs \\ %{}) do
    n = System.unique_integer([:positive, :monotonic])
    default = %{name: "TA Space #{n}", slug: "ta-space-#{n}", kind: "channel"}
    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  # The author is a throwaway user distinct from any caller under test — an
  # author who happened to be the caller would hand the case a free `:member`.
  defp canvas!(space, overrides \\ %{}) do
    author = add_user!(space.id, create_user!().id)

    {:ok, canvas} =
      Chat.create_canvas(
        Map.merge(
          %{
            "space_id" => space.id,
            "created_by" => author.id,
            "title" => "Secret Canvas #{System.unique_integer([:positive])}"
          },
          overrides
        )
      )

    canvas
  end

  defp soft_delete_canvas!(canvas) do
    canvas
    |> Canvas.delete_changeset(%{deleted_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  defp task_in!(org) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "TA Project #{System.unique_integer([:positive])}",
        org_id: org.id
      })

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "TA Task"})
    task
  end

  defp attach!(task, canvas) do
    {:ok, attachment} =
      CanvasAttachments.attach_canvas(:system, task.id, canvas.id,
        attached_by: %{kind: "user", id: UUID.generate()}
      )

    attachment
  end

  # The exact shape `PlatformWeb.MCPController.build_context/2` and
  # `PlatformWeb.RuntimeChannel.execute_tool_call/4` construct. Written out in
  # full rather than as a minimal map, because the point of `actor/1` is that
  # it reads the real thing correctly.
  defp federation_context(space_id, agent_id, participant_id \\ nil) do
    %{
      space_id: space_id,
      agent_id: agent_id,
      agent_participant_id: participant_id,
      runtime_id: "runtime-#{System.unique_integer([:positive])}"
    }
  end

  # ── actor/1 ───────────────────────────────────────────────────────────────

  describe "actor/1" do
    test "a real federation context yields {:agent, id}" do
      agent_id = UUID.generate()
      space = space!()

      assert ToolAccess.actor(federation_context(space.id, agent_id)) == {:agent, agent_id}
    end

    test "a federation context with a nil agent_id yields NO principal" do
      # `agent_id` is a nullable :binary_id on Platform.Agents.AgentRuntime, so
      # an authenticated runtime with no linked agent reaches these handlers.
      # It must resolve to nil, never to a grant.
      assert ToolAccess.actor(federation_context(UUID.generate(), nil)) == nil
    end

    test "a user-driven context yields {:user, id}" do
      user_id = UUID.generate()

      assert ToolAccess.actor(%{user_id: user_id}) == {:user, user_id}
    end

    test "agent_id wins when both are present" do
      agent_id = UUID.generate()
      user_id = UUID.generate()

      assert ToolAccess.actor(%{agent_id: agent_id, user_id: user_id}) == {:agent, agent_id}
    end

    test "anything unusable yields nil" do
      for bogus <- [%{}, %{agent_id: nil, user_id: nil}, %{agent_id: 42}, nil, :system, "ctx"] do
        assert ToolAccess.actor(bogus) == nil, "expected no principal from #{inspect(bogus)}"
      end
    end
  end

  # ── fetch_for_read/2 — grants ─────────────────────────────────────────────

  describe "fetch_for_read/2 — grants" do
    test "an agent participant of the canvas's space reads it", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      agent_id = UUID.generate()
      add_agent!(space.id, agent_id)

      assert {:ok, %Canvas{id: id}} =
               ToolAccess.fetch_for_read(canvas.id, federation_context(space.id, agent_id))

      assert id == canvas.id
    end

    test "the READER grant set applies, not the writer's", %{org_a: org_a} do
      # A `:task_reader` may read but may not write. If the seam had been built
      # on `fetch_for_writer/2` for convenience, this would deny.
      space = space!(%{kind: "execution", org_id: nil})
      canvas = canvas!(space)
      task = task_in!(org_a)
      attach!(task, canvas)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:ok, %Canvas{}} = ToolAccess.fetch_for_read(canvas.id, %{user_id: user.id})
    end

    test "a non-participating agent is denied", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))

      assert {:error, payload} =
               ToolAccess.fetch_for_read(canvas.id, federation_context(nil, UUID.generate()))

      assert payload.recoverable == false
    end

    test "a nil-agent runtime is denied", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)

      assert {:error, payload} =
               ToolAccess.fetch_for_read(canvas.id, federation_context(space.id, nil))

      assert payload.recoverable == false
    end

    test "an agent from another org is denied a canvas in this one", %{
      org_a: org_a,
      org_b: org_b
    } do
      canvas = canvas!(space!(%{org_id: org_a.id}))

      other_space = space!(%{org_id: org_b.id})
      agent_id = UUID.generate()
      add_agent!(other_space.id, agent_id)

      assert {:error, _payload} =
               ToolAccess.fetch_for_read(canvas.id, federation_context(other_space.id, agent_id))
    end
  end

  # ── fetch_for_read/2 — the soft-delete collapse ───────────────────────────

  describe "fetch_for_read/2 — soft-deleted canvases" do
    test "a grant-holder gets not-found, not the deleted document", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      agent_id = UUID.generate()
      add_agent!(space.id, agent_id)

      # Reads fine while live …
      assert {:ok, _canvas} =
               ToolAccess.fetch_for_read(canvas.id, federation_context(space.id, agent_id))

      soft_delete_canvas!(canvas)

      # … and the underlying resolver still hands it back to the grant-holder,
      # by design, for the LiveView "removed" state.
      assert {:ok, %Canvas{}, :member} =
               Platform.Chat.CanvasAccess.fetch_for_viewer(canvas.id, {:agent, agent_id})

      # The MCP seam must not inherit that. Deleted collapses to not-found,
      # matching `Chat.get_canvas/2`, which every pre-existing MCP read used.
      assert {:error, payload} =
               ToolAccess.fetch_for_read(canvas.id, federation_context(space.id, agent_id))

      assert payload.error =~ "not found"
      assert payload.recoverable == false
    end

    test "a caller with no grant also gets not-found", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space) |> soft_delete_canvas!()

      assert {:error, payload} =
               ToolAccess.fetch_for_read(canvas.id, federation_context(nil, UUID.generate()))

      assert payload.error =~ "not found"
    end
  end

  # ── fetch_for_read/2 — missing ids ────────────────────────────────────────

  describe "fetch_for_read/2 — missing ids" do
    test "an id that matches no row is not-found" do
      assert {:error, payload} =
               ToolAccess.fetch_for_read(
                 UUID.generate(),
                 federation_context(nil, UUID.generate())
               )

      assert payload.error =~ "not found"
    end

    test "a malformed id is not-found" do
      assert {:error, payload} =
               ToolAccess.fetch_for_read("not-a-uuid", federation_context(nil, UUID.generate()))

      assert payload.error =~ "not found"
    end

    test "not-found and forbidden stay textually distinguishable", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      context = federation_context(nil, UUID.generate())

      assert {:error, forbidden} = ToolAccess.fetch_for_read(canvas.id, context)
      assert {:error, missing} = ToolAccess.fetch_for_read(UUID.generate(), context)

      refute forbidden.error == missing.error
      assert missing.error =~ "not found"
      refute forbidden.error =~ "not found"
    end
  end

  # ── Denial payload field allowlist ────────────────────────────────────────

  describe "denial payloads" do
    @allowed_keys [:canvas_id, :error, :recoverable, :suggestion]

    test "a forbidden read carries the caller's canvas_id and nothing else", %{org_a: org_a} do
      space =
        space!(%{
          name: "Confidential Board Channel #{System.unique_integer([:positive])}",
          org_id: org_a.id
        })

      canvas = canvas!(space, %{"title" => "Acquisition Terms"})

      assert {:error, payload} =
               ToolAccess.fetch_for_read(canvas.id, federation_context(nil, UUID.generate()))

      assert Enum.sort(Map.keys(payload)) == @allowed_keys
      assert payload.canvas_id == canvas.id
      assert payload.recoverable == false

      serialized = inspect(payload)
      refute serialized =~ "Acquisition Terms"
      refute serialized =~ "Confidential Board Channel"
      refute serialized =~ space.id
      refute serialized =~ org_a.id
    end

    test "a forbidden read names access, not absence", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))

      assert {:error, payload} =
               ToolAccess.fetch_for_read(canvas.id, federation_context(nil, UUID.generate()))

      assert payload.error =~ ~r/access/i
    end

    test "a not-found read carries the caller's id verbatim, even when malformed" do
      assert {:error, payload} =
               ToolAccess.fetch_for_read("wat", federation_context(nil, UUID.generate()))

      assert Enum.sort(Map.keys(payload)) == @allowed_keys
      assert payload.canvas_id == "wat"
    end

    test "a forbidden write carries no more than a forbidden read", %{org_a: org_a} do
      space =
        space!(%{
          name: "Confidential Board Channel #{System.unique_integer([:positive])}",
          org_id: org_a.id
        })

      canvas = canvas!(space, %{"title" => "Acquisition Terms"})

      assert {:error, payload} =
               ToolAccess.fetch_for_write(canvas.id, federation_context(nil, UUID.generate()))

      assert Enum.sort(Map.keys(payload)) == @allowed_keys
      assert payload.canvas_id == canvas.id

      serialized = inspect(payload)
      refute serialized =~ "Acquisition Terms"
      refute serialized =~ space.id
    end
  end

  # ── fetch_for_write/3 ─────────────────────────────────────────────────────

  describe "fetch_for_write/3" do
    test "an agent participant may write", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      agent_id = UUID.generate()
      add_agent!(space.id, agent_id)

      assert {:ok, %Canvas{id: id}} =
               ToolAccess.fetch_for_write(canvas.id, federation_context(space.id, agent_id))

      assert id == canvas.id
    end

    test "a read-only grant does not confer write", %{org_a: org_a} do
      space = space!(%{kind: "execution", org_id: nil})
      canvas = canvas!(space)
      task = task_in!(org_a)
      attach!(task, canvas)

      user = create_user!()
      plain_member!(user, org_a)
      context = %{user_id: user.id}

      assert {:ok, %Canvas{}} = ToolAccess.fetch_for_read(canvas.id, context)
      assert {:error, %{recoverable: false}} = ToolAccess.fetch_for_write(canvas.id, context)
    end

    test "a nil-agent runtime is denied", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)

      assert {:error, %{recoverable: false}} =
               ToolAccess.fetch_for_write(canvas.id, federation_context(space.id, nil))
    end

    test "a soft-deleted canvas is not-found even for a participant", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space) |> soft_delete_canvas!()
      agent_id = UUID.generate()
      add_agent!(space.id, agent_id)

      assert {:error, payload} =
               ToolAccess.fetch_for_write(canvas.id, federation_context(space.id, agent_id))

      assert payload.error =~ "not found"
    end

    test "the denial sentence is caller-supplied", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      context = federation_context(nil, UUID.generate())

      assert {:error, payload} =
               ToolAccess.fetch_for_write(canvas.id, context,
                 denial: "canvas_restore overwrites the whole document.",
                 suggestion: "Ask a human."
               )

      assert payload.error == "canvas_restore overwrites the whole document."
      assert payload.suggestion == "Ask a human."
      assert Enum.sort(Map.keys(payload)) == @allowed_keys
    end

    test "the not-found payload ignores the denial opt", %{org_a: _org_a} do
      # A missing canvas is not a permission answer, so a caller's denial
      # sentence must not be reported for one.
      assert {:error, payload} =
               ToolAccess.fetch_for_write(UUID.generate(), %{}, denial: "custom denial")

      assert payload.error =~ "not found"
      refute payload.error =~ "custom denial"
    end
  end
end
