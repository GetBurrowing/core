defmodule Platform.Federation.MemoryRenamePrefixTest do
  @moduledoc """
  Task 01a1386d-e528 stage 1: `memory_rename`'s subtree mode.

  When BOTH paths are page-namespace prefixes ending in `/`, the tool routes
  to `Platform.Org.Wiki.rename_prefix/3`. That trailing-slash input is the
  only response this stage changes. Measured on the base
  (`origin/stack/rbac-roles` 94dc8189, a probe run on moon) before the change:

    * Historian, pages under the prefix: `{:error, %{code: :not_found,
      error: "Page not found at path \\"org/page/eng/\\".", …}}` and the pages
      stayed put.
    * Historian, nothing under the prefix: the same `:not_found` envelope.
    * Plain agent: `:historian_required` on the source gate.

  The last two are pinned below as unchanged, byte for byte.
  """

  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Federation.ToolSurface
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.{Node, NodePath, Nodes}
  alias Platform.Org.WikiPage
  alias Platform.Repo

  setup do
    Repo.delete_all(NodePath)
    Repo.delete_all(Node)
    Repo.delete_all(WikiPage)

    %{historian: create_agent("historian", true), plain: create_agent("plain", false)}
  end

  defp create_agent(prefix, historian?) do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}",
        name: String.capitalize(prefix),
        status: "active"
      })
      |> Repo.insert()

    if historian?, do: {:ok, _} = Platform.Roles.assign_role("historian", agent.id)
    agent
  end

  defp rename(agent, old, new) do
    ToolSurface.execute(
      "memory_rename",
      %{"old_path" => old, "new_path" => new},
      %{agent_id: agent.id}
    )
  end

  test "a Historian renames a subtree; pages and nodes move", %{historian: h} do
    {:ok, _} = Wiki.upsert_page("org/page/eng/x.md", %{content: "x"})
    {:ok, _} = Wiki.upsert_page("org/page/eng/sub/y.md", %{content: "y"})
    {:ok, eng} = Nodes.ensure("org/page/eng/")

    assert {:ok, result} = rename(h, "org/page/eng/", "org/page/engineering/")

    assert result.path == "org/page/engineering/"
    assert result.kind == "page"
    assert result.count == 2

    assert result.renamed == [
             %{from: "org/page/eng/sub/y.md", to: "org/page/engineering/sub/y.md", version: 1},
             %{from: "org/page/eng/x.md", to: "org/page/engineering/x.md", version: 1}
           ]

    assert %WikiPage{content: "x", updated_by: updated_by} =
             Wiki.get_page("org/page/engineering/x.md")

    assert updated_by == h.id
    refute Wiki.get_page("org/page/eng/x.md")
    assert Nodes.current("org/page/engineering/").id == eng.id
  end

  test "an empty prefix returns the base's not_found envelope unchanged", %{historian: h} do
    assert rename(h, "org/page/none/", "org/page/nada/") ==
             {:error,
              %{
                error: "Page not found at path \"org/page/none/\".",
                code: :not_found,
                recoverable: true,
                suggestion:
                  "Verify the path. For pages use `memory_view` to list candidates; for journal days check that the date has entries."
              }}
  end

  test "a plain agent is refused on the source gate, as on the base", %{plain: p} do
    {:ok, _} = Wiki.upsert_page("org/page/eng/x.md", %{content: "x"})

    assert {:error, %{code: :historian_required}} =
             rename(p, "org/page/eng/", "org/page/engineering/")

    assert Wiki.get_page("org/page/eng/x.md")
  end

  test "a conflicting target refuses the whole subtree rename", %{historian: h} do
    {:ok, _} = Wiki.upsert_page("org/page/eng/x.md", %{content: "x"})
    {:ok, _} = Wiki.upsert_page("org/page/eng/z.md", %{content: "z"})
    {:ok, _} = Wiki.upsert_page("org/page/engineering/z.md", %{content: "occupied"})

    assert {:error, env} = rename(h, "org/page/eng/", "org/page/engineering/")
    assert env.code == :conflict
    assert env.conflicts == ["org/page/engineering/z.md"]

    assert Wiki.get_page("org/page/eng/x.md")
    assert %WikiPage{content: "occupied"} = Wiki.get_page("org/page/engineering/z.md")
  end

  test "a product-owned prefix is refused by the existing gate", %{historian: h} do
    assert {:error, %{code: :product_owned}} =
             rename(h, "org/page/eng/", "burrow/page/eng/")
  end

  test "a private trailing-slash rename keeps the single-page route", %{historian: h} do
    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Private prefix control",
        slug: "private-prefix-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, _} = Platform.Chat.add_agent_participant(space.id, h, display_name: "Historian")
    base = "space/#{space.id}/private/#{h.id}/"

    assert {:error, %{code: :not_found}} = rename(h, base <> "a/", base <> "b/")
  end

  test "a page-path rename is unchanged and still moves a node", %{historian: h} do
    {:ok, _} = Wiki.upsert_page("org/page/old.md", %{content: "body"})
    {:ok, node} = Nodes.ensure("org/page/old.md")

    assert {:ok, %{path: "org/page/new.md", kind: "page", version: 1}} =
             rename(h, "org/page/old.md", "org/page/new.md")

    assert Nodes.current("org/page/new.md").id == node.id
  end
end
