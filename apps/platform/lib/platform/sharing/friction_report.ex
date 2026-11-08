defmodule Platform.Sharing.FrictionReport do
  @moduledoc """
  What happened to one friction occurrence at or past the threshold (task
  01a1b678 stage 3); see `Platform.Sharing.Friction`. `outcome` is `filed`
  (an issue was created), `deduped` (the shared feedback path answered with
  the existing issue), `rate_limited` (the per-install weekly cap) or
  `refused` (the feedback path refused; `detail` holds its bounded code).
  """

  use Ecto.Schema

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}

  @outcomes ~w(filed deduped rate_limited refused)

  @type t :: %__MODULE__{}

  schema "sharing_friction_reports" do
    field(:fingerprint, :string)
    field(:kind, :string)
    field(:outcome, :string)
    field(:detail, :string)
    field(:issue_url, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "The outcomes a row may carry."
  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes
end
