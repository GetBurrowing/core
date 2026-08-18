defmodule PlatformWeb.Tasks.TaskDisplayMaskTest do
  # Pure functions — no DB, no DataCase.
  use ExUnit.Case, async: true

  alias Platform.MaskAssertions
  alias PlatformWeb.Tasks.TaskDisplay

  # `project_sections/2` yields `{org_slug, org_name, [project]}` three-tuples.
  # The rail renders `Tenancy.scope_label(org_slug)` for the header and
  # `project.name` for each row, so those are the two real names under test.
  defp project(id, name), do: %{id: id, name: name}

  defp sections do
    [
      {"cyberdyne", "Cyberdyne", [project("p1", "Orbit"), project("p2", "Ascent")]},
      {"wayne_tech", "Wayne-Tech", [project("p3", "Shieldwall")]},
      {"sxi", "Small Business Solutions", [project("p4", "Orion")]}
    ]
  end

  # Every real name the rail would render unmasked, in every surface.
  defp real_names do
    [
      "Cyberdyne",
      "Wayne-Tech",
      "Small Business Solutions",
      "Orbit",
      "Ascent",
      "Shieldwall",
      "Orion"
    ]
  end

  describe "mask_labels/3 — masking off" do
    test "every key resolves to the real name the rail would otherwise render" do
      labels = TaskDisplay.mask_labels(sections(), false, MapSet.new())

      # Org display name is scope_label(slug), NOT the tuple's org_name.
      assert labels[{:org, "cyberdyne"}] == Platform.Tenancy.scope_label("cyberdyne")
      assert labels[{:org, "wayne_tech"}] == Platform.Tenancy.scope_label("wayne_tech")

      assert labels[{:project, "p1"}] == "Orbit"
      assert labels[{:project, "p3"}] == "Shieldwall"
      assert labels[{:project, "p4"}] == "Orion"
    end

    test "the map covers every org and every project — one entry each, no more" do
      labels = TaskDisplay.mask_labels(sections(), false, MapSet.new())

      assert map_size(labels) == 3 + 4

      assert Map.keys(labels) |> Enum.sort() ==
               Enum.sort([
                 {:org, "cyberdyne"},
                 {:org, "wayne_tech"},
                 {:org, "sxi"},
                 {:project, "p1"},
                 {:project, "p2"},
                 {:project, "p3"},
                 {:project, "p4"}
               ])
    end
  end

  describe "mask_labels/3 — masking on" do
    test "NO value carries ANY real name, in any of its three spellings" do
      labels = TaskDisplay.mask_labels(sections(), true, MapSet.new())

      # Not a spot check: every value against every fixture name, through the
      # helper that also covers the underscore/hyphen slug forms. `wayne_tech`
      # rendered as `wayne-tech` is exactly the leak a display-form refute misses.
      for {_key, value} <- labels, name <- real_names() do
        MaskAssertions.refute_name_anywhere(value, name)
      end
    end

    test "anti-vacuity: the same sweep FAILS when masking is off" do
      # Proves the sweep above can fire. An absence assertion over a surface
      # that never carried the name passes for free and proves nothing.
      labels = TaskDisplay.mask_labels(sections(), false, MapSet.new())

      assert Enum.any?(labels, fn {_key, value} ->
               Enum.any?(real_names(), fn name ->
                 match?({:error, _}, safe_refute(value, name))
               end)
             end)
    end

    test "orgs letter in section order under the Workspace prefix" do
      labels = TaskDisplay.mask_labels(sections(), true, MapSet.new())

      assert labels[{:org, "cyberdyne"}] == "Workspace A"
      assert labels[{:org, "wayne_tech"}] == "Workspace B"
      assert labels[{:org, "sxi"}] == "Workspace C"
    end

    test "projects letter in FLATTENED rail order across orgs, from A" do
      labels = TaskDisplay.mask_labels(sections(), true, MapSet.new())

      assert labels[{:project, "p1"}] == "Project A"
      assert labels[{:project, "p2"}] == "Project B"
      # First project of the SECOND org continues the flat sequence.
      assert labels[{:project, "p3"}] == "Project C"
      assert labels[{:project, "p4"}] == "Project D"
    end

    test "the two kinds letter independently — both start at A" do
      labels = TaskDisplay.mask_labels(sections(), true, MapSet.new())

      assert labels[{:org, "cyberdyne"}] == "Workspace A"
      assert labels[{:project, "p1"}] == "Project A"
    end

    test "projects roll over past 26 in flattened order" do
      projects = for i <- 1..30, do: project("p#{i}", "Project name #{i}")
      labels = TaskDisplay.mask_labels([{"o", "Org", projects}], true, MapSet.new())

      assert labels[{:project, "p26"}] == "Project Z"
      assert labels[{:project, "p27"}] == "Project AA"
      assert labels[{:project, "p28"}] == "Project AB"
    end

    test "orgs roll over past 26 in section order" do
      sections = for i <- 1..30, do: {"org#{i}", "Org #{i}", []}
      labels = TaskDisplay.mask_labels(sections, true, MapSet.new())

      assert labels[{:org, "org26"}] == "Workspace Z"
      assert labels[{:org, "org27"}] == "Workspace AA"
    end

    test "an empty rail yields an empty map" do
      assert TaskDisplay.mask_labels([], true, MapSet.new()) == %{}
    end
  end

  describe "mask_labels/3 — per-item reveal" do
    test "a MapSet reveals only the listed id" do
      labels = TaskDisplay.mask_labels(sections(), true, MapSet.new(["wayne_tech", "p1"]))

      assert labels[{:org, "wayne_tech"}] == Platform.Tenancy.scope_label("wayne_tech")
      assert labels[{:project, "p1"}] == "Orbit"

      # Everything else stays masked.
      assert labels[{:org, "cyberdyne"}] == "Workspace A"
      assert labels[{:org, "sxi"}] == "Workspace C"
      assert labels[{:project, "p2"}] == "Project B"
      assert labels[{:project, "p3"}] == "Project C"
    end

    test "a plain LIST reveals the same ids as the equivalent MapSet" do
      from_list = TaskDisplay.mask_labels(sections(), true, ["wayne_tech", "p1"])
      from_set = TaskDisplay.mask_labels(sections(), true, MapSet.new(["wayne_tech", "p1"]))

      assert from_list == from_set
    end

    test "revealing an org does NOT reveal its projects" do
      labels = TaskDisplay.mask_labels(sections(), true, MapSet.new(["cyberdyne"]))

      assert labels[{:org, "cyberdyne"}] == Platform.Tenancy.scope_label("cyberdyne")
      assert labels[{:project, "p1"}] == "Project A"
      assert labels[{:project, "p2"}] == "Project B"
    end
  end

  # Wrap the assertion so "did it fire?" is itself testable.
  defp safe_refute(value, name) do
    MaskAssertions.refute_name_anywhere(value, name)
    :ok
  rescue
    e in ExUnit.AssertionError -> {:error, e}
  end
end
