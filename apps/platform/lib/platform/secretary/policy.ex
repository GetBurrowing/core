defmodule Platform.Secretary.Policy do
  @moduledoc """
  The `secretary.policy` payload in force (task 01a1b721 stage 3), read
  through the experiment surface (`Platform.Experiments.Surfaces.SecretaryPolicy`).

    * `for_user/1` — the person's arm: an experiment variant, a promoted
      default, or the control. Never raises; any failure is the control.
    * `install/0` — the install-wide knobs (`max_in_flight`,
      `install_daily_token_ceiling`, `debounce_ms`): the install-wide promoted
      default or the control. These are not per person, so no person's arm
      may move them.
  """

  alias Platform.Experiments.{Subject, Surfaces}
  alias Platform.Experiments.Surfaces.SecretaryPolicy

  @type t :: %{payload: map(), variant_slug: String.t() | nil}

  @doc "The person's payload and the variant slug it came from (nil for none)."
  @spec for_user(Ecto.UUID.t()) :: t()
  def for_user(user_id) when is_binary(user_id) do
    subject =
      Subject.new(
        SecretaryPolicy.subject_type(),
        user_id,
        SecretaryPolicy.subject_attributes(user_id)
      )

    case Surfaces.resolve(SecretaryPolicy.key(), SecretaryPolicy.target(), subject,
           org_id: subject.attributes[:org_id]
         ) do
      {:variant, _experiment, slug, payload} -> %{payload: complete(payload), variant_slug: slug}
      {:default, payload} -> %{payload: complete(payload), variant_slug: nil}
      _ -> control()
    end
  rescue
    _ -> control()
  end

  @doc "The install-wide payload."
  @spec install() :: map()
  def install do
    case Surfaces.current_default(SecretaryPolicy.key(), SecretaryPolicy.target(), nil) do
      %{} = payload -> complete(payload)
      _ -> SecretaryPolicy.control()
    end
  rescue
    _ -> SecretaryPolicy.control()
  end

  defp control, do: %{payload: SecretaryPolicy.control(), variant_slug: nil}

  defp complete(payload) do
    case SecretaryPolicy.validate_payload(payload) do
      {:ok, valid} -> valid
      {:error, _} -> SecretaryPolicy.control()
    end
  end
end
