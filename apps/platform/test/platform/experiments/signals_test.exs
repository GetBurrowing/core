defmodule Platform.Experiments.SignalsTest do
  @moduledoc """
  Signal recording (task 01a0d415, the experimentation-layer ADR-0052): idempotent
  on the source, unmatched sources recorded, and no delete anywhere.
  """

  use Platform.DataCase, async: true

  alias Platform.Experiments
  alias Platform.Experiments.Signal
  alias Platform.Experiments.Signals

  defp unique, do: System.unique_integer([:positive])

  setup do
    {:ok, experiment} = Experiments.create_experiment(%{slug: "sig-#{unique()}", name: "Signals"})
    %{experiment: experiment}
  end

  defp attrs(experiment, overrides \\ %{}) do
    Map.merge(
      %{
        experiment_id: experiment.id,
        subject_type: "task",
        subject_id: Ecto.UUID.generate(),
        label: "positive",
        confidence: 0.9,
        status: "labelled",
        source_type: "mail.reply",
        source_id: "msg-#{unique()}",
        labeler: "blind-labeler"
      },
      overrides
    )
  end

  test "a duplicate source is a no-op that returns the original row", %{experiment: e} do
    first = attrs(e)

    assert {:ok, %Signal{id: id}} = Signals.record(first)

    assert {:ok, %Signal{id: ^id, label: "positive"}} =
             Signals.record(%{first | label: "negative"})

    assert [%Signal{id: ^id}] = Signals.list(e)
  end

  test "an unmatched source is recorded with a null subject, not dropped", %{experiment: e} do
    assert {:ok, %Signal{subject_id: nil, status: "unlabelled", label: nil}} =
             Signals.record(attrs(e, %{subject_id: nil, label: nil, status: "unlabelled"}))

    assert [%Signal{subject_id: nil}] = Signals.list(e, status: "unlabelled")
  end

  test "a labelled signal must carry a label; an unknown status is refused", %{experiment: e} do
    assert {:error, changeset} = Signals.record(attrs(e, %{label: nil}))
    assert changeset.errors[:label]

    assert {:error, changeset} = Signals.record(attrs(e, %{status: "maybe"}))
    assert changeset.errors[:status]
  end

  test "there is no delete function" do
    assert {:module, Signals} = Code.ensure_loaded(Signals)
    # Anti-vacuity: the module is loaded and exports what we expect.
    assert function_exported?(Signals, :record, 1)

    refute function_exported?(Signals, :delete, 1)
    refute function_exported?(Signals, :delete, 2)
    refute function_exported?(Signals, :delete_signal, 1)

    exported = Signals.__info__(:functions) |> Keyword.keys() |> Enum.map(&Atom.to_string/1)
    assert Enum.filter(exported, &String.contains?(&1, "delete")) == []
  end
end
