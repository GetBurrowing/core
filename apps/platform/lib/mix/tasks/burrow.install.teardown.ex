defmodule Mix.Tasks.Burrow.Install.Teardown do
  @moduledoc """
  Tear down one install `Platform.Installs` provisioned (task 01a10315 stage 2):

      mix burrow.install.teardown <slug-or-id>

  Deletes its droplets by tag, its firewall and (for a subdomain of ours) its
  two A records, then confirms `GET /v2/droplets?tag_name=suite-install-<id>`
  is empty. A second run is a no-op that exits 0. Same as
  `bin/platform eval 'Platform.Installs.teardown("<slug>")'` in a release.

  Exits non-zero via `Mix.raise/1` naming the reason when anything is left.
  """
  use Mix.Task

  @shortdoc "Tear down a one-click install (droplets, firewall, DNS records)"

  @impl Mix.Task
  def run(args) do
    case args do
      [slug] ->
        Mix.Task.run("app.start")

        case Platform.Installs.teardown(slug) do
          :ok -> Mix.shell().info("torn down: #{slug} (no droplet left for its tag)")
          {:error, reason} -> Mix.raise(message(slug, reason))
        end

      _ ->
        Mix.raise("usage: mix burrow.install.teardown <slug-or-id>")
    end
  end

  @doc false
  def message(slug, :not_found), do: "no install #{inspect(slug)}"

  def message(slug, :droplets_remain),
    do: "teardown of #{slug}: droplets still listed for its tag; re-run to retry"

  def message(slug, reason),
    do: "teardown of #{slug} failed: #{Platform.Installs.reason_code(reason)}; re-run to retry"
end
