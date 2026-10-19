defmodule Platform.Org.WikiPageOrgTopologyTest do
  @moduledoc """
  ADR 0042 Stage 1 — verifies the schema-level pieces of the WikiPage /
  WikiJournalEntry changes on `org_wiki_pages` / `org_wiki_journal_entries`:

    * `org_id` is required (or auto-defaulted to Acme for legacy callers)
    * `project_id` is accepted as an optional belongs_to
    * Namespaced `file_key`s (`project/<uuid>/page/<rest>`) are accepted

  The original ADR brief called this file `context_file_test.exs`, but
  `Platform.Org.ContextFile` was renamed to `Platform.Org.WikiPage` in
  migration 20260515224500 — these assertions cover the same surface
  against the current module name.
  """

  use Platform.DataCase, async: true

  import Platform.TenancyFixtures

  alias Platform.Org.WikiPage
  alias Platform.Repo

  describe "WikiPage.changeset/2 — ADR 0042 org topology" do
    test "defaults org_id to root Acme when the caller omits it" do
      changeset = WikiPage.changeset(%WikiPage{}, %{file_key: "org/page/identity.md"})
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :org_id) == acme_org_id()
    end

    test "preserves an explicitly-supplied tenant org_id" do
      tenant_id = tenant_org_id("initech")

      changeset =
        WikiPage.changeset(%WikiPage{}, %{
          file_key: "org/page/identity.md",
          org_id: tenant_id
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :org_id) == tenant_id
    end

    test "accepts namespaced project/<uuid>/page/<rest> file_keys" do
      project_id = Ecto.UUID.generate()
      file_key = "project/#{project_id}/page/decisions.md"

      changeset = WikiPage.changeset(%WikiPage{}, %{file_key: file_key})
      assert changeset.valid?

      # The schema-level whitelist was removed in T1; namespaced keys are
      # not constrained beyond the unique (workspace_id, file_key) index.
      assert Ecto.Changeset.get_field(changeset, :file_key) == file_key
    end

    test "round-trips a namespaced page through Repo.insert/1" do
      {:ok, page} =
        %WikiPage{}
        |> WikiPage.changeset(%{
          file_key: "org/page/FILES.md",
          content: "# Files\n",
          org_id: acme_org_id()
        })
        |> Repo.insert()

      assert page.org_id == acme_org_id()
      assert page.file_key == "org/page/FILES.md"
    end

    test "rejects insert when org_id refers to a non-existent org" do
      bogus = Ecto.UUID.generate()
      # Unique key to avoid colliding with the seeded `org/page/identity.md`
      # row through the unique (workspace_id, file_key) index — we want the
      # FK check to be the one that fires.
      file_key = "org/page/adr_0042_fk_test_#{System.unique_integer([:positive])}.md"

      {:error, changeset} =
        %WikiPage{}
        |> WikiPage.changeset(%{file_key: file_key, org_id: bogus})
        |> Repo.insert()

      assert %{org_id: ["does not exist"]} = errors_on(changeset)
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
