defmodule Platform.Social.Analytics.PublicationOrgBudget do
  @moduledoc "Local publication-read allowance and rotation, not a provider quota or credential."
  use Ecto.Schema
  @primary_key {:org_id, :binary_id, autogenerate: false}
  schema "social_publication_org_budgets" do
    field(:next_attempt_at, :utc_datetime_usec)
    field(:last_account_id, :binary_id)
    field(:next_kind, :string, default: "discovery")
    field(:reservations, :map, default: %{})
  end
end
