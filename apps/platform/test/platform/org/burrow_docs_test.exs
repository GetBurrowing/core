defmodule Platform.Org.BurrowDocsTest do
  @moduledoc """
  `Platform.Org.BurrowDocs` mirrors `docs/burrow/*.md` into `burrow/page/*`
  wiki rows (task 01a10a44 stage 1): insert missing, update only on a content
  difference, prune rows whose file is gone, and never raise at boot.
  """
  use Platform.DataCase, async: true

  import Ecto.Query

  alias Platform.Org.BurrowDocs
  alias Platform.Org.BurrowDocs.Source
  alias Platform.Org.Wiki
  alias Platform.Org.WikiPage
  alias Platform.Repo

  # The repo's docs/burrow, walked from this file — read from disk here so the
  # byte-equality assertion does not compare `docs/0` with itself.
  @repo_docs_dir Path.expand("../../../../../docs/burrow", __DIR__)

  setup do
    root = Platform.Tenancy.get_root_org()
    assert root, "the test database has no root org; BurrowDocs.sync/0 would no-op"
    Repo.delete_all(from(p in WikiPage, where: like(p.file_key, "burrow/page/%")))
    %{root_org: root}
  end

  defp burrow_rows do
    from(p in WikiPage, where: like(p.file_key, "burrow/page/%"), order_by: p.file_key)
    |> Repo.all()
  end

  defp row!(file_key) do
    from(p in WikiPage, where: p.file_key == ^file_key and is_nil(p.workspace_id))
    |> Repo.one!()
  end

  defp fixture_corpus do
    [
      %{file_key: "burrow/page/alpha.md", content: "---\ntitle: Alpha\n---\n\nAlpha body.\n"},
      %{file_key: "burrow/page/beta.md", content: "---\ntitle: Beta\n---\n\nBeta body.\n"},
      %{file_key: "burrow/page/gamma.md", content: "---\ntitle: Gamma\n---\n\nGamma body.\n"}
    ]
  end

  defp insert_row!(file_key, content, org_id) do
    %WikiPage{}
    |> WikiPage.changeset(%{file_key: file_key, content: content, org_id: org_id})
    |> Repo.insert!()
  end

  describe "docs/0" do
    test "has one entry per docs/burrow/*.md file, keyed burrow/page/<basename>" do
      files = @repo_docs_dir |> Path.join("*.md") |> Path.wildcard() |> Enum.sort()
      assert files != [], "expected docs/burrow to hold at least one .md file"

      assert Enum.map(BurrowDocs.docs(), & &1.file_key) ==
               Enum.map(files, &("burrow/page/" <> Path.basename(&1)))
    end
  end

  describe "sync/0 on an empty namespace" do
    test "inserts one row per file, byte-equal to the file, owned by the root org", %{
      root_org: root
    } do
      assert burrow_rows() == []

      assert {:ok, report} = BurrowDocs.sync()
      assert report.failed == []
      assert report.updated == [] and report.deleted == [] and report.unchanged == []

      files = @repo_docs_dir |> Path.join("*.md") |> Path.wildcard() |> Enum.sort()
      rows = burrow_rows()

      assert Enum.map(rows, & &1.file_key) ==
               Enum.map(files, &("burrow/page/" <> Path.basename(&1)))

      assert report.inserted == Enum.map(rows, & &1.file_key)

      for {row, file} <- Enum.zip(rows, files) do
        assert row.content == File.read!(file), "#{row.file_key} is not byte-equal to #{file}"
        assert row.version == 1
        assert row.workspace_id == nil
        assert row.updated_by == nil
        assert row.org_id == root.id
      end
    end

    test "the index row's frontmatter carries preamble: true" do
      {:ok, _} = BurrowDocs.sync()

      index = row!("burrow/page/index.md")
      assert index.frontmatter["preamble"] == true
      assert index.frontmatter["title"] == "Burrow Docs"
    end
  end

  describe "sync is change-driven" do
    # `version` alone cannot tell a skipped write from an equal-content write:
    # Ecto turns an update with no changes into a no-op, so the version stays
    # put either way (measured: a mutation that always calls upsert_page/3
    # passed every version assertion here). The write path's observable side
    # effect is the `org_wiki:index` broadcast, so that is what these assert.
    test "a second sync moves no version or updated_at, and triggers no re-index" do
      {:ok, _} = BurrowDocs.sync(fixture_corpus())
      before = Map.new(burrow_rows(), &{&1.file_key, {&1.version, &1.updated_at}})
      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, Wiki.index_topic())

      assert {:ok, report} = BurrowDocs.sync(fixture_corpus())
      assert report.inserted == [] and report.updated == [] and report.deleted == []
      assert report.unchanged == Enum.map(fixture_corpus(), & &1.file_key)

      assert Map.new(burrow_rows(), &{&1.file_key, {&1.version, &1.updated_at}}) == before
      refute_receive {:wiki_page_written, %{file_key: "burrow/page/" <> _}}, 100
    end

    test "positive control: a corrupted row alone is restored, at version + 1" do
      {:ok, _} = BurrowDocs.sync(fixture_corpus())
      before = Map.new(burrow_rows(), &{&1.file_key, &1})

      # Out-of-band corruption: update_all leaves version and updated_at as
      # they were, so any movement after the sync is the sync's doing.
      {1, _} =
        from(p in WikiPage, where: p.file_key == "burrow/page/beta.md")
        |> Repo.update_all(set: [content: "corrupted"])

      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, Wiki.index_topic())

      assert {:ok, report} = BurrowDocs.sync(fixture_corpus())
      assert report.updated == ["burrow/page/beta.md"]

      # The broadcast the second-sync test refutes does fire for a real
      # change, and only for the changed row.
      assert_receive {:wiki_page_written, %{file_key: "burrow/page/beta.md"}}
      refute_receive {:wiki_page_written, %{file_key: "burrow/page/" <> _}}, 100
      assert report.unchanged == ["burrow/page/alpha.md", "burrow/page/gamma.md"]

      beta = row!("burrow/page/beta.md")
      assert beta.content == Enum.at(fixture_corpus(), 1).content
      assert beta.version == before["burrow/page/beta.md"].version + 1

      for key <- ["burrow/page/alpha.md", "burrow/page/gamma.md"] do
        row = row!(key)
        assert row.version == before[key].version
        assert row.updated_at == before[key].updated_at
      end
    end

    test "the real corpus is also change-driven on a second sync" do
      {:ok, _} = BurrowDocs.sync()
      before = Map.new(burrow_rows(), &{&1.file_key, {&1.version, &1.updated_at}})

      assert {:ok, %{inserted: [], updated: [], deleted: [], failed: []}} = BurrowDocs.sync()
      assert Map.new(burrow_rows(), &{&1.file_key, {&1.version, &1.updated_at}}) == before
    end
  end

  describe "sync prunes" do
    test "a burrow/page row with no file is deleted; an org/page row with the same content survives",
         %{root_org: root} do
      ghost_content = "# Ghost\n\nA doc that was removed from the repo.\n"
      insert_row!("burrow/page/ghost.md", ghost_content, root.id)
      notes = insert_row!("org/page/notes.md", ghost_content, root.id)

      assert {:ok, report} = BurrowDocs.sync(fixture_corpus())
      assert report.deleted == ["burrow/page/ghost.md"]

      refute Repo.get_by(WikiPage, file_key: "burrow/page/ghost.md")

      assert Enum.map(burrow_rows(), & &1.file_key) ==
               Enum.map(fixture_corpus(), & &1.file_key)

      # Control: same content, different namespace — untouched.
      survivor = row!("org/page/notes.md")
      assert survivor.content == ghost_content
      assert survivor.version == notes.version
      assert survivor.updated_at == notes.updated_at
    end
  end

  describe "run_at_boot/1 never raises" do
    test "returns :ok on a real sync" do
      assert BurrowDocs.run_at_boot() == :ok
      assert burrow_rows() != []
    end

    test "returns :ok when sync raises, throws, exits or finds no root org" do
      assert BurrowDocs.run_at_boot(fn -> raise "boom" end) == :ok
      assert BurrowDocs.run_at_boot(fn -> throw(:boom) end) == :ok
      assert BurrowDocs.run_at_boot(fn -> exit(:boom) end) == :ok
      assert BurrowDocs.run_at_boot(fn -> {:error, :no_root_org} end) == :ok

      assert BurrowDocs.run_at_boot(fn -> {:ok, %{failed: [{"burrow/page/x.md", :nope}]}} end) ==
               :ok
    end
  end

  describe "Source.resolve!/1" do
    @tag :tmp_dir
    test "prefers the first existing candidate (the packaged priv copy)", %{tmp_dir: tmp} do
      priv = Path.join(tmp, "priv")
      repo = Path.join(tmp, "repo")
      File.mkdir_p!(priv)
      File.mkdir_p!(repo)
      File.write!(Path.join(priv, "b.md"), "b")
      File.write!(Path.join(priv, "a.md"), "a")
      File.write!(Path.join(priv, "skip.txt"), "x")
      File.write!(Path.join(repo, "r.md"), "r")

      assert Source.resolve!([priv, repo]) ==
               {priv, [Path.join(priv, "a.md"), Path.join(priv, "b.md")]}

      assert Source.resolve!([Path.join(tmp, "absent"), repo]) ==
               {repo, [Path.join(repo, "r.md")]}
    end

    @tag :tmp_dir
    test "raises when the chosen directory holds no .md file", %{tmp_dir: tmp} do
      empty = Path.join(tmp, "empty")
      repo = Path.join(tmp, "repo")
      File.mkdir_p!(empty)
      File.mkdir_p!(repo)
      File.write!(Path.join(repo, "r.md"), "r")

      # A present-but-empty packaged copy is the slip; it must not fall back.
      assert_raise ArgumentError, ~r/contains no \.md files/, fn ->
        Source.resolve!([empty, repo])
      end
    end

    @tag :tmp_dir
    test "raises when no candidate exists", %{tmp_dir: tmp} do
      assert_raise ArgumentError, ~r/source not found/, fn ->
        Source.resolve!([Path.join(tmp, "a"), Path.join(tmp, "b")])
      end
    end

    test "the default candidates are the app's priv copy, then the repo's docs/burrow" do
      [priv, repo] = Source.default_candidates()
      assert String.ends_with?(priv, "apps/platform/priv/burrow_docs")
      assert repo == @repo_docs_dir
    end
  end

  describe "boot wiring" do
    test "the supervised child is transient and calls run_at_boot/0, not sync" do
      source = File.read!(Path.expand("../../../lib/platform/application.ex", __DIR__))

      assert source =~ "|> maybe_add_burrow_docs_seed(flag)"
      assert source =~ "Platform.Org.BurrowDocs.run_at_boot()"
      refute source =~ "Platform.Org.BurrowDocs.sync("
      assert source =~ "id: :burrow_docs_seed"
      assert source =~ "flag.(:platform, :start_burrow_docs_seed, true)"
    end

    test "it is disabled in the test environment" do
      assert Application.get_env(:platform, :start_burrow_docs_seed) == false
    end
  end
end
