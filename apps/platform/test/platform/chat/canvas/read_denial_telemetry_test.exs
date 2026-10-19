defmodule Platform.Chat.Canvas.ReadDenialTelemetryTest do
  @moduledoc """
  `[:platform, :chat, :canvas_read_denied]` — the detection half of the canvas
  read gate (task 019fb01b, stage 5).

  Stages 1 to 4 closed the reads. This event is what makes a refused read
  visible. The two are not the same control and the second is the one that was
  missing: `:not_found` and `:forbidden` stay deliberately distinct on this
  surface (see `Platform.Chat.Canvas.ToolAccess`), so a caller holding the
  `canvas` bundle can still ask "does this id exist" one id at a time. The
  argument for keeping that oracle is that canvas ids are UUIDv7 and therefore
  expensive to guess. That argument says an id is hard to find. It says nothing
  about whether anyone would notice someone looking, and until this event there
  was nothing to notice with: a denial returned a payload to the caller and
  left no trace anywhere else.

  ## What this file pins, and why each half is here

  Emission and REGISTRATION are asserted separately because they fail
  separately, and the second is the one that rots quietly.
  `:telemetry.execute/3` on an event no handler subscribes to is a silent
  no-op — not an error, not a log line — so deleting the entry from
  `Platform.Audit.TelemetryHandler`'s `@events` list would leave every emit
  site in place, every unit test that attaches its own handler still green, and
  the audit stream empty. `Platform.Chat.CanvasAccess`'s moduledoc already
  warns about exactly this trap for the sibling `[:platform, :chat,
  :canvas_read]` event; a warning is not a test.

  So the load-bearing assertion here is the end-to-end one: with only the
  handler the application attaches at boot, a forbidden read must leave a row
  in `audit_events`. That fails if the emit is removed, if the registration is
  removed, or if the two drift apart on the event name.

  ## Scope of the emit, stated so it is not mistaken for more

  The event fires from `ToolAccess.fetch_for_read/2`, which is the MCP tool
  surface only. Denials decided elsewhere do NOT emit:

    * `fetch_for_write/3` denials (`canvas_patch`, `canvas_restore`). A refused
      write is a different signal class and the write itself is what downstream
      audit records.
    * `CanvasAccess.fetch_for_viewer/3` denials reached from the LiveView, which
      is a human hitting a page they may not see.
    * `:not_found` answers. A stale task attachment produces one on a perfectly
      honest call — `canvas_get`'s own suggestion string tells callers to expect
      it — so emitting there would bury the signal under benign noise. The
      forbidden answers are the oracle's actual HITS: a probe sweep over guessed
      ids returns not-found almost every time and forbidden exactly when it
      lands on something real.
  """

  use Platform.DataCase, async: false

  import Platform.ExternalUserFixtures, except: [canvas!: 2]

  alias Ecto.UUID
  alias Platform.Audit
  alias Platform.Audit.TelemetryHandler
  alias Platform.Chat
  alias Platform.Chat.Canvas.ToolAccess
  alias Platform.Chat.Canvas.ToolHandlers
  alias Platform.Chat.Canvas.VersionHandlers
  alias Platform.Federation.ToolSurface
  alias Platform.Tenancy

  @event [:platform, :chat, :canvas_read_denied]
  @event_type "platform.chat.canvas_read_denied"

  setup do
    Platform.TelemetryHelpers.ensure_boot_handler!(TelemetryHandler)
    %{org_a: Tenancy.get_org_by_slug!("globex"), org_b: Tenancy.get_org_by_slug!("initech")}
  end

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp space!(attrs) do
    n = System.unique_integer([:positive, :monotonic])
    default = %{name: "Denial Space #{n}", slug: "denial-space-#{n}", kind: "channel"}
    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  # The author is a throwaway user in the space, never the caller under test —
  # a caller who authored the canvas would hold `:member` and never be denied.
  defp canvas!(space) do
    author = add_user!(space.id, create_user!().id)

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => author.id,
        "title" => "Denial Fixture #{System.unique_integer([:positive])}"
      })

    canvas
  end

  # Rostered somewhere, just not anywhere touching the canvas under test. An
  # agent with no rows at all could be denied by accident rather than by rule.
  defp outsider_agent!(org) do
    agent_id = UUID.generate()
    add_agent!(space!(%{org_id: org.id}).id, agent_id)
    agent_id
  end

  # The shape `PlatformWeb.MCPController.build_context/2` and
  # `PlatformWeb.RuntimeChannel.execute_tool_call/4` both construct.
  defp federation_context(agent_id) do
    %{
      space_id: nil,
      agent_id: agent_id,
      agent_participant_id: nil,
      runtime_id: "runtime-#{System.unique_integer([:positive])}"
    }
  end

  defp listen! do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      "canvas-denial-probe-#{inspect(ref)}",
      @event,
      fn name, measurements, metadata, _ ->
        send(test_pid, {:denial, ref, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("canvas-denial-probe-#{inspect(ref)}") end)
    ref
  end

  # ── Registration ──────────────────────────────────────────────────────────

  describe "registration in the audit handler" do
    test "the event is in the handler's explicit allowlist" do
      assert @event in TelemetryHandler.events(), """
      #{inspect(@event)} is not registered in Platform.Audit.TelemetryHandler's
      @events list. `:telemetry.execute/3` on an unsubscribed event is a silent
      no-op, so the emit site would still run, this file's emission tests would
      still pass, and nothing would ever reach audit_events.
      """
    end

    test "registration is live: a forbidden read persists an audit row", %{
      org_a: org_a,
      org_b: org_b
    } do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      outsider = outsider_agent!(org_b)
      context = federation_context(outsider)

      assert Audit.list(event_type: @event_type) == []

      assert {:error, _} = ToolAccess.fetch_for_read(canvas.id, context)

      # No test-local handler is attached here on purpose. The only listener is
      # the one `Platform.Application` attaches at boot, so this row existing is
      # proof the registration is real rather than proof the emit ran.
      assert [event] = Audit.list(event_type: @event_type)
      assert event.actor_id == outsider
      assert event.actor_type == "agent"
      assert event.resource_type == "canvas"
      assert event.resource_id == canvas.id
      assert event.action == "read_denied"
      assert event.metadata["surface"] == "mcp_tool"

      # Asserted at the PERSISTENCE layer, not only on the emitted event.
      # `TelemetryHandler.build_metadata/2` is where a key can be dropped or
      # mangled on its way into the column, and runtime_id is the field an
      # operator would filter a sweep on.
      assert event.metadata["runtime_id"] == context.runtime_id
    end

    test "a context carrying no runtime_id omits the key rather than storing \"nil\"", %{
      org_a: org_a
    } do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      user = create_user!()

      # The user-shaped context `ToolAccess.actor/1` documents and accepts. It
      # carries no :runtime_id.
      assert {:error, _} = ToolAccess.fetch_for_read(canvas.id, %{user_id: user.id})

      assert [event] = Audit.list(event_type: @event_type)
      assert event.actor_type == "user"

      refute Map.has_key?(event.metadata, "runtime_id"), """
      runtime_id was persisted for a context that has none. `ensure_json_safe/1`
      stringifies atoms and `nil` IS an atom, so a nil-valued key lands in the
      column as the STRING "nil" — an operator filtering
      `metadata->>'runtime_id' IS NULL` gets zero rows and no hint why.
      """
    end

    test "a non-map context denies instead of raising", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))

      # `ToolAccess.actor/1` accepts any term because callers pass `nil` and
      # `:system`, and `tool_access_test.exs` pins that contract. The denial
      # telemetry must not narrow it: turning a clean fail-closed denial into a
      # BadMapError would be a worse outage than the one the event was added to
      # catch.
      for context <- [nil, :system, "ctx", []] do
        assert {:error, payload} = ToolAccess.fetch_for_read(canvas.id, context),
               "a #{inspect(context)} context must deny, not raise"

        assert payload.recoverable == false
      end
    end

    test "an unidentified caller is recorded as anonymous", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))

      assert {:error, _} = ToolAccess.fetch_for_read(canvas.id, federation_context(nil))

      assert [event] = Audit.list(event_type: @event_type)
      assert event.actor_id == nil

      assert event.actor_type == "anonymous", """
      A runtime with a nil agent_id has no principal, and `Platform.Audit.Event`
      already defines "anonymous" for exactly that (event.ex actor_types). It
      must not be filed as "system": system is the platform acting on its own
      behalf, and recording an unidentified remote caller that way would hide
      the single most interesting row in this stream.
      """
    end
  end

  # ── Emission ──────────────────────────────────────────────────────────────

  describe "emission" do
    test "a forbidden read emits the event with the caller and the canvas", %{
      org_a: org_a,
      org_b: org_b
    } do
      ref = listen!()
      canvas = canvas!(space!(%{org_id: org_a.id}))
      outsider = outsider_agent!(org_b)
      context = federation_context(outsider)

      assert {:error, _} = ToolAccess.fetch_for_read(canvas.id, context)

      assert_receive {:denial, ^ref, @event, measurements, metadata}
      assert is_integer(measurements.system_time)
      assert metadata.actor_id == outsider
      assert metadata.actor_type == "agent"
      assert metadata.resource_id == canvas.id
      assert metadata.action == "read_denied"
      assert metadata.runtime_id == context.runtime_id
    end

    test "the runtime id is carried so a sweep is attributable to one caller", %{
      org_a: org_a,
      org_b: org_b
    } do
      ref = listen!()
      outsider = outsider_agent!(org_b)
      context = federation_context(outsider)
      space = space!(%{org_id: org_a.id})

      for _ <- 1..3 do
        canvas = canvas!(space)
        assert {:error, _} = ToolAccess.fetch_for_read(canvas.id, context)
      end

      # Three denials, one runtime. Without `runtime_id` an operator reading the
      # audit stream can see that denials happened but not that one caller made
      # all of them, which is the difference between noise and a sweep.
      for _ <- 1..3 do
        assert_receive {:denial, ^ref, @event, _, %{runtime_id: rid}}
        assert rid == context.runtime_id
      end
    end

    test "every gated read on the tool surface emits, not just the one that was patched last",
         %{org_a: org_a, org_b: org_b} do
      ref = listen!()
      canvas = canvas!(space!(%{org_id: org_a.id}))
      context = federation_context(outsider_agent!(org_b))
      args = %{"canvas_id" => canvas.id}

      # All three canvas-id-keyed reads resolve through the same seam, so all
      # three must produce the same trace. Driving them from one list is what
      # stops a fourth read from being added with the gate and without the
      # signal.
      reads = [
        {"canvas_describe", fn -> ToolHandlers.describe(args, context) end},
        {"canvas_versions", fn -> VersionHandlers.versions(args, context) end},
        {"canvas_get", fn -> ToolSurface.execute("canvas_get", args, context) end}
      ]

      for {name, call} <- reads do
        assert {:error, _} = call.(), "#{name} was expected to deny this caller"
        assert_receive {:denial, ^ref, @event, _, %{resource_id: id}}, 1_000
        assert id == canvas.id, "#{name} emitted a denial naming the wrong canvas"
      end
    end
  end

  # ── Non-emission ──────────────────────────────────────────────────────────

  describe "what must NOT emit" do
    test "an authorized read is silent", %{org_a: org_a} do
      ref = listen!()
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      member = UUID.generate()
      add_agent!(space.id, member)

      assert {:ok, _} = ToolAccess.fetch_for_read(canvas.id, federation_context(member))

      refute_receive {:denial, ^ref, _, _, _}, 200
      assert Audit.list(event_type: @event_type) == []
    end

    test "a not-found read is silent", %{org_b: org_b} do
      ref = listen!()
      context = federation_context(outsider_agent!(org_b))

      assert {:error, _} = ToolAccess.fetch_for_read(UUID.generate(), context)

      # See the moduledoc: a stale task attachment produces this answer on an
      # honest call, so emitting here would bury the forbidden signal in noise.
      # Pinned rather than left implicit, because "also emit on not-found" is a
      # plausible-sounding change that would cost the signal.
      refute_receive {:denial, ^ref, _, _, _}, 200
      assert Audit.list(event_type: @event_type) == []
    end

    test "a denied WRITE is silent on this event", %{org_a: org_a, org_b: org_b} do
      ref = listen!()
      canvas = canvas!(space!(%{org_id: org_a.id}))
      context = federation_context(outsider_agent!(org_b))

      assert {:error, _} = ToolAccess.fetch_for_write(canvas.id, context)

      refute_receive {:denial, ^ref, _, _, _}, 200
      assert Audit.list(event_type: @event_type) == []
    end
  end
end
