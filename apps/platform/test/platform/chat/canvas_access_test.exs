defmodule Platform.Chat.CanvasAccessTest do
  @moduledoc """
  Stage 1 of task 019e2c4b — canvas read authorization.

  This module decides who may read a canvas through the forthcoming standalone
  `/canvases/:id` page, so every grant path and every denial is asserted
  explicitly rather than inferred from a happy path.

  Covers:

    * `:member` — space participation, including in an execution space
    * `:task_reader` — attachment to a live task in an org the viewer belongs
      to, including the incident shape (canvas in an EXECUTION space)
    * `:org_reader` — accessible non-archived CHANNEL with a non-nil org, for
      an org member or a Fabrikam admin
    * external users are capped at `:member`
    * a null `org_id` DENIES (DMs and groups)
    * execution and archived spaces are excluded from `:org_reader`
    * `:not_found` and `:forbidden` are distinct return values
    * soft-deleted canvases: `:not_found` without a grant, `{:ok, …}` with one
    * audit rows for `:task_reader` / `:org_reader`, none for `:member`
  """

  use Platform.DataCase, async: true

  import Platform.ExternalUserFixtures
  import Platform.TenancyFixtures

  alias Ecto.UUID
  alias Platform.Audit
  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Chat.CanvasAccess
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.CanvasAttachments
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  setup do
    %{org_a: Tenancy.get_org_by_slug!("sxi"), org_b: Tenancy.get_org_by_slug!("soylent")}
  end

  # ── Builders ──────────────────────────────────────────────────────────────

  defp space!(attrs) do
    n = System.unique_integer([:positive, :monotonic])
    default = %{name: "CA Space #{n}", slug: "ca-space-#{n}", kind: "channel"}
    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  # `chat_canvases.created_by` is FK-constrained to a participant row, so every
  # canvas needs an author IN its space. The author is deliberately a throwaway
  # user distinct from any viewer under test — an author who happened to be the
  # viewer would hand every case a free `:member` grant.
  defp canvas!(space, overrides \\ %{}) do
    author = add_user!(space.id, create_user!().id)

    {:ok, canvas} =
      Chat.create_canvas(
        Map.merge(
          %{
            "space_id" => space.id,
            "created_by" => author.id,
            "title" => "Canvas #{System.unique_integer([:positive])}"
          },
          overrides
        )
      )

    canvas
  end

  defp fabrikam_admin! do
    user = create_user!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: fabrikam_org_id(), role: "admin"})
    |> Repo.insert!()

    user
  end

  defp task_in!(org) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "CA Project #{System.unique_integer([:positive])}",
        org_id: org.id
      })

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "CA Task"})
    %{project: project, task: task}
  end

  defp attach!(task, canvas) do
    {:ok, attachment} =
      CanvasAttachments.attach_canvas(:system, task.id, canvas.id,
        attached_by: %{kind: "user", id: UUID.generate()}
      )

    attachment
  end

  defp soft_delete_canvas!(canvas) do
    canvas
    |> Canvas.delete_changeset(%{deleted_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  defp canvas_audit_rows(canvas) do
    Audit.list(resource_type: "canvas", resource_id: canvas.id)
  end

  # ── 1. :member ────────────────────────────────────────────────────────────

  describe "fetch_for_viewer/3 — :member" do
    test "a space participant reads their own space's canvas", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      user = create_user!()
      add_user!(space.id, user.id)

      assert {:ok, %Canvas{id: id}, :member} = CanvasAccess.fetch_for_viewer(canvas.id, user)
      assert id == canvas.id
    end

    test "membership still works inside an EXECUTION space" do
      # Execution spaces are closed to org REACH, not to their own participants.
      space = space!(%{kind: "execution", org_id: nil})
      canvas = canvas!(space)
      user = create_user!()
      add_user!(space.id, user.id)

      assert {:ok, _canvas, :member} = CanvasAccess.fetch_for_viewer(canvas.id, user)
    end

    test "an EXTERNAL user who participates still gets :member", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      ext = external_user!(org_a)
      add_user!(space.id, ext.id)

      assert {:ok, _canvas, :member} = CanvasAccess.fetch_for_viewer(canvas.id, ext)
    end

    test "a :member read is NOT audited", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      user = create_user!()
      add_user!(space.id, user.id)

      assert {:ok, _canvas, :member} = CanvasAccess.fetch_for_viewer(canvas.id, user)
      assert canvas_audit_rows(canvas) == []
    end

    test "an agent-type participant row does not confer :member on a user of the same id",
         %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      user = create_user!()
      add_agent!(space.id, user.id)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, user)
    end
  end

  # ── 2. :task_reader ───────────────────────────────────────────────────────

  describe "fetch_for_viewer/3 — :task_reader" do
    test "a non-member in the attached task's project org reads the canvas", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:ok, _canvas, :task_reader} = CanvasAccess.fetch_for_viewer(canvas.id, user)
    end

    test "reaches a canvas in an EXECUTION space — the reported incident shape", %{
      org_a: org_a
    } do
      # Execution spaces are excluded by `space_accessible?/1`, so :org_reader
      # cannot help here. Without :task_reader the reviewer stays locked out.
      space = space!(%{kind: "execution", org_id: nil})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:ok, _canvas, :task_reader} = CanvasAccess.fetch_for_viewer(canvas.id, user)
    end

    test "a viewer in a DIFFERENT org than the task's project is denied", %{
      org_a: org_a,
      org_b: org_b
    } do
      space = space!(%{kind: "execution", org_id: nil})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      user = create_user!()
      plain_member!(user, org_b)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, user)
    end

    test "a soft-deleted task no longer confers the grant", %{org_a: org_a} do
      space = space!(%{kind: "execution", org_id: nil})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      user = create_user!()
      plain_member!(user, org_a)
      assert {:ok, _canvas, :task_reader} = CanvasAccess.fetch_for_viewer(canvas.id, user)

      {:ok, _deleted} = Tasks.soft_delete_task(task)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, user)
    end

    # There is deliberately NO org-less-project case here: `projects.org_id` is
    # NOT NULL in the schema, so the state cannot exist. That asymmetry with
    # `chat_spaces` — where null org is the DM/group norm and is denied
    # explicitly below — is why the two arms are written differently.

    test "the resolution is audited", %{org_a: org_a} do
      space = space!(%{kind: "execution", org_id: nil})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:ok, _canvas, :task_reader} = CanvasAccess.fetch_for_viewer(canvas.id, user)

      assert [event] = canvas_audit_rows(canvas)
      assert event.event_type == "platform.chat.canvas_read"
      assert event.actor_id == user.id
      assert event.actor_type == "user"
      assert event.action == "read"
      assert event.resource_id == canvas.id
      assert event.metadata["grant"] == "task_reader"
      assert event.metadata["space_id"] == space.id
    end
  end

  # ── 3. :org_reader ────────────────────────────────────────────────────────

  describe "fetch_for_viewer/3 — :org_reader" do
    test "an org member reads a canvas in a channel owned by that org", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:ok, _canvas, :org_reader} = CanvasAccess.fetch_for_viewer(canvas.id, user)
    end

    test "a Fabrikam admin reads a channel canvas in any org", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)

      assert {:ok, _canvas, :org_reader} = CanvasAccess.fetch_for_viewer(canvas.id, fabrikam_admin!())
    end

    test "a member of a DIFFERENT org is denied", %{org_a: org_a, org_b: org_b} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)

      user = create_user!()
      plain_member!(user, org_b)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, user)
    end

    test "a NULL org_id denies — a channel with no org is not org-readable", %{org_a: org_a} do
      space = space!(%{org_id: nil})
      canvas = canvas!(space)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, user)
    end

    test "a NULL org_id denies a Fabrikam admin too" do
      # DMs and group conversations never set org_id. If null were a wildcard,
      # every private conversation in the product would be org-readable.
      space = space!(%{org_id: nil})
      canvas = canvas!(space)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, fabrikam_admin!())
    end

    test "a GROUP space with an org_id is still denied — channels only", %{org_a: org_a} do
      space = space!(%{kind: "group", org_id: org_a.id})
      canvas = canvas!(space)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, user)
    end

    test "a DM space with an org_id is still denied", %{org_a: org_a} do
      space = space!(%{kind: "dm", org_id: org_a.id})
      canvas = canvas!(space)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, user)
    end

    test "an EXECUTION space is excluded even with a matching org_id", %{org_a: org_a} do
      space = space!(%{kind: "execution", org_id: org_a.id})
      canvas = canvas!(space)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, user)
    end

    test "an ARCHIVED channel is excluded", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      {:ok, _archived} = Chat.archive_space(space)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, user)
    end

    test "the resolution is audited", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:ok, _canvas, :org_reader} = CanvasAccess.fetch_for_viewer(canvas.id, user)

      assert [event] = canvas_audit_rows(canvas)
      assert event.event_type == "platform.chat.canvas_read"
      assert event.metadata["grant"] == "org_reader"
      assert event.actor_id == user.id
    end
  end

  # ── External users are capped at :member ──────────────────────────────────

  describe "fetch_for_viewer/3 — external users" do
    test "an external org member gets NO :org_reader on a channel in their own org", %{
      org_a: org_a
    } do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      ext = external_user!(org_a)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, ext)
    end

    test "an external org member gets NO :task_reader", %{org_a: org_a} do
      space = space!(%{kind: "execution", org_id: nil})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      ext = external_user!(org_a)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, ext)
    end
  end

  # ── :not_found vs :forbidden ──────────────────────────────────────────────

  describe "fetch_for_viewer/3 — :not_found is distinct from :forbidden" do
    test "an unknown canvas id is :not_found, not :forbidden" do
      assert {:error, :not_found} = CanvasAccess.fetch_for_viewer(UUID.generate(), create_user!())
    end

    test "a malformed id is :not_found rather than a raise" do
      assert {:error, :not_found} = CanvasAccess.fetch_for_viewer("not-a-uuid", create_user!())
      assert {:error, :not_found} = CanvasAccess.fetch_for_viewer(<<1::128>>, create_user!())
      assert {:error, :not_found} = CanvasAccess.fetch_for_viewer(nil, create_user!())
    end

    test "an existing canvas the viewer cannot reach is :forbidden, not :not_found", %{
      org_a: org_a
    } do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, create_user!())
    end

    test "a nil viewer is :forbidden on a live canvas", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, nil)
    end
  end

  # ── Soft-deleted canvases ─────────────────────────────────────────────────

  describe "fetch_for_viewer/3 — soft-deleted canvases" do
    test "resolve to :not_found for a viewer with NO grant", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      soft_delete_canvas!(canvas)

      assert {:error, :not_found} = CanvasAccess.fetch_for_viewer(canvas.id, create_user!())
    end

    test "resolve to :not_found for a nil viewer", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      soft_delete_canvas!(canvas)

      assert {:error, :not_found} = CanvasAccess.fetch_for_viewer(canvas.id, nil)
    end

    test "still resolve for a grant holder so the renderer can say 'removed'", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      user = create_user!()
      add_user!(space.id, user.id)
      soft_delete_canvas!(canvas)

      assert {:ok, %Canvas{deleted_at: %DateTime{}}, :member} =
               CanvasAccess.fetch_for_viewer(canvas.id, user)
    end

    test "still resolve for an :org_reader grant holder", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      soft_delete_canvas!(canvas)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:ok, %Canvas{deleted_at: %DateTime{}}, :org_reader} =
               CanvasAccess.fetch_for_viewer(canvas.id, user)
    end
  end

  # ── Audit opt-out ─────────────────────────────────────────────────────────

  describe "fetch_for_viewer/3 — audit: false" do
    test "suppresses the audit row for a LiveView remount", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      user = create_user!()
      plain_member!(user, org_a)

      assert {:ok, _canvas, :org_reader} =
               CanvasAccess.fetch_for_viewer(canvas.id, user, audit: false)

      assert canvas_audit_rows(canvas) == []
    end
  end

  # ══ STAGE 2 ═══════════════════════════════════════════════════════════════
  #
  # Actor shapes and the write door. Everything above resolves READ for a
  # `%User{}`; everything below covers the `t:actor/0` triple and
  # `fetch_for_writer/2`.

  # ── Actor shapes on the read door ─────────────────────────────────────────

  describe "fetch_for_viewer/3 — actor shapes" do
    test "{:user, id} resolves identically to a %User{}", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      user = create_user!()
      add_user!(space.id, user.id)

      assert {:ok, _canvas, :member} = CanvasAccess.fetch_for_viewer(canvas.id, {:user, user.id})
    end

    test "an agent participant of the space gets :member", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      agent_id = UUID.generate()
      add_agent!(space.id, agent_id)

      assert {:ok, _canvas, :member} =
               CanvasAccess.fetch_for_viewer(canvas.id, {:agent, agent_id})
    end

    test "an agent that does not participate is forbidden", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))

      assert {:error, :forbidden} =
               CanvasAccess.fetch_for_viewer(canvas.id, {:agent, UUID.generate()})
    end

    # The org-reach paths query `org_memberships.user_id`. Sharing an id with a
    # user who WOULD qualify must not smuggle an agent through them.
    test "an agent never reaches :org_reader, even sharing an id with an org member",
         %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      user = create_user!()
      plain_member!(user, org_a)

      assert {:ok, _canvas, :org_reader} = CanvasAccess.fetch_for_viewer(canvas.id, user)
      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, {:agent, user.id})
    end

    test "an agent never reaches :task_reader, even sharing an id with an org member",
         %{org_a: org_a} do
      space = space!(%{kind: "execution", org_id: nil})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:ok, _canvas, :task_reader} = CanvasAccess.fetch_for_viewer(canvas.id, user)
      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, {:agent, user.id})
    end

    test "an unrecognised actor shape is denied, never promoted to :system", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))

      for bogus <- [nil, :agent, {:user, nil}, {:agent, 42}, "a-string", %{}] do
        assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, bogus)
      end
    end
  end

  # ── fetch_for_writer/2 ────────────────────────────────────────────────────

  describe "fetch_for_writer/2 — grants" do
    test "a space participant may write", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      user = create_user!()
      add_user!(space.id, user.id)

      assert {:ok, %Canvas{id: id}} = CanvasAccess.fetch_for_writer(canvas.id, {:user, user.id})
      assert id == canvas.id
    end

    test "an agent participant may write", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      agent_id = UUID.generate()
      add_agent!(space.id, agent_id)

      assert {:ok, _canvas} = CanvasAccess.fetch_for_writer(canvas.id, {:agent, agent_id})
    end

    test "the :system actor may write", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))

      assert {:ok, _canvas} = CanvasAccess.fetch_for_writer(canvas.id, :system)
    end
  end

  describe "fetch_for_writer/2 — read levels do not confer write" do
    test "an :org_reader is rejected", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      user = create_user!()
      plain_member!(user, org_a)

      # Reads fine …
      assert {:ok, _canvas, :org_reader} = CanvasAccess.fetch_for_viewer(canvas.id, user)
      # … and must not write.
      assert {:error, :forbidden} = CanvasAccess.fetch_for_writer(canvas.id, {:user, user.id})
    end

    test "a :task_reader is rejected", %{org_a: org_a} do
      space = space!(%{kind: "execution", org_id: nil})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:ok, _canvas, :task_reader} = CanvasAccess.fetch_for_viewer(canvas.id, user)
      assert {:error, :forbidden} = CanvasAccess.fetch_for_writer(canvas.id, {:user, user.id})
    end

    test "a Fabrikam admin with no participation is rejected", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      admin = fabrikam_admin!()

      assert {:ok, _canvas, :org_reader} = CanvasAccess.fetch_for_viewer(canvas.id, admin)
      assert {:error, :forbidden} = CanvasAccess.fetch_for_writer(canvas.id, {:user, admin.id})
    end

    test "an unidentified actor is rejected", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))

      for bogus <- [nil, :agent, {:user, nil}, "a-string"] do
        assert {:error, :forbidden} = CanvasAccess.fetch_for_writer(canvas.id, bogus)
      end
    end
  end

  describe "fetch_for_writer/2 — missing and deleted canvases" do
    test "a non-existent id is :not_found" do
      assert {:error, :not_found} = CanvasAccess.fetch_for_writer(UUID.generate(), :system)
    end

    test "a malformed id is :not_found" do
      assert {:error, :not_found} = CanvasAccess.fetch_for_writer("not-a-uuid", :system)
    end

    # The read door deliberately hands a soft-deleted canvas back to a
    # grant-holder so the renderer can say "removed". The write door must not
    # inherit that: every pre-existing write path went through
    # `Chat.get_canvas/2`, which filters `deleted_at`.
    test "a soft-deleted canvas is :not_found for a member, though it READS", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      user = create_user!()
      add_user!(space.id, user.id)
      soft_delete_canvas!(canvas)

      assert {:ok, %Canvas{deleted_at: %DateTime{}}, :member} =
               CanvasAccess.fetch_for_viewer(canvas.id, user)

      assert {:error, :not_found} = CanvasAccess.fetch_for_writer(canvas.id, {:user, user.id})
    end

    test "a soft-deleted canvas is :not_found even for :system", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      soft_delete_canvas!(canvas)

      assert {:error, :not_found} = CanvasAccess.fetch_for_writer(canvas.id, :system)
    end
  end

  describe "fetch_for_writer/2 — no audit" do
    test "resolving write intent does not mint a canvas_read row", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      user = create_user!()
      add_user!(space.id, user.id)

      assert {:ok, _canvas} = CanvasAccess.fetch_for_writer(canvas.id, {:user, user.id})
      assert canvas_audit_rows(canvas) == []
    end
  end
end
