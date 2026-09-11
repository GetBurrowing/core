defmodule PlatformWeb.HealthController do
  use PlatformWeb, :controller

  # Status stays 200 so status-only probes (the production quadlet's
  # `wget --spider`, `curl -fsS`, the router wiring test) are unaffected; the
  # body carries the build commit so an operator can read what is deployed
  # without dumping the container environment (task 01a089d5).
  def index(conn, _params) do
    json(conn, %{status: "ok", commit: Platform.BuildInfo.commit()})
  end
end
