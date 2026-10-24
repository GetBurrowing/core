defmodule Platform.Social.Profile do
  @moduledoc """
  A social profile: one brand or show an org posts as (task 01a140a8). It
  owns the platform accounts (`Platform.Social.Account`) and the clip
  candidates (`Platform.Social.Clip`); deleting it deletes both (FK
  `delete_all`).

  `org_id` is set by `Platform.Social`, never cast, so a profile cannot be
  moved between orgs through attrs. `approver_user_ids` names the humans who
  may approve its posts; `Platform.Social` checks every id is a user (never
  an agent) when it is written. Whether the approver of a given post is in
  this list is Social 3/7's rule, not this schema's.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "social_profiles" do
    belongs_to(:org, Platform.Tenancy.Org)
    belongs_to(:project, Platform.Tasks.Project)

    field(:name, :string)
    field(:home_url, :string)
    field(:voice_notes, :string)
    field(:default_hashtags, {:array, :string}, default: [])
    field(:approver_user_ids, {:array, :binary_id}, default: [])
    # Social 2/7: the vendor's profile or workspace id (not a secret).
    field(:provider_profile_ref, :string)
    # Social 5/7: caption and end-card values over `Platform.Social.Brand`'s
    # provisional placeholders.
    field(:brand, :map, default: %{})
    # Social 3/7: the channel approval cards are posted in (FK to chat_spaces,
    # nilified when the space is deleted). Must be a space in the profile's org.
    belongs_to(:space, Platform.Chat.Space)
    # Clip Studio 1/9: the show's default clip look (`Platform.Social.ClipLook`),
    # possibly partial. Not editable here: ClipJobs.save_show_default writes it.
    field(:show_look, :map, default: %{})
    # Social authoring 4/11: the brand's clock (IANA), structured voice, who
    # is notified (a subset of the approvers) and the drafting agent.
    field(:timezone, :string, default: "Etc/UTC")
    embeds_one(:voice, Platform.Social.Voice, on_replace: :update, defaults_to_struct: true)
    field(:notify_user_ids, {:array, :binary_id}, default: [])
    belongs_to(:drafting_agent, Platform.Agents.Agent)

    has_many(:accounts, Platform.Social.Account)
    has_many(:clips, Platform.Social.Clip)

    timestamps()
  end

  @editable ~w(project_id name home_url voice_notes default_hashtags approver_user_ids brand space_id
               timezone notify_user_ids drafting_agent_id)a

  @doc """
  Changeset for the editable fields. `org_id` is set by `Platform.Social`,
  never cast from attrs.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = profile, attrs) do
    profile
    |> cast(attrs, @editable)
    |> cast(attrs, [:provider_profile_ref])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_timezone()
    |> cast_embed(:voice, with: &Platform.Social.Voice.changeset/2)
    |> Platform.Social.Brand.validate(profile.org_id)
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:space_id)
    |> foreign_key_constraint(:drafting_agent_id)
    |> unique_constraint([:org_id, :name])
  end

  @doc "Whether `tz` names a zone in the time zone database."
  @spec valid_timezone?(term()) :: boolean()
  def valid_timezone?(tz) when is_binary(tz) and tz != "",
    do: match?({:ok, _}, DateTime.now(tz))

  def valid_timezone?(_tz), do: false

  defp validate_timezone(changeset) do
    validate_change(changeset, :timezone, fn :timezone, tz ->
      if valid_timezone?(tz), do: [], else: [timezone: "is not a known time zone"]
    end)
  end
end
