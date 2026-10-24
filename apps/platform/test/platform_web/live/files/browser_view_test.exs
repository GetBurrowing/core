defmodule PlatformWeb.Files.BrowserViewTest do
  @moduledoc """
  Unit tests for `PlatformWeb.Files.BrowserView`, the pure view helpers of the
  Files & Canvases browser (task 01a1557a-b5f9 stage 3). No database: trees and
  rail sections are built in memory.
  """
  use ExUnit.Case, async: true

  alias Platform.Chat.Section
  alias PlatformWeb.Files.BrowserView

  # Rail order: the root section first, then Org B, then Org A, so a letter
  # that followed tree order (A before B) instead of the rail would be wrong.
  @sections [
    %{section: %Section{id: "sec-root", org_id: "org-root", org_name: "Root Org"}},
    %{section: %Section{id: "sec-b", org_id: "org-b", org_name: "Org B"}},
    %{section: %Section{id: "sec-a", org_id: "org-a", org_name: "Org A"}}
  ]

  defp tree do
    %{
      orgs: [
        %{
          org: %{id: "org-a", name: "Org A"},
          projects: [%{id: "p1", name: "alpha-design"}, %{id: "p2", name: "alpha-ops"}],
          spaces: [
            %{id: "s1", kind: "channel", name: "org-a-design"},
            %{id: "s2", kind: "channel", name: "atlas"}
          ]
        },
        %{org: %{id: "org-c", name: "Org C"}, projects: [], spaces: []}
      ],
      other: %{projects: [], spaces: [%{id: "s3", kind: "dm", name: nil}]}
    }
  end

  describe "browser_path/2" do
    test "merges overrides, drops nil values and sorts the query" do
      assert BrowserView.browser_path(%{"tab" => "browse"}, %{"type" => "canvas"}) ==
               "/files?tab=browse&type=canvas"

      assert BrowserView.browser_path(%{"tab" => "browse", "type" => "doc"}, %{"type" => nil}) ==
               "/files?tab=browse"

      assert BrowserView.browser_path(%{}, %{}) == "/files"
    end

    test "a project_id becomes the path; an empty q is kept; unknown keys are dropped" do
      assert BrowserView.browser_path(%{"project_id" => "p1", "file" => "f1"}, %{}) ==
               "/files/p1?file=f1"

      assert BrowserView.browser_path(%{"q" => ""}, %{}) == "/files?q="
      assert BrowserView.browser_path(%{"evil" => "x"}, %{}) == "/files"
    end
  end

  describe "browser_layout/2" do
    test "a stored choice wins; Images defaults to grid; everything else to list" do
      assert BrowserView.browser_layout(%{type: :image}, :list) == :list
      assert BrowserView.browser_layout(%{type: nil}, :grid) == :grid
      assert BrowserView.browser_layout(%{type: :image}, nil) == :grid
      assert BrowserView.browser_layout(%{type: :canvas}, nil) == :list
    end
  end

  describe "browser_labels/3" do
    test "unmasked: real names, '#' for channels, 'Conversation' for an unnamed space" do
      labels = BrowserView.browser_labels(tree(), @sections, false)

      assert labels.orgs == %{"org-a" => "Org A", "org-c" => "Org C"}
      assert labels.projects == %{"p1" => "alpha-design", "p2" => "alpha-ops"}
      assert labels.spaces["s1"] == "#org-a-design"
      assert labels.spaces["s3"] == "Conversation"
    end

    test "masked: the rail's letter by section order, re-keyed by org" do
      labels = BrowserView.browser_labels(tree(), @sections, true)

      # Org A is third in the rail: Workspace C, not A.
      assert labels.orgs["org-a"] == "Workspace C"
      # An org with no rail section falls back to the bare word.
      assert labels.orgs["org-c"] == "Workspace"
      # Projects letter in tree order.
      assert labels.projects == %{"p1" => "Project A", "p2" => "Project B"}
      # The org-named channel takes its org's letter; a project-code one stays.
      assert labels.spaces["s1"] == "#workspace-c"
      assert labels.spaces["s2"] == "#atlas"
    end
  end

  describe "browser_labels/3 with two orgs sharing a name (stage-5 advisory)" do
    test "a channel takes ITS org's letter, as the Chat rail row does" do
      sections = [
        %{section: %Section{id: "sec-root", org_id: "org-root", org_name: "Root Org"}},
        %{section: %Section{id: "sec-a1", org_id: "org-a1", org_name: "Org A"}},
        %{section: %Section{id: "sec-a2", org_id: "org-a2", org_name: "Org A"}}
      ]

      tree = %{
        orgs: [
          %{
            org: %{id: "org-a2", name: "Org A"},
            projects: [],
            spaces: [%{id: "s-a2", kind: "channel", name: "org-a-design", org_id: "org-a2"}]
          }
        ],
        other: %{projects: [], spaces: []}
      }

      labels = BrowserView.browser_labels(tree, sections, true)

      # Org A (the second one) is third in the rail: Workspace C, and its
      # channel reads #workspace-c, not the first Org A's #workspace-b.
      assert labels.orgs["org-a2"] == "Workspace C"
      assert labels.spaces["s-a2"] == "#workspace-c"
    end
  end

  describe "browser_crumbs/2" do
    setup do
      %{labels: BrowserView.browser_labels(tree(), @sections, false)}
    end

    test "All alone is the current crumb", %{labels: labels} do
      assert BrowserView.browser_crumbs(%{mode: :browse, node: :all}, labels) ==
               [%{label: "All", href: nil}]
    end

    test "a project node reads All > Org > Project", %{labels: labels} do
      crumbs =
        BrowserView.browser_crumbs(
          %{mode: :browse, node: {:project, %{id: "p1", org_id: "org-a"}}},
          labels
        )

      assert Enum.map(crumbs, & &1.label) == ["All", "Org A", "alpha-design"]

      assert Enum.map(crumbs, & &1.href) ==
               ["/files?tab=browse", "/files?org=org-a&tab=browse", nil]
    end

    test "a space with no org sits under Other spaces", %{labels: labels} do
      crumbs =
        BrowserView.browser_crumbs(
          %{mode: :browse, node: {:space, %{id: "s3", org_id: nil}}},
          labels
        )

      assert Enum.map(crumbs, & &1.label) == ["All", "Other spaces", "Conversation"]
      assert Enum.at(crumbs, 1).href == "/files?org=other&tab=browse"
    end

    test "outside Browse there are no crumbs", %{labels: labels} do
      assert BrowserView.browser_crumbs(%{mode: :recents, node: nil}, labels) == []
    end
  end

  describe "node_label/2" do
    test "labels each node kind through the label map" do
      labels = BrowserView.browser_labels(tree(), @sections, true)

      assert BrowserView.node_label(%{kind: :org, id: "org-a"}, labels) == "Workspace C"
      assert BrowserView.node_label(%{kind: :other, id: "other"}, labels) == "Other spaces"
      assert BrowserView.node_label(%{kind: :project, id: "p2"}, labels) == "Project B"
      assert BrowserView.node_label(%{kind: :space, id: "s2"}, labels) == "#atlas"
      assert BrowserView.node_label(%{kind: :project, id: "nope"}, labels) == "Project"
    end
  end
end
