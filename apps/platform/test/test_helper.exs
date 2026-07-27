# The exclusion list is DERIVED from `Platform.TestQuarantine`, never written
# here. That module records why each quarantined test is untrustworthy and
# refuses to hide anything whose cause is deterministic or unknown — see its
# moduledoc for the incident (task 019fa06a) that made the distinction load-bearing.
ExUnit.start(exclude: Platform.TestQuarantine.excluded_tags())

if Process.whereis(Platform.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, :manual)
end
