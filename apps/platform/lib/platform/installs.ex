defmodule Platform.Installs do
  @moduledoc """
  One-click installs on DigitalOcean (task 01a10315 stage 2): a business name
  in, a running install with its own domain, root key and first admin out.

  core owns the orchestration (this context, `Platform.Installs.Runner`, the
  DigitalOcean client and the screens); the cloud-init comes from the ONE
  install template, `python3 -m burrow_install render`, and the first admin
  from stage 1's `bootstrap-admin` (`Platform.Installs.Python`).

  ## Entry points

    * `create/2`: a root admin creates an install. Returns the install and
      its status token ONCE; only the token's sha256 is stored. The token is
      the capability for the customer's progress page (`get_by_token/2`). The
      marketing-site front door (out of scope here) will call this too.
    * `retry/2`, `teardown/1`, `reveal_handover/1`, `acknowledge_handover/1`.
    * `defaults/0`: the experiment surface,
      `config :platform, Platform.Installs, default_size:, sizes:, regions:`.

  ## Teardown is one command

      bin/platform eval 'Platform.Installs.teardown("<slug>")'
      mix burrow.install.teardown <slug>

  It deletes the droplets by tag, the firewall by name and, for a subdomain of
  ours, both A records, then re-reads `GET /v2/droplets?tag_name=` and returns
  `:ok` only when that is empty (`{:error, :droplets_remain}` otherwise). A
  second call is a no-op `:ok`.

  ## Hand-over custody

  `handover_sealed` (`Platform.Vault.EncryptedBinary`, AES-GCM) holds JSON
  `{ssh_private_key, static_api_key, oidc_client_secret}`. The last one is
  the render's pocket-id client secret, needed only by `final`'s
  bootstrap to register core's OIDC client. `reveal_handover/1` mints a fresh
  one-time sign-in link each time, so an expired 30-minute link never strands
  the customer, and returns the credentials to the caller; nothing from it
  is persisted. `acknowledge_handover/1` drops the sealed blob for good. An
  unacknowledged hand-over is purged 7 days after the install became ready
  (or was created, if it never did): `expire_handovers/1`, run hourly by
  `Platform.Installs.Sweeper` and also lazily by `reveal_handover/1`.

  No secret is ever logged, put in `steps`, or broadcast. Broadcasts are
  `{:install_updated, id}` on `"install:<id>"`.

  ## Dev stub mode

  `BURROW_INSTALLS_FAKE=1` in dev only (`config/runtime.exs`): the DigitalOcean
  client talks to `PlatformWeb.Dev.FakeDigitalOcean` (also mounted at
  `/dev/fake-digitalocean`, with `GET _calls` and `POST _fail`), and the
  render, probes and bootstrap are `Platform.Installs.Fake`. Stub mode never
  reads the real token.
  """

  import Ecto.Query

  require Logger

  alias Platform.Access
  alias Platform.Installs.DigitalOcean
  alias Platform.Installs.Install
  alias Platform.Installs.Runner
  alias Platform.Installs.SshKey
  alias Platform.Repo

  @handover_ttl_seconds 7 * 24 * 60 * 60
  @org_name_max 80
  @email ~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/
  @label ~r/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/
  @default_sizes ["s-2vcpu-4gb", "s-4vcpu-8gb"]

  # Every write may carry `handover_sealed`, and Ecto's :debug query log
  # prints CAST params, i.e. the PLAINTEXT (the reason `Platform.Vault`
  # writes with it too). So no installs write is query-logged.
  @no_query_log [log: false]

  # ---------------------------------------------------------------------------
  # Defaults (experiment surface)
  # ---------------------------------------------------------------------------

  @doc """
  `%{default_size:, sizes:, regions:}` from
  `config :platform, Platform.Installs`. Regions are always a subset of the
  US list DigitalOcean installs may use.
  """
  @spec defaults() :: %{default_size: String.t(), sizes: [String.t()], regions: [String.t()]}
  def defaults do
    sizes = config(:sizes, @default_sizes)

    %{
      default_size: config(:default_size, "s-2vcpu-4gb"),
      sizes: sizes,
      regions:
        Enum.filter(config(:regions, DigitalOcean.regions()), &(&1 in DigitalOcean.regions()))
    }
  end

  # ---------------------------------------------------------------------------
  # Create / read
  # ---------------------------------------------------------------------------

  @doc """
  Create an install. `actor` must be a root admin (re-checked here with
  `Platform.Access.authorize_install/1`, as `Platform.Vault.Shared` does; the
  route gate is not load-bearing alone).

  `attrs` (string or atom keys): `business_name`, `owner_email`, `region`,
  `size` (default `defaults().default_size`), `domain_mode` (`"ours"`, the
  default, or `"customer"`) and, for `"customer"`, `primary_host`.

  Returns `{:ok, %{install: install, status_token: token}}`; the token is
  never stored and cannot be shown again.
  """
  @spec create(term(), map()) ::
          {:ok, %{install: Install.t(), status_token: String.t()}}
          | {:error, :unauthorized | {:invalid, atom()} | :dns_zone_missing | term()}
  def create(actor, attrs) do
    with :ok <- Access.authorize_install(actor),
         {:ok, fields} <- validate_create(attrs) do
      token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      key = SshKey.generate()

      result =
        insert_with_unique_slug(fields, %{
          status: "queued",
          steps: Runner.initial_steps(),
          ssh_public_key: key.public,
          status_token_hash: hash_token(token),
          handover_sealed: Jason.encode!(%{"ssh_private_key" => key.private})
        })

      with {:ok, install} <- result do
        if config(:start_runs, true), do: Runner.start(install.id)
        {:ok, %{install: install, status_token: token}}
      end
    end
  end

  defp validate_create(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    defaults = defaults()
    name = attrs["business_name"]
    email = attrs["owner_email"]
    size = attrs["size"] || defaults.default_size
    mode = attrs["domain_mode"] || "ours"

    cond do
      not valid_business_name?(name) ->
        {:error, {:invalid, :business_name}}

      not (is_binary(email) and Regex.match?(@email, email)) ->
        {:error, {:invalid, :owner_email}}

      attrs["region"] not in defaults.regions ->
        {:error, {:invalid, :region}}

      size not in defaults.sizes ->
        {:error, {:invalid, :size}}

      mode not in ["ours", "customer"] ->
        {:error, {:invalid, :domain_mode}}

      true ->
        with_primary(mode, attrs, %{
          business_name: name,
          owner_email: email,
          region: attrs["region"],
          size: size,
          domain_mode: mode
        })
    end
  end

  defp with_primary("customer", attrs, fields) do
    host = attrs["primary_host"]
    host = if is_binary(host), do: host |> String.trim() |> String.downcase(), else: host

    if valid_host?(host),
      do: {:ok, Map.put(fields, :primary_host, host)},
      else: {:error, {:invalid, :primary_host}}
  end

  defp with_primary("ours", _attrs, fields) do
    case config(:dns_zone, nil) do
      zone when is_binary(zone) and zone != "" -> {:ok, Map.put(fields, :dns_zone, zone)}
      _ -> {:error, :dns_zone_missing}
    end
  end

  defp insert_with_unique_slug(fields, extra, attempts \\ 3) do
    slug = new_slug(fields.business_name)

    primary =
      case fields do
        %{domain_mode: "ours", dns_zone: zone} -> "#{slug}.#{zone}"
        %{primary_host: host} -> host
      end

    attrs =
      fields
      |> Map.drop([:dns_zone])
      |> Map.merge(extra)
      |> Map.merge(%{slug: slug, primary_host: primary})

    case %Install{} |> Install.create_changeset(attrs) |> Repo.insert(@no_query_log) do
      {:ok, install} ->
        broadcast(install.id)
        {:ok, install}

      {:error, %Ecto.Changeset{errors: errors}} = error ->
        if Keyword.has_key?(errors, :slug) and attempts > 1,
          do: insert_with_unique_slug(fields, extra, attempts - 1),
          else: error
    end
  end

  @doc """
  The business-name rule, the renderer's `install.org_name` rule: 1-80
  printable characters, no surrounding space, no `"`, `$` or backtick.
  """
  @spec valid_business_name?(term()) :: boolean()
  def valid_business_name?(name) when is_binary(name) do
    String.length(name) in 1..@org_name_max and String.printable?(name) and
      String.trim(name) == name and not String.contains?(name, ["\"", "$", "`", "\n", "\r", "\t"])
  end

  def valid_business_name?(_), do: false

  defp valid_host?(host) when is_binary(host) and byte_size(host) <= 253 do
    labels = String.split(host, ".")

    length(labels) >= 2 and Enum.all?(labels, &Regex.match?(@label, &1)) and
      not Regex.match?(~r/^[0-9]+$/, List.last(labels))
  end

  defp valid_host?(_), do: false

  @doc false
  def new_slug(business_name) do
    base =
      business_name
      |> :unicode.characters_to_nfkd_binary()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 30)
      |> String.trim("-")

    base = if Regex.match?(~r/^[a-z]/, base), do: base, else: "b-" <> base
    suffix = for _ <- 1..4, into: "", do: <<Enum.random(~c"abcdefghijkmnpqrstuvwxyz23456789")>>
    String.trim(base, "-") <> "-" <> suffix
  end

  @doc "The install with `id`, or nil (also for a malformed id)."
  @spec get(term()) :: Install.t() | nil
  def get(id) do
    if Platform.UUID.valid?(id), do: Repo.one(from(i in Install, where: i.id == ^id)), else: nil
  end

  @doc "The install with `slug`, or nil."
  @spec get_by_slug(term()) :: Install.t() | nil
  def get_by_slug(slug) when is_binary(slug),
    do: Repo.one(from(i in Install, where: i.slug == ^slug))

  def get_by_slug(_), do: nil

  @doc """
  The install whose status token is `token`, or nil. Lookups are rate-limited
  per node (`Platform.Calendar.BookingRateLimit` counters) by `opts[:rate_key]`
  (the caller's address; default one shared bucket), `token_lookups_per_minute`
  a minute (default 60); over the limit is nil too, so the answer is never an
  oracle.
  """
  @spec get_by_token(term(), keyword()) :: Install.t() | nil
  def get_by_token(token, opts \\ []) do
    rate_key = "install-token:" <> to_string(Keyword.get(opts, :rate_key, "all"))
    limit = config(:token_lookups_per_minute, 60)

    with true <- is_binary(token) and byte_size(token) in 1..128,
         :ok <- Platform.Calendar.BookingRateLimit.check(rate_key, 1, limit) do
      hash = hash_token(token)
      Repo.one(from(i in Install, where: i.status_token_hash == ^hash))
    else
      {:error, :rate_limited} ->
        Logger.warning("[installs] status-token lookups rate-limited")
        nil

      _ ->
        nil
    end
  end

  @doc "Every install, newest first. Root admins only."
  @spec list(term()) :: {:ok, [Install.t()]} | {:error, :unauthorized}
  def list(actor) do
    with :ok <- Access.authorize_install(actor) do
      {:ok, Repo.all(from(i in Install, order_by: [desc: i.inserted_at]))}
    end
  end

  defp hash_token(token), do: :crypto.hash(:sha256, token)

  # ---------------------------------------------------------------------------
  # Retry / resume
  # ---------------------------------------------------------------------------

  @doc """
  Retry a failed install. `by` is the status token (the customer's page) or
  a root-admin actor. The failed step goes back to pending and the run
  restarts; `reserve` finds the existing droplet by tag, so no second one is
  ever created.
  """
  @spec retry(Install.t(), term()) :: {:ok, Install.t()} | {:error, :unauthorized | :not_failed}
  def retry(%Install{} = install, by) do
    with :ok <- authorize_retry(install, by) do
      install = get(install.id)

      if install.status == "failed" do
        steps =
          Enum.map(install.steps, fn
            %{"state" => "failed"} = step ->
              %{
                step
                | "state" => "pending",
                  "started_at" => nil,
                  "finished_at" => nil,
                  "error" => nil
              }

            step ->
              step
          end)

        install = update!(install, %{status: "queued", steps: steps})
        if config(:start_runs, true), do: Runner.start(install.id)
        {:ok, install}
      else
        {:error, :not_failed}
      end
    end
  end

  defp authorize_retry(install, token) when is_binary(token) do
    if Plug.Crypto.secure_compare(hash_token(token), install.status_token_hash),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp authorize_retry(_install, actor), do: Access.authorize_install(actor)

  @doc """
  Restart every unfinished run (`queued`/`provisioning`) and every unfinished
  teardown (`destroying`). Called once at boot by `Platform.Installs.Supervisor`.
  """
  @spec resume_all() :: :ok
  def resume_all do
    from(i in Install,
      where: i.status in ["queued", "provisioning", "destroying"],
      select: {i.id, i.status}
    )
    |> Repo.all()
    |> Enum.each(fn
      {id, "destroying"} ->
        Task.Supervisor.start_child(Platform.TaskSupervisor, fn -> teardown(id) end)

      {id, _} ->
        Runner.start(id)
    end)
  end

  # ---------------------------------------------------------------------------
  # Teardown
  # ---------------------------------------------------------------------------

  @doc "Tear an install down by id or slug. See the moduledoc."
  @spec teardown(String.t()) :: :ok | {:error, :not_found | :droplets_remain | term()}
  def teardown(id_or_slug) do
    case get(id_or_slug) || get_by_slug(id_or_slug) do
      nil ->
        {:error, :not_found}

      %Install{status: "destroyed"} ->
        :ok

      install ->
        Runner.stop(install.id)
        install = update!(get(install.id), %{status: "destroying"})
        tag = DigitalOcean.install_tag(install.id)

        with :ok <- DigitalOcean.delete_droplets_by_tag(tag),
             :ok <- DigitalOcean.delete_firewall(install.id),
             :ok <- delete_dns(install),
             :ok <- confirm_gone(tag, config(:teardown_confirm_attempts, 6)) do
          update!(get(install.id), %{status: "destroyed", handover_sealed: nil})
          :ok
        end
    end
  end

  defp delete_dns(%Install{domain_mode: "ours"} = install) do
    DigitalOcean.delete_records(ours_zone(install), [install.slug, "auth." <> install.slug])
  end

  defp delete_dns(_customer), do: :ok

  defp confirm_gone(tag, attempts) do
    case DigitalOcean.find_droplets_by_tag(tag) do
      {:ok, []} ->
        :ok

      {:ok, _remaining} when attempts > 1 ->
        Process.sleep(config(:teardown_confirm_interval_ms, :timer.seconds(5)))
        confirm_gone(tag, attempts - 1)

      {:ok, _remaining} ->
        {:error, :droplets_remain}

      {:error, _} = error ->
        error
    end
  end

  # ---------------------------------------------------------------------------
  # Hand-over
  # ---------------------------------------------------------------------------

  @doc """
  The hand-over credentials of a ready install, with a FRESH one-time sign-in
  link: `%{burrow_url, admin_email, sign_in_link, ssh: %{host, user, private_key}}`.
  Nothing is persisted. Errors: `:not_ready`, `:already_handed_over` (after
  `acknowledge_handover/1`), `:handover_expired` (7 days unacknowledged).
  """
  @spec reveal_handover(Install.t()) :: {:ok, map()} | {:error, term()}
  def reveal_handover(%Install{} = install) do
    install = expire_if_due(get(install.id), DateTime.utc_now())

    cond do
      install.handover_acknowledged_at -> {:error, :already_handed_over}
      install.handover_expired_at -> {:error, :handover_expired}
      install.status != "ready" -> {:error, :not_ready}
      true -> mint_handover(install)
    end
  end

  defp mint_handover(install) do
    with {:ok, sealed} <- unseal(install),
         {:ok, link} <-
           Platform.Installs.Bootstrap.impl().admin_link(install, auth_host(install), %{
             "STATIC_API_KEY" => sealed["static_api_key"]
           }) do
      {:ok,
       %{
         burrow_url: "https://#{install.primary_host}",
         admin_email: install.owner_email,
         sign_in_link: link,
         ssh: %{host: install.droplet_ip, user: "root", private_key: sealed["ssh_private_key"]}
       }}
    end
  end

  @doc "The customer saved the credentials: drop them for good."
  @spec acknowledge_handover(Install.t()) :: {:ok, Install.t()} | {:error, :not_ready}
  def acknowledge_handover(%Install{} = install) do
    install = get(install.id)

    cond do
      install.handover_acknowledged_at ->
        {:ok, install}

      install.status != "ready" ->
        {:error, :not_ready}

      true ->
        {:ok,
         update!(install, %{handover_sealed: nil, handover_acknowledged_at: DateTime.utc_now()})}
    end
  end

  @doc """
  Purge every hand-over left unacknowledged for 7 days after its install
  became ready (or was created, if it never did). Returns how many.
  """
  @spec expire_handovers(DateTime.t()) :: non_neg_integer()
  def expire_handovers(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@handover_ttl_seconds, :second)

    from(i in Install,
      where:
        not is_nil(i.handover_sealed) and is_nil(i.handover_acknowledged_at) and
          coalesce(i.ready_at, i.inserted_at) < ^cutoff
    )
    |> Repo.all()
    |> Enum.map(&expire(&1, now))
    |> length()
  end

  defp expire_if_due(install, now) do
    due = DateTime.add(install.ready_at || install.inserted_at, @handover_ttl_seconds, :second)

    if install.handover_sealed && is_nil(install.handover_acknowledged_at) &&
         DateTime.compare(now, due) == :gt,
       do: expire(install, now),
       else: install
  end

  defp expire(install, now) do
    Logger.info("[installs] hand-over of #{install.id} expired unacknowledged; purged")
    update!(install, %{handover_sealed: nil, handover_expired_at: now})
  end

  # ---------------------------------------------------------------------------
  # Shared helpers (runner, screens)
  # ---------------------------------------------------------------------------

  @doc "The decoded hand-over blob, or `{:error, :handover_missing}`."
  @spec unseal(Install.t()) :: {:ok, map()} | {:error, :handover_missing}
  def unseal(%Install{handover_sealed: sealed}) when is_binary(sealed),
    do:
      Jason.decode(sealed)
      |> then(fn
        {:ok, map} -> {:ok, map}
        _ -> {:error, :handover_missing}
      end)

  def unseal(_), do: {:error, :handover_missing}

  @doc "pocket-id's host: `auth.<primary>`."
  def auth_host(%Install{primary_host: primary}), do: "auth." <> primary

  @doc "The DNS zone of an install on a subdomain of ours (`<slug>.<zone>`)."
  def ours_zone(%Install{slug: slug, primary_host: primary}),
    do: String.replace_prefix(primary, slug <> ".", "")

  @doc false
  def update!(%Install{} = install, attrs) do
    install = install |> Install.update_changeset(attrs) |> Repo.update!(@no_query_log)
    broadcast(install.id)
    install
  end

  @doc "Subscribe to `{:install_updated, id}` for one install."
  def subscribe(id), do: Phoenix.PubSub.subscribe(Platform.PubSub, topic(id))

  defp broadcast(id),
    do: Phoenix.PubSub.broadcast(Platform.PubSub, topic(id), {:install_updated, id})

  defp topic(id), do: "install:#{id}"

  @doc """
  A failed step's reason in plain words for the customer. Never a secret,
  and never infrastructure jargon.
  """
  @spec describe_error(String.t(), term()) :: String.t()
  def describe_error(_step, :timeout), do: "This step took longer than expected."
  def describe_error(_step, :forbidden), do: "Our hosting provider refused the request."
  def describe_error(_step, :region_not_allowed), do: "That region is not available."

  def describe_error(_step, :registry_auth_missing),
    do: "The server software could not be fetched; we need to finish a setting on our side."

  def describe_error(_step, reason)
      when reason in [:do_token_unusable, :not_found, :access_denied, :ambiguous_slug],
      do: "Our hosting account is not ready for new servers right now."

  def describe_error(_step, {kind, _}) when kind in [:http, :transport],
    do: "Our hosting provider did not answer as expected."

  def describe_error(_step, {:bootstrap_failed, _}),
    do: "We could not set up your admin account yet."

  def describe_error(_step, _reason), do: "Something went wrong on our side."

  @doc "A short, secret-free code for a failure reason, for logs."
  @spec reason_code(term()) :: String.t()
  def reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)

  def reason_code({kind, detail}) when is_atom(kind) and (is_atom(detail) or is_integer(detail)),
    do: "#{kind}:#{detail}"

  def reason_code({kind, _}) when is_atom(kind), do: Atom.to_string(kind)
  def reason_code(_), do: "error"

  defp config(key, default),
    do: Keyword.get(Application.get_env(:platform, __MODULE__, []), key, default)
end
