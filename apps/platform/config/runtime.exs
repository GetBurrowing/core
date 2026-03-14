import Config

if System.get_env("PHX_SERVER") do
  config :platform, PlatformWeb.Endpoint, server: true
end

if config_env() != :test do
  pool_size = String.to_integer(System.get_env("POOL_SIZE", "10"))

  socket_options =
    case System.get_env("ECTO_IPV6") do
      value when value in ["true", "1"] -> [:inet6]
      _ -> []
    end

  database_url =
    if config_env() == :prod do
      System.get_env("DATABASE_URL") ||
        raise "environment variable DATABASE_URL is missing"
    else
      System.get_env("DATABASE_URL")
    end

  if database_url do
    config :platform, Platform.Repo,
      url: database_url,
      pool_size: pool_size,
      socket_options: socket_options
  end

  app_url = System.get_env("APP_URL") || "http://localhost:4000"

  config :platform, :oidc,
    client_id: System.get_env("OIDC_CLIENT_ID"),
    client_secret: System.get_env("OIDC_CLIENT_SECRET"),
    issuer: System.get_env("OIDC_ISSUER"),
    app_url: app_url

  config :platform, PlatformWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))]
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :platform, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :platform, PlatformWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base
end
