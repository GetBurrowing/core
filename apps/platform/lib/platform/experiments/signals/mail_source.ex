defmodule Platform.Experiments.Signals.MailSource do
  @moduledoc """
  Turns inbound mail into experiment signals. Task 01a0d415 stage 3, the
  experimentation-layer ADR-0052.

  Mail does not call this module. `Platform.Mail.Inbound` publishes an
  ID-only `{:mail_inbound_ingested, %{id, account_id, org_id}}` event and
  `Platform.Experiments.Signals.MailSubscriber` calls `on_inbound/1` with the
  id; this module then READS the row itself. Nothing under
  `lib/platform/mail` references `Platform.Experiments`.

  ## Which experiments an inbound row feeds

  A non-draft experiment whose `signal_source` is
  `%{"kind" => "mail_inbound", "to_address" => addr}`, where `addr` appears
  (case-insensitively) in the row's `to_addresses`, and whose `org_id`
  COLUMN is null (install-wide) or equals the row's `org_id`. An org-A
  experiment is never fed by org-B mail.

  Matching a reply to a SUBJECT is done by the blind labeler reading the
  reply against the candidates (`Platform.Experiments.Labeler`). There are
  no sub-address tokens: Rowan declined them.

  ## Idempotence and the at-most-once gap

  Each (experiment, inbound row) pair is one signal: source_type
  `mail_inbound`, source_id the inbound id, recorded through
  `Platform.Experiments.Signals.record/1`, idempotent on the stage-1 unique
  index. A pair that already has a signal is skipped BEFORE the labeler is
  called, so a repeat costs no model call.

  PubSub delivery is at-most-once: a broadcast sent while the subscriber is
  down is lost. `reconcile/0` closes that gap by labelling every inbound row
  addressed to a matching experiment, ingested since the experiment was
  created, that has no signal row yet. Experiments carry no start timestamp,
  so `inserted_at` is the (wider) lower bound; a draft never matches, so the
  bound only matters for mail that arrived between creation and start.
  """

  import Ecto.Query

  require Logger

  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Labeler
  alias Platform.Experiments.Signal
  alias Platform.Experiments.Signals
  alias Platform.Mail.InboundMessage
  alias Platform.Repo

  @source_type "mail_inbound"
  @kind "mail_inbound"

  @doc "The `source_type` every mail signal carries."
  @spec source_type() :: String.t()
  def source_type, do: @source_type

  @doc """
  Label and record `inbound_id` for every matching experiment. Returns one
  result per matching experiment: `{:ok, signal}`, `{:skipped, :already_recorded}`
  or `{:error, reason}`. An unknown or malformed id returns `[]`.
  """
  @spec on_inbound(Ecto.UUID.t()) :: [
          {:ok, Signal.t()} | {:skipped, :already_recorded} | {:error, term()}
        ]
  def on_inbound(inbound_id) when is_binary(inbound_id) do
    if Platform.UUID.valid?(inbound_id) do
      case Repo.one(from(m in InboundMessage, where: m.id == ^inbound_id)) do
        nil ->
          []

        %InboundMessage{} = inbound ->
          inbound
          |> matching_experiments()
          |> Enum.map(&label_and_record(&1, inbound))
      end
    else
      []
    end
  end

  def on_inbound(_inbound_id), do: []

  @doc """
  Label every unsignalled inbound row for every matching experiment.
  Idempotent: running it twice records nothing the second time. Returns the
  number of signals written.
  """
  @spec reconcile() :: non_neg_integer()
  def reconcile do
    mail_experiments()
    |> Enum.flat_map(fn experiment ->
      experiment
      |> unsignalled_inbound()
      |> Enum.map(&label_and_record(experiment, &1))
    end)
    |> Enum.count(&match?({:ok, _}, &1))
  end

  # ── matching ─────────────────────────────────────────────────────────────

  defp matching_experiments(%InboundMessage{} = inbound) do
    addresses = Enum.map(inbound.to_addresses || [], &String.downcase/1)

    if addresses == [] do
      []
    else
      mail_experiments_query()
      |> where(
        [e],
        fragment(
          "lower(?->>'to_address') = ANY(?)",
          e.signal_source,
          type(^addresses, {:array, :string})
        )
      )
      |> where_org_matches(inbound.org_id)
      |> Repo.all()
    end
  end

  defp mail_experiments, do: Repo.all(mail_experiments_query())

  defp mail_experiments_query do
    from(e in Experiment,
      where: e.status != "draft" and fragment("?->>'kind'", e.signal_source) == ^@kind,
      order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  defp where_org_matches(query, nil), do: where(query, [e], is_nil(e.org_id))

  defp where_org_matches(query, org_id),
    do: where(query, [e], is_nil(e.org_id) or e.org_id == ^org_id)

  defp unsignalled_inbound(%Experiment{signal_source: source} = experiment) do
    case Map.get(source || %{}, "to_address") do
      addr when is_binary(addr) and addr != "" ->
        experiment_id = experiment.id

        signalled =
          from(s in Signal,
            where:
              s.experiment_id == ^experiment_id and s.source_type == ^@source_type and
                s.source_id == fragment("?::text", parent_as(:inbound).id)
          )

        from(m in InboundMessage,
          as: :inbound,
          where:
            fragment(
              "EXISTS (SELECT 1 FROM unnest(?) AS a WHERE lower(a) = lower(?))",
              m.to_addresses,
              ^addr
            ) and m.inserted_at >= ^experiment.inserted_at and not exists(signalled),
          order_by: [asc: m.inserted_at, asc: m.id]
        )
        |> inbound_org_matches(experiment.org_id)
        |> Repo.all()

      _ ->
        []
    end
  end

  # An install-wide experiment reads every org's mail; an org experiment
  # reads its own org's only.
  defp inbound_org_matches(query, nil), do: query
  defp inbound_org_matches(query, org_id), do: where(query, [m], m.org_id == ^org_id)

  # ── labelling ────────────────────────────────────────────────────────────

  defp label_and_record(%Experiment{} = experiment, %InboundMessage{} = inbound) do
    source_id = to_string(inbound.id)

    if recorded?(experiment, source_id) do
      {:skipped, :already_recorded}
    else
      case Labeler.label(experiment, inbound) do
        {:ok, verdict} ->
          verdict
          |> Map.merge(%{
            experiment_id: experiment.id,
            subject_type: Labeler.subject_type(),
            source_type: @source_type,
            source_id: source_id
          })
          |> Signals.record()

        {:error, reason} = error ->
          Logger.warning(
            "[Experiments.MailSource] labeler failed experiment=#{experiment.id} " <>
              "inbound=#{inbound.id} reason=#{inspect(reason)}"
          )

          error
      end
    end
  end

  defp recorded?(experiment, source_id) do
    Repo.exists?(
      from(s in Signal,
        where:
          s.experiment_id == ^experiment.id and s.source_type == ^@source_type and
            s.source_id == ^source_id
      )
    )
  end
end
