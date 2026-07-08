defmodule Platform.Security.Scanners.CveScan.OsvClientBehaviour do
  @moduledoc """
  Behaviour defining the CVE scanner's OSV.dev client contract
  (task `019f3e8e-4406` stage 3, ADR-0043).

  The scanner talks to OSV through this behaviour so tests can inject
  a mock module via `config :platform, :cve_scan_osv_client,
  <mock_module>`. See `Platform.Security.Scanners.CveScan.OsvClient`
  for the production implementation.

  Queries are a list of maps shaped like
  `%{package: %{name: name, ecosystem: ecosystem}, version: version}`.
  Ecosystem strings follow OSV's own vocabulary: `"Hex"`, `"npm"`,
  `"crates.io"`.
  """

  @callback query_batch(queries :: [map()]) :: {:ok, [map()]} | {:error, term()}
end
