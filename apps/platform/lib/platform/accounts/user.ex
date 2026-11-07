defmodule Platform.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field(:email, :string)
    field(:name, :string)
    field(:oidc_sub, :string)
    field(:avatar_url, :string)
    field(:avatar_source, Ecto.Enum, values: [:oidc, :local, :generated])
    # JSONB blob for lightweight per-user UI prefs (chat plan v2 Stage 3).
    # Today: `chat_section_order` (list of sub-org slugs). See
    # `Platform.Accounts.update_user_preference/3`.
    field(:preferences, :map, default: %{})

    # Soft-archive columns (task 019f671f Stage 1). Presence of `archived_at`
    # means the user is archived; downstream reads filter via
    # `list_users(include_archived: false)` (default) and
    # `get_users_map(ids, include_archived: false)` (default). Historical
    # attribution paths opt in with `include_archived: true`. Mirrors the
    # `spaces.archived_at` precedent in `Platform.Chat.archive_space/2`.
    field(:archived_at, :utc_datetime_usec)
    field(:archived_by_user_id, :binary_id)
    field(:archived_reason, :string)

    # Latest expiry of any sign-in link `Platform.SignInAdmin` minted for this
    # user (task 01a114c1). Written only by
    # `Platform.Accounts.note_sign_in_link_expiry/2`; the link itself is never
    # stored.
    field(:sign_in_link_expires_at, :utc_datetime)

    # Vendor support user (task 01a1b362 stage 1, ADR 0059). One per support
    # operator email, created only by `Platform.SupportAccess`. Such a user is
    # treated as signed out unless its support session is active
    # (`Platform.SupportAccess.session_allows?/2`). Never cast from user
    # input: only `support_changeset/2` sets it.
    field(:support_vendor, :boolean, default: false)

    # MT/RBAC foundation (Plan 2 v3, task 019e3c4a). Users carry their
    # org memberships so authenticated request hot paths can preload
    # them on the same round-trip as the user fetch and avoid a
    # follow-up query in plugs / LV `on_mount` hooks.
    has_many(:org_memberships, Platform.Tenancy.OrgMembership)

    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [
      :email,
      :name,
      :oidc_sub,
      :avatar_url,
      :avatar_source,
      :preferences,
      :archived_at,
      :archived_by_user_id,
      :archived_reason,
      :sign_in_link_expires_at
    ])
    |> validate_required([:email, :name, :oidc_sub])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> unique_constraint(:email)
    |> unique_constraint(:oidc_sub)
  end

  @doc "Changeset for a vendor support user (`Platform.SupportAccess` only)."
  def support_changeset(user, attrs) do
    user
    |> changeset(attrs)
    |> put_change(:support_vendor, true)
  end
end
