defmodule PlatformWeb.CanvasLiveTest do
  @moduledoc """
  Stage 3 of task 019e2c4b — the standalone `/canvases/:id` page.

  The plan carries no `manual_approval` gate, so these render assertions are
  the behavioural floor for the route. They cover the five contract points the
  stage names:

    * an authorized mount renders the title, the crumb, the read-only pill and
      the footer revision stamp
    * the delegated `CanvasRenderer.canvas_document/1` output is present, which
      is what citation parity depends on
    * an external user is denied
    * the route resolves in its OWN `live_session` (the security-relevant half
      — a shared `live_session` would let a `live_redirect` skip the
      `:enforce_external_scope` HTTP plug)
    * both denial outcomes reach the template as `@load_error` so stage 4 can
      render them

  Plus one assertion on the audit contract: `fetch_for_viewer/3` takes
  `audit: false` specifically so a LiveView does not mint an audit row per
  socket, and this pins the "exactly one row per page load" behaviour that
  opt exists for.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.ExternalUserFixtures

  alias Platform.Audit
  alias Platform.Chat
  alias Platform.Tenancy

  @router PlatformWeb.Router

  setup do
    %{org: Tenancy.get_org_by_slug!("sxi")}
  end

  # ── Builders ──────────────────────────────────────────────────────────────

  # A canvas with a real heading node, so "the renderer ran" is assertable
  # against document CONTENT rather than against an empty wrapper div.
  defp canvas_with_heading!(space, heading, opts \\ []) do
    author = add_user!(space.id, create_user!().id)

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => author.id,
        "title" => Keyword.get(opts, :title, "Cross-space canvas share"),
        "created_by_display_name" => Keyword.get(opts, :author_name, "Saru"),
        "created_by_participant_type" => "agent",
        "document" => %{
          "version" => 1,
          "revision" => Keyword.get(opts, :revision, 7),
          "root" => %{
            "id" => "root",
            "type" => "stack",
            "props" => %{},
            "children" => [
              %{
                "id" => "h1",
                "type" => "heading",
                "props" => %{"level" => 1, "value" => heading}
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

  # A canvas carrying one of each interactive kind, so "visible but inert" is
  # assertable against real `action_row` / `form` / `checklist_item` markup
  # rather than against a document that has none.
  defp canvas_with_interactive_nodes!(space) do
    author = add_user!(space.id, create_user!().id)

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => author.id,
        "title" => "Release checklist",
        "created_by_display_name" => "Saru",
        "created_by_participant_type" => "agent",
        "document" => %{
          "version" => 1,
          "revision" => 3,
          "root" => %{
            "id" => "root",
            "type" => "stack",
            "props" => %{},
            "children" => [
              %{
                "id" => "actions",
                "type" => "action_row",
                "props" => %{
                  "actions" => [%{"label" => "Approve deploy", "value" => "approve"}]
                }
              },
              %{
                "id" => "item",
                "type" => "checklist_item",
                "props" => %{"label" => "Ship the migration", "state" => "active"}
              },
              %{
                "id" => "signoff",
                "type" => "form",
                "props" => %{
                  "title" => "Sign off",
                  "fields" => [%{"name" => "who", "type" => "text", "label" => "Reviewer"}]
                }
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

  # Same-org denial is reachable for an internal viewer: an execution space is
  # excluded from `:org_reader` by `Chat.space_accessible?/1`, so an org member
  # who is not a participant lands on 403 while genuinely sharing the org.
  # That is the incident case this task started from.
  defp forbidden_same_org(conn, org) do
    space = channel!(%{kind: "execution", org_id: org.id, name: "spike-019e2740"})
    canvas = canvas_with_heading!(space, "Audit body", author_name: "Saru")
    viewer = create_user!()
    plain_member!(viewer, org)

    {login(conn, viewer.id), canvas, space}
  end

  # No membership anywhere, so no grant path and no standing in the org.
  defp forbidden_other_org(conn, org) do
    space = channel!(%{org_id: org.id, name: "Frontend Design"})
    canvas = canvas_with_heading!(space, "Audit body", author_name: "Saru")

    {login(conn, create_user!().id), canvas, space}
  end

  defp member_conn(conn, space) do
    user = create_user!()
    add_user!(space.id, user.id)
    {login(conn, user.id), user}
  end

  # Phoenix does not guarantee attribute ORDER in rendered markup, so pull the
  # element out first and assert its attributes individually rather than
  # matching a whole tag string.
  defp element_html(view, role), do: view |> element(~s|[data-role="#{role}"]|) |> render()

  defp attr(view, role, name) do
    case Regex.run(~r/#{name}="([^"]*)"/, element_html(view, role)) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp class_of(view, role), do: attr(view, role, "class") || ""

  # ── Authorized mount ──────────────────────────────────────────────────────

  describe "authorized mount" do
    test "renders title, crumb, read-only pill and footer revision stamp", %{
      conn: conn,
      org: org
    } do
      space = channel!(%{org_id: org.id, name: "Frontend Design"})
      canvas = canvas_with_heading!(space, "Design direction", revision: 7)
      {conn, _user} = member_conn(conn, space)

      {:ok, _view, html} = live(conn, ~p"/canvases/#{canvas.id}")

      # Title — the only display-weight string on the page.
      assert html =~ ~s|data-role="canvas-title"|
      assert html =~ "Cross-space canvas share"

      # Crumb — org › space · author · updated, from the ADR-0038 creator
      # snapshot on the canvas row.
      assert html =~ ~s|data-role="canvas-crumb"|
      assert html =~ org.name
      assert html =~ "Frontend Design"
      assert html =~ "Saru"
      assert html =~ "updated"

      # Read-only pill.
      assert html =~ ~s|data-role="canvas-read-only-pill"|
      assert html =~ "Read only"

      # Footer stamp: `rev N · <canvas uuid>`.
      assert html =~ ~s|data-role="canvas-revision-stamp"|
      assert html =~ "rev 7"
      assert html =~ canvas.id
    end

    test "the provenance bar is the only tinted band, over content on base-100", %{
      conn: conn,
      org: org
    } do
      space = channel!(%{org_id: org.id})
      canvas = canvas_with_heading!(space, "Body")
      {conn, _user} = member_conn(conn, space)

      {:ok, view, _html} = live(conn, ~p"/canvases/#{canvas.id}")

      bar_class = class_of(view, "canvas-provenance-bar")
      assert bar_class =~ "bg-base-200"
      assert bar_class =~ "border-edge"
      assert bar_class =~ "sticky"

      # The content column carries no card and no grey backdrop — the
      # card-on-grey shape the design direction deliberately killed.
      body_class = class_of(view, "canvas-body")
      assert body_class =~ "max-w-[880px]"
      refute body_class =~ "bg-base-200"
      refute body_class =~ "card"
    end

    test "truncation order: crumb collapses first, title gives way last", %{
      conn: conn,
      org: org
    } do
      space = channel!(%{org_id: org.id})
      canvas = canvas_with_heading!(space, "Body")
      {conn, _user} = member_conn(conn, space)

      {:ok, view, _html} = live(conn, ~p"/canvases/#{canvas.id}")

      # The crumb collapses FIRST: it ellipsises on a shared row and, below
      # `sm`, yields the row entirely (`basis-full` drops it to its own line).
      crumb = class_of(view, "canvas-crumb")
      assert crumb =~ "min-w-0"
      assert crumb =~ "truncate"
      assert crumb =~ "basis-full"

      # The title gives way LAST: unshrinkable from `sm` up, where the crumb
      # still shares its row, and ellipsising only below that, where the crumb
      # has already vacated.
      title = class_of(view, "canvas-title")
      assert title =~ "sm:shrink-0"
      assert title =~ "truncate"

      # The pill never wins space from the title.
      assert class_of(view, "canvas-read-only-pill") =~ "shrink-0"
    end

    test "the copy-link control carries the absolute canvas URL", %{conn: conn, org: org} do
      space = channel!(%{org_id: org.id})
      canvas = canvas_with_heading!(space, "Body")
      {conn, _user} = member_conn(conn, space)

      {:ok, view, _html} = live(conn, ~p"/canvases/#{canvas.id}")

      assert attr(view, "canvas-copy-link", "data-clipboard-text") ==
               PlatformWeb.Endpoint.url() <> "/canvases/" <> canvas.id

      # `--color-primary` on hover and active only, never as text on white.
      copy_class = class_of(view, "canvas-copy-link")
      assert copy_class =~ "hover:text-primary"
      assert copy_class =~ "active:text-primary"
      refute copy_class =~ ~r/(^|\s)text-primary(\s|$)/
    end
  end

  # ── The way out ───────────────────────────────────────────────────────────
  #
  # Added after stage 4 on Robin's call: the design direction specified the
  # bar's contents and omitted an exit, so a pasted link opened in a fresh tab
  # had no back history and nowhere to go.

  describe "the close control" do
    test "is the rightmost control in the bar, with the same glyph as the in-chat overlay",
         %{conn: conn, org: org} do
      space = channel!(%{org_id: org.id})
      canvas = canvas_with_heading!(space, "Body")
      {conn, _user} = member_conn(conn, space)

      {:ok, view, _html} = live(conn, ~p"/canvases/#{canvas.id}")

      close = element_html(view, "canvas-close")
      assert close =~ "hero-x-mark"
      assert attr(view, "canvas-close", "aria-label") == "Close canvas"

      # Rightmost at both widths, and it never yields space.
      close_class = class_of(view, "canvas-close")
      assert close_class =~ "shrink-0"
      assert close_class =~ "order-4"
      assert close_class =~ "sm:order-5"
    end

    test "a member's exit lands in the space the canvas lives in", %{conn: conn, org: org} do
      space = channel!(%{org_id: org.id})
      canvas = canvas_with_heading!(space, "Body")
      {conn, _user} = member_conn(conn, space)

      {:ok, view, _html} = live(conn, ~p"/canvases/#{canvas.id}")

      assert attr(view, "canvas-close", "href") ==
               "/chat/#{PlatformWeb.ChatLive.space_nav_target(space)}"
    end

    test "an org_reader's exit lands at /chat, not at a space they cannot enter",
         %{conn: conn, org: org} do
      space = channel!(%{org_id: org.id})
      canvas = canvas_with_heading!(space, "Body")

      reader = create_user!()
      plain_member!(reader, org)

      {:ok, view, _html} = live(login(conn, reader.id), ~p"/canvases/#{canvas.id}")

      assert attr(view, "canvas-close", "href") == "/chat"
    end

    test "a task_reader's exit lands at /chat — the execution space would deny them",
         %{conn: conn, org: org} do
      space = channel!(%{kind: "execution", org_id: org.id, name: "spike-019e2740"})
      canvas = canvas_with_heading!(space, "Audit body")

      {:ok, project} =
        Platform.Tasks.create_project(%{
          name: "Canvas close #{System.unique_integer([:positive])}",
          org_id: org.id
        })

      {:ok, task} =
        Platform.Tasks.create_task(%{project_id: project.id, title: "Canvas close task"})

      {:ok, _attachment} =
        Platform.Tasks.CanvasAttachments.attach_canvas(:system, task.id, canvas.id,
          attached_by: %{kind: "user", id: Ecto.UUID.generate()}
        )

      reader = create_user!()
      plain_member!(reader, org)

      {:ok, view, _html} = live(login(conn, reader.id), ~p"/canvases/#{canvas.id}")

      # The grant came from the task, not from the space. Sending them to the
      # execution space would bounce them into a second denial.
      assert attr(view, "canvas-close", "href") == "/chat"
    end
  end

  # ── Delegated rendering (citation parity) ─────────────────────────────────

  describe "body rendering delegates to CanvasRenderer" do
    test "renders the document node tree, not a placeholder", %{conn: conn, org: org} do
      space = channel!(%{org_id: org.id})
      canvas = canvas_with_heading!(space, "The document itself rendered here")
      {conn, _user} = member_conn(conn, space)

      {:ok, _view, html} = live(conn, ~p"/canvases/#{canvas.id}")

      # `CanvasRenderer.canvas_document/1` mints
      # `canvas-doc-<id>-<dom_id_base>-<mode>`. Asserting that exact id proves
      # the delegation (and the `inline: false` / `dom_id_base` we pass),
      # which is what keeps this page and the chat pane showing the same
      # document.
      assert html =~ ~s|id="canvas-doc-#{canvas.id}-canvas-standalone-expanded"|
      assert html =~ "The document itself rendered here"
    end

    test "no in-chat 'Live Canvas' label comes along", %{conn: conn, org: org} do
      space = channel!(%{org_id: org.id})
      canvas = canvas_with_heading!(space, "Body")
      {conn, _user} = member_conn(conn, space)

      {:ok, _view, html} = live(conn, ~p"/canvases/#{canvas.id}")

      refute html =~ "Live Canvas"
    end

    test "interactive canvas events are inert rather than crashing the socket", %{
      conn: conn,
      org: org
    } do
      space = channel!(%{org_id: org.id})
      canvas = canvas_with_heading!(space, "Body")
      {conn, _user} = member_conn(conn, space)

      {:ok, view, _html} = live(conn, ~p"/canvases/#{canvas.id}")

      # Nodes stay rendered for citation parity, so their events still reach
      # this LiveView. They must resolve to nothing, not to a crash.
      assert render_hook(view, "canvas_action_click", %{"action" => "noop"})
      assert render_hook(view, "canvas_form_submit", %{})
      assert Process.alive?(view.pid)
    end
  end

  # ── Denials ───────────────────────────────────────────────────────────────

  describe "denials" do
    test "an external user is denied BEFORE the LiveView mounts", %{conn: conn, org: org} do
      space = channel!(%{org_id: org.id})
      canvas = canvas_with_heading!(space, "Internal only")
      external = external_user!(org)

      # `Plugs.ExternalUserScope` is allowlist-based: an external user reaches
      # only `/chat` and `/chat/:slug`, so `/canvases/:id` halts with the
      # uniform 403 before CanvasLive is ever entered. This is exactly why the
      # route needs its OWN live_session — inside `:authenticated`, a
      # `live_redirect` from /chat would never re-enter this plug and the
      # denial below would not happen.
      resp = get(login(conn, external.id), ~p"/canvases/#{canvas.id}")

      assert resp.status == 403
      refute resp.resp_body =~ "Internal only"
      refute resp.resp_body =~ ~s|data-role="canvas-provenance-bar"|
    end

    test "an external space participant is still denied the standalone route", %{
      conn: conn,
      org: org
    } do
      # Even the `:member` grant does not open this surface to an external
      # user: the plug allowlist is by ROUTE, not by canvas grant.
      space = channel!(%{org_id: org.id})
      canvas = canvas_with_heading!(space, "Internal only")
      external = external_user!(org)
      add_user!(space.id, external.id)

      resp = get(login(conn, external.id), ~p"/canvases/#{canvas.id}")

      assert resp.status == 403
      refute resp.resp_body =~ "Internal only"
    end

    test "an internal non-member of a null-org space is denied", %{conn: conn} do
      # A DM/group space carries no org_id, so `:org_reader` cannot apply.
      space = channel!(%{org_id: nil})
      canvas = canvas_with_heading!(space, "Private thread")
      outsider = create_user!()

      {:ok, _view, html} = live(login(conn, outsider.id), ~p"/canvases/#{canvas.id}")

      assert html =~ ~s|data-error="forbidden"|
      refute html =~ "Private thread"
    end

    test "a non-existent canvas id resolves to not_found, distinctly", %{conn: conn} do
      user = create_user!()

      {:ok, _view, html} = live(login(conn, user.id), ~p"/canvases/#{Ecto.UUID.generate()}")

      # The two denial outcomes must stay distinguishable — stage 4 renders
      # structurally different surfaces for them.
      assert html =~ ~s|data-error="not_found"|
      refute html =~ ~s|data-error="forbidden"|
    end

    test "a malformed canvas id does not raise", %{conn: conn} do
      user = create_user!()

      {:ok, _view, html} = live(login(conn, user.id), "/canvases/not-a-uuid")

      assert html =~ ~s|data-error="not_found"|
    end
  end

  # ── Stage 4: read-only renders inert, never hidden ────────────────────────

  describe "inert read-only rendering" do
    test "action_row, form and checklist_item nodes stay visible", %{conn: conn, org: org} do
      space = channel!(%{org_id: org.id})
      canvas = canvas_with_interactive_nodes!(space)
      {conn, _user} = member_conn(conn, space)

      {:ok, _view, html} = live(conn, ~p"/canvases/#{canvas.id}")

      # Citation parity: an agent that writes "one open action" must not be
      # contradicted by a reader who counts none.
      assert html =~ ~s|data-role="canvas-action-button"|
      assert html =~ "Approve deploy"
      assert html =~ "Ship the migration"
      assert html =~ "Sign off"
      assert html =~ ~s|phx-submit="canvas_form_submit"|
    end

    test "the rendered tree sits under the scoped inert wrapper", %{conn: conn, org: org} do
      space = channel!(%{org_id: org.id})
      canvas = canvas_with_interactive_nodes!(space)
      {conn, _user} = member_conn(conn, space)

      {:ok, view, _html} = live(conn, ~p"/canvases/#{canvas.id}")

      # `.canvas-inert` in app.css is the whole inertness mechanism on the
      # visual side. Losing the class silently restores hover lift and filled
      # buttons on a page that can never act on either.
      assert class_of(view, "canvas-body") =~ "canvas-inert"
    end

    test "inertness does not fork the renderer", %{conn: conn, org: org} do
      space = channel!(%{org_id: org.id})
      canvas = canvas_with_interactive_nodes!(space)
      {conn, _user} = member_conn(conn, space)

      {:ok, view, _html} = live(conn, ~p"/canvases/#{canvas.id}")

      button = element_html(view, "canvas-action-button")

      # The button is the kind module's own output: same phx-click, no
      # `disabled` attribute, no read-only variant threaded through
      # `Renderer.render_node/1`. CSS scoping is what makes it inert, so this
      # page and the chat pane render the same document.
      assert button =~ ~s|phx-click="canvas_action_click"|
      refute button =~ "disabled"
      refute button =~ "read_only"
    end
  end

  # ── Stage 4: the two denial states ────────────────────────────────────────

  describe "the 403 state" do
    test "renders a tinted card with exactly one action", %{conn: conn, org: org} do
      {conn, canvas, _space} = forbidden_same_org(conn, org)

      {:ok, view, html} = live(conn, ~p"/canvases/#{canvas.id}")

      assert html =~ ~s|data-error="forbidden"|

      card = class_of(view, "canvas-forbidden-card")
      assert card =~ "rounded-box"
      assert card =~ "border-info/30"
      assert card =~ "bg-info/10"

      # Exactly ONE action. A second one would turn a door into a menu.
      denial = element_html(view, "canvas-load-error")
      assert length(Regex.scan(~r/data-role="canvas-denial-action"/, denial)) == 1
    end

    test "the action names the owner from the creator snapshot", %{conn: conn, org: org} do
      {conn, canvas, _space} = forbidden_same_org(conn, org)

      {:ok, _view, html} = live(conn, ~p"/canvases/#{canvas.id}")

      assert html =~ "Ask Saru for access"
    end

    test "names the parent space to a viewer who shares its org", %{conn: conn, org: org} do
      {conn, canvas, space} = forbidden_same_org(conn, org)

      {:ok, view, _html} = live(conn, ~p"/canvases/#{canvas.id}")

      place = element_html(view, "canvas-forbidden-place")
      assert place =~ org.name
      assert place =~ space.name
    end

    test "says 'a private space' to everyone else", %{conn: conn, org: org} do
      {conn, canvas, space} = forbidden_other_org(conn, org)

      {:ok, view, _html} = live(conn, ~p"/canvases/#{canvas.id}")

      # The denial page must not be walkable as a directory of spaces.
      place = element_html(view, "canvas-forbidden-place")
      assert place =~ "a private space"
      assert Platform.Regression.InstallIdentityScanner.hits(place) == []
      refute place =~ space.name
      refute place =~ org.name
    end

    test "carries a ghost link back to Suite alongside its one primary action",
         %{conn: conn, org: org} do
      {conn, canvas, _space} = forbidden_same_org(conn, org)

      {:ok, view, _html} = live(conn, ~p"/canvases/#{canvas.id}")

      denial = element_html(view, "canvas-load-error")

      # Still exactly ONE primary action: a ghost link is not one.
      assert length(Regex.scan(~r/data-role="canvas-denial-action"/, denial)) == 1

      back = element_html(view, "canvas-forbidden-link")
      assert attr(view, "canvas-forbidden-link", "href") == "/chat"
      assert back =~ "underline"
      refute class_of(view, "canvas-forbidden-link") =~ ~r/(^|\s)btn(\s|$)/
    end

    test "never renders the canvas title or body", %{conn: conn, org: org} do
      {conn, canvas, _space} = forbidden_same_org(conn, org)

      {:ok, _view, html} = live(conn, ~p"/canvases/#{canvas.id}")

      refute html =~ "Audit body"
      refute html =~ canvas.title
      refute html =~ ~s|data-role="canvas-provenance-bar"|
    end
  end

  describe "the 404 state" do
    test "renders no card, no tint and zero actions", %{conn: conn} do
      {conn, missing_id} = {login(conn, create_user!().id), Ecto.UUID.generate()}

      {:ok, view, html} = live(conn, ~p"/canvases/#{missing_id}")

      assert html =~ ~s|data-error="not_found"|

      denial = element_html(view, "canvas-load-error")

      # A clean dead end should look like one: bare text on `--color-base-100`.
      refute denial =~ "canvas-forbidden-card"
      refute denial =~ "rounded-box"
      refute denial =~ "bg-info"

      # ZERO actions. Offering one would imply a path that does not exist, so
      # the single way back is a ghost link and not a button.
      refute denial =~ ~r/class="[^"]*\bbtn\b/
      refute denial =~ "canvas-denial-action"
      assert denial =~ ~s|data-role="canvas-not-found-link"|
    end
  end

  describe "the two denial states differ in shape, not only in copy" do
    test "card present versus absent, action count one versus zero", %{conn: conn, org: org} do
      space = channel!(%{kind: "execution", org_id: org.id})
      canvas = canvas_with_heading!(space, "Audit body")
      viewer = create_user!()
      plain_member!(viewer, org)

      {:ok, forbidden_view, _} = live(login(conn, viewer.id), ~p"/canvases/#{canvas.id}")

      {:ok, not_found_view, _} =
        live(login(conn, viewer.id), ~p"/canvases/#{Ecto.UUID.generate()}")

      forbidden = element_html(forbidden_view, "canvas-load-error")
      not_found = element_html(not_found_view, "canvas-load-error")

      # Blur the text out and these still say different things.
      assert forbidden =~ "canvas-forbidden-card"
      refute not_found =~ "canvas-forbidden-card"

      assert length(Regex.scan(~r/data-role="canvas-denial-action"/, forbidden)) == 1
      assert length(Regex.scan(~r/data-role="canvas-denial-action"/, not_found)) == 0
    end

    test "neither state uses --color-error", %{conn: conn, org: org} do
      space = channel!(%{kind: "execution", org_id: org.id})
      canvas = canvas_with_heading!(space, "Audit body")
      viewer = create_user!()
      plain_member!(viewer, org)

      {:ok, forbidden_view, _} = live(login(conn, viewer.id), ~p"/canvases/#{canvas.id}")

      {:ok, not_found_view, _} =
        live(login(conn, viewer.id), ~p"/canvases/#{Ecto.UUID.generate()}")

      # A permission boundary is not a system failure. Red would teach viewers
      # that a normal denial is a bug; it stays reserved for `render_invalid`.
      for denial <- [
            element_html(forbidden_view, "canvas-load-error"),
            element_html(not_found_view, "canvas-load-error")
          ] do
        refute denial =~ "text-error"
        refute denial =~ "bg-error"
        refute denial =~ "border-error"
        refute denial =~ "btn-error"
      end
    end
  end

  # ── Route shape ───────────────────────────────────────────────────────────

  describe "route registration" do
    test "resolves to CanvasLive in its OWN :canvas_standalone live_session" do
      assert %{phoenix_live_view: {PlatformWeb.CanvasLive, :show, _opts, %{name: name}}} =
               Phoenix.Router.route_info(@router, "GET", "/canvases/#{Ecto.UUID.generate()}", nil)

      # NOT `:authenticated`. `:enforce_external_scope` is an HTTP plug and a
      # `live_redirect` inside one live_session never re-enters the plug
      # pipeline, so sharing the session with /chat would let a chat-to-canvas
      # hop skip the external gate entirely.
      assert name == :canvas_standalone
      refute name == :authenticated
    end

    test "still runs the default scope's auth + external-scope pipeline" do
      %{pipe_through: pipeline} =
        Phoenix.Router.route_info(@router, "GET", "/canvases/#{Ecto.UUID.generate()}", nil)

      assert :browser in pipeline
      assert :require_auth in pipeline
      assert :enforce_external_scope in pipeline
    end
  end

  # ── Audit ─────────────────────────────────────────────────────────────────

  describe "audit" do
    test "an org_reader arrival mints exactly one canvas_read row, not one per socket", %{
      conn: conn,
      org: org
    } do
      space = channel!(%{org_id: org.id})
      canvas = canvas_with_heading!(space, "Body")

      # Org member, NOT a space participant — the `:org_reader` path, which is
      # the sensitive read the audit stream exists for.
      reader = create_user!()
      plain_member!(reader, org)

      {:ok, _view, _html} = live(login(conn, reader.id), ~p"/canvases/#{canvas.id}")

      # `live/2` runs the disconnected render AND the connected mount. Only
      # the disconnected one audits (`audit: not connected?(socket)`), so a
      # single human arrival is a single row.
      assert [row] = Audit.list(resource_type: "canvas", resource_id: canvas.id)
      assert row.action == "read"
      assert row.actor_id == reader.id
    end

    test "a member arrival mints no audit row", %{conn: conn, org: org} do
      space = channel!(%{org_id: org.id})
      canvas = canvas_with_heading!(space, "Body")
      {conn, _user} = member_conn(conn, space)

      {:ok, _view, _html} = live(conn, ~p"/canvases/#{canvas.id}")

      assert Audit.list(resource_type: "canvas", resource_id: canvas.id) == []
    end
  end
end
