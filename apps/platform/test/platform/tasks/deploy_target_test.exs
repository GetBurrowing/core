defmodule Platform.Tasks.DeployTargetTest do
  use ExUnit.Case, async: true

  alias Platform.Tasks.DeployTarget

  # ── Valid configs ─────────────────────────────────────────────────────────

  describe "validate/1 — docker_compose" do
    test "accepts valid docker_compose target" do
      target = %{
        "name" => "production",
        "type" => "docker_compose",
        "config" => %{
          "host" => "dev@192.0.2.234",
          "stack_path" => "~/docker/stacks/my-app",
          "image_registry" => "ghcr.io/org/repo",
          "watchtower" => true
        }
      }

      assert {:ok, validated} = DeployTarget.validate(target)
      assert validated["name"] == "production"
      assert validated["type"] == "docker_compose"
      assert validated["config"]["host"] == "dev@192.0.2.234"
    end

    test "rejects docker_compose missing host" do
      target = %{
        "name" => "prod",
        "type" => "docker_compose",
        "config" => %{"stack_path" => "/app"}
      }

      assert {:error, {:missing_config_keys, ["host"]}} = DeployTarget.validate(target)
    end

    test "rejects docker_compose missing stack_path" do
      target = %{
        "name" => "prod",
        "type" => "docker_compose",
        "config" => %{"host" => "x@y"}
      }

      assert {:error, {:missing_config_keys, ["stack_path"]}} = DeployTarget.validate(target)
    end
  end

  describe "validate/1 — fly" do
    test "accepts valid fly target" do
      target = %{"name" => "staging", "type" => "fly", "config" => %{"app" => "my-fly-app"}}
      assert {:ok, _} = DeployTarget.validate(target)
    end

    test "rejects fly missing app" do
      target = %{"name" => "staging", "type" => "fly", "config" => %{}}
      assert {:error, {:missing_config_keys, ["app"]}} = DeployTarget.validate(target)
    end
  end

  describe "validate/1 — k8s" do
    test "accepts valid k8s target" do
      target = %{
        "name" => "prod-k8s",
        "type" => "k8s",
        "config" => %{"cluster" => "prod-cluster", "namespace" => "default"}
      }

      assert {:ok, _} = DeployTarget.validate(target)
    end

    test "rejects k8s missing cluster" do
      target = %{"name" => "x", "type" => "k8s", "config" => %{"namespace" => "default"}}
      assert {:error, {:missing_config_keys, ["cluster"]}} = DeployTarget.validate(target)
    end
  end

  describe "validate/1 — static" do
    test "accepts valid static target" do
      target = %{"name" => "cdn", "type" => "static", "config" => %{"bucket" => "s3://my-site"}}
      assert {:ok, _} = DeployTarget.validate(target)
    end

    test "rejects static missing bucket" do
      target = %{"name" => "cdn", "type" => "static", "config" => %{}}
      assert {:error, {:missing_config_keys, ["bucket"]}} = DeployTarget.validate(target)
    end
  end

  describe "validate/1 — unknown type" do
    test "unknown types pass through with no required config keys" do
      target = %{
        "name" => "custom",
        "type" => "cloudflare_pages",
        "config" => %{"project" => "my-pages"}
      }

      assert {:ok, validated} = DeployTarget.validate(target)
      assert validated["type"] == "cloudflare_pages"
    end
  end

  # ── Missing fields ──────────────────────────────────────────────────────

  describe "validate/1 — missing fields" do
    test "rejects missing name" do
      target = %{"type" => "fly", "config" => %{"app" => "x"}}
      assert {:error, {:missing_fields, fields}} = DeployTarget.validate(target)
      assert "name" in fields
    end

    test "rejects missing type" do
      target = %{"name" => "prod", "config" => %{}}
      assert {:error, {:missing_fields, fields}} = DeployTarget.validate(target)
      assert "type" in fields
    end

    test "rejects missing config" do
      target = %{"name" => "prod", "type" => "fly"}
      assert {:error, {:missing_fields, fields}} = DeployTarget.validate(target)
      assert "config" in fields
    end

    test "rejects non-map input" do
      assert {:error, :invalid_target} = DeployTarget.validate("not a map")
    end
  end

  # ── Key normalization ───────────────────────────────────────────────────

  describe "validate/1 — atom key normalization" do
    test "normalizes atom keys to string keys" do
      target = %{name: "prod", type: "fly", config: %{"app" => "x"}}
      assert {:ok, validated} = DeployTarget.validate(target)
      assert validated["name"] == "prod"
    end
  end

  # ── validate!/1 ────────────────────────────────────────────────────────

  describe "validate!/1" do
    test "returns target on success" do
      target = %{"name" => "prod", "type" => "fly", "config" => %{"app" => "x"}}
      assert %{"name" => "prod"} = DeployTarget.validate!(target)
    end

    test "raises on failure" do
      assert_raise ArgumentError, fn ->
        DeployTarget.validate!(%{"name" => "prod"})
      end
    end
  end
end
