defmodule Platform.Installs.RenderTest do
  @moduledoc """
  Task 01a10315 stage 2: the manifest core renders an install from, the
  registry-auth guard, and (tag `:python`, when `python3` with `tomllib` is
  on PATH) one real `python3 -m burrow_install render` of it.
  """
  use Platform.DataCase, async: false

  alias Platform.Installs.Install
  alias Platform.Installs.Python
  alias Platform.Installs.Render
  alias Platform.Installs.SshKey

  @python_ok (case System.find_executable("python3") do
                nil ->
                  false

                py ->
                  match?({_, 0}, System.cmd(py, ["-c", "import tomllib"], stderr_to_stdout: true))
              end)

  defp install do
    %Install{
      id: "0195f6c3-0000-7000-8000-000000000001",
      slug: "baeckerei-x2k4",
      business_name: "Bäckerei & Söhne",
      owner_email: "owner@baeckerei.example.test",
      primary_host: "baeckerei-x2k4.installs.example.test",
      region: "nyc3",
      size: "s-2vcpu-4gb",
      domain_mode: "ours"
    }
  end

  test "the manifest carries the stage-1 knobs, the full_machine agents and acme" do
    key = SshKey.generate().public
    toml = Render.manifest(install(), key)

    for line <- [
          ~s(name = "baeckerei-x2k4"),
          ~s(org_name = "Bäckerei & Söhne"),
          ~s(hosted = true),
          ~s(primary = "baeckerei-x2k4.installs.example.test"),
          ~s(tls = "acme"),
          ~s(acme_email = "owner@baeckerei.example.test"),
          ~s(ssh_authorized_key = #{Jason.encode!(key)}),
          ~s(registry = "ghcr.io/getburrowing"),
          ~s(source = "registry"),
          ~s(profile = "full_machine"),
          ~s(vapid = "generate-on-host"),
          ~s(voice = false)
        ] do
      assert toml =~ line
    end
  end

  defp with_auth_slug(slug) do
    previous = Application.get_env(:platform, Platform.Installs, [])
    configured = Keyword.put(previous, :registry_auth_slug, slug)
    Application.put_env(:platform, Platform.Installs, configured)
    on_exit(fn -> Application.put_env(:platform, Platform.Installs, previous) end)
  end

  test "by default the images are public: no vault read, no auth, public = true" do
    assert {:ok, :public} = Render.Python.registry_auth()
    toml = Render.manifest(install(), "ssh-ed25519 AAAA x")
    assert toml =~ ~s(source = "registry"\npublic = true\n)
    refute Render.manifest(install(), "ssh-ed25519 AAAA x", public: false) =~ "public = true"
  end

  test "a configured slug missing from the vault is :registry_auth_missing, before any python" do
    with_auth_slug("install-registry-pull-auth")
    assert {:error, :registry_auth_missing} = Render.Python.registry_auth()

    assert {:error, :registry_auth_missing} =
             Render.Python.render(install(), SshKey.generate().public)
  end

  test "a configured slug present in the vault is the auth" do
    with_auth_slug("install-registry-pull-auth")
    value = ~s({"auths": {"ghcr.io": {"auth": "ZmFrZS1yZWFkLW9ubHk="}}})
    {:ok, _} = Platform.Vault.put("install-registry-pull-auth", :custom, value)
    assert {:ok, ^value} = Render.Python.registry_auth()
  end

  test "read_render keeps exactly the two values and refuses an incomplete render" do
    Python.with_private_dir(fn dir ->
      File.write!(Path.join(dir, "user-data"), "#cloud-config\n")

      File.write!(
        Path.join(dir, "secrets.env"),
        "# c\nSTATIC_API_KEY=fake-static\nSECRET_KEY_BASE=fake-skb\nOIDC_CLIENT_SECRET=fake-oidc\n"
      )

      assert {:ok, %{user_data: "#cloud-config\n", secrets: secrets}} =
               Render.Python.read_render(dir)

      assert secrets == %{"STATIC_API_KEY" => "fake-static", "OIDC_CLIENT_SECRET" => "fake-oidc"}

      File.write!(Path.join(dir, "secrets.env"), "STATIC_API_KEY=fake-static\n")
      assert {:error, :render_incomplete} = Render.Python.read_render(dir)
    end)
  end

  test "the private dir is 0700 and gone afterwards, also when the body raises" do
    dir =
      Python.with_private_dir(fn dir ->
        assert {:ok, %File.Stat{mode: mode}} = File.stat(dir)
        assert Bitwise.band(mode, 0o777) == 0o700
        Python.write_private!(Path.join(dir, "f"), "x")
        assert {:ok, %File.Stat{mode: fmode}} = File.stat(Path.join(dir, "f"))
        assert Bitwise.band(fmode, 0o777) == 0o600
        dir
      end)

    refute File.exists?(dir)

    assert_raise RuntimeError, fn ->
      Python.with_private_dir(fn dir ->
        send(self(), {:dir, dir})
        raise "boom"
      end)
    end

    assert_received {:dir, raised_dir}
    refute File.exists?(raised_dir)
  end

  @tag :python
  @tag skip: if(@python_ok, do: false, else: "python3 with tomllib is not on PATH here")
  test "renders for real, public images: org name, the key and the VAPID unit" do
    key = SshKey.generate().public
    before = tmp_dirs()

    assert {:ok, %{user_data: user_data, secrets: secrets}} =
             Render.Python.render(install(), key)

    assert user_data =~ "#cloud-config"
    assert user_data =~ ~s(ROOT_ORG_NAME: "Bäckerei & Söhne")
    assert user_data =~ "ExecStartPre=/opt/burrow/bin/burrow-vapid"
    assert user_data =~ "ssh_authorized_keys:\n  - #{Jason.encode!(key)}"
    assert byte_size(user_data) < 65_536
    # Public images: no pull credential reaches the droplet.
    refute user_data =~ "/root/.docker/config.json"
    assert Map.keys(secrets) |> Enum.sort() == ["OIDC_CLIENT_SECRET", "STATIC_API_KEY"]
    assert tmp_dirs() == before
  end

  defp tmp_dirs, do: Path.wildcard(Path.join(System.tmp_dir!(), "burrow-installs-*"))
end
