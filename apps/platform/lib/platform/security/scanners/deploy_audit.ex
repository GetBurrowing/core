defmodule Platform.Security.Scanners.DeployAudit do
  @moduledoc """
  Deploy-audit scanner for the `security.deploy_audit` responsibility
  (task `019f3e8e-4406` stage 4, ADR-0043).

  Pure filesystem read-only work — no network calls, no sub-process
  spawns beyond `File.stat!/1` on cert symlinks. Runs the same
  progressive-enhancement contract every scanner does: with no role
  assigned to `security_guard`, the Sweeper never invokes this and
  no findings are filed. When invoked, this module:

    1. Walks Traefik rules at
       `config :platform, Platform.Security,
       deploy_audit_traefik_root` (default `~/docker/traefik3/rules`).
       Flags routes that either serve unencrypted HTTP without a
       redirect middleware, target internal-looking upstreams
       without the `chain-oauth2` middleware, or lack a `Host()`
       matcher on `websecure`.
    2. Walks container manifests at
       `deploy_audit_containers_root` (default
       `~/.config/containers/systemd`). Flags missing
       `AutoUpdate=registry` directives so a container drifts on
       security patches, and flags `PublishPort=0.0.0.0:*` bindings
       for services in the tailscale-only allowlist.
    3. Diffs `.env.example` files against their matching
       `.secrets.env` files under
       `deploy_audit_core_ops_root/targets/<target>/env` vs
       `deploy_audit_core_ops_root/secrets/<target>/`. Any key
       defined in the example but missing from secrets → finding.
       This is the check that would have caught the
       `MEETING_GUEST_SIGNING_KEY` boot crash (see memory
       `reference_suite_prod_secrets`). The root has NO default: it
       is the install's private ops checkout, set through
       `DEPLOY_AUDIT_CORE_OPS_ROOT` (runtime.exs). Unset, the probe is
       `{:not_configured, "DEPLOY_AUDIT_CORE_OPS_ROOT"}` (see
       `env_var_probe/0`) and contributes no findings.
    4. Best-effort TLS expiry probe against
       `deploy_audit_tls_root` (default `/etc/letsencrypt/live`).
       Flags certs expiring within 30 days. Skips silently on dev
       workstations where the path doesn't exist.

  ## Missing filesystems → :noop

  Each of the four probes returns `[]` when its root path doesn't
  exist. This keeps the scanner runnable in dev (no Traefik, no
  systemd units, no core-ops repo) without a mountain of warnings.
  The Sweeper's telemetry still reports the tick.
  """

  require Logger

  alias Platform.Security.FindingFiler
  alias Platform.Security.LlmEnrichment

  @default_traefik_root "~/docker/traefik3/rules"
  @default_containers_root "~/.config/containers/systemd"
  @core_ops_root_env "DEPLOY_AUDIT_CORE_OPS_ROOT"
  @default_tls_root "/etc/letsencrypt/live"
  @default_tls_expiry_warning_days 30

  @doc """
  Run a deploy audit and file findings. Sweeper-facing entrypoint —
  matches the four-scanner uniform contract.
  """
  @spec run_scan(map(), map()) :: {:ok, non_neg_integer()}
  def run_scan(_responsibility, _trigger_meta) do
    case configured_project_id() do
      nil ->
        Logger.warning(
          "[Security.Scanners.DeployAudit] no project_id configured — set config :platform, Platform.Security, project_id: <uuid>"
        )

        {:ok, 0}

      project_id ->
        findings =
          []
          |> Kernel.++(traefik_findings())
          |> Kernel.++(container_findings())
          |> Kernel.++(env_var_findings())
          |> Kernel.++(tls_findings())

        Logger.info(
          "[Security.Scanners.DeployAudit] scanned traefik=#{length(traefik_findings())} " <>
            "containers=#{length(container_findings())} envs=#{length(env_var_findings())} " <>
            "tls=#{length(tls_findings())}"
        )

        filed = file_all(findings, project_id)
        {:ok, filed}
    end
  rescue
    error ->
      Logger.error("[Security.Scanners.DeployAudit] scanner raised — #{Exception.message(error)}")

      {:ok, 0}
  end

  # ── Traefik ────────────────────────────────────────────────────────

  @doc false
  def traefik_findings do
    root = expand(deploy_config(:deploy_audit_traefik_root, @default_traefik_root))

    if File.dir?(root) do
      root
      |> Path.join("*.toml")
      |> Path.wildcard()
      |> Enum.flat_map(&audit_traefik_file/1)
    else
      []
    end
  rescue
    error ->
      Logger.warning(
        "[Security.Scanners.DeployAudit] traefik probe raised — #{Exception.message(error)}"
      )

      []
  end

  defp audit_traefik_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> extract_traefik_routers()
        |> Enum.flat_map(fn router -> audit_traefik_router(router, path) end)

      _ ->
        []
    end
  end

  # A very small TOML-slice parser: split the file on top-level
  # `[<section>]` headers (top-level = starting at column 0), grab
  # each block whose header matches `http.routers.<name>`, then pull
  # `entryPoints` / `rule` / `middlewares` / `service` values from
  # the block via inline regex. This avoids pulling in a full TOML
  # dep just for one probe.
  defp extract_traefik_routers(contents) do
    contents
    |> split_toml_sections()
    |> Enum.flat_map(fn {header, body} ->
      case Regex.run(~r/^http\.routers\.(.+)$/, header) do
        [_, name] ->
          [
            %{
              name: String.trim(name),
              entry_points: extract_toml_list(body, "entryPoints"),
              rule: extract_toml_string(body, "rule"),
              middlewares: extract_toml_list(body, "middlewares"),
              service: extract_toml_string(body, "service")
            }
          ]

        _ ->
          []
      end
    end)
  end

  # Split TOML contents into `[{section_header, body}]` tuples. A
  # section header is a line whose first non-whitespace char is `[`
  # and last non-whitespace char is `]`. Nested-header syntax
  # (`[[array]]`) is treated as a normal header — Traefik doesn't
  # use it in our rules files.
  defp split_toml_sections(contents) do
    lines = String.split(contents, "\n")

    {sections, last_header, last_body} =
      Enum.reduce(lines, {[], nil, []}, fn line, {acc, cur_header, cur_body} ->
        trimmed = String.trim(line)

        cond do
          # New section header — flush current, start new.
          section_header?(trimmed) ->
            new_acc =
              if is_nil(cur_header) do
                acc
              else
                [{cur_header, Enum.join(Enum.reverse(cur_body), "\n")} | acc]
              end

            {new_acc, extract_header_name(trimmed), []}

          # Line before any section header — skip.
          is_nil(cur_header) ->
            {acc, cur_header, cur_body}

          true ->
            {acc, cur_header, [line | cur_body]}
        end
      end)

    final =
      if is_nil(last_header) do
        sections
      else
        [{last_header, Enum.join(Enum.reverse(last_body), "\n")} | sections]
      end

    Enum.reverse(final)
  end

  defp section_header?(trimmed) do
    String.starts_with?(trimmed, "[") and String.ends_with?(trimmed, "]") and
      not String.contains?(trimmed, "=")
  end

  defp extract_header_name(trimmed) do
    trimmed
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
  end

  defp extract_toml_list(body, key) do
    case Regex.run(~r/^\s*#{Regex.escape(key)}\s*=\s*\[(?<contents>[^\]]*)\]/m, body,
           capture: :all_names
         ) do
      [inner] ->
        inner
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.trim(&1, ~S(")))
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp extract_toml_string(body, key) do
    case Regex.run(~r/^\s*#{Regex.escape(key)}\s*=\s*"([^"]*)"/m, body) do
      [_, val] -> val
      _ -> nil
    end
  end

  defp audit_traefik_router(router, path) do
    file = Path.basename(path)

    []
    |> maybe_add_http_only(router, file)
    |> maybe_add_missing_oauth(router, file)
    |> maybe_add_missing_host(router, file)
  end

  defp maybe_add_http_only(acc, router, file) do
    if "web" in router.entry_points and "websecure" not in router.entry_points and
         not has_redirect?(router.middlewares) do
      [
        %{
          scanner_key: "security.deploy_audit",
          severity: :high,
          title:
            "Traefik router #{router.name} serves HTTP without a redirect middleware (file: #{file})",
          description: """
          Router `#{router.name}` in `#{file}` binds `entryPoints = [\"web\"]` without a
          `redirect-to-https` middleware. Any traffic to the corresponding host will be
          served plaintext.

          ## Suggested fix

          Add a `redirect-to-https` middleware to the router's `middlewares` list, or move
          the router to `entryPoints = [\"websecure\"]` and let the entrypoint-level
          redirect handle the plaintext flavour.
          """,
          fingerprint: "deploy_audit:traefik_http_only:#{file}:#{router.name}",
          metadata: %{"router" => router.name, "file" => file}
        }
        | acc
      ]
    else
      acc
    end
  end

  defp maybe_add_missing_oauth(acc, router, file) do
    protected? = protected_upstream?(router.rule)

    if protected? and not has_oauth_chain?(router.middlewares) do
      [
        %{
          scanner_key: "security.deploy_audit",
          severity: :critical,
          title:
            "Traefik router #{router.name} appears protected but has no chain-oauth2 middleware (file: #{file})",
          description: """
          Router `#{router.name}` in `#{file}` matches rule `#{router.rule}` — which looks
          like an admin/dashboard/internal host — but its middleware chain does not include
          `chain-oauth2`.

          Middlewares seen: `#{inspect(router.middlewares)}`.

          ## Suggested fix

          Add `chain-oauth2` to the router's `middlewares` list. If the route is genuinely
          public, add a comment to `#{file}` documenting that decision so future audits
          skip it — the heuristic keys off the hostname.
          """,
          fingerprint: "deploy_audit:traefik_missing_oauth:#{file}:#{router.name}",
          metadata: %{"router" => router.name, "file" => file, "rule" => router.rule}
        }
        | acc
      ]
    else
      acc
    end
  end

  defp maybe_add_missing_host(acc, router, file) do
    if "websecure" in router.entry_points and not host_matcher?(router.rule) do
      [
        %{
          scanner_key: "security.deploy_audit",
          severity: :medium,
          title:
            "Traefik router #{router.name} on websecure has no Host() matcher (file: #{file})",
          description: """
          Router `#{router.name}` binds `websecure` without a `Host()` matcher. A missing
          host matcher can catch traffic intended for other services on the same entrypoint.

          Rule seen: `#{inspect(router.rule)}`.
          """,
          fingerprint: "deploy_audit:traefik_no_host_matcher:#{file}:#{router.name}",
          metadata: %{"router" => router.name, "file" => file, "rule" => router.rule}
        }
        | acc
      ]
    else
      acc
    end
  end

  defp has_redirect?(middlewares) do
    Enum.any?(middlewares, fn m -> String.contains?(m, "redirect") end)
  end

  defp has_oauth_chain?(middlewares) do
    Enum.any?(middlewares, fn m -> String.contains?(m, "oauth") end)
  end

  defp host_matcher?(nil), do: false
  defp host_matcher?(rule) when is_binary(rule), do: String.contains?(rule, "Host(")

  defp protected_upstream?(nil), do: false

  defp protected_upstream?(rule) when is_binary(rule) do
    Enum.any?(["admin.", "dashboard.", "internal.", "grafana.", "prometheus."], fn prefix ->
      String.contains?(rule, prefix)
    end)
  end

  # ── Containers ──────────────────────────────────────────────────

  @doc false
  def container_findings do
    root = expand(deploy_config(:deploy_audit_containers_root, @default_containers_root))

    if File.dir?(root) do
      root
      |> Path.join("*.container")
      |> Path.wildcard()
      |> Enum.flat_map(&audit_container_file/1)
    else
      []
    end
  rescue
    error ->
      Logger.warning(
        "[Security.Scanners.DeployAudit] container probe raised — #{Exception.message(error)}"
      )

      []
  end

  defp audit_container_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        file = Path.basename(path)
        name = String.replace_suffix(file, ".container", "")

        keys = parse_ini_keys(contents)

        []
        |> maybe_add_no_autoupdate(keys, name, file)
        |> maybe_add_missing_env_file(keys, name, file)
        |> maybe_add_public_bind(keys, name, file)

      _ ->
        []
    end
  end

  # `.container` files are systemd unit files (INI-like). Each key
  # can appear multiple times so we collect a list of values per key.
  defp parse_ini_keys(contents) do
    contents
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.trim(line) do
        "" ->
          acc

        "#" <> _ ->
          acc

        "[" <> _ ->
          acc

        other ->
          case String.split(other, "=", parts: 2) do
            [k, v] -> Map.update(acc, String.trim(k), [String.trim(v)], &[String.trim(v) | &1])
            _ -> acc
          end
      end
    end)
  end

  defp maybe_add_no_autoupdate(acc, keys, name, file) do
    if Map.has_key?(keys, "AutoUpdate") do
      acc
    else
      [
        %{
          scanner_key: "security.deploy_audit",
          severity: :high,
          title: "Container #{name} won't get security patches (missing AutoUpdate=registry)",
          description: """
          `#{file}` has no `AutoUpdate=` directive. Without one, `podman auto-update` won't
          restart the container after a fresh image is pushed to the registry — so critical
          upstream patches never land in prod.

          ## Suggested fix

          Add `AutoUpdate=registry` to the `[Container]` section of `#{file}` and enable
          the timer via `systemctl --user enable --now podman-auto-update.timer` if it
          isn't already active.
          """,
          fingerprint: "deploy_audit:container_no_autoupdate:#{file}",
          metadata: %{"container" => name, "file" => file}
        }
        | acc
      ]
    end
  end

  defp maybe_add_missing_env_file(acc, keys, name, file) do
    envs =
      keys
      |> Map.get("EnvironmentFile", [])
      |> Enum.map(fn v -> String.trim_leading(v, "-") end)
      |> Enum.reject(fn v -> v == "" end)

    missing = Enum.reject(envs, &File.exists?/1)

    Enum.reduce(missing, acc, fn path, inner_acc ->
      [
        %{
          scanner_key: "security.deploy_audit",
          severity: :critical,
          title: "Container #{name} references a missing EnvironmentFile #{path}",
          description: """
          `#{file}` has `EnvironmentFile=#{path}` but that file does not exist on the host.
          When systemd starts the unit, it will (silently, for a `-` prefix; loudly, for a
          bare prefix) skip the missing file. Any secret the unit expected to read from it
          will be `nil`, which is the exact class of boot-crash we hit with
          `MEETING_GUEST_SIGNING_KEY`.

          ## Suggested fix

          Either populate `#{path}` on the target host or remove the reference from `#{file}`.
          """,
          fingerprint: "deploy_audit:container_missing_env_file:#{file}:#{path}",
          metadata: %{"container" => name, "file" => file, "env_file" => path}
        }
        | inner_acc
      ]
    end)
  end

  # A very small allowlist — only flag services that are declared
  # tailscale-only by convention. The heuristic reads the
  # `Description=` line for a `[tailscale-only]` tag.
  defp maybe_add_public_bind(acc, keys, name, file) do
    tailscale_only? =
      keys
      |> Map.get("Description", [])
      |> Enum.any?(fn desc -> String.contains?(desc, "[tailscale-only]") end)

    if tailscale_only? do
      public_binds =
        keys
        |> Map.get("PublishPort", [])
        |> Enum.filter(fn v -> String.starts_with?(v, "0.0.0.0:") end)

      Enum.reduce(public_binds, acc, fn bind, inner_acc ->
        [
          %{
            scanner_key: "security.deploy_audit",
            severity: :high,
            title: "Container #{name} declared tailscale-only but binds public interface",
            description: """
            `#{file}` describes itself as `[tailscale-only]` but its `PublishPort=#{bind}`
            binds the wildcard interface. Anyone on the LAN (or the internet, if the
            host is externally reachable) will hit the service.

            ## Suggested fix

            Bind explicitly to the tailscale interface, e.g. `PublishPort=100.x.y.z:port`, or
            remove the `[tailscale-only]` tag from `Description=` if the service is meant
            to be public.
            """,
            fingerprint: "deploy_audit:container_public_bind:#{file}:#{bind}",
            metadata: %{"container" => name, "file" => file, "bind" => bind}
          }
          | inner_acc
        ]
      end)
    else
      acc
    end
  end

  # ── Env-var diff ────────────────────────────────────────────────

  @doc false
  def env_var_findings do
    case env_var_probe() do
      {:ok, findings} -> findings
      {:not_configured, _env} -> []
    end
  end

  @doc """
  The env-diff probe with its configuration state named.

  Returns `{:not_configured, "DEPLOY_AUDIT_CORE_OPS_ROOT"}` when
  `deploy_audit_core_ops_root` is unset or blank (there is no code
  default), `{:ok, []}` when the configured root does not exist, and
  `{:ok, findings}` otherwise.
  """
  @spec env_var_probe() :: {:ok, [map()]} | {:not_configured, String.t()}
  def env_var_probe do
    case deploy_config(:deploy_audit_core_ops_root, nil) do
      root when is_binary(root) and root != "" -> {:ok, env_var_findings_at(expand(root))}
      _ -> {:not_configured, @core_ops_root_env}
    end
  end

  defp env_var_findings_at(root) do
    if File.dir?(root) do
      root
      |> Path.join("targets/*/env/*.env.example")
      |> Path.wildcard()
      |> Enum.flat_map(fn example_path -> audit_env_pair(root, example_path) end)
    else
      []
    end
  rescue
    error ->
      Logger.warning(
        "[Security.Scanners.DeployAudit] env-diff probe raised — #{Exception.message(error)}"
      )

      []
  end

  defp audit_env_pair(root, example_path) do
    target = extract_target_from_example(example_path, root)

    example_keys = parse_env_keys(example_path)

    secrets_keys =
      target
      |> secrets_paths_for(root)
      |> Enum.flat_map(&parse_env_keys/1)
      |> MapSet.new()

    missing =
      example_keys
      |> MapSet.new()
      |> MapSet.difference(secrets_keys)
      |> MapSet.to_list()

    Enum.map(missing, fn key ->
      %{
        scanner_key: "security.deploy_audit",
        severity: :high,
        title:
          "Env var #{key} declared in #{Path.basename(example_path)} but missing from #{target} secrets",
        description: """
        The env-example file `#{Path.relative_to(example_path, root)}` declares a required
        key `#{key}=` that is not present in any `secrets/#{target}/*.secrets.env` file.

        This is the exact class of miss that caused the `MEETING_GUEST_SIGNING_KEY`
        boot-crash — the app's `runtime.exs` calls `System.fetch_env!/1`, gets `:error`,
        and the release crash-loops the moment podman-auto-update pulls a fresh image.

        ## Suggested fix

        Append `#{key}=<real value>` to the relevant secrets file (see memory
        `reference_suite_prod_secrets` for the on-host paths) and restart the affected
        systemd unit.
        """,
        fingerprint: "deploy_audit:missing_env_var:#{target}:#{key}",
        metadata: %{
          "target" => target,
          "env_var" => key,
          "example" => Path.basename(example_path)
        }
      }
    end)
  end

  defp extract_target_from_example(example_path, root) do
    example_path
    |> Path.relative_to(root)
    |> Path.split()
    |> case do
      ["targets", target, "env", _] -> target
      _ -> "unknown"
    end
  end

  defp secrets_paths_for(target, root) do
    root
    |> Path.join(["secrets/", target, "/"])
    |> Path.join("*.env")
    |> Path.wildcard()
  end

  defp parse_env_keys(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.flat_map(fn line ->
          trimmed = String.trim(line)

          cond do
            trimmed == "" -> []
            String.starts_with?(trimmed, "#") -> []
            true -> extract_env_key(trimmed)
          end
        end)

      _ ->
        []
    end
  end

  defp extract_env_key(line) do
    case String.split(line, "=", parts: 2) do
      [key, _value] ->
        key = key |> String.trim() |> String.trim_leading("export ")
        if valid_env_key?(key), do: [key], else: []

      _ ->
        []
    end
  end

  defp valid_env_key?(key) do
    Regex.match?(~r/^[A-Z_][A-Z0-9_]*$/, key)
  end

  # ── TLS expiry ──────────────────────────────────────────────────

  @doc false
  def tls_findings do
    root = expand(deploy_config(:deploy_audit_tls_root, @default_tls_root))

    if File.dir?(root) do
      root
      |> Path.join("*/cert.pem")
      |> Path.wildcard()
      |> Enum.flat_map(&audit_tls_cert/1)
    else
      []
    end
  rescue
    error ->
      Logger.warning(
        "[Security.Scanners.DeployAudit] tls probe raised — #{Exception.message(error)}"
      )

      []
  end

  defp audit_tls_cert(path) do
    domain =
      path
      |> Path.dirname()
      |> Path.basename()

    with {:ok, %File.Stat{mtime: mtime}} <- File.stat(path, time: :posix),
         %DateTime{} = mod_at <- posix_to_dt(mtime) do
      # Certificates are ~90 days from cert.pem's mtime (Let's Encrypt
      # default). We use mtime as a proxy for issue date + 90 - 30
      # for the warning window. A real prod deployment would parse the
      # cert; this stage's version is intentionally coarse.
      expiry = DateTime.add(mod_at, 90 * 24 * 3600, :second)
      warning_at = DateTime.add(expiry, -1 * warning_days() * 24 * 3600, :second)

      if DateTime.compare(DateTime.utc_now(), warning_at) != :lt do
        [
          %{
            scanner_key: "security.deploy_audit",
            severity: :high,
            title: "TLS cert for #{domain} expires within #{warning_days()} days",
            description: """
            The certificate at `#{path}` has an estimated expiry of
            `#{DateTime.to_iso8601(expiry)}`, which is within the
            #{warning_days()}-day warning window.

            ## Suggested fix

            Run `certbot renew --dry-run` on the host to confirm renewal automation is
            healthy, then let the timer renew (or `certbot renew --force-renewal` if the
            unattended renewer looks broken).
            """,
            fingerprint: "deploy_audit:tls_expiry:#{domain}",
            metadata: %{"domain" => domain, "cert_path" => path}
          }
        ]
      else
        []
      end
    else
      _ -> []
    end
  end

  defp posix_to_dt(nil), do: nil

  defp posix_to_dt(posix) when is_integer(posix) do
    case DateTime.from_unix(posix) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp posix_to_dt(_), do: nil

  defp warning_days do
    deploy_config(:deploy_audit_tls_expiry_warning_days, @default_tls_expiry_warning_days)
  end

  # ── shared plumbing ────────────────────────────────────────────

  # Stage 5: batch path applies the > threshold digest rule so a
  # sprawling scan (many missing env vars across many targets) rolls up
  # into one weekly digest task. v2 stage 3: LLM enrichment sits between
  # add-project-id and file — noop when no external-runtime agent is
  # pinned.
  defp file_all(findings, project_id) do
    findings
    |> Enum.map(&Map.put(&1, :project_id, project_id))
    |> Enum.map(&enrich/1)
    |> FindingFiler.file_findings()
  end

  # v2 stage 3 (ADR-0043): LLM enrichment seam.
  defp enrich(finding) do
    case LlmEnrichment.enrich_finding(finding, "security.deploy_audit") do
      {:enriched, f} -> f
      {:noop, f} -> f
    end
  end

  defp deploy_config(key, default) do
    case Application.get_env(:platform, Platform.Security) do
      nil -> default
      kw -> Keyword.get(kw, key, default)
    end
  end

  defp configured_project_id do
    case Application.get_env(:platform, Platform.Security) do
      nil -> nil
      kw -> Keyword.get(kw, :project_id)
    end
  end

  defp expand(nil), do: nil
  defp expand(path) when is_binary(path), do: Path.expand(path)
end
