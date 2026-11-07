defmodule Platform.Ux.FindingTest do
  @moduledoc "Task 01a1af00 stage 1: `Platform.Ux.Finding`'s shape rules and table."

  use Platform.DataCase, async: true

  alias Platform.Repo
  alias Platform.Ux.Finding

  defp u, do: System.unique_integer([:positive])

  defp user! do
    Repo.insert!(%Platform.Accounts.User{
      email: "ux-finding-#{u()}@example.com",
      name: "Ux Finding User",
      oidc_sub: "ux-finding-#{u()}"
    })
  end

  defp citation, do: Finding.citation(Ecto.UUID.generate(), Ecto.UUID.generate())

  defp attrs(user, overrides \\ %{}) do
    Map.merge(
      %{
        recipient_user_id: user.id,
        question: "Should DMs get their own section on the phone?",
        kind: "decision",
        evidence: %{count: 4, quotes: ["where are my DMs"], citations: [citation()]},
        options: [
          %{label: "A DM section", recommended: true},
          %{label: "Search only", recommended: false}
        ],
        mockup_refs: %{before: "canvas:a", after: "canvas:b"},
        group_key: "dm-findability",
        variant: "control"
      },
      overrides
    )
  end

  defp errors(changeset, field) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(inspect(v)))
      end)
    end)
    |> Map.get(field, [])
  end

  test "a well-formed decision inserts, defaulting to open, with string keys" do
    user = user!()
    assert {:ok, finding} = %Finding{} |> Finding.changeset(attrs(user)) |> Repo.insert()

    finding = Repo.get!(Finding, finding.id)
    assert finding.status == "open"
    assert [%{"label" => "A DM section", "recommended" => true}, _] = finding.options
    assert finding.evidence["count"] == 4
    assert finding.mockup_refs == %{"before" => "canvas:a", "after" => "canvas:b"}
  end

  test "more than three options is refused" do
    opts = for i <- 1..4, do: %{label: "o#{i}", recommended: i == 1}
    cs = Finding.changeset(%Finding{}, attrs(user!(), %{options: opts}))
    assert "at most 3 options" in errors(cs, :options)
  end

  test "zero or two recommended options is refused" do
    user = user!()
    none = [%{label: "a", recommended: false}, %{label: "b"}]
    two = [%{label: "a", recommended: true}, %{label: "b", recommended: true}]

    for opts <- [none, two] do
      cs = Finding.changeset(%Finding{}, attrs(user, %{options: opts}))
      assert "exactly one option must be recommended" in errors(cs, :options)
    end
  end

  test "a decision needs an option; an fyi may carry none" do
    user = user!()
    cs = Finding.changeset(%Finding{}, attrs(user, %{options: []}))
    assert "a decision needs at least one option" in errors(cs, :options)

    cs = Finding.changeset(%Finding{}, attrs(user, %{options: [], kind: "fyi"}))
    assert cs.valid?
  end

  test "the question must end in a question mark" do
    cs = Finding.changeset(%Finding{}, attrs(user!(), %{question: "DMs are hard to find."}))
    assert ["must be a question ending in \"?\""] = errors(cs, :question)
  end

  test "evidence: positive count, at most two quotes, chat citations only" do
    user = user!()

    cs = Finding.changeset(%Finding{}, attrs(user, %{evidence: %{count: 0}}))
    assert "count must be a positive integer" in errors(cs, :evidence)

    cs =
      Finding.changeset(
        %Finding{},
        attrs(user, %{evidence: %{count: 3, quotes: ["a", "b", "c"]}})
      )

    assert "at most 2 quotes" in errors(cs, :evidence)

    cs =
      Finding.changeset(
        %Finding{},
        attrs(user, %{evidence: %{count: 1, citations: ["msg:#{Ecto.UUID.generate()}"]}})
      )

    assert "citations must be chat:<space_id>:<message_id>" in errors(cs, :evidence)
  end

  test "kind, status and mockup keys are closed" do
    user = user!()
    assert errors(Finding.changeset(%Finding{}, attrs(user, %{kind: "nag"})), :kind) != []
    assert errors(Finding.changeset(%Finding{}, attrs(user, %{status: "snoozed"})), :status) != []

    cs = Finding.changeset(%Finding{}, attrs(user, %{mockup_refs: %{during: "x"}}))
    assert "only before and after are allowed" in errors(cs, :mockup_refs)
  end

  test "answering needs an answer; dismissing does not" do
    {:ok, finding} = %Finding{} |> Finding.changeset(attrs(user!())) |> Repo.insert()

    refute Finding.resolve_changeset(finding, "answered").valid?

    assert {:ok, %{status: "answered"}} =
             finding |> Finding.resolve_changeset("answered", "A DM section") |> Repo.update()

    {:ok, other} = %Finding{} |> Finding.changeset(attrs(user!())) |> Repo.insert()

    assert {:ok, %{status: "dismissed"}} =
             other |> Finding.resolve_changeset("dismissed") |> Repo.update()
  end

  test "one OPEN finding per recipient and group; a resolved one frees the group" do
    user = user!()
    {:ok, first} = %Finding{} |> Finding.changeset(attrs(user)) |> Repo.insert()

    assert {:error, cs} = %Finding{} |> Finding.changeset(attrs(user)) |> Repo.insert()
    assert "already has an open finding for this group" in errors(cs, :recipient_user_id)

    {:ok, _} = first |> Finding.resolve_changeset("dismissed") |> Repo.update()
    assert {:ok, _} = %Finding{} |> Finding.changeset(attrs(user)) |> Repo.insert()
  end
end
