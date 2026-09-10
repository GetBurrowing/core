defmodule Platform.Org.Wiki.SearchLexicalQueryTest do
  @moduledoc """
  Pins the lexical-channel query construction in `Platform.Org.Wiki.Search`
  (task 01a08a27, stage 1).

  `search/2` funnels every lexical channel through
  `websearch_to_tsquery('english', ?)`, which ANDs every stem of the query
  together. A ticket-length question therefore only matches a row that
  contains *every* stem — which no real row does — so the channel returns
  `[]` and the caller cannot distinguish that manufactured false negative
  from a true absence.

  This file lands RED on purpose. Stage 2 replaces the whole-body
  conjunction with a capped OR-alternation and turns it green *because the
  lexical channel returns the row*, not because any scoring changed.

  The semantic provider is forced to `Noop` throughout. It is never
  asserted on in either direction: the real provider stalls in episodes,
  so an assertion in *either* direction is a flake whose failure rate
  depends on when CI runs. Everything asserted here is lexical.
  """

  use Platform.DataCase, async: false

  alias Platform.Org.Wiki.Search
  alias Platform.Repo
  alias Platform.Tasks

  setup do
    # Same stubbing the `task_create similar_tasks (stage 4, task 019f3dbb)`
    # describe block in tool_surface_test.exs installs.
    prev = Application.get_env(:platform, :memory_service, [])

    Application.put_env(:platform, :memory_service, provider: Platform.Memory.Providers.Noop)

    on_exit(fn -> Application.put_env(:platform, :memory_service, prev) end)
    :ok
  end

  defp parsed_tsquery(prepared) do
    %{rows: [[text]]} =
      Repo.query!("SELECT websearch_to_tsquery('english', $1)::text", [prepared])

    text
  end

  defp create_project do
    {:ok, project} =
      Tasks.create_project(%{name: "Lexical Query Project #{System.unique_integer([:positive])}"})

    project
  end

  describe "lexical task channel under a ticket-length query (task 01a08a27)" do
    test "a ticket-length query returns a task sharing its strong subject phrase (noop semantic provider)" do
      project = create_project()

      {:ok, seeded} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Meeting transcript segments attributed to the wrong speaker",
          description:
            "Speaker attribution on the meeting transcript assigns segments to the participant identity rather than the voice, so a shared account collapses two speakers into one."
        })

      # A real ticket-length body: >= 12 stems, sharing the strong subject
      # phrase ("meeting transcript speaker attribution") with the seeded
      # task but NOT containing every stem of it.
      long_query =
        "why does the meeting transcript speaker attribution keep collapsing two different people " <>
          "into a single participant when they dial in from the same shared account on a recorded call"

      {:ok, %{results: results}} =
        Search.search(long_query,
          source: "task",
          project_id: project.id,
          agent: nil,
          limit: 6
        )

      # RED on main. `websearch_to_tsquery` ANDs every stem above, so no
      # row can satisfy it, and `ilike_tasks_fallback/3` cannot rescue it
      # either — it wraps the whole normalized body in one `%...%` pattern,
      # which matches nothing. This failure is not reachable by any
      # scoring change; only rewriting the query fixes it. That is the
      # discrimination this test buys.
      assert Enum.any?(results, fn hit -> hit.id == seeded.id end),
             "expected the seeded task to be returned for a ticket-length query, got: " <>
               inspect(Enum.map(results, & &1.id))
    end

    test "the same subject asked in three stems does return the task (short-query control)" do
      project = create_project()

      {:ok, seeded} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Meeting transcript segments attributed to the wrong speaker",
          description:
            "Speaker attribution on the meeting transcript assigns segments to the participant identity rather than the voice, so a shared account collapses two speakers into one."
        })

      # The positive control that makes the test above evidence rather
      # than an unexplained empty: the SAME corpus, the SAME subject, but
      # few enough stems that the implicit AND still matches. If this one
      # ever goes red the corpus or the search_vector column is broken and
      # the red above says nothing about the conjunction.
      {:ok, %{results: results}} =
        Search.search("transcript speaker attribution",
          source: "task",
          project_id: project.id,
          agent: nil,
          limit: 6
        )

      assert Enum.any?(results, fn hit -> hit.id == seeded.id end)
    end
  end

  describe "prepare_lexical_query/1 operator guard (task 01a08a27, stage 2)" do
    # This asserts on the tsquery OPERATOR, not on a result set. A result-set
    # assertion can be satisfied by a corpus accident; only reading the parsed
    # query back out of Postgres makes a silent revert to conjunction fail
    # loudly. Verified against PostgreSQL 16.14, which is what the test
    # container runs.
    test "a long query parses to an alternation and contains no AND operator" do
      long_query =
        "why does the meeting transcript speaker attribution keep collapsing two different people " <>
          "into a single participant when they dial in from the same shared account on a recorded call"

      prepared = Search.prepare_lexical_query(long_query)
      parsed = parsed_tsquery(prepared)

      assert String.contains?(parsed, "|"),
             "expected alternation, got: #{parsed}"

      refute String.contains?(parsed, "&"),
             "the implicit conjunction has been reintroduced — the fix is inert. got: #{parsed}"
    end

    test "a query at or under the short-query floor is returned unchanged" do
      # Six distinct tokens: at the floor, so the conjunction is preserved
      # byte-for-byte. Asserting identity of the STRING, not of a result set,
      # is what makes "byte-identical to today" checkable.
      short = "transcript speaker attribution shared account voice"
      assert length(String.split(short)) == 6
      assert Search.prepare_lexical_query(short) == short
      assert String.contains?(parsed_tsquery(short), "&")
    end

    test "one token past the floor is rewritten to alternation" do
      seven = "transcript speaker attribution shared account voice segments"
      assert length(String.split(seven)) == 7
      prepared = Search.prepare_lexical_query(seven)
      assert prepared == Enum.join(String.split(seven), " or ")
      assert String.contains?(parsed_tsquery(prepared), "|")
      refute String.contains?(parsed_tsquery(prepared), "&")
    end

    test "a quoted-phrase query is passed through untouched even when long" do
      phrase =
        ~s(why does "meeting transcript speaker attribution" collapse two people into one participant account)

      assert Search.prepare_lexical_query(phrase) == String.trim(phrase)
      # The phrase-distance operator survives — a deliberate phrase search was
      # not rewritten into OR soup.
      assert String.contains?(parsed_tsquery(phrase), "<->")
    end

    test "a negated-token query is passed through untouched even when long" do
      negated =
        "meeting transcript speaker attribution collapsing participants into one account -fix -resolved"

      assert Search.prepare_lexical_query(negated) == negated
      assert String.contains?(parsed_tsquery(negated), "!")
    end

    test "a bare uppercase OR is treated as a deliberate operator and passed through" do
      explicit = "meeting transcript OR recorded call attribution shared account voice segments"
      assert Search.prepare_lexical_query(explicit) == explicit
    end

    test "tokens are downcased, deduped first-seen, and capped at 32" do
      # NB the short-query floor counts DEDUPED tokens, so this fixture needs
      # more than six DISTINCT ones to reach the alternation path at all — an
      # earlier version of this test used five distinct tokens and asserted the
      # rewrite, which the floor correctly refused.
      dupes = "Alpha alpha ALPHA beta Beta gamma delta epsilon zeta eta theta"

      assert Search.prepare_lexical_query(dupes) ==
               "alpha or beta or gamma or delta or epsilon or zeta or eta or theta"

      many = Enum.map_join(1..50, " ", &"tok#{&1}")
      prepared = Search.prepare_lexical_query(many)
      terms = String.split(prepared, " or ")
      assert length(terms) == 32
      assert List.first(terms) == "tok1"
      assert List.last(terms) == "tok32"
    end

    test "punctuation is a token separator, not part of a token" do
      punctuated = "meeting-transcript: speaker/attribution, shared (account) voice; segments"

      assert Search.prepare_lexical_query(punctuated) ==
               "meeting or transcript or speaker or attribution or shared or account or voice or segments"
    end

    test "an all-stopword long query degenerates to an empty tsquery, matching nothing" do
      # Documented edge case, not a regression: `the a of and` parses to an
      # empty tsquery under the CONJUNCTION too, so this behaviour is
      # unchanged by the rewrite. Recorded so a future reader does not read
      # the empty result as caused by the alternation.
      stopwords = "the and a of the or an and it is to be for"
      prepared = Search.prepare_lexical_query(stopwords)
      assert parsed_tsquery(prepared) == ""
      assert parsed_tsquery(stopwords) == ""
    end
  end

  describe "short-query results are unchanged by the rewrite (task 01a08a27, stage 2)" do
    test "a <= 6 token query returns the same result set it did before the change" do
      project = create_project()

      {:ok, seeded} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Meeting transcript segments attributed to the wrong speaker",
          description:
            "Speaker attribution on the meeting transcript assigns segments to the participant identity rather than the voice, so a shared account collapses two speakers into one."
        })

      {:ok, decoy} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Billing export drops the trailing invoice row",
          description: "The monthly billing export truncates its final row."
        })

      short = "transcript speaker attribution"

      {:ok, %{results: results}} =
        Search.search(short, source: "task", project_id: project.id, agent: nil, limit: 6)

      ids = Enum.map(results, & &1.id)

      # The short path goes down the untouched conjunction, so the decoy —
      # which shares no stem — must still be excluded. If the OR had leaked
      # into the short path this assertion is what fails.
      assert seeded.id in ids
      refute decoy.id in ids
    end
  end
end
