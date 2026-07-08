defmodule Platform.Security.Scanners.CveScan.LockfileParserTest do
  @moduledoc """
  Per-format lockfile parser tests (task `019f3e8e-4406` stage 3,
  ADR-0043).

  The scanner leans on these small pure parsers to translate the
  three lockfile formats OSV can query — `mix.lock`,
  `package-lock.json`, `Cargo.lock` — into a flat list of
  `{ecosystem, name, version}` maps. This suite exercises each
  parser independently against fixture strings so a regression in
  one format is isolated to the failing test.
  """
  use ExUnit.Case, async: true

  alias Platform.Security.Scanners.CveScan.LockfileParser

  @fixtures Path.expand("../../../../support/fixtures/security", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  describe "parse_mix_lock/1" do
    test "extracts hex entries and skips git / path sources" do
      assert {:ok, entries} = LockfileParser.parse_mix_lock(fixture("mix.lock.critical"))

      assert %{ecosystem: "Hex", name: "plug", version: "1.14.0"} in entries
      assert %{ecosystem: "Hex", name: "jason", version: "1.4.4"} in entries

      # Git-sourced deps are silently dropped — OSV can't advise on them.
      refute Enum.any?(entries, &(&1.name == "some_git_dep"))
      assert length(entries) == 2
    end

    test "an empty map returns no entries" do
      assert {:ok, []} = LockfileParser.parse_mix_lock("%{}\n")
    end

    test "malformed contents return an empty list rather than crashing" do
      assert {:ok, []} = LockfileParser.parse_mix_lock("this is not a valid lockfile at all")
    end
  end

  describe "parse_package_lock/1" do
    test "extracts npm entries from lockfileVersion 3 packages map" do
      assert {:ok, entries} = LockfileParser.parse_package_lock(fixture("package-lock.json.high"))

      assert %{ecosystem: "npm", name: "lodash", version: "4.17.15"} in entries
      assert %{ecosystem: "npm", name: "leftpad", version: "1.0.0"} in entries
      # The root workspace entry (empty-string key) is skipped.
      refute Enum.any?(entries, &(&1.name == ""))
    end

    test "extracts npm entries from lockfileVersion 1 dependencies map" do
      contents =
        Jason.encode!(%{
          "name" => "fixture",
          "version" => "1.0.0",
          "lockfileVersion" => 1,
          "dependencies" => %{
            "react" => %{"version" => "18.2.0"},
            "underscore" => %{"version" => "1.13.6"}
          }
        })

      assert {:ok, entries} = LockfileParser.parse_package_lock(contents)

      assert %{ecosystem: "npm", name: "react", version: "18.2.0"} in entries
      assert %{ecosystem: "npm", name: "underscore", version: "1.13.6"} in entries
    end

    test "invalid JSON returns {:error, {:invalid_json, ...}}" do
      assert {:error, {:invalid_json, _reason}} =
               LockfileParser.parse_package_lock("this is not json {")
    end

    test "strips the deepest node_modules prefix for nested transitive deps" do
      contents =
        Jason.encode!(%{
          "packages" => %{
            "" => %{"name" => "root"},
            "node_modules/a" => %{"version" => "1.0.0"},
            "node_modules/a/node_modules/b" => %{"version" => "2.0.0"}
          }
        })

      assert {:ok, entries} = LockfileParser.parse_package_lock(contents)
      assert %{ecosystem: "npm", name: "a", version: "1.0.0"} in entries
      assert %{ecosystem: "npm", name: "b", version: "2.0.0"} in entries
    end

    test "scoped npm names survive the strip" do
      contents =
        Jason.encode!(%{
          "packages" => %{
            "" => %{"name" => "root"},
            "node_modules/@scope/pkg" => %{"version" => "3.0.0"}
          }
        })

      assert {:ok, entries} = LockfileParser.parse_package_lock(contents)
      assert %{ecosystem: "npm", name: "@scope/pkg", version: "3.0.0"} in entries
    end

    test "workspace symlinks (link: true) are skipped" do
      contents =
        Jason.encode!(%{
          "packages" => %{
            "" => %{"name" => "root"},
            "node_modules/local" => %{"link" => true, "resolved" => "packages/local"}
          }
        })

      assert {:ok, []} = LockfileParser.parse_package_lock(contents)
    end
  end

  describe "parse_cargo_lock/1" do
    test "extracts crates.io packages and skips workspace-local blocks" do
      assert {:ok, entries} = LockfileParser.parse_cargo_lock(fixture("Cargo.lock.medium"))

      assert %{ecosystem: "crates.io", name: "serde", version: "1.0.100"} in entries
      assert %{ecosystem: "crates.io", name: "openssl", version: "0.10.30"} in entries
      # Workspace-local packages have no source line — dropped.
      refute Enum.any?(entries, &(&1.name == "workspace_local_crate"))
      assert length(entries) == 2
    end

    test "an empty Cargo.lock returns no entries" do
      assert {:ok, []} = LockfileParser.parse_cargo_lock("")
    end

    test "sparse+ registries are also treated as crates.io sources" do
      contents = """
      [[package]]
      name = "tokio"
      version = "1.35.1"
      source = "sparse+https://index.crates.io/"
      """

      assert {:ok, entries} = LockfileParser.parse_cargo_lock(contents)
      assert %{ecosystem: "crates.io", name: "tokio", version: "1.35.1"} in entries
    end
  end

  describe "discover_lockfiles/1" do
    setup do
      root =
        System.tmp_dir!() |> Path.join("cve_scan_fixture_#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)

      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end

    test "returns the mix.lock at root when present", %{root: root} do
      File.write!(Path.join(root, "mix.lock"), "%{}\n")

      assert [{:mix_lock, path}] = LockfileParser.discover_lockfiles(root)
      assert path == Path.join(root, "mix.lock")
    end

    test "finds package-lock.json under assets/", %{root: root} do
      assets = Path.join(root, "assets")
      File.mkdir_p!(assets)
      File.write!(Path.join(assets, "package-lock.json"), "{}\n")

      assert [{:package_lock, _}] = LockfileParser.discover_lockfiles(root)
    end

    test "returns an empty list when no lockfiles exist", %{root: root} do
      assert [] == LockfileParser.discover_lockfiles(root)
    end
  end
end
