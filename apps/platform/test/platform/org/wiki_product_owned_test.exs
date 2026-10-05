defmodule Platform.Org.WikiProductOwnedTest do
  @moduledoc """
  The domain backstop for the product-owned `burrow/` namespace in
  `Platform.Org.Wiki` and `Platform.Org.Context` (task 01a10a44 stage 2).

  A sibling of `Platform.Org.WikiTest` rather than a describe inside it,
  because that file is `async: true` and these tests write `burrow/page/*`
  rows: every write broadcasts on the global `org_wiki:index` topic, and
  `Platform.Org.BurrowDocsTest` (also async) refutes ANY burrow broadcast
  to prove its sync writes nothing. Running here, `async: false`, keeps the
  two from overlapping.
  """
  use Platform.DataCase, async: false

  alias Platform.Org.Wiki
  alias Platform.Org.WikiPage
  alias Platform.Repo

  setup do
    Repo.delete_all(WikiPage)
    :ok
  end

  # ── Product-owned burrow/ backstop (task 01a10a44 stage 2) ──────────
  #
  # The domain guard for writers that never pass through Wiki.Routing (the
  # org-memory LiveView, memory proposals, the maintenance subagent, file
  # supersession, the cataloger). Only BurrowDocs passes the opt.

  describe "burrow/ backstop — Wiki" do
    test "upsert_page on a burrow key returns {:error, :product_owned} and writes nothing" do
      assert {:error, :product_owned} =
               Wiki.upsert_page("burrow/page/x.md", %{content: "x"})

      refute Wiki.get_page("burrow/page/x.md")
    end

    test "CONTROL: with the BurrowDocs opt the same upsert succeeds" do
      assert {:ok, %WikiPage{file_key: "burrow/page/x.md", version: 1}} =
               Wiki.upsert_page("burrow/page/x.md", %{content: "x"}, product_docs: true)
    end

    test "any burrow/ key is refused, not only burrow/page" do
      assert {:error, :product_owned} = Wiki.upsert_page("burrow/other.md", %{content: "x"})
    end

    test "CONTROL: an org page upserts as before" do
      assert {:ok, %WikiPage{}} = Wiki.upsert_page("org/page/x.md", %{content: "x"})
    end

    test "delete_page on a burrow key is refused and the row survives" do
      {:ok, page} = Wiki.upsert_page("burrow/page/x.md", %{content: "x"}, product_docs: true)

      assert {:error, :product_owned} = Wiki.delete_page("burrow/page/x.md")
      assert %WikiPage{version: v} = Wiki.get_page("burrow/page/x.md")
      assert v == page.version

      # CONTROL: the opt deletes it.
      assert {:ok, _} = Wiki.delete_page("burrow/page/x.md", product_docs: true)
      refute Wiki.get_page("burrow/page/x.md")
    end

    test "rename_page in either direction is refused" do
      {:ok, _} = Wiki.upsert_page("burrow/page/x.md", %{content: "b"}, product_docs: true)
      {:ok, _} = Wiki.upsert_page("org/page/y.md", %{content: "o"})

      assert {:error, :product_owned} = Wiki.rename_page("burrow/page/x.md", "org/page/x.md")
      assert {:error, :product_owned} = Wiki.rename_page("org/page/y.md", "burrow/page/y.md")

      assert Wiki.get_page("burrow/page/x.md")
      assert Wiki.get_page("org/page/y.md")
      refute Wiki.get_page("org/page/x.md")
      refute Wiki.get_page("burrow/page/y.md")

      # CONTROL: an org -> org rename still works.
      assert {:ok, _} = Wiki.rename_page("org/page/y.md", "org/page/z.md")
    end

    test "exclude_product_docs/1 drops burrow rows and keeps the rest" do
      {:ok, _} = Wiki.upsert_page("burrow/page/x.md", %{content: "b"}, product_docs: true)
      {:ok, _} = Wiki.upsert_page("org/page/y.md", %{content: "o"})

      keys =
        WikiPage
        |> Wiki.exclude_product_docs()
        |> Repo.all()
        |> Enum.map(& &1.file_key)

      assert "org/page/y.md" in keys
      refute "burrow/page/x.md" in keys
    end
  end

  describe "burrow/ backstop — Org.Context (the V1 writers)" do
    alias Platform.Org.Context

    test "upsert_context_file, upsert_file and delete_file refuse a burrow key" do
      assert {:error, :product_owned} =
               Context.upsert_context_file("burrow/page/x.md", %{content: "x"})

      assert {:error, :product_owned} =
               Context.upsert_file(%{file_key: "burrow/page/x.md", content: "x"})

      refute Wiki.get_page("burrow/page/x.md")

      {:ok, page} = Wiki.upsert_page("burrow/page/x.md", %{content: "x"}, product_docs: true)

      assert {:error, :product_owned} = Context.delete_file("burrow/page/x.md")

      assert {:error, :product_owned} =
               Context.upsert_context_file("burrow/page/x.md", %{content: "changed"})

      row = Wiki.get_page("burrow/page/x.md")
      assert row.content == "x"
      assert row.version == page.version
    end

    test "CONTROL: the same calls on an org page succeed" do
      assert {:ok, _} = Context.upsert_context_file("org/page/x.md", %{content: "x"})
      assert {:ok, _} = Context.upsert_file(%{file_key: "org/page/x.md", content: "y"})
      assert {:ok, _} = Context.delete_file("org/page/x.md")
    end
  end
end
