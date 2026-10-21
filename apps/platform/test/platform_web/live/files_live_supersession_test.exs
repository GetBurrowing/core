defmodule PlatformWeb.FilesLiveSupersessionTest do
  @moduledoc """
  The supersession ruling UI on the Files surface (task 01a0008c stage 5).

  Deliberately in its own file rather than in `files_live_test.exs`:
  a sibling task has unmerged changes to that file, and this stage's
  cases share none of its fixtures.

  Every fixture here goes through the REAL `Platform.Files.Cataloger`
  with a stubbed LLM transport. Hand-writing a card would let the
  frontmatter this UI reads drift from the frontmatter stage 2 writes,
  and every assertion below would keep passing while the surface
  rendered nothing in production.

  `async: false`: the card provider is wired through application env
  and an OS env var, both process-global.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Files
  alias Platform.Files.Cataloger
  alias Platform.Files.Supersession
  alias Platform.Org.Wiki
  alias Platform.Org.WikiPage
  alias Platform.Repo
  alias Platform.Tasks

  @api_key_env "FILE_CARDS_SUPERSESSION_TEST_KEY"
  @stub_name :file_cards_supersession_llm_test

  # ── Fixtures ───────────────────────────────────────────────────────────

  setup %{conn: conn} do
    {:ok, _} = Application.ensure_all_started(:req)

    previous_cfg = Application.get_env(:platform, :file_cards)

    System.put_env(@api_key_env, "sk-supersession-test")

    Application.put_env(:platform, :file_cards, %{
      provider: :anthropic,
      model: "claude-card-test",
      api_key_env: @api_key_env,
      max_tokens: 700,
      temperature: 0.2
    })

    Application.put_env(
      :platform,
      :anthropic_req_client,
      Req.new(plug: {Req.Test, @stub_name})
    )

    on_exit(fn ->
      Application.delete_env(:platform, :anthropic_req_client)
      System.delete_env(@api_key_env)

      if previous_cfg do
        Application.put_env(:platform, :file_cards, previous_cfg)
      else
        Application.delete_env(:platform, :file_cards)
      end
    end)

    user =
      Repo.insert!(%User{
        email: "files_supersession_#{System.unique_integer([:positive])}@example.com",
        name: "Supersession Ruler",
        oidc_sub: "oidc-supersession-#{System.unique_integer([:positive])}"
      })

    member_of_all_orgs!(user)

    {:ok, project} =
      Tasks.create_project(%{
        name: "Supersession UI #{System.unique_integer([:positive])}",
        org_id: tenant_org_id("globex")
      })

    original = ingested_file!(project, "Order Form.pdf", "Order form, June.")
    revision = ingested_file!(project, "Order Form v1.3.pdf", "Order form, July.")

    stub_llm!("A revised order form.\nSUPERSEDES: Order Form.pdf")

    {:ok, card} = Cataloger.catalog_file(revision)

    assert card.frontmatter["supersedes_file_id"] == original.id,
           "precondition: the fixture must carry a real, resolved claim"

    assert card.frontmatter["supersession_ruling"] == "unruled",
           "precondition: the fixture's claim starts unruled"

    %{
      conn: init_test_session(conn, current_user_id: user.id),
      user: user,
      project: project,
      original: original,
      revision: Files.get_file(revision.id),
      card: card
    }
  end

  # ── The ghost state ────────────────────────────────────────────────────
  #
  # Per the ratified design direction, the claim rides the row of the
  # document being SUPERSEDED ("Superseded by v1.3 — unconfirmed"), not
  # the row of the one doing the superseding. The useful fact is which
  # document is dead, and it is judged beside that document's own
  # preview — which is why there is no queue anywhere in this feature.

  describe "the ghost badge" do
    test "an unruled claim renders on the SUPERSEDED document's row", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/files/#{ctx.project.id}")

      badge = badge_html(view)

      assert badge =~ ~s(data-supersession-ruling="unruled")
      assert badge =~ "Superseded by Order Form v1.3.pdf"
      assert badge =~ "unconfirmed"

      assert has_element?(
               view,
               ~s([data-role="files-row"][data-file-id="#{ctx.original.id}"] [data-role="files-supersession-badge"])
             )
    end

    test "the document doing the superseding wears no badge", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/files/#{ctx.project.id}")

      # Exactly one of the two rows wears it. A badge on every row would
      # make every assertion in this file pass for the wrong reason, and
      # a badge on the WRONG row would still leave a count of one.
      assert length(badge_nodes(view)) == 1

      refute has_element?(
               view,
               ~s([data-role="files-row"][data-file-id="#{ctx.revision.id}"] [data-role="files-supersession-badge"])
             )
    end

    test "carries no hue at all — only confidence", ctx do
      # The design call, and the direction pins it: base-content at 60%
      # while unconfirmed, full weight once ruled. --color-error and
      # --color-warning are named to rule out. Red on this table already
      # means an ingest failed (task 01a0008b is landing more of it),
      # amber is the in-flight ingest pill, and a superseded document is
      # correct and old rather than broken.
      {:ok, view, _html} = live(ctx.conn, ~p"/files/#{ctx.project.id}")

      badge = badge_html(view)

      assert badge =~ "text-subtle",
             "an unconfirmed claim must be quiet — the machine's guess is not a finding yet"

      for taken <-
            ~w(badge-error badge-warning badge-success badge-ghost badge-info badge-primary) do
        refute badge =~ taken,
               "the ghost badge reuses #{taken}; status_badge_class/1 already means something by it"
      end
    end

    test "the detail pane names the claimant and offers both verbs", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/files/#{ctx.project.id}")

      select_row(view, ctx.original.id)

      panel = panel_html(view)

      assert panel =~ ~s(data-supersession-ruling="unruled")
      assert panel =~ "Card says: superseded by Order Form v1.3.pdf."
      assert panel =~ "Confirm"
      assert panel =~ "Not true"

      assert panel =~ "published and searchable either way",
             "the panel must say plainly that the ruling withholds nothing"
    end

    test "the verbs sit beside the superseded document's own preview", ctx do
      # The direction's whole argument for not building a queue: the
      # ruling is answered with the evidence in view.
      {:ok, view, _html} = live(ctx.conn, ~p"/files/#{ctx.project.id}")

      select_row(view, ctx.original.id)

      assert has_element?(view, ~s([data-role="files-detail-preview"]))
      assert has_element?(view, ~s([data-role="files-supersession-panel"]))
    end
  end

  # ── Ruling ─────────────────────────────────────────────────────────────

  describe "Confirm" do
    test "leaves the ghost state and persists the ruling", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/files/#{ctx.project.id}")

      select_row(view, ctx.original.id)
      assert badge_html(view) =~ ~s(data-supersession-ruling="unruled")

      view |> element(~s([data-role="files-supersession-confirm"])) |> render_click()

      badge = badge_html(view)
      assert badge =~ ~s(data-supersession-ruling="confirmed")
      refute badge =~ ~s(data-supersession-ruling="unruled")

      refute badge =~ "text-subtle",
             "full weight is the reward for being verified — the badge must stop being quiet"

      refute badge =~ "unconfirmed"

      # And it survives a reload, because it was written, not assigned.
      # The ruling lands on the CLAIMANT's card, not the row that was clicked.
      assert %{ruling: "confirmed"} = Supersession.claim_for_file(reload(ctx.revision))

      page = Wiki.get_page(ctx.card.file_key)
      assert page.frontmatter["supersession_ruling"] == "confirmed"

      assert page.content =~ "Supersedes: Order Form.pdf (confirmed by a person).",
             "the card BODY is what the Historian reads — it cannot still say 'not yet ruled on'"

      refute page.content =~ "claim not yet ruled on"
    end

    test "stamps the ruling human on the card", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/files/#{ctx.project.id}")

      select_row(view, ctx.original.id)
      view |> element(~s([data-role="files-supersession-confirm"])) |> render_click()

      assert Wiki.get_page(ctx.card.file_key).updated_by == ctx.user.id
    end

    test "does not disturb the prose the cataloger wrote", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/files/#{ctx.project.id}")

      select_row(view, ctx.original.id)
      view |> element(~s([data-role="files-supersession-confirm"])) |> render_click()

      page = Wiki.get_page(ctx.card.file_key)

      # The ruling actually landed — without this the three assertions
      # below all hold on the untouched card and this test proves nothing.
      assert page.frontmatter["supersession_ruling"] == "confirmed"

      assert page.content =~ "A revised order form."
      assert page.frontmatter["file_id"] == ctx.revision.id
      assert page.frontmatter["supersedes_file_id"] == ctx.original.id
    end
  end

  describe "Not true" do
    test "records the ruling and drops the row badge", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/files/#{ctx.project.id}")

      select_row(view, ctx.original.id)
      view |> element(~s([data-role="files-supersession-reject"])) |> render_click()

      assert badge_nodes(view) == [],
             "a denied claim must stop implying a supersession in the list"

      assert %{ruling: "rejected"} = Supersession.claim_for_file(reload(ctx.revision))

      page = Wiki.get_page(ctx.card.file_key)
      assert page.content =~ "Does not supersede Order Form.pdf"
      refute page.content =~ "claim not yet ruled on"
    end

    test "the detail pane still shows the ruling, and it is reversible", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/files/#{ctx.project.id}")

      select_row(view, ctx.original.id)
      view |> element(~s([data-role="files-supersession-reject"])) |> render_click()

      panel = panel_html(view)
      assert panel =~ ~s(data-supersession-ruling="rejected")
      assert panel =~ "ruled not true"

      # A ruling is a human judgement; a mis-click must not be terminal.
      view |> element(~s([data-role="files-supersession-confirm"])) |> render_click()

      assert %{ruling: "confirmed"} = Supersession.claim_for_file(reload(ctx.revision))
      assert panel_html(view) =~ ~s(data-supersession-ruling="confirmed")
    end
  end

  # ── The rule the whole design turns on ─────────────────────────────────

  describe "an unruled claim blocks nothing" do
    test "the card is published, catalogued and rendered while nobody has ruled", ctx do
      # Nothing below rules on anything. This is the state an unattended
      # queue decays to, and every one of these must hold in it.
      file = reload(ctx.revision)

      assert is_binary(file.card_file_key),
             "the card was WRITTEN — there is no pending state that withholds it"

      assert not is_nil(file.card_generated_at)

      page = Wiki.get_page(file.card_file_key)
      assert page.frontmatter["supersession_ruling"] == "unruled"

      assert Enum.any?(Wiki.list_pages(), &(&1.file_key == page.file_key)),
             "the card is visible in the wiki like any other page"

      assert page.file_key in Repo.all(
               Wiki.only_card_pages(from(p in WikiPage, select: p.file_key))
             ),
             "the card is in the files corpus the Historian reads"

      assert Enum.any?(Files.list_files_for_project(ctx.project.id), &(&1.id == file.id)),
             "the document itself is still listed"

      {:ok, view, html} = live(ctx.conn, ~p"/files/#{ctx.project.id}")

      assert html =~ "Order Form v1.3.pdf"

      assert has_element?(view, ~s([data-role="files-row"][data-file-id="#{file.id}"])),
             "the row renders — the ghost treatment is a badge, not a hidden row"

      # And its ingest pill is untouched: the claim says nothing about
      # ingest and must not colour it.
      status =
        view
        |> element(
          ~s([data-role="files-row"][data-file-id="#{file.id}"] [data-role="files-status-badge"])
        )
        |> render()

      assert status =~ "Ready"
      assert status =~ "badge-success"

      # The GHOSTED row — the superseded document — is withheld least of
      # all: it wears the badge, and everything else about it is normal.
      assert has_element?(
               view,
               ~s([data-role="files-row"][data-file-id="#{ctx.original.id}"])
             )

      ghosted_status =
        view
        |> element(
          ~s([data-role="files-row"][data-file-id="#{ctx.original.id}"] [data-role="files-status-badge"])
        )
        |> render()

      assert ghosted_status =~ "Ready"
      assert ghosted_status =~ "badge-success"

      select_row(view, ctx.original.id)

      assert has_element?(view, ~s([data-role="files-detail-download"])),
             "every ordinary affordance still works on a ghosted document"
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp select_row(view, file_id) do
    view
    |> element(~s([data-role="files-row"][data-file-id="#{file_id}"]))
    |> render_click()
  end

  defp badge_nodes(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find(~s([data-role="files-supersession-badge"]))
  end

  defp badge_html(view) do
    case badge_nodes(view) do
      [] -> flunk("expected a supersession badge on the file list, found none")
      [node | _] -> Floki.raw_html(node)
    end
  end

  defp panel_html(view) do
    view
    |> element(~s([data-role="files-supersession-panel"]))
    |> render()
  end

  defp ingested_file!(project, filename, text) do
    {:ok, file} =
      Files.create_file(%{
        project_id: project.id,
        org_id: project.org_id,
        original_filename: filename,
        name: filename,
        content_type: "application/pdf",
        byte_size: 1024,
        storage_key: "files/#{project.id}/#{System.unique_integer([:positive])}/#{filename}",
        content_hash: :crypto.hash(:sha256, filename) |> Base.encode16(case: :lower)
      })

    {:ok, file} = Files.update_ingest_status(file, "ingested")
    {:ok, _} = Files.upsert_extracted_text(file.id, text, nil)

    file
  end

  defp reload(file), do: Files.get_file(file.id)

  defp stub_llm!(completion) do
    Req.Test.stub(@stub_name, fn conn ->
      {:ok, _raw, conn} = Plug.Conn.read_body(conn)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "id" => "msg_test",
          "model" => "claude-card-test",
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 100, "output_tokens" => 100},
          "content" => [%{"type" => "text", "text" => completion}]
        })
      )
    end)
  end
end
