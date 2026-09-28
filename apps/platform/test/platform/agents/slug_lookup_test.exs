defmodule Platform.Agents.SlugLookupTest do
  @moduledoc """
  `Platform.Agents.SlugLookup.resolve/2` is the fail-closed replacement for
  bare `Repo.get_by(Agent, slug: ...)` (task 01a0e77c).

  Every same-slug fixture here puts the two agents in DISTINCT NON-NIL
  workspaces, except the single mixed NULL/non-NULL case: once
  `agents_unique_slug` is NULLS NOT DISTINCT, two NULL-workspace rows with
  one slug cannot be inserted, and these tests must survive that.
  """
  use Platform.DataCase, async: true

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Agents.SlugLookup
  alias Platform.Repo

  defp insert_agent!(attrs) do
    %Agent{}
    |> Agent.changeset(Map.merge(%{name: "Agent", status: "active"}, attrs))
    |> Repo.insert!()
  end

  defp unique_slug, do: "slug-lookup-#{System.unique_integer([:positive])}"

  defp two_workspace_collision do
    slug = unique_slug()
    wid_a = Ecto.UUID.generate()
    wid_b = Ecto.UUID.generate()
    a = insert_agent!(%{slug: slug, workspace_id: wid_a})
    b = insert_agent!(%{slug: slug, workspace_id: wid_b})
    %{slug: slug, a: a, b: b, wid_a: wid_a, wid_b: wid_b}
  end

  describe "premise (positive control)" do
    test "the two-workspace fixture really crashes a bare Repo.get_by(Agent, slug:)" do
      %{slug: slug} = two_workspace_collision()

      assert_raise Ecto.MultipleResultsError, fn ->
        Repo.get_by(Agent, slug: slug)
      end
    end
  end

  describe "resolve/2 unscoped" do
    test "a unique slug resolves to its agent" do
      agent = insert_agent!(%{slug: unique_slug()})
      assert {:ok, %Agent{id: id}} = SlugLookup.resolve(agent.slug)
      assert id == agent.id
    end

    test "an unknown slug is :not_found" do
      assert {:error, :not_found} = SlugLookup.resolve(unique_slug())
    end

    test "nil, a non-binary and the empty string are :not_found" do
      assert {:error, :not_found} = SlugLookup.resolve(nil)
      assert {:error, :not_found} = SlugLookup.resolve(42)
      assert {:error, :not_found} = SlugLookup.resolve("")
    end

    test "a slug shared across two workspaces is :ambiguous_slug and logs a warning" do
      %{slug: slug, a: a, b: b, wid_a: wid_a, wid_b: wid_b} = two_workspace_collision()

      log =
        capture_log([level: :warning], fn ->
          assert {:error, :ambiguous_slug} = SlugLookup.resolve(slug)
        end)

      assert log =~ slug
      assert log =~ "unscoped"
      assert log =~ a.id
      assert log =~ b.id
      assert log =~ wid_a
      assert log =~ wid_b
    end
  end

  describe "resolve/2 scoped by :workspace_id" do
    test "each workspace resolves to its own agent" do
      %{slug: slug, a: a, b: b, wid_a: wid_a, wid_b: wid_b} = two_workspace_collision()

      assert {:ok, %Agent{id: id_a}} = SlugLookup.resolve(slug, workspace_id: wid_a)
      assert id_a == a.id
      assert {:ok, %Agent{id: id_b}} = SlugLookup.resolve(slug, workspace_id: wid_b)
      assert id_b == b.id
    end

    test "a workspace with no such slug is :not_found" do
      %{slug: slug} = two_workspace_collision()

      assert {:error, :not_found} =
               SlugLookup.resolve(slug, workspace_id: Ecto.UUID.generate())
    end

    test "workspace_id: nil means IS NULL and picks the NULL-workspace agent" do
      slug = unique_slug()
      null_agent = insert_agent!(%{slug: slug})
      _ws_agent = insert_agent!(%{slug: slug, workspace_id: Ecto.UUID.generate()})

      assert {:ok, %Agent{id: id}} = SlugLookup.resolve(slug, workspace_id: nil)
      assert id == null_agent.id
    end

    test "workspace_id: nil does not match a slug that exists only in a workspace" do
      slug = unique_slug()
      _ws_agent = insert_agent!(%{slug: slug, workspace_id: Ecto.UUID.generate()})

      assert {:error, :not_found} = SlugLookup.resolve(slug, workspace_id: nil)
      assert {:ok, _} = SlugLookup.resolve(slug)
    end
  end
end
