defmodule Platform.Agents.Archetypes do
  @moduledoc """
  The character builder's data (task 01a1b6ad stage 1): the six classes, the
  four personality dials, the fourteen traits, the eight portraits, the ten
  toolkit entries and the five voices with their fine-tune knobs.

  Ported verbatim from the sponsor's comp (`studio()` in burrow-data.js and the
  voice block in burrow-agents.js) except for one copy rule: the comp names
  real people, a client channel and a host, and none of those may live in a
  tracked file, so each is generic copy here (a Strategist name, the
  Producer's first line, and the sample replies in `samples/0`). The viewer's
  own display name is passed in at runtime wherever the comp greeted one.
  `test/fixtures/character/comp.json` is the comp's output with that same
  substitution, and `Platform.Agents.ArchetypesTest` holds this module to it.

  `template` is the `Platform.Agents.RoleTemplates` id a class seeds its tool
  profile and model from; Wildcard has none (the comp's "Create Custom":
  profile `minimal`, nothing allowed). `template_label` is the comp's label.

  Nothing here is experimentable: an install creates a handful of agents in
  its lifetime, so no default could reach a measurable sample.
  """

  @toolkit [
    %{id: "read", ic: "💬", t: "Read & reply"},
    %{id: "tasks", ic: "☑", t: "Tasks"},
    %{id: "canvases", ic: "🧩", t: "Canvases"},
    %{id: "meetings", ic: "🎥", t: "Meetings"},
    %{id: "email", ic: "✉️", t: "Email drafts"},
    %{id: "prs", ic: "⑂", t: "Open PRs"},
    %{id: "deploy", ic: "🚀", t: "Ship to main"},
    %{id: "web", ic: "🔎", t: "Web search"},
    %{id: "memory", ic: "🧠", t: "Org memory"},
    %{id: "files", ic: "🗂️", t: "Files"}
  ]

  @archetypes [
    %{
      id: "builder",
      n: "Builder",
      glyph: "🛠️",
      vibe: "Ships it. Turns a plan into a merged PR.",
      template: "architect",
      template_label: "Architect",
      color: "orange",
      portrait: "visor",
      toolkit: ["read", "tasks", "prs", "deploy", "files"],
      names: ["Forge", "Rivet", "Anvil", "Tensor", "Brick", "Sprocket", "Torque", "Weld"],
      sl: %{"chatty" => 28, "bold" => 72, "playful" => 38, "collab" => 46},
      traits: ["ships fast", "tests first", "owns the fix"],
      line: "Point me at the branch. I'll have a PR up before your coffee cools."
    },
    %{
      id: "scout",
      n: "Scout",
      glyph: "🔭",
      vibe: "Finds things out before you think to ask.",
      template: "researcher",
      template_label: "Researcher",
      color: "teal",
      portrait: "owl",
      toolkit: ["read", "web", "memory", "canvases"],
      names: ["Wren", "Kestrel", "Vesper", "Juno", "Atlas", "Pathfinder", "Lark", "Scope"],
      sl: %{"chatty" => 55, "bold" => 40, "playful" => 45, "collab" => 62},
      traits: ["cites sources", "asks first", "early riser"],
      line: "I went digging. Three things you'll want, one you won't like."
    },
    %{
      id: "scribe",
      n: "Scribe",
      glyph: "🪶",
      vibe: "Writes it down so nobody has to remember.",
      template: "writer",
      template_label: "Writer",
      color: "purple",
      portrait: "quill",
      toolkit: ["read", "canvases", "meetings", "memory"],
      names: ["Quill", "Folio", "Margo", "Inkwell", "Ledger", "Verse", "Script", "Pagey"],
      sl: %{"chatty" => 62, "bold" => 30, "playful" => 50, "collab" => 70},
      traits: ["tidy", "cites sources", "over-explains"],
      line: "Got it all. Summary's in the canvas, decisions are pinned."
    },
    %{
      id: "strategist",
      n: "Strategist",
      glyph: "🧭",
      vibe: "Sees three moves ahead. Asks the annoying question.",
      template: "analyst",
      template_label: "Analyst",
      color: "green",
      portrait: "orbit",
      toolkit: ["read", "tasks", "memory", "meetings"],
      names: ["Orion", "Bishop", "Sable", "Cassius", "Vector", "Marshal", "Regent", "Gambit"],
      sl: %{"chatty" => 40, "bold" => 64, "playful" => 30, "collab" => 58},
      traits: ["devil's advocate", "dry wit", "asks first"],
      line: "Before we build it: what would make this the wrong call?"
    },
    %{
      id: "producer",
      n: "Producer",
      glyph: "🎬",
      vibe: "Keeps the show moving. Chases, schedules, unblocks.",
      template: "pm",
      template_label: "Project Manager",
      color: "amber",
      portrait: "spark",
      toolkit: ["read", "tasks", "meetings", "email"],
      names: ["Cue", "Tempo", "Roadie", "Marquee", "Booker", "Reel", "Callsheet", "Stagehand"],
      sl: %{"chatty" => 66, "bold" => 58, "playful" => 62, "collab" => 80},
      traits: ["optimist", "early riser", "ships fast"],
      line: "Standup's at 10, two things are blocked, I already pinged the owners."
    },
    %{
      id: "wildcard",
      n: "Wildcard",
      glyph: "🃏",
      vibe: "No class. Learns your shape as it goes.",
      template: nil,
      template_label: "Create Custom",
      color: "rose",
      portrait: "ghost",
      toolkit: ["read", "canvases"],
      names: ["Jinx", "Moxie", "Nova", "Riff", "Zig", "Echo", "Mischief", "Pip"],
      sl: %{"chatty" => 58, "bold" => 66, "playful" => 84, "collab" => 52},
      traits: ["dry wit", "night owl", "optimist"],
      line: "New here. Tell me one thing you hate and I'll never do it."
    }
  ]

  @sliders [
    %{k: "chatty", lo: "Terse", hi: "Chatty"},
    %{k: "bold", lo: "Careful", hi: "Bold"},
    %{k: "playful", lo: "Formal", hi: "Playful"},
    %{k: "collab", lo: "Solo", hi: "Collaborative"}
  ]

  @traits [
    "dry wit",
    "asks first",
    "cites sources",
    "ships fast",
    "tests first",
    "tidy",
    "optimist",
    "skeptic",
    "devil's advocate",
    "early riser",
    "night owl",
    "emoji-free",
    "over-explains",
    "owns the fix"
  ]

  @portraits ["orbit", "visor", "owl", "quill", "spark", "ghost", "fox", "cube"]

  @voices [
    %{
      key: "texting",
      n: "Texting",
      s: "Texting",
      ic: "💬",
      blurb: "lowercase, a line or two, emoji ok",
      rule: "Write like a text message: lowercase, no headings, no lists, no preamble."
    },
    %{
      key: "casual",
      n: "Casual",
      s: "Casual",
      ic: "☕",
      blurb: "short, friendly, plain words",
      rule: "Write in short, friendly, plain sentences. No headings."
    },
    %{
      key: "balanced",
      n: "Balanced",
      s: "Balanced",
      ic: "⚖️",
      blurb: "clear full sentences, answer first",
      rule:
        "Write in clear, complete sentences. Lead with the answer; use a short list only when it helps."
    },
    %{
      key: "professional",
      n: "Professional",
      s: "Professional",
      ic: "💼",
      blurb: "polished, courteous, complete",
      rule:
        "Write in complete, polished sentences with a courteous, neutral tone. Lead with the answer, then the supporting detail."
    },
    %{
      key: "exhaustive",
      n: "Exhaustive & formal",
      s: "Exhaustive",
      ic: "📚",
      blurb: "thorough, structured, nothing left out",
      rule:
        "Write formally and thoroughly in complete sentences. Structure longer answers as numbered lists and cover context, options and risks."
    }
  ]

  @knobs [
    %{k: "len", label: "Length", options: ["Short", "Medium", "Long"]},
    %{k: "emoji", label: "Emoji", options: ["None", "Some"]},
    %{k: "why", label: "Explains why", options: ["Never", "When useful", "Always"]},
    %{k: "greet", label: "Hello & sign-off", options: ["Off", "On"]}
  ]

  @vdef [
    %{"len" => 0, "emoji" => 1, "why" => 0, "greet" => 0},
    %{"len" => 0, "emoji" => 1, "why" => 1, "greet" => 0},
    %{"len" => 1, "emoji" => 0, "why" => 1, "greet" => 0},
    %{"len" => 1, "emoji" => 0, "why" => 1, "greet" => 1},
    %{"len" => 2, "emoji" => 0, "why" => 2, "greet" => 1}
  ]

  @class_voice %{
    "builder" => 1,
    "scout" => 2,
    "scribe" => 3,
    "strategist" => 2,
    "producer" => 2,
    "wildcard" => 1
  }

  @len_rule [
    "Keep replies to 1–3 lines.",
    "Keep replies to a short paragraph, 3–6 lines.",
    "Long, complete answers are fine when the question warrants it."
  ]

  @why_rule [
    "Don't explain your reasoning unless asked.",
    "Explain your reasoning only when it changes the decision.",
    "Always end with a one-line reason for your answer."
  ]

  @samples [
    %{
      id: "meeting",
      q: "Summarise today's meeting",
      em: "📝",
      useful: false,
      r: [
        [
          "standup was quick. #207 is ready, step D is next, the lead's out fri",
          "nothing for you yet"
        ],
        [
          "Quick one today. PR #207 is ready to merge, step D of the advice ladder is next, and the lead's out Friday.",
          "Nothing needs you right now."
        ],
        [
          "Today's standup covered three things:",
          "• PR #207 is ready to merge.",
          "• Step D of the advice ladder starts next.",
          "• The lead is out Friday, so reviews go to a teammate.",
          "Nothing needs your input yet."
        ],
        [
          "Here's a summary of today's standup.",
          "Decisions: PR #207 is approved to merge, and step D of the advice ladder begins this afternoon.",
          "Changes: the lead is out on Friday, so a teammate will cover reviews.",
          "Action for you: none at this stage. I'll flag anything that needs a decision."
        ],
        [
          "Summary of today's standup (14 minutes, four attendees).",
          "1. Decisions — PR #207 (meeting transcript fixes) was approved for merge; it has passing tests and no migration.",
          "2. Next work — Step D of the advice ladder begins this afternoon under my ownership, with a draft expected tomorrow.",
          "3. Availability — the lead is out on Friday; a teammate will cover code review in their absence.",
          "4. Open questions — None were raised that require your input."
        ]
      ],
      why: [
        "why: only flagging what changes your day",
        "I have included only the items that affect your plans; routine updates are in the meeting canvas."
      ],
      more: [
        "full notes are in the canvas if you want them",
        "The full transcript and action items are available in the meeting canvas."
      ]
    },
    %{
      id: "pr",
      q: "Is PR #207 ready?",
      em: "✅",
      useful: true,
      r: [
        [
          "yep, green + approved. want me to merge?"
        ],
        [
          "Yep — tests are green and the reviewer approved it. Want me to merge?"
        ],
        [
          "Yes, PR #207 is ready. Tests pass, the reviewer approved it, and there's no migration. I can merge it now if you'd like."
        ],
        [
          "Yes, PR #207 is ready to merge.",
          "All checks are passing, the reviewer has approved it, and it touches two files with no database migration.",
          "Shall I merge it now, or would you prefer to hold it until after the demo?"
        ],
        [
          "Yes. PR #207 meets every criterion for merging:",
          "• CI — all 1,412 tests pass, including the two new transcript tests.",
          "• Review — approved by the reviewer this morning, with no outstanding comments.",
          "• Scope — two files changed (+86 / −14); no database migration and no configuration changes.",
          "• Risk — low; the change is confined to the meeting transcript path.",
          "Would you like me to merge it now?"
        ]
      ],
      why: [
        "why: it's small, tested, one code path",
        "Reasoning: the change is small, fully tested and isolated to a single code path, so the risk is low."
      ],
      more: [
        "merging ships it — the host re-pulls :latest hourly",
        "Merging publishes :latest, and the host re-pulls hourly, so it will be live within the hour."
      ]
    },
    %{
      id: "linkedin",
      q: "Draft a LinkedIn post about the show",
      em: "🎬",
      useful: true,
      r: [
        [
          "\"we run the show's whole back office with ai agents now. they join calls, write the notes, ship the code. more soon\"",
          "want a longer one?"
        ],
        [
          "Here's a draft:",
          "\"Our show now runs with a little team of AI agents. They sit in on meetings, take the notes and ship code with us. Wild few months. More soon!\""
        ],
        [
          "Here's a draft:",
          "\"Behind every episode of the show is a small team — and, lately, a few AI agents. They join our calls, keep the notes and help ship the tools we use every day. Proud of what we've built. More soon.\"",
          "Happy to make it punchier or longer."
        ],
        [
          "Here is a draft for your review:",
          "\"Over the past few months, our production team has been working alongside AI agents that attend meetings, document decisions and help build our internal tools. It has changed how we work, and I'm proud of the team that made it happen. More to share soon.\"",
          "I can adjust the tone or add a link to the latest episode."
        ],
        [
          "Below is a draft, followed by notes on the choices made.",
          "\"Over the past few months, the team behind our show has quietly changed how it works. AI agents now attend our production meetings, record decisions, draft documents and help ship the tools we rely on each day. They have not replaced anyone; they have given people back the hours that used to go to note-taking and follow-ups. I am proud of the team that built this, and grateful to everyone who tried it with us. More to share soon.\"",
          "Notes: roughly 90 words, which suits LinkedIn's preview length; no hashtags, consistent with your previous posts; the closing line leaves room to announce the next episode.",
          "Shall I prepare a shorter alternative for comparison?"
        ]
      ],
      why: [
        "why: leading with the people, not the tech, gets more reach",
        "Rationale: posts that lead with the people involved tend to outperform feature announcements."
      ],
      more: [
        "i can do a longer one with the backstory too",
        "I can also prepare a longer version that covers how the project started."
      ]
    },
    %{
      id: "working",
      q: "What are you working on?",
      em: "🛠️",
      useful: false,
      r: [
        [
          "step D of the advice ladder. draft by tmrw"
        ],
        [
          "Step D of the advice ladder in #product. Should have a draft by tomorrow."
        ],
        [
          "Right now I'm on step D of the advice ladder in #product. The draft should be ready tomorrow; after that I'll pick up the grading cells."
        ],
        [
          "I'm currently working on step D of the advice ladder in #product.",
          "The draft is on track for tomorrow, after which I'll move on to the grading cells. Nothing is blocked at the moment."
        ],
        [
          "Here is my current workload, in priority order:",
          "1. Step D of the advice ladder (#product) — in progress; draft expected tomorrow.",
          "2. Grading cells for the advice pipeline — queued; begins once step D has been reviewed.",
          "3. Weekly memory tidy — scheduled for Friday.",
          "There are no blockers at present, and I will let you know promptly if that changes."
        ]
      ],
      why: [
        "why: it's what's blocking the client's review",
        "It is prioritised because it is currently blocking the client's review."
      ],
      more: [
        "then grading cells, then the memory tidy fri",
        "After that I will move on to the grading cells, followed by the weekly memory tidy on Friday."
      ]
    }
  ]

  @steps [
    {"class", "Pick a class"},
    {"name", "Name it"},
    {"color", "Its colour"},
    {"portrait", "Its face"},
    {"personality", "Its personality"},
    {"voice", "How it talks"},
    {"ai", "AI"},
    {"reveal", "Meet your agent"}
  ]

  @default_voice 2

  @doc "The six classes, in picker order."
  def all, do: @archetypes

  @doc "Every class id."
  def ids, do: Enum.map(@archetypes, & &1.id)

  @doc "The class with `id`, or nil."
  def get(id), do: Enum.find(@archetypes, &(&1.id == id))

  @doc "The class with `id`, falling back to the first (Builder) like the comp's `arch/1`."
  def fetch(id), do: get(id) || hd(@archetypes)

  @doc "The ten toolkit entries."
  def toolkit, do: @toolkit

  @doc "The toolkit entry with `id`, or nil."
  def tool(id), do: Enum.find(@toolkit, &(&1.id == id))

  @doc "Every toolkit id, in toolkit order."
  def toolkit_ids, do: Enum.map(@toolkit, & &1.id)

  @doc "The four personality dials: key, low label, high label."
  def sliders, do: @sliders

  @doc "The fourteen traits."
  def traits, do: @traits

  @doc "The eight portrait ids."
  def portraits, do: @portraits

  @doc "The five voice presets, from Texting (0) to Exhaustive (4)."
  def voices, do: @voices

  @doc "The preset at index `p`."
  def voice(p) when is_integer(p) and p >= 0 and p < length(@voices), do: Enum.at(@voices, p)

  @doc "The preset index for a voice key, or nil."
  def voice_index(key), do: Enum.find_index(@voices, &(&1.key == key))

  @doc "The four fine-tune knobs."
  def knobs, do: @knobs

  @doc "Each preset's knob defaults, indexed like `voices/0`."
  def vdef, do: @vdef

  @doc "The preset a class starts on; a class with none starts Balanced."
  def class_voice(id), do: Map.get(@class_voice, id, @default_voice)

  @doc "The class-to-preset map."
  def class_voices, do: @class_voice

  @doc "The length rule for each `len` knob value."
  def len_rules, do: @len_rule

  @doc "The explains-why rule for each `why` knob value."
  def why_rules, do: @why_rule

  @doc "The four Try-it prompts and each preset's reply to them."
  def samples, do: @samples

  @doc "The builder's eight steps: id and title."
  def steps, do: @steps
end
