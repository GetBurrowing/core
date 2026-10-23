defmodule Platform.Files.BrowserTest do
  @moduledoc """
  `Platform.Files.Browser`, the query layer behind the Files & Canvases
  browser (task 01a1557a-b5f9 stage 1).

  Every absence is preceded, on the same fixture, by its positive control:
  a `:not_found` sits beside the same call answering for the viewer's own
  project or space, and a denied canvas is shown present before the deny.

  Mutation probes run while writing this file (stage report has the output):
    (a) drop `maybe_scope_canvases` from `Chat.list_browser_canvases/2`;
    (b) remove the `%` escape in `Files.search_files_by_name/3`;
    (c) take the project id from the argument in `in_project/2`;
    (d) make `:canvas` include games in `Chat.list_browser_canvases/2`.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.TenancyFixtures

  alias Platform.Access.{Grants, Scope}
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.{Canvas, Participant, Space}
  alias Platform.Files
  alias Platform.Files.Browser
  alias Platform.Files.Browser.Item
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  setup do
    Application.put_env(:platform, :canvas_persist_sync, true)
    on_exit(fn -> Application.put_env(:platform, :canvas_persist_sync, true) end)

    _root = acme_org_id()
    org_a = org!("Org A")
    org_b = org!("Org B")
    org_c = org!("Org C")

    user = user!("Ada Example")
    member!(user, org_a)
    member!(user, org_b)

    project_a = project!("alpha-design", org_a)
    project_b = project!("bravo-build", org_b)
    foreign_project = project!("charlie-ops", org_c)

    space_a = space!("alpha-channel", org_a)
    space_b = space!("bravo-channel", org_b)
    loose = space!("loose-channel", nil)
    archived = space!("archived-channel", org_a)
    stranger_space = space!("stranger-channel", org_a)

    participant_a = join!(space_a, user)
    participant_b = join!(space_b, user)
    _ = join!(loose, user)
    _ = join!(archived, user)
    {:ok, _} = Chat.archive_space(archived)

    %{
      org_a: org_a,
      org_b: org_b,
      org_c: org_c,
      user: user,
      project_a: project_a,
      project_b: project_b,
      foreign_project: foreign_project,
      space_a: space_a,
      space_b: space_b,
      loose: loose,
      archived: archived,
      stranger_space: stranger_space,
      participant_a: participant_a,
      participant_b: participant_b
    }
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp n, do: System.unique_integer([:positive])

  defp org!(name) do
    {:ok, org} = Tenancy.create_org(root_admin!(), %{name: name, slug: "browser-org-#{n()}"})
    org
  end

  defp user!(name) do
    k = n()
    Repo.insert!(%User{email: "browser-#{k}@example.com", name: name, oidc_sub: "browser-#{k}"})
  end

  defp member!(user, org) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "member"})
    |> Repo.insert!()
  end

  defp project!(name, org) do
    {:ok, p} = Tasks.create_project(%{name: "#{name}-#{n()}", org_id: org.id})
    p
  end

  defp space!(name, org) do
    k = n()

    %Space{}
    |> Space.changeset(%{
      kind: "channel",
      name: "#{name}-#{k}",
      slug: "#{name}-#{k}",
      org_id: org && org.id
    })
    |> Repo.insert!()
  end

  defp join!(space, user) do
    Repo.insert!(%Participant{
      space_id: space.id,
      participant_type: "user",
      participant_id: user.id,
      role: "member",
      display_name: user.name,
      joined_at: DateTime.utc_now()
    })
  end

  defp viewer(user) do
    user = Accounts.get_user(user.id)
    %{user: user, access_scope: Scope.for_user(user)}
  end

  defp file!(project, name, opts \\ []) do
    {:ok, file} =
      Files.create_file(%{
        project_id: project.id,
        name: name,
        original_filename: name,
        content_type: Keyword.get(opts, :content_type, "application/pdf"),
        byte_size: 10,
        storage_key: "files/#{project.id}/#{n()}/#{name}",
        content_hash: :crypto.hash(:sha256, "#{name}-#{n()}") |> Base.encode16(case: :lower),
        uploaded_by_user_id: Keyword.get(opts, :uploader_id),
        ingest_intent: Keyword.get(opts, :ingest_intent, "attempt")
      })

    file
  end

  defp attachment!(space, message, filename, content_type) do
    {:ok, att} =
      Chat.create_attachment(%{
        space_id: space.id,
        message_id: message.id,
        filename: filename,
        content_type: content_type,
        byte_size: 10,
        storage_key: "browser-#{n()}"
      })

    att
  end

  defp text_doc(body) do
    %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{"gap" => 12},
        "children" => [
          %{"id" => "t1", "type" => "text", "props" => %{"value" => body}, "children" => []}
        ]
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }
  end

  # Indexed body: created through `Chat.create_canvas/1`, which writes the
  # `chat_canvas_search` row the way canvas_search_index_test.exs relies on.
  defp canvas!(space, participant, title, body \\ "plain body") do
    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => participant.id,
        "created_by_display_name" => "Ada Example",
        "title" => title,
        "document" => text_doc(body)
      })

    canvas
  end

  # The document map is inserted directly: the kind need not be registered
  # for the query to see a nested `game_stream` node.
  defp game!(space, participant, title) do
    Repo.insert!(%Canvas{
      space_id: space.id,
      created_by: participant.id,
      title: title,
      document: %{
        "version" => 1,
        "revision" => 1,
        "root" => %{
          "id" => "root",
          "type" => "stack",
          "children" => [
            %{
              "id" => "card",
              "type" => "card",
              "children" => [%{"id" => "g", "type" => "game_stream", "props" => %{}}]
            }
          ]
        }
      }
    })
  end

  defp age!(%Canvas{id: id}, days) do
    at = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
    Repo.update_all(from(c in Canvas, where: c.id == ^id), set: [updated_at: at])
  end

  defp age!(%Files.File{id: id}, days) do
    at = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
    Repo.update_all(from(f in Files.File, where: f.id == ^id), set: [updated_at: at])
  end

  defp ids(items), do: Enum.map(items, & &1.id)

  # ── tree/1 ──────────────────────────────────────────────────────────────

  describe "tree/1" do
    test "groups the viewer's projects and spaces under their orgs", ctx do
      tree = Browser.tree(viewer(ctx.user))

      assert Enum.map(tree.orgs, & &1.org.id) |> Enum.sort() ==
               Enum.sort([ctx.org_a.id, ctx.org_b.id])

      node_a = Enum.find(tree.orgs, &(&1.org.id == ctx.org_a.id))
      node_b = Enum.find(tree.orgs, &(&1.org.id == ctx.org_b.id))

      assert ids(node_a.projects) == [ctx.project_a.id]
      assert ids(node_a.spaces) == [ctx.space_a.id]
      assert ids(node_b.projects) == [ctx.project_b.id]
      assert ids(node_b.spaces) == [ctx.space_b.id]

      # A space with no org lands in :other.
      assert ids(tree.other.spaces) == [ctx.loose.id]
      assert tree.other.projects == []
    end

    test "a third org's project, an archived space and a non-member space are absent", ctx do
      tree = Browser.tree(viewer(ctx.user))
      all_projects = Enum.flat_map(tree.orgs, & &1.projects) ++ tree.other.projects
      all_spaces = Enum.flat_map(tree.orgs, & &1.spaces) ++ tree.other.spaces

      refute ctx.org_c.id in Enum.map(tree.orgs, & &1.org.id)
      refute ctx.foreign_project.id in ids(all_projects)
      refute ctx.archived.id in ids(all_spaces)
      refute ctx.stranger_space.id in ids(all_spaces)

      # Positive control on the same tree.
      assert ctx.project_a.id in ids(all_projects)
      assert ctx.space_a.id in ids(all_spaces)
    end

    test "the order of orgs is stable across calls", ctx do
      v = viewer(ctx.user)

      assert Enum.map(Browser.tree(v).orgs, & &1.org.id) ==
               Enum.map(Browser.tree(v).orgs, & &1.org.id)
    end
  end

  # ── in_project/2 and in_space/2 ─────────────────────────────────────────

  describe "in_project/2" do
    test "returns the viewer's own project's files and :not_found for another org's", ctx do
      file = file!(ctx.project_a, "alpha-brief.pdf", uploader_id: ctx.user.id)
      foreign_file = file!(ctx.foreign_project, "charlie-brief.pdf")
      v = viewer(ctx.user)

      assert {:ok, [item]} = Browser.in_project(v, ctx.project_a.id)
      assert %Item{id: id, kind: :file, type: :doc, author: "Ada Example"} = item
      assert id == file.id
      assert item.href == "/files/#{ctx.project_a.id}?file=#{file.id}"
      assert item.location_href == "/files/#{ctx.project_a.id}"
      assert item.org_id == ctx.org_a.id
      assert item.thumb_src == nil

      assert Browser.in_project(v, ctx.foreign_project.id) == :not_found
      refute foreign_file.id in ids(Browser.recents(v).items)
    end

    test "a non-UUID or unknown id is :not_found, not a crash", ctx do
      v = viewer(ctx.user)
      assert Browser.in_project(v, "not-a-uuid") == :not_found
      assert Browser.in_project(v, Ecto.UUID.generate()) == :not_found
    end
  end

  describe "in_space/2" do
    test "returns the viewer's own space's canvases and :not_found for a non-member space",
         ctx do
      canvas = canvas!(ctx.space_a, ctx.participant_a, "alpha-board")
      outsider = join!(ctx.stranger_space, user!("Bea Example"))
      _hidden = canvas!(ctx.stranger_space, outsider, "stranger-board")
      v = viewer(ctx.user)

      assert {:ok, [item]} = Browser.in_space(v, ctx.space_a.id)
      assert %Item{kind: :canvas, type: :canvas, author: "Ada Example"} = item
      assert item.id == canvas.id
      assert item.href == "/canvases/#{canvas.id}"
      assert item.location_href == "/files?space=#{ctx.space_a.id}"
      assert item.org_id == ctx.org_a.id

      assert Browser.in_space(v, ctx.stranger_space.id) == :not_found
      assert Browser.in_space(v, ctx.archived.id) == :not_found
    end
  end

  describe "in_space/2 shared files" do
    test "returns the space's canvases AND its shared files, images with a thumbnail", ctx do
      canvas = canvas!(ctx.space_a, ctx.participant_a, "alpha-board")

      {:ok, msg} =
        Chat.post_message(%{
          space_id: ctx.space_a.id,
          participant_id: ctx.participant_a.id,
          content_type: "text",
          content: "sharing two files"
        })

      pdf = attachment!(ctx.space_a, msg, "alpha-spec.pdf", "application/pdf")
      png = attachment!(ctx.space_a, msg, "alpha-shot.png", "image/png")

      # Positive control for scoping: another space's attachment stays out.
      {:ok, other_msg} =
        Chat.post_message(%{
          space_id: ctx.space_b.id,
          participant_id: ctx.participant_b.id,
          content_type: "text",
          content: "elsewhere"
        })

      elsewhere = attachment!(ctx.space_b, other_msg, "bravo.pdf", "application/pdf")

      assert {:ok, items} = Browser.in_space(viewer(ctx.user), ctx.space_a.id)
      by_id = Map.new(items, &{&1.id, &1})

      assert Enum.sort(Map.keys(by_id)) == Enum.sort([canvas.id, pdf.id, png.id])
      refute Map.has_key?(by_id, elsewhere.id)

      assert %Item{kind: :space_file, type: :doc, thumb_src: nil} = by_id[pdf.id]
      assert by_id[pdf.id].href == "/chat/attachments/#{pdf.id}"
      assert by_id[pdf.id].location_href == "/files?space=#{ctx.space_a.id}"
      assert by_id[pdf.id].org_id == ctx.org_a.id
      assert by_id[pdf.id].author == "Ada Example"

      assert %Item{kind: :space_file, type: :image} = by_id[png.id]
      assert by_id[png.id].thumb_src == "/chat/attachments/#{png.id}"
      assert by_id[canvas.id].kind == :canvas
    end
  end

  # ── recents/2 ───────────────────────────────────────────────────────────

  describe "recents/2" do
    test "files and canvases changed in the last 3 days, newest first", ctx do
      two_days = canvas!(ctx.space_a, ctx.participant_a, "two-days")
      four_days = canvas!(ctx.space_b, ctx.participant_b, "four-days")
      one_day = file!(ctx.project_b, "one-day.pdf")
      age!(two_days, 2)
      age!(four_days, 4)
      age!(one_day, 1)

      %{items: items, capped?: false} = Browser.recents(viewer(ctx.user))
      got = ids(items)

      assert one_day.id in got
      assert two_days.id in got
      refute four_days.id in got

      assert Enum.filter(got, &(&1 in [one_day.id, two_days.id])) == [one_day.id, two_days.id]

      ats = Enum.map(items, & &1.at)
      assert ats == Enum.sort(ats, {:desc, DateTime})
    end

    test "reports capped? when more items than :limit exist", ctx do
      for t <- ~w(one two three), do: canvas!(ctx.space_a, ctx.participant_a, t)
      assert %{items: items, capped?: true} = Browser.recents(viewer(ctx.user), limit: 2)
      assert length(items) == 2

      assert %{capped?: false} = Browser.recents(viewer(ctx.user), limit: 10)
    end
  end

  # ── of_type/3 ───────────────────────────────────────────────────────────

  describe "of_type/3" do
    test ":canvas returns canvases from both orgs and no game; :game returns the game", ctx do
      a = canvas!(ctx.space_a, ctx.participant_a, "alpha-board")
      b = canvas!(ctx.space_b, ctx.participant_b, "bravo-board")
      game = game!(ctx.space_a, ctx.participant_a, "alpha-game")
      v = viewer(ctx.user)

      canvases = Browser.of_type(v, :canvas).items
      assert Enum.sort(ids(canvases)) == Enum.sort([a.id, b.id])
      assert Enum.all?(canvases, &(&1.type == :canvas))
      assert MapSet.new(canvases, & &1.org_id) == MapSet.new([ctx.org_a.id, ctx.org_b.id])

      assert [%Item{type: :game} = g] = Browser.of_type(v, :game).items
      assert g.id == game.id
    end

    test ":image and :doc split project files by content type", ctx do
      image = file!(ctx.project_a, "alpha-shot.png", content_type: "image/png")
      doc = file!(ctx.project_b, "bravo-notes.pdf")
      v = viewer(ctx.user)

      assert [%Item{type: :image} = i] = Browser.of_type(v, :image).items
      assert i.id == image.id
      assert i.thumb_src == "/files/blob/#{image.id}"

      assert [%Item{type: :doc} = d] = Browser.of_type(v, :doc).items
      assert d.id == doc.id
      assert d.thumb_src == nil
    end
  end

  # ── search/2 ────────────────────────────────────────────────────────────

  describe "search/2" do
    test "finds a file by name substring, a canvas by body word and a canvas by title", ctx do
      file = file!(ctx.project_a, "quarterly-zephyrine-report.pdf")
      bodied = canvas!(ctx.space_a, ctx.participant_a, "Notes", "mentions the word quixotrel")
      titled = canvas!(ctx.space_b, ctx.participant_b, "Plimsoll roadmap")
      v = viewer(ctx.user)

      assert ids(Browser.search(v, "zephyrine")) == [file.id]
      assert ids(Browser.search(v, "quixotrel")) == [bodied.id]
      assert ids(Browser.search(v, "plimsoll")) == [titled.id]
    end

    test "canvas hits come first, then files, and a game hit is typed :game", ctx do
      file = file!(ctx.project_a, "marigold.pdf")
      canvas = canvas!(ctx.space_a, ctx.participant_a, "marigold board")
      game = game!(ctx.space_a, ctx.participant_a, "marigold game")

      items = Browser.search(viewer(ctx.user), "marigold")
      assert List.last(ids(items)) == file.id
      assert Enum.sort(Enum.take(ids(items), 2)) == Enum.sort([canvas.id, game.id])
      assert Enum.find(items, &(&1.id == game.id)).type == :game
    end

    test "% in the query matches literally", ctx do
      literal = file!(ctx.project_a, "100% done.pdf")
      _decoy = file!(ctx.project_a, "1000 done.pdf")

      assert ids(Browser.search(viewer(ctx.user), "100%")) == [literal.id]
    end

    test "a blank query returns []", ctx do
      _ = file!(ctx.project_a, "anything.pdf")
      assert Browser.search(viewer(ctx.user), "") == []
      assert Browser.search(viewer(ctx.user), "   ") == []
    end

    test "another org's file is not found", ctx do
      _ = file!(ctx.foreign_project, "saffron.pdf")
      mine = file!(ctx.project_a, "saffron-mine.pdf")
      assert ids(Browser.search(viewer(ctx.user), "saffron")) == [mine.id]
    end
  end

  # ── canvas.read deny ────────────────────────────────────────────────────

  describe "a canvas.read deny on one canvas" do
    test "drops it from recents, in_space, of_type and search", ctx do
      denied = canvas!(ctx.space_a, ctx.participant_a, "Ochre denied")
      kept = canvas!(ctx.space_a, ctx.participant_a, "Ochre kept")

      before = viewer(ctx.user)
      assert denied.id in ids(Browser.recents(before).items)
      assert {:ok, items} = Browser.in_space(before, ctx.space_a.id)
      assert denied.id in ids(items)
      assert denied.id in ids(Browser.of_type(before, :canvas).items)
      assert denied.id in ids(Browser.search(before, "ochre"))

      {:ok, _} =
        Grants.deny(%{principal: ctx.user, permission: "canvas.read", resource: denied})

      v = viewer(ctx.user)
      refute denied.id in ids(Browser.recents(v).items)
      assert {:ok, items} = Browser.in_space(v, ctx.space_a.id)
      refute denied.id in ids(items)
      refute denied.id in ids(Browser.of_type(v, :canvas).items)
      refute denied.id in ids(Browser.search(v, "ochre"))

      # The sibling stays.
      assert kept.id in ids(Browser.search(v, "ochre"))
      assert kept.id in ids(items)
    end
  end

  # ── flags ───────────────────────────────────────────────────────────────

  describe "item flags" do
    test "human_only? follows ingest_intent", ctx do
      human = file!(ctx.project_a, "human.pdf", ingest_intent: "human_only")
      agent = file!(ctx.project_a, "agent.pdf")

      {:ok, items} = Browser.in_project(viewer(ctx.user), ctx.project_a.id)
      by_id = Map.new(items, &{&1.id, &1})

      assert by_id[human.id].human_only?
      refute by_id[agent.id].human_only?
    end

    test "cloned? follows cloned_from", ctx do
      parent = canvas!(ctx.space_a, ctx.participant_a, "parent")

      clone =
        Repo.insert!(%Canvas{
          space_id: ctx.space_a.id,
          created_by: ctx.participant_a.id,
          title: "clone",
          cloned_from: parent.id,
          document: text_doc("x")
        })

      {:ok, items} = Browser.in_space(viewer(ctx.user), ctx.space_a.id)
      by_id = Map.new(items, &{&1.id, &1})
      assert by_id[clone.id].cloned?
      refute by_id[parent.id].cloned?
    end
  end

  # ── pure helpers ────────────────────────────────────────────────────────

  describe "sort/2 and filter/2" do
    setup do
      now = DateTime.utc_now()
      at = fn s -> DateTime.add(now, -s, :second) end

      items = [
        %Item{id: "img", type: :image, title: "apple", at: at.(10)},
        %Item{id: "doc", type: :doc, title: "Banana", at: at.(5)},
        %Item{id: "game", type: :game, title: "cherry", at: at.(1)},
        %Item{id: "can-old", type: :canvas, title: "Apple", at: at.(30)},
        %Item{id: "can-new", type: :canvas, title: "apple", at: at.(2)}
      ]

      %{items: items}
    end

    test ":recent is newest first", %{items: items} do
      assert ids(Browser.sort(items, :recent)) == ~w(game can-new doc img can-old)
    end

    test ":name is case-insensitive, newest first within a name", %{items: items} do
      assert ids(Browser.sort(items, :name)) == ~w(can-new img can-old doc game)
    end

    test ":type is canvas, game, doc, image, then name", %{items: items} do
      assert ids(Browser.sort(items, :type)) == ~w(can-new can-old game doc img)
    end

    test "filter/2 keeps one type; nil and :all keep everything", %{items: items} do
      assert ids(Browser.filter(items, :canvas)) == ~w(can-old can-new)
      assert ids(Browser.filter(items, :image)) == ~w(img)
      assert Browser.filter(items, :all) == items
      assert Browser.filter(items, nil) == items
    end
  end

  describe "games_enabled?/0" do
    test "mirrors whether the game_stream kind is registered" do
      assert Browser.games_enabled?() ==
               (Platform.Chat.Canvas.Kinds.get("game_stream") != nil)
    end
  end
end
