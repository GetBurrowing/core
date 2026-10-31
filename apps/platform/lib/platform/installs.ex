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
      the capability for the customer's progress page (`get_by_token/2`).
    * `request/1`: the getburrow.ing front door (task 01a18f0c). A request is
      an `installs` row with status `requested`, one open per email; a root
      admin turns it into a run with `provision_request/2` (or dismisses it,
      `dismiss_request/2`), unless the spend gate
      `Platform.Installs.RequestSettings` provisions it at once.
    * `retry/2`, `teardown/1`, `reveal_handover/1`, `acknowledge_handover/1`.
    * `defaults/0`: the experiment surface,
      `config :platform, Platform.Installs, default_size:, sizes:, regions:`.

  ## Install-request environment (task 01a18f0c)

    * `BURROW_INSTALL_INTAKE_TOKEN` (`intake_token`): the bearer token the
      getburrow.ing Pages Function sends to `POST /api/install-requests`
      (`PlatformWeb.Plugs.VerifyInstallIntakeToken`). Unset: the route 404s.
    * `BURROW_INSTALLS_MAIL_ORG_ID`, `BURROW_INSTALLS_MAIL_ACCOUNT_ID`,
      `BURROW_INSTALLS_MAIL_SENDER_KEY` (`mail_sender: %{org_id, account_id,
      sender_key}`): the mail account and sender the requester's hand-over
      email goes out through. Any unset: no email is sent.

  ## Teardown is one command

      bin/platform eval 'Platform.Installs.teardown("<slug>")'
      mix burrow.install.teardown <slug>

  It deletes the droplets by tag, the firewall by name and, for a subdomain of
  ours, both A records, then re-reads `GET /v2/droplets?tag_name=` and returns
  `:ok` only when that is empty (`{:error, :droplets_remain}` otherwise). A
  second call is a no-op `:ok`.

  ## Hand-over custody

  `handover_sealed` (`Platform.Installs.Handover.Type`: AES-GCM
  `Platform.Vault.EncryptedBinary` in the column) holds JSON
  `{ssh_private_key, static_api_key, oidc_client_secret}` and loads as a
  `Platform.Installs.Handover`, which prints `#Handover<redacted>` and gives a
  value up only through `Handover.fetch/2`. `oidc_client_secret` is
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
  alias Platform.Installs.Handover
  alias Platform.Installs.Install
  alias Platform.Installs.Runner
  alias Platform.Installs.SshKey
  alias Platform.Repo

  @handover_ttl_seconds 7 * 24 * 60 * 60
  @org_name_max 80
  @email ~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/
  @label ~r/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/
  @default_sizes ["s-2vcpu-4gb", "s-4vcpu-8gb"]
  # DigitalOcean size slug -> the install manifest's `[install] size_tier`
  # (task 01a18f76). The tier picks the local embeddings profile the
  # installer renders (deployment/installer registry.EMBEDDINGS_PROFILES), so
  # a 4 GB droplet gets the 4 GB row. Data only: the flags live in that table.
  # `config :platform, Platform.Installs, size_tiers:` overrides it; a size
  # with no tier is refused by `create/2`.
  @size_tiers %{"s-2vcpu-4gb" => "small", "s-4vcpu-8gb" => "medium"}

  # Every write may carry `handover_sealed`, and Ecto's :debug query log
  # prints CAST params, i.e. the PLAINTEXT (the reason `Platform.Vault`
  # writes with it too). So no installs write is query-logged.
  @no_query_log [log: false]

  # ---------------------------------------------------------------------------
  # Defaults (experiment surface)
  # ---------------------------------------------------------------------------

  @doc """
  `%{default_size:, sizes:, regions:, available:}` from
  `config :platform, Platform.Installs`. Regions are always a subset of the
  US list DigitalOcean installs may use.

  Stage 6: `regions` are only those where `default_size` can be created right
  now (`DigitalOcean.availability/0`, cached), with `default_region` (config,
  default `"nyc1"`) first when it is one of them. So the first region and the
  default size are ALWAYS a pair the provider offers; a caller that takes
  both (the admin form, the public front door) never starts with a 422.
  `available` is `%{size => [region]}` for every offered size. When the
  provider's list cannot be read, nothing is filtered.
  """
  @spec defaults() :: %{
          default_size: String.t(),
          sizes: [String.t()],
          regions: [String.t()],
          available: %{String.t() => [String.t()]}
        }
  def defaults do
    sizes = config(:sizes, @default_sizes)
    default_size = config(:default_size, "s-2vcpu-4gb")
    allowed = allowed_regions()
    known = availability()
    available = Map.new(sizes, &{&1, offered_regions(&1, allowed, known)})

    %{
      default_size: default_size,
      sizes: sizes,
      regions: offered_regions(default_size, allowed, known),
      available: available
    }
  end

  @doc "The regions `size` can be created in now, preferred region first (see `defaults/0`)."
  @spec regions_for(String.t()) :: [String.t()]
  def regions_for(size), do: offered_regions(size, allowed_regions(), availability())

  defp allowed_regions,
    do: Enum.filter(config(:regions, DigitalOcean.regions()), &(&1 in DigitalOcean.regions()))

  defp offered_regions(size, allowed, known) do
    regions =
      case Map.get(known, size) do
        list when is_list(list) -> Enum.filter(allowed, &(&1 in list))
        nil -> allowed
      end

    preferred = config(:default_region, "nyc1")
    if preferred in regions, do: [preferred | List.delete(regions, preferred)], else: regions
  end

  # Unknown (`%{}`) when the provider's list cannot be read: nothing is filtered.
  defp availability do
    case DigitalOcean.availability() do
      {:ok, known} -> known
      {:error, _} -> %{}
    end
  rescue
    _ -> %{}
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
      {token, provisioned} = provision_secrets()
      result = insert_with_unique_slug(fields, provisioned)

      with {:ok, install} <- result do
        if config(:start_runs, true), do: Runner.start(install.id)
        {:ok, %{install: install, status_token: token}}
      end
    end
  end

  @doc """
  The install manifest `size_tier` for a DigitalOcean size slug, or nil when
  the slug has none (`@size_tiers`, overridable with `config :platform,
  Platform.Installs, size_tiers:`).
  """
  @spec size_tier(String.t() | nil) :: String.t() | nil
  def size_tier(size), do: Map.get(config(:size_tiers, @size_tiers), size)

  defp validate_create(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    name = attrs["business_name"]
    email = attrs["owner_email"]
    size = attrs["size"] || config(:default_size, "s-2vcpu-4gb")
    mode = attrs["domain_mode"] || "ours"

    cond do
      not valid_business_name?(name) ->
        {:error, {:invalid, :business_name}}

      not (is_binary(email) and Regex.match?(@email, email)) ->
        {:error, {:invalid, :owner_email}}

      attrs["region"] not in allowed_regions() ->
        {:error, {:invalid, :region}}

      size not in config(:sizes, @default_sizes) ->
        {:error, {:invalid, :size}}

      # Task 01a18f76: `sizes` is configurable, so an operator can list a slug
      # with no tier, whose embeddings profile nobody has measured. Refused
      # here, before any provider call (the availability read below included).
      is_nil(size_tier(size)) ->
        {:error, {:invalid, :size_unsupported}}

      # Stage 6: refused here, before any droplet POST (the provider's 422).
      attrs["region"] not in Map.fetch!(defaults().available, size) ->
        {:error, {:invalid, :size_unavailable}}

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
    attrs = fields |> provisioned_fields(slug) |> Map.merge(extra) |> Map.put(:slug, slug)

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

  # What `create/2` and `provision_request/2` both write to queue a run: the
  # install's root key (private half sealed in the hand-over), a status token
  # (only its hash is stored) and the initial steps. Returns the token too.
  defp provision_secrets do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    key = SshKey.generate()

    {token,
     %{
       status: "queued",
       steps: Runner.initial_steps(),
       ssh_public_key: key.public,
       status_token_hash: hash_token(token),
       handover_sealed: Handover.wrap(%{"ssh_private_key" => key.private})
     }}
  end

  # `validate_create/1`'s fields for an install whose slug is `slug`: a
  # subdomain of ours is `<slug>.<zone>`.
  defp provisioned_fields(fields, slug) do
    primary =
      case fields do
        %{domain_mode: "ours", dns_zone: zone} -> "#{slug}.#{zone}"
        %{primary_host: host} -> host
      end

    fields |> Map.drop([:dns_zone]) |> Map.put(:primary_host, primary)
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

  @doc """
  Every install, newest first. Root admins only. A `requested` row is not an
  install yet and is listed by `list_requests/1` instead.
  """
  @spec list(term()) :: {:ok, [Install.t()]} | {:error, :unauthorized}
  def list(actor) do
    with :ok <- Access.authorize_install(actor) do
      {:ok,
       Repo.all(
         from(i in Install, where: i.status != "requested", order_by: [desc: i.inserted_at])
       )}
    end
  end

  # ---------------------------------------------------------------------------
  # Install requests (task 01a18f0c stage 1)
  # ---------------------------------------------------------------------------

  @open_statuses ~w(requested queued provisioning ready)
  @requests_topic "install-requests"
  @requester_name_max 120
  @note_max 1000
  @email_max 254

  @doc """
  Record an install request from the public form. `attrs` (string or atom
  keys): `name`, `email`, `business`, `note` and `website` (the honeypot).

  A request IS an `installs` row with status `requested`; there is no other
  store. Returns:

    * `{:ok, :ignored}`: the honeypot `website` is filled. Nothing is written.
    * `{:ok, :duplicate}`: lower(email) already has a `requested`, `queued`,
      `provisioning` or `ready` install. Nothing is written. Two concurrent
      requests for one email meet the partial unique index
      `installs_one_open_request_per_email` and the loser gets this too.
    * `{:ok, :created}`: one `requested` row.
    * `{:error, {:invalid, field}}`, `field` one of `:email`, `:name`,
      `:note`, `:business_name`.

  The business name is NORMALISED to satisfy `valid_business_name?/1` (it
  becomes the install's ROOT_ORG_NAME): `"`, `$`, backtick and control
  characters go, whitespace collapses, and it is cut to 80 characters. The
  operator sees the normalised name before clicking Provision.

  ## The spend gate

  Only when `Platform.Installs.RequestSettings.get().auto_provision_requests`
  is on does a request provision at once, and even then only while fewer than
  `auto_provision_max_in_flight` (default 3) installs are queued or
  provisioning and fewer than `auto_provision_max_per_day` (default 10)
  requests were provisioned in the last 24 hours. Past either cap the row
  stays `requested` for an operator. With the switch off (the default) a
  request makes no provider call at all.

  The requester's email is unverified: whoever types an address gets the
  hand-over at it. The operator's Provision click is the check, which is why
  auto-provision is off by default.

  No write or read here is query-logged, and nothing logged carries the
  requester's name, email or note.
  """
  @spec request(map()) ::
          {:ok, :created | :duplicate | :ignored} | {:error, {:invalid, atom()}}
  def request(attrs) when is_map(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    if honeypot_filled?(attrs["website"]) do
      {:ok, :ignored}
    else
      with {:ok, fields} <- validate_request(attrs) do
        if open_install_exists?(fields.owner_email),
          do: {:ok, :duplicate},
          else: insert_request(fields)
      end
    end
  end

  def request(_attrs), do: {:error, {:invalid, :email}}

  defp honeypot_filled?(nil), do: false
  defp honeypot_filled?(value) when is_binary(value), do: String.trim(value) != ""
  defp honeypot_filled?(_other), do: true

  defp validate_request(attrs) do
    with {:ok, email} <- request_email(attrs["email"]),
         {:ok, name} <- requester_name(attrs["name"]),
         {:ok, note} <- request_note(attrs["note"]),
         {:ok, business} <- normalise_business_name(attrs["business"]) do
      {:ok,
       %{owner_email: email, requester_name: name, request_note: note, business_name: business}}
    end
  end

  defp request_email(email) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()

    if String.valid?(email) and byte_size(email) <= @email_max and Regex.match?(@email, email),
      do: {:ok, email},
      else: {:error, {:invalid, :email}}
  end

  defp request_email(_), do: {:error, {:invalid, :email}}

  defp requester_name(name) when is_binary(name) do
    name = if String.valid?(name), do: String.trim(name), else: ""

    if String.length(name) in 1..@requester_name_max and not control_chars?(name),
      do: {:ok, name},
      else: {:error, {:invalid, :name}}
  end

  defp requester_name(_), do: {:error, {:invalid, :name}}

  defp request_note(nil), do: {:ok, nil}

  defp request_note(note) when is_binary(note) do
    cond do
      not String.valid?(note) -> {:error, {:invalid, :note}}
      String.trim(note) == "" -> {:ok, nil}
      String.length(String.trim(note)) <= @note_max -> {:ok, String.trim(note)}
      true -> {:error, {:invalid, :note}}
    end
  end

  defp request_note(_), do: {:error, {:invalid, :note}}

  defp control_chars?(text), do: Regex.match?(~r/\p{Cc}/u, text)

  @doc """
  `name` made to satisfy `valid_business_name?/1`, or
  `{:error, {:invalid, :business_name}}` when nothing usable is left.
  """
  @spec normalise_business_name(term()) :: {:ok, String.t()} | {:error, {:invalid, atom()}}
  def normalise_business_name(name) when is_binary(name) do
    normalised =
      if String.valid?(name) do
        name
        |> String.replace(~r/[\p{Cc}]/u, " ")
        |> String.replace(["\"", "$", "`"], "")
        |> String.graphemes()
        |> Enum.filter(&String.printable?/1)
        |> Enum.join()
        |> String.replace(~r/\s+/u, " ")
        |> String.trim()
        |> String.slice(0, @org_name_max)
        |> String.trim()
      else
        ""
      end

    if valid_business_name?(normalised),
      do: {:ok, normalised},
      else: {:error, {:invalid, :business_name}}
  end

  def normalise_business_name(_), do: {:error, {:invalid, :business_name}}

  defp open_install_exists?(email) do
    from(i in Install,
      where: fragment("lower(?)", i.owner_email) == ^email and i.status in @open_statuses
    )
    |> Repo.exists?(@no_query_log)
  end

  defp insert_request(fields, attempts \\ 3) do
    attrs =
      Map.merge(fields, %{
        slug: new_slug(fields.business_name),
        status: "requested",
        requested_at: DateTime.utc_now()
      })

    case %Install{} |> Install.request_changeset(attrs) |> Repo.insert(@no_query_log) do
      {:ok, install} ->
        Logger.info("[installs] request #{install.id} created")
        broadcast(install.id)
        broadcast_requests()
        maybe_auto_provision(install)
        {:ok, :created}

      {:error, %Ecto.Changeset{errors: errors}} = error ->
        cond do
          Keyword.has_key?(errors, :owner_email) -> {:ok, :duplicate}
          Keyword.has_key?(errors, :slug) and attempts > 1 -> insert_request(fields, attempts - 1)
          true -> error
        end
    end
  end

  defp maybe_auto_provision(%Install{id: id}) do
    cond do
      not Platform.Installs.RequestSettings.get().auto_provision_requests ->
        :ok

      auto_provision_capped?() ->
        Logger.warning(
          "[installs] request #{id} left for an operator: auto-provision cap reached"
        )

      true ->
        case do_provision_request(id) do
          {:ok, _install} ->
            Logger.info("[installs] request #{id} auto-provisioned")

          {:error, reason} ->
            Logger.warning(
              "[installs] auto-provision of request #{id} failed: #{reason_code(reason)}"
            )
        end
    end
  end

  # The architecture review's must-have: with the switch on, distinct emails
  # alone must not be able to buy an unbounded number of servers.
  defp auto_provision_capped? do
    in_flight =
      Repo.aggregate(
        from(i in Install, where: i.status in ["queued", "provisioning"]),
        :count
      )

    since = DateTime.add(DateTime.utc_now(), -24 * 60 * 60, :second)

    provisioned_today =
      Repo.aggregate(
        from(i in Install,
          where: not is_nil(i.requested_at) and i.status != "requested" and i.updated_at >= ^since
        ),
        :count
      )

    in_flight >= config(:auto_provision_max_in_flight, 3) or
      provisioned_today >= config(:auto_provision_max_per_day, 10)
  end

  @doc """
  Provision the `requested` install `id`: one click, nothing retyped.
  `actor` must be a root admin (`Platform.Access.authorize_install/1`).

  The region is the first of `defaults().regions` (the preferred region the
  default size can be created in now), the size `defaults().default_size`,
  and the domain a subdomain of ours (`<slug>.<BURROW_INSTALLS_DNS_ZONE>`).
  They pass through the same validation `create/2` uses. The row gets the
  install's root key, sealed hand-over and steps exactly as `create/2` would
  and goes to `queued`; the run starts (honouring `start_runs`).

  The status token minted here is DISCARDED: the requester's token is minted
  when the install is ready (stage 4's hand-over email).

  Errors: `:unauthorized`, `:not_found`, `:not_requested` (already
  provisioned or dismissed), `:dns_zone_missing`, `{:invalid, field}`.
  """
  @spec provision_request(term(), term()) :: {:ok, Install.t()} | {:error, term()}
  def provision_request(:system_auto, _id), do: {:error, :unauthorized}

  def provision_request(actor, id) do
    with :ok <- Access.authorize_install(actor), do: do_provision_request(id)
  end

  # Reached by an authorised admin, or by request/1 behind the spend gate.
  defp do_provision_request(id) do
    case get(id) do
      nil ->
        {:error, :not_found}

      %Install{status: "requested"} = row ->
        defaults = defaults()

        with {:ok, fields} <-
               validate_create(%{
                 "business_name" => row.business_name,
                 "owner_email" => row.owner_email,
                 "region" => List.first(defaults.regions),
                 "size" => defaults.default_size,
                 "domain_mode" => "ours"
               }),
             {_discarded_token, provisioned} = provision_secrets(),
             attrs =
               fields
               |> provisioned_fields(row.slug)
               |> Map.drop([:business_name, :owner_email])
               |> Map.merge(provisioned),
             {:ok, install} <- queue_request(row.id, attrs) do
          broadcast(install.id)
          broadcast_requests()
          if config(:start_runs, true), do: Runner.start(install.id)
          {:ok, install}
        end

      %Install{} ->
        {:error, :not_requested}
    end
  end

  # Row-locked, so two concurrent clicks provision once.
  defp queue_request(id, attrs) do
    Repo.transaction(
      fn ->
        locked =
          Repo.one(
            from(i in Install, where: i.id == ^id and i.status == "requested", lock: "FOR UPDATE")
          )

        with %Install{} <- locked,
             {:ok, install} <-
               locked |> Install.update_changeset(attrs) |> Repo.update(@no_query_log) do
          install
        else
          nil -> Repo.rollback(:not_requested)
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end,
      @no_query_log
    )
  end

  @doc "Every `requested` row, oldest first. Root admins only."
  @spec list_requests(term()) :: {:ok, [Install.t()]} | {:error, :unauthorized}
  def list_requests(actor) do
    with :ok <- Access.authorize_install(actor) do
      {:ok,
       Repo.all(
         from(i in Install,
           where: i.status == "requested",
           order_by: [asc: i.requested_at, asc: i.inserted_at]
         )
       )}
    end
  end

  @doc """
  Hard-delete the `requested` row `id`, so the requester's details go with
  it. Root admins only. `{:error, :not_requested}` when there is no such
  requested row (already provisioned, dismissed or never there).
  """
  @spec dismiss_request(term(), term()) :: :ok | {:error, :unauthorized | :not_requested}
  def dismiss_request(actor, id) do
    with :ok <- Access.authorize_install(actor) do
      if Platform.UUID.valid?(id) do
        case Repo.delete_all(
               from(i in Install, where: i.id == ^id and i.status == "requested"),
               @no_query_log
             ) do
          {1, _} ->
            Logger.info("[installs] request #{id} dismissed")
            broadcast(id)
            broadcast_requests()
            :ok

          {0, _} ->
            {:error, :not_requested}
        end
      else
        {:error, :not_requested}
      end
    end
  end

  defp hash_token(token), do: :crypto.hash(:sha256, token)

  @doc """
  Replace `install`'s status token with a fresh one and return it. Only its
  sha256 is stored; every earlier token stops resolving. Used by
  `Platform.Installs.HandoverMail` (task 01a18f0c stage 4), which mints the
  requester's token at ready time because `provision_request/2` discarded
  the provision-time one.
  """
  @spec mint_status_token(Install.t()) :: String.t()
  def mint_status_token(%Install{} = install) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    update!(install, %{status_token_hash: hash_token(token)})
    token
  end

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
        maybe_reboot(install)

        steps =
          Enum.map(install.steps, fn
            %{"state" => "failed"} = step ->
              # A retried final step earns its consecutive memory polls anew.
              %{
                Map.drop(step, ["memory_oks", "memory_checked_at"])
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

  # Stage 6: a server that never finished installing (its stack never came
  # up, e.g. the model download gave up) is restarted, so its units run again.
  # Best effort: the retry goes ahead whatever the reboot answers.
  defp maybe_reboot(%Install{droplet_id: id, steps: steps}) when is_integer(id) do
    if Enum.any?(steps, &(&1["key"] == "install" and &1["state"] == "failed")) do
      case DigitalOcean.reboot_droplet(id) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("[installs] reboot before retry failed: #{reason_code(reason)}")
      end
    end

    :ok
  end

  defp maybe_reboot(_install), do: :ok

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
        Task.Supervisor.start_child(Platform.TaskSupervisor, fn -> supervised_teardown(id) end)

      {id, _} ->
        Runner.start(id)
    end)
  end

  # ---------------------------------------------------------------------------
  # Teardown
  # ---------------------------------------------------------------------------

  @doc "Tear an install down by id or slug. See the moduledoc."
  @spec teardown(String.t()) ::
          :ok | {:error, :not_found | :not_provisioned | :droplets_remain | term()}
  def teardown(id_or_slug) do
    case get(id_or_slug) || get_by_slug(id_or_slug) do
      nil ->
        {:error, :not_found}

      %Install{status: "destroyed"} ->
        :ok

      # Task 01a18f0c: a request owns nothing at the provider; dismiss it.
      %Install{status: "requested"} ->
        {:error, :not_provisioned}

      install ->
        Runner.stop(install.id)
        install = update!(get(install.id), %{status: "destroying"})
        tag = DigitalOcean.install_tag(install.id)

        with :ok <- DigitalOcean.delete_droplets_by_tag(tag),
             :ok <- DigitalOcean.delete_firewall(install.id),
             :ok <- delete_dns(install),
             # Stage 6: the account SSH key registered for this install.
             :ok <- DigitalOcean.delete_ssh_key(install.id),
             :ok <- confirm_gone(tag, config(:teardown_confirm_attempts, 6)) do
          update!(get(install.id), %{status: "destroyed", handover_sealed: nil, ssh_key_id: nil})
          :ok
        end
    end
  end

  # Spawned by resume_all/0; see Runner's supervised_run/1 for the rescue.
  defp supervised_teardown(id) do
    teardown(id)
  rescue
    DBConnection.OwnershipError -> :stopped
  end

  defp delete_dns(%Install{domain_mode: "ours"} = install) do
    DigitalOcean.delete_records(ours_zone(install), [install.slug, "auth." <> install.slug])
  end

  defp delete_dns(%Install{domain_mode: "customer"} = install) do
    case cname_zone() do
      nil -> :ok
      zone -> DigitalOcean.delete_records(zone, [install.slug, "auth." <> install.slug])
    end
  end

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
             "STATIC_API_KEY" => Handover.fetch(sealed, "static_api_key")
           }) do
      {:ok,
       %{
         burrow_url: "https://#{install.primary_host}",
         admin_email: install.owner_email,
         sign_in_link: link,
         ssh: %{
           host: install.droplet_ip,
           user: "root",
           private_key: Handover.fetch(sealed, "ssh_private_key")
         }
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

  @doc """
  The hand-over as a redacted `Platform.Installs.Handover` (read a value with
  `Handover.fetch/2` at its point of use), or `{:error, :handover_missing}`.
  """
  @spec unseal(Install.t()) :: {:ok, Handover.t()} | {:error, :handover_missing}
  def unseal(%Install{handover_sealed: %Handover{} = sealed}), do: {:ok, sealed}

  def unseal(_), do: {:error, :handover_missing}

  # A pinned build's tag: never a moving flavour tag (`core`, `play`) and
  # never `latest`, so an override cannot silently become "whatever main is".
  @moving_tags ~w(core play latest)
  @image_ref ~r/^[a-z0-9]([a-z0-9._\/-]*[a-z0-9])?(:[0-9]+)?(\/[a-z0-9._-]+)*:(?<tag>[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})\z/

  @doc """
  The core image installs pull instead of the flavour default, or nil (the
  default, which is unchanged: `<registry>/core:core`).

  Dev/staging test seam (stage 6 round 2): `BURROW_INSTALLS_CORE_IMAGE` names
  a pinned branch build so a droplet can run code main does not have yet. It
  is honoured ONLY when ALL hold, and otherwise ignored with a logged warning:

    * the release is not `:prod` (`config/runtime.exs` records `config_env()`);
    * the explicit opt-in `BURROW_INSTALLS_CORE_IMAGE_OPT_IN=1` is set;
    * the ref is `<repo>:<tag>` with a tag that is not `core`, `play` or
      `latest` (a pinned build, never a moving tag).

  Rendered as the installer's existing `[images.refs] core-platform`.
  """
  @spec core_image_override() :: String.t() | nil
  def core_image_override do
    case config(:core_image_override, nil) do
      %{ref: ref} = override when is_binary(ref) and ref != "" -> honoured_override(override)
      _ -> nil
    end
  end

  defp honoured_override(%{ref: ref} = override) do
    tag = Regex.named_captures(@image_ref, ref)

    cond do
      Map.get(override, :env) == :prod ->
        ignore_override("this is a :prod release")

      Map.get(override, :opt_in) != true ->
        ignore_override("BURROW_INSTALLS_CORE_IMAGE_OPT_IN=1 is not set")

      tag == nil ->
        ignore_override("it is not a <repo>:<tag> image reference")

      tag["tag"] in @moving_tags ->
        ignore_override("its tag is a moving tag (core, play or latest), not a pinned build")

      true ->
        ref
    end
  end

  defp ignore_override(reason) do
    Logger.warning("[installs] BURROW_INSTALLS_CORE_IMAGE ignored: #{reason}")
    nil
  end

  @doc """
  The zone a customer-domain install's CNAME targets live in
  (`BURROW_INSTALLS_DNS_ZONE`), or nil. With a zone, `reserve` also points
  `<slug>.<zone>` and `auth.<slug>.<zone>` at the server so the customer
  can CNAME to them (task 01a10315 stage 3); without one the customer gets
  A records to the server's address instead.
  """
  @spec cname_zone() :: String.t() | nil
  def cname_zone do
    case config(:dns_zone, nil) do
      zone when is_binary(zone) and zone != "" -> zone
      _ -> nil
    end
  end

  @doc """
  The two records a customer-domain install's owner adds where they manage
  their domain: `[%{name, type, value}]`, primary host first. A CNAME to
  `<slug>.<zone>.` (and `auth.<slug>.<zone>.`), or an A record to the
  server's address when the host is an apex (an apex cannot CNAME) or no
  zone is configured. `[]` for a subdomain of ours. `value` is nil for an A
  record while the address is not known yet.
  """
  @spec dns_instructions(Install.t()) :: [%{name: String.t(), type: String.t(), value: term()}]
  def dns_instructions(%Install{domain_mode: "customer"} = install) do
    host = install.primary_host
    zone = cname_zone()
    apex? = length(String.split(host, ".")) == 2
    a = fn name -> %{name: name, type: "A", value: install.droplet_ip} end

    cname = fn name, target ->
      %{name: name, type: "CNAME", value: "#{target}.#{zone}."}
    end

    case zone do
      nil ->
        [a.(host), a.("auth." <> host)]

      _zone ->
        primary = if apex?, do: a.(host), else: cname.(host, install.slug)
        [primary, cname.("auth." <> host, "auth." <> install.slug)]
    end
  end

  def dns_instructions(%Install{}), do: []

  @region_names %{
    "nyc1" => "New York",
    "nyc2" => "New York",
    "nyc3" => "New York",
    "sfo2" => "San Francisco",
    "sfo3" => "San Francisco",
    "atl1" => "Atlanta",
    "ric1" => "Richmond"
  }

  @fallback_prices %{"s-2vcpu-4gb" => 24, "s-4vcpu-8gb" => 48}

  @doc ~S'A region slug in business terms: `"New York (nyc3)"`.'
  @spec region_label(String.t() | nil) :: String.t() | nil
  def region_label(nil), do: nil
  def region_label(region), do: "#{Map.get(@region_names, region, region)} (#{region})"

  @doc ~S'A size slug in business terms: `"s-2vcpu-4gb"` is `"2 vCPU / 4 GB"`.'
  @spec size_label(String.t() | nil) :: String.t() | nil
  def size_label(nil), do: nil

  def size_label(size) do
    case Regex.run(~r/(\d+)vcpu-(\d+)gb/, size) do
      [_, cpu, gb] -> "#{cpu} vCPU / #{gb} GB"
      _ -> size
    end
  end

  @doc """
  `%{slug => monthly price}` for the offered sizes, from
  `DigitalOcean.sizes/0` (cached an hour) and falling back to the list
  price when the API cannot be reached, so a screen never fails on it.
  """
  @spec monthly_prices() :: %{String.t() => number()}
  def monthly_prices do
    live =
      try do
        case DigitalOcean.sizes() do
          {:ok, sizes} -> sizes
          _ -> %{}
        end
      rescue
        _ -> %{}
      end

    Map.new(defaults().sizes, fn size ->
      {size, Map.get(live, size) || Map.get(@fallback_prices, size)}
    end)
  end

  @doc ~S'A monthly price as `"$24/mo"` (nil when unknown).'
  @spec price_label(number() | nil) :: String.t() | nil
  def price_label(nil), do: nil

  def price_label(price) when is_float(price) and price == trunc(price),
    do: price_label(trunc(price))

  def price_label(price) when is_integer(price), do: "$#{price}/mo"
  def price_label(price), do: "$#{:erlang.float_to_binary(price / 1, decimals: 2)}/mo"

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

  @doc """
  Subscribe to `:install_requests_changed`, broadcast whenever a request is
  created, provisioned or dismissed (task 01a18f0c stage 3).
  """
  def subscribe_requests, do: Phoenix.PubSub.subscribe(Platform.PubSub, @requests_topic)

  defp broadcast_requests,
    do: Phoenix.PubSub.broadcast(Platform.PubSub, @requests_topic, :install_requests_changed)

  @doc """
  The hand-over email state of each install that came from a request
  (`requested_at` set), as one word: `"not sent yet"`, `"queued"` (also while
  sending), `"accepted"`, `"failed"`, `"refused"` or `"not configured"` (a
  ready install with no email because the mail sender is not configured).
  Read from `mail_deliveries.status` only; never a body. `%{id => word}`.
  """
  @spec handover_email_states([Install.t()]) :: %{String.t() => String.t()}
  def handover_email_states(installs) do
    from_request = Enum.filter(installs, & &1.requested_at)

    delivery_ids =
      from_request |> Enum.map(& &1.handover_email_delivery_id) |> Enum.reject(&is_nil/1)

    statuses =
      if delivery_ids == [],
        do: %{},
        else:
          Repo.all(
            from(d in Platform.Mail.Delivery,
              where: d.id in ^delivery_ids,
              select: {d.id, d.status}
            )
          )
          |> Map.new()

    configured? = mail_sender_configured?()

    Map.new(from_request, fn install ->
      {install.id, email_state(install, statuses, configured?)}
    end)
  end

  defp email_state(%Install{handover_email_delivery_id: id}, statuses, _configured?)
       when is_binary(id) do
    case Map.get(statuses, id) do
      status when status in ["queued", "sending"] -> "queued"
      status when status in ["accepted", "failed", "refused"] -> status
      _ -> "not sent yet"
    end
  end

  defp email_state(%Install{status: "ready"}, _statuses, false), do: "not configured"
  defp email_state(_install, _statuses, _configured?), do: "not sent yet"

  @doc """
  Whether the requester hand-over email can be sent: mail is enabled and
  `mail_sender` (`BURROW_INSTALLS_MAIL_*`) names an org, account and sender.
  """
  @spec mail_sender_configured?() :: boolean()
  def mail_sender_configured? do
    sender = config(:mail_sender, %{}) || %{}

    Platform.Mail.Config.enabled?() and
      Enum.all?([:org_id, :account_id, :sender_key], fn key ->
        case Map.get(sender, key) do
          value when is_binary(value) -> String.trim(value) != ""
          _ -> false
        end
      end)
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
  def describe_error("install", :timeout),
    do: "Your server didn't finish installing in time. Retry restarts it and tries again."

  def describe_error(_step, :timeout), do: "This step took longer than expected."

  def describe_error(_step, :memory_unavailable),
    do:
      "Memory and search didn't start on this server; the embeddings service kept restarting. " <>
        "Nothing was charged beyond the server; you can retry or tear it down."

  # Stage 6: DigitalOcean answers 422 when the size is not offered in the region.
  def describe_error("reserve", {:http, 422}),
    do: "That server size isn't available in this region right now. Pick another region."

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
