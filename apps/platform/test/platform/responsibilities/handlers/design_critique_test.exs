defmodule Platform.Responsibilities.Handlers.DesignCritiqueTest do
  @moduledoc """
  Guards for `design.critique` (task `019fe844` stage 1).

  ## Verification label: DETECTORS, not guards

  Every assertion here was run against the pre-change stub and observed
  to fail. That matters more than usual for this file, because the
  obvious test — "`design.critique` gathers context without erroring" —
  PASSES AGAINST THE STUB: the stub returned
  `{:ok, %{canvas_snapshot: %{missing?: true}, ...}}`, which is a
  successful gather of nothing. Anything asserting only `:ok` here would
  be vacuous by construction.

  What each test detonates on against the stub:

    * canvas snapshot — stub returned a `%{missing?: true}` MAP where a
      rendered binary belongs, so both the `is_binary` assertion and the
      substring match fail.
    * refusal — stub returned `{:ok, _}` for every input, including one
      naming no canvas at all, so the `{:error, :no_canvas_resolved}`
      match fails.
    * prompt — stub exported no `build_prompt/1` at all
      (`UndefinedFunctionError`), which is exactly why the Router fell
      through to the DB template row that also says "Vega".
    * trigger — stub's regex was `(?i)@vega\\s+(critique|review)\\b`, so
      the `@designer` match fails. Both the `@vega` AND the `@saru`
      refutations are kept: together they prove the trigger stopped
      naming a person at all, rather than swapping one name for another.
    * shim round-trip — the positive control on the feature-level
      indirection. It fails against the stub for the same reason the
      direct call does, and it is here so a handler that is correct but
      unreachable through `Providers.Design` cannot pass this file.
  """
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Responsibilities.Handlers.DesignCritique
  alias Platform.Responsibilities.Providers
  alias Platform.Responsibilities.Responsibility

  # Inserted into the canvas document fixture and asserted on the way out
  # the far side. A string no template, prompt or module body contains,
  # so a match proves the FIXTURE reached the prompt rather than proving
  # that some canned text did.
  @probe "contrast ratio 2.1:1"

  describe "gather_context/2" do
    test "renders the resolved canvas into a binary snapshot carrying the canvas's own text" do
      %{canvas: canvas} = canvas_fixture()

      assert {:ok, context} =
               DesignCritique.gather_context(responsibility(), %{canvas_id: canvas.id})

      assert is_binary(context.canvas_snapshot)
      assert context.canvas_snapshot =~ @probe
      assert context.canvas_snapshot =~ canvas.id

      # The stub's shape, explicitly refuted: no slot anywhere in the
      # returned context may still be a "not wired yet" marker map.
      refute_missing_markers(context)
    end

    test "resolves a canvas id captured by the chat trigger out of :match" do
      %{canvas: canvas, space: space} = canvas_fixture()

      ctx = %{
        kind: :chat_pattern,
        space_id: space.id,
        match: ["@designer critique #{canvas.id}", "critique", canvas.id]
      }

      assert {:ok, context} = DesignCritique.gather_context(responsibility(), ctx)
      assert context.canvas_id == canvas.id
      assert context.canvas_snapshot =~ @probe
    end

    test "falls back to the most recently updated canvas in the space" do
      %{space: space, participant: participant, canvas: older} = canvas_fixture()

      {:ok, newer} =
        Chat.create_canvas(%{
          space_id: space.id,
          created_by: participant.id,
          title: "Newer canvas",
          document: document_with("newest surface under review")
        })

      assert {:ok, context} =
               DesignCritique.gather_context(responsibility(), %{space_id: space.id})

      assert context.canvas_id == newer.id
      assert context.canvas_snapshot =~ "newest surface under review"
      refute context.canvas_snapshot =~ older.id
    end

    test "refuses when no canvas resolves from any of the three sources" do
      assert {:error, :no_canvas_resolved} =
               DesignCritique.gather_context(responsibility(), %{note: "please review"})
    end

    test "refuses when the space it was given holds no canvas at all" do
      space = space_fixture()

      assert {:error, :no_canvas_resolved} =
               DesignCritique.gather_context(responsibility(), %{space_id: space.id})
    end

    test "names the dispatch space so a native assignee is invited into it" do
      %{canvas: canvas, space: space} = canvas_fixture()

      assert {:ok, context} =
               DesignCritique.gather_context(responsibility(), %{
                 canvas_id: canvas.id,
                 space_id: space.id
               })

      assert context.dispatch_space_id == space.id
    end

    test "an absent grounding note is not a refusal" do
      %{canvas: canvas} = canvas_fixture()

      assert {:ok, context} =
               DesignCritique.gather_context(responsibility(), %{canvas_id: canvas.id})

      assert context.grounding_notes == ""
    end

    test "carries the requester's note into grounding_notes" do
      %{canvas: canvas} = canvas_fixture()

      assert {:ok, context} =
               DesignCritique.gather_context(responsibility(), %{
                 canvas_id: canvas.id,
                 note: "the empty state is the part I am unsure about"
               })

      assert context.grounding_notes =~ "the empty state is the part I am unsure about"
    end
  end

  describe "build_prompt/1" do
    test "names Saru, never Vega, and restates the issues JSON contract" do
      %{canvas: canvas} = canvas_fixture()
      {:ok, context} = DesignCritique.gather_context(responsibility(), %{canvas_id: canvas.id})

      assert {:ok, %{system: system, user: user}} = DesignCritique.build_prompt(context)

      assert system =~ "Saru"
      refute system =~ "Vega"
      assert system =~ "issues"
      assert system =~ "severity"
      assert system =~ "suggestion"

      # The canvas fixture's own text reaches the model. Without this the
      # prompt assertions above would pass over an empty canvas.
      assert user =~ @probe
    end
  end

  describe "register/0" do
    test "the compiled trigger fires on the role token and on no agent handle" do
      regex = Regex.compile!(trigger_regex())

      assert Regex.match?(regex, "@designer critique this")
      assert Regex.match?(regex, "@Designer review the checkout screen")

      # BOTH refutations matter. `@vega` alone would only prove the stale
      # handle went away; `@saru` proves the trigger names no person at
      # all, which is the actual rule.
      refute Regex.match?(regex, "@vega critique this")
      refute Regex.match?(regex, "@vega review this")
      refute Regex.match?(regex, "@saru critique this")
      refute Regex.match?(regex, "@saru review this")
    end

    test "the registered regex contains no @ token other than the role key" do
      tokens =
        ~r/@([A-Za-z0-9_]+)/
        |> Regex.scan(trigger_regex())
        |> Enum.map(fn [_, token] -> String.downcase(token) end)

      assert tokens == ["designer"]
    end

    test "the trigger captures a trailing canvas id, bare or in a URL" do
      regex = Regex.compile!(trigger_regex())
      id = Ecto.UUID.generate()

      assert id in Regex.run(regex, "@designer critique #{id}")
      assert id in Regex.run(regex, "@designer critique /chat/canvas/#{id}")

      # The canvas-id group must remain the LAST group: `strip_canvas_id/1`
      # scans positional captures. `Regex.run/2` returns them in order, so
      # asserting the id is the final element pins that ordering.
      assert List.last(Regex.run(regex, "@designer critique #{id}")) == id
    end

    test "the verb group precedes the canvas-id group in the positional captures" do
      regex = Regex.compile!(trigger_regex())
      id = Ecto.UUID.generate()

      assert [_full, "critique", ^id] = Regex.run(regex, "@designer critique #{id}")
    end

    test "the row is not declared inert and no longer advertises itself as a placeholder" do
      [spec] = DesignCritique.register()

      refute spec.metadata["status"] == "placeholder"
      refute spec.metadata["dispatch"] == "inert"
    end
  end

  describe "Providers.Design shim" do
    test "the feature-level provider reaches the same non-stub context" do
      %{canvas: canvas} = canvas_fixture()
      resp = responsibility()

      assert {:ok, via_shim} = Providers.Design.gather_context(resp, %{canvas_id: canvas.id})
      assert {:ok, direct} = DesignCritique.gather_context(resp, %{canvas_id: canvas.id})

      assert via_shim.canvas_snapshot == direct.canvas_snapshot
      assert via_shim.canvas_snapshot =~ @probe
      refute_missing_markers(via_shim)
    end

    test "the shim exposes build_prompt for this key, which is what the Router probes" do
      %{canvas: canvas} = canvas_fixture()
      resp = responsibility()

      {:ok, context} = Providers.Design.gather_context(resp, %{canvas_id: canvas.id})

      assert {:ok, %{system: system}} =
               Providers.Design.build_prompt(Map.put(context, :__responsibility__, resp))

      assert system =~ "Saru"
    end
  end

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp responsibility do
    [spec] = DesignCritique.register()
    struct!(Responsibility, Map.put(spec, :id, Ecto.UUID.generate()))
  end

  defp trigger_regex do
    [spec] = DesignCritique.register()
    spec.trigger_config["regex"]
  end

  defp space_fixture do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "critique-#{n}",
        slug: "critique-#{n}",
        kind: "channel"
      })

    space
  end

  defp canvas_fixture do
    space = space_fixture()
    {:ok, participant} = ExecutionSpace.ensure_system_participant(space.id)

    {:ok, canvas} =
      Chat.create_canvas(%{
        space_id: space.id,
        created_by: participant.id,
        title: "Checkout screen",
        document: document_with(@probe)
      })

    %{space: space, participant: participant, canvas: canvas}
  end

  defp document_with(text) do
    %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "children" => [
          %{"id" => "note", "type" => "markdown", "props" => %{"content" => text}}
        ]
      }
    }
  end

  # `missing?` was the stub's tell. Asserted structurally rather than by
  # key so a slot that grew a nested marker map is caught too.
  defp refute_missing_markers(context) do
    Enum.each(context, fn {key, value} ->
      refute match?(%{missing?: _}, value), "slot #{inspect(key)} still carries a missing? marker"
    end)
  end
end
