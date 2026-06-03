# Agent Instructions

This file gives the AI agent persistent rules across sessions.

<!-- PMB-RULES-START (managed by `pmb connect`) -->
## PMB - memory tools (via MCP)

**PMB is OFF by default.** Ignore PMB and answer normally for general
questions. Engage PMB ONLY on the explicit triggers below.

### When to CALL pmb.recall(query)

Only if user asks about themselves / their past / their project:
- "когда я / что я / кто такой / почему мы выбрали / какой у меня"
- "what did I / when did I / who is <name> / why did we choose"

For general/technical questions ("что такое Next.js", "как работает X",
"explain Y", coding help, debugging) - DO NOT call recall. Answer directly.

### When to CALL pmb.recent_activity / what_just_happened

- "что я недавно спрашивал / что мы обсуждали" → `recent_activity(minutes=10080, kind="research")`
- "что мы только что делали / что я писал час назад" → `recent_activity(minutes=60)` or `what_just_happened(5)`
- "какие у меня открытые цели / что я планировал" → `list_goals(status="in_progress")`

### When to CALL pmb.record_batch(items=[…])

Only if the user EXPLICITLY does one of these:

1. Says "запомни / remember / это важно / сохрани":
   ```
   record_batch(items=[{"type":"fact_tree", "main":"...", "subfacts":[...],
                        "importance":0.95, "pin":true}])
   ```

2. Shares a personal fact ("я работаю над X", "у меня кошка Y", "вчера ...",
   "решил выбрать Z", "встречаюсь с ..."):
   ```
   record_batch(items=[{"type":"fact","content":"User works on X"},
                       {"type":"goal","title":"...","status":"in_progress"}])
   ```

3. You (the agent) make a meaningful design/code decision on user's behalf:
   ```
   record_batch(items=[{"type":"activity","kind":"decision",
                        "content":"Chose X over Y for project Z because..."}])
   ```

4. The user CORRECTS you, or you discover a reusable gotcha/technique that
   should change how you work in THIS project going forward - record a LESSON:
   ```
   record_batch(items=[{"type":"lesson",
                        "content":"This repo uses pnpm, never npm"}])
   ```
   Lessons are procedural ("how to work here"), not facts. Record them when
   the user says "no, do it this way", "we always/never ...", "stop doing X",
   or when a fix reveals a non-obvious project rule. They are stored at high
   importance and surface automatically on future recalls.

For general questions answered from your own knowledge - DO NOT save anything.
PMB is not a logbook of every interaction.

### When to RECALL lessons (apply them, don't repeat mistakes)

At the START of a non-trivial coding task in a known project, call
`recall("<task topic> conventions lessons")` once. If a lesson comes back
(e.g. "use pnpm, never npm"), FOLLOW it - that's the point of lessons. This is
the one case where recall is worth it for a coding task, not just a personal
question.

### Rules when you DO call PMB

- Exactly ONE `record_batch` per turn (collect all items in one call).
- NEVER call `recall` after writing to "verify".
- NEVER call `pin()` separately - use the `pin: true` field on items.
- Use ABSOLUTE dates ("On May 25, 2026") not "today".

### Style - never expose the plumbing

- Never say "в памяти / I found in memory / согласно записям / я записал"
- After recall, use results as your own knowledge, weave them naturally
- Don't narrate what tools you called

### NOT a constraint on your response

The save-content rules apply to MEMORY only. Your answer to the user can
be as long, detailed, code-rich as the question deserves.

PMB is local-only.

<!-- PMB-RULES-END -->
