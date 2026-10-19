defmodule Platform.ScopeRegistryConsistencyTest do
  @moduledoc """
  Guard: NO compiled list of tenant org scopes exists (task 01a14dd9 stage 2).

  This file used to pin a five-atom scope enum across `Platform.Tasks`,
  `Platform.Tenancy` and `PlatformWeb.Components.ScopePill`, so that adding a
  sixth atom to only some of them failed here. Stage 2 deleted every one of
  those lists: scope pills, section dots, recolor swatches and the scope
  filter are driven by `orgs` rows through the slug-agnostic `data-scope`
  path. So the guard now asserts the lists are GONE, and that the row-driven
  replacements answer for a runtime org no code has ever heard of.

  A list coming back under a new name is the failure this cannot see; the
  render-level tests (`scope_pill_test.exs`, the chat LiveView tests) and the
  install-identity guard cover that from the other side.
  """
  use Platform.DataCase, async: true

  alias Platform.Tenancy
  alias Platform.Tenancy.Org

  describe "the compiled lists are gone" do
    test "Tasks.scope_keys/0 does not exist" do
      Code.ensure_loaded!(Platform.Tasks)
      refute function_exported?(Platform.Tasks, :scope_keys, 0)
    end

    test "ScopePill.scopes/0 does not exist" do
      Code.ensure_loaded!(PlatformWeb.Components.ScopePill)
      refute function_exported?(PlatformWeb.Components.ScopePill, :scopes, 0)
    end

    test "Tenancy.scope_color/1 and scope_label/1 do not exist" do
      Code.ensure_loaded!(Tenancy)
      refute function_exported?(Tenancy, :scope_color, 1)
      refute function_exported?(Tenancy, :scope_label, 1)
    end

    test "ChatLive's compiled section helpers do not exist" do
      Code.ensure_loaded!(PlatformWeb.ChatLive)

      for {fun, arity} <- [
            sibling_scope_tokens: 0,
            section_scope_atom: 1,
            section_dot_class: 1,
            parse_scope: 1
          ] do
        refute function_exported?(PlatformWeb.ChatLive, fun, arity), "#{fun}/#{arity}"
      end
    end

    test "no source file under lib/ declares one of the retired attributes" do
      offenders =
        "lib/**/*.{ex,heex}"
        |> Path.wildcard()
        |> Enum.filter(fn path ->
          File.read!(path) =~
            ~r/@(scope_keys|scope_classes|scope_labels|sibling_scope_tokens)\s+(\[|%\{|~w)/
        end)

      assert offenders == []
    end
  end

  describe "the row-driven replacements answer for a runtime org" do
    setup do
      parent = Tenancy.get_root_org()

      {:ok, org} =
        %Org{}
        |> Org.changeset(%{
          name: "Newco Runtime",
          slug: "newco_runtime",
          parent_org_id: parent && parent.id,
          color_hue: 30,
          color_chroma: 0.14,
          color_lightness: 0.7
        })
        |> Repo.insert()

      %{org: org}
    end

    test "css_slug/1 is the section-token form of a slug" do
      assert Tenancy.css_slug("newco_runtime") == "newco-runtime"
      assert Tenancy.css_slug(nil) == nil
    end

    test "the recolor palette includes a coloured org created at runtime", %{org: org} do
      assert %{token: "newco-runtime", slug: "newco_runtime"} =
               Enum.find(Tenancy.scope_palette(), &(&1.slug == org.slug))
    end

    test "the token index resolves the runtime org's token to its row", %{org: org} do
      index = Tenancy.scope_token_index(Tenancy.list_orgs())

      assert %{slug: "newco_runtime", hue: 30, archived?: false} = index["newco-runtime"]
      assert index["newco-runtime"].slug == org.slug
    end
  end
end
