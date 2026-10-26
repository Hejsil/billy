# Working on billy

**Update AGENTS.md with lessons learned.**

Rules earned from a full review of this codebase. Each one is here because the code got it wrong at
least once. Read the rule, not the story; the story is in the review.

## Untrusted text

- **A model, a file or a request is the source of every string you do not own.** Anything of theirs
  that reaches a page goes through `html.escape`. Anything of theirs that reaches a terminal header
  has its control characters removed.
  *A model-supplied tool name was written into `<span class="name">{s}</span>` unescaped, and into a
  terminal header raw. `web/script.js` inserts server HTML with `insertAdjacentHTML`, so a tool
  called `<img src=x onerror=…>` became live markup in a page that has no authentication and can run
  commands as the user.*
- **Escape at the point of writing, not at the point of reading.** `element`, `part`, `titled`,
  `pill` and the favicons take text and escape it; use them instead of `out.print("{s}", …)`. The
  one place that formats a field directly is the one place that was wrong.
- **An invariant stated in a module doc needs a test.** "Every string from outside passes through
  `escape`" was the first paragraph of `html.zig` and was false. A test that renders a hostile tool
  name would have kept it true.
- **A JSON field of theirs that may be null is optional in the shape it is read into.** A provider
  spells a field it has nothing for either by leaving it out or by writing `null`, and a `null` read
  as a slice or a struct is `UnexpectedToken`, not the empty value the default would have given.
  *One DeepSeek chunk wrote `"tool_calls":null`, so `llm.Chunk` refused the whole delta and the
  answer's text and thinking beside it were dropped with a warning; a `delta:null` frame did the
  same.*

## Failing

- **A tool never fails the turn.** A tool that cannot do its job writes `error: …` through
  `Tools.fail` and returns normally. `Tools.run` is the only place a tool's failure becomes a
  result, and both frontends branch on that prefix to colour it and to draw it as a failure.
  *`web_fetch`'s `raw` path used `try direct.fetch`, so a bad url ended the whole turn, left an
  unanswered tool call in the session, and told the user the request failed. `read` wrote its error
  without the prefix, so a missing file showed up as a successful, grey result.*
- **A hint that cannot be kept is not a failure of the work.** `Health`'s waits are advice about a
  backend, and whoever records one is holding the answer the advice is about — a search that has
  already found its results. A table that cannot be added to, or a file that cannot be written, is a
  warning in the log and the call carries on: returning the error throws the answer away to report
  the hint.
- **Report a failure once, at the layer that can say something useful.** A layer that cannot add
  anything returns the error and says nothing. The layer that can explain it prints, and returns
  `report.Reported`: `main` counts that as a failure and stays quiet, so the process still exits
  non-zero for whatever is scripted around it.
  *Nineteen sites logged an error and then returned it, and `main` printed it again — so a typo in a
  flag produced two error lines and a stack trace, which reads as a crash.*
- **A way out of a state is not gated on the state it is leaving.** A command that changes where a
  turn goes has to run before anything resolves where turns go. *`take` made the session's client
  before it read the line, so a session left on a provider that no longer resolved could not be
  moved off it with `/model` — the one command that existed to fix it.*
- **Nothing to try and everything tried are different answers.** An empty set is a configuration
  mistake; a set that was asked and refused is a failure. `Search` told a user with no backend at
  all that "every search backend is set aside after failing", so they were told to add another to a
  list they had never filled. Say which state it is.
- **Do not claim what you cannot know.** Gate the claim on what the layer that knows can tell you:
  `failureNotice` says "nothing was sent" only when the turn's emitter count did not move, and says
  the turn stopped partway when it had. *It said the first on every failure, including one that
  happened after half the reply had streamed.*
- **Believing which layer catches a failure is not the same as having run it.** An error left out of
  the `Reported` sweep because "the agent catches it and shows a notice" is reported twice, with a
  trace, the first time the path to it is not the one you pictured. *`Endpoint` logged and returned
  `MissingApiKey`; `ask` catches that and shows a notice — but `take` resolves a client before `ask`
  is reached, so the first prompt of a run with no key stored printed the message, the error's name
  and a stack trace, and ended the run. Ten lines of test would have walked it.*
- **A failure a turn can meet does not end the run.** Anything `take` or `ask` can fail with belongs
  in a notice, so the next line can be typed — `/model`, `/login` — and only a failure no turn can
  fix belongs in the run's return. The notice carries what the failing layer knows: which provider,
  and what to do about it.
- **A silent `catch` is a decision: write it down.** `catch return`, `catch continue` and
  `catch {}` are fine where a comment says why the failure is not worth reporting (`Health.read`,
  `dirHas`, the terminal's restore). They are not fine by default.

- **A request the user did not ask for is the one that most needs a deadline.** The run's own
  requests happen where the user is watching a spinner; a catalog fetch happens before anything is
  printed, on a path nobody chose, and a connection that is accepted and then stalls hangs the run
  with no output at all.

## Writing files

- **Anything that replaces a file billy owns is written atomically** — `createFileAtomic`, write,
  `replace` — and anything that replaces a file billy does *not* own is written that way too, only
  more so. *`edit` and `write` truncated the user's source files in place while config, credentials,
  sessions and health were all careful.* `Tools.writeFile` is the one to write through.
- **What is written is streamed onto the file's writer, not built in memory first.** Writing
  allocates nothing, and a large file costs no second copy. *The catalog stringified into an
  `Allocating` buffer to copy it into its atomic file, while `Config.save` beside it already wrote
  straight through.*
- **Replacing a file is not the same as writing it.** The new file is a new inode, which carries the
  permissions it was created with unless the old one's are read and given back — an edit must not
  take the bit off a script, nor open a file the user keeps to themselves — it replaces a symbolic
  link rather than writing through it, and it is the *directory* that has to be writable rather than
  the file. The first is done for you; the other two are what replacing costs.
- **A file a human may open is indented and versioned; a file only billy reads is compact and
  versioned.** When a version is bumped, the load path migrates the old shape; do not let a reader
  guess.
- **A catalog is fetched into the cache, not compiled in.** It changes without a release, so a
  snapshot in the binary is stale by the time it ships. Fetch it when a run first needs it, version
  the file, and give the user a command to fetch it again; a failed fetch leaves an empty catalog
  and a run that still works, not a start that fails. **And what the default configuration names has
  to resolve without the fetch**: a catalog that adds windows and other providers is a gain; one that
  gates the providers billy ships is a run that cannot send a request offline. *With the shipped
  provider table removed, a laptop with no network could not reach `deepseek/deepseek-flash` at all
  — and the error told the user to run the one command that needed the network.*
- **A document from a service is read into the shape billy keeps, and the cache holds only what is
  read back from it.** A typed parse skips what billy does not use as it reads, where a
  `std.json.Value` tree needs a helper and a `switch` per field; a field nothing reads is bytes
  parsed on every start for no reader. *The catalog walked models.dev through `stringField`,
  `intField`, `boolField` and `envOf`, and every model in the 632 KB cache carried `output`, `tools`
  and `reasoning` that nothing read; typed, and with only the window kept, it is 336 KB.*
- **A value the layer below can resolve itself is not carried down.** `Target.provider` was copied
  out of the catalog for a window lookup that asks the catalog by the choice instead, so the field
  was read by no one and its doc said it was what the gauge measured against. The same mistake runs
  the other way: a field added in case a frontend wants it, that only a test reads, is a promise to
  keep it fed — grep for the reader before adding it.
- **A lookup over stored things asks each only for the field that decides it.** `Session.latest`
  walks the listing in the order the question means (newest written first), asks each session file
  only for the directory it recorded by stepping over the conversation a token at a time, and stops
  at the first answer. *Loading every conversation to find the one started in this directory would
  cost the whole store to answer a question about one field of it; the title is read the same way,
  from the front of the file.* **Stepping over is not free, though: it reads the bytes.** A field a
  lookup asks for belongs in the first few fields, where a reader can stop, not last, where answering
  costs every conversation in the store. *`cwd` was written last, so `--resume` with nothing named
  read 14 MB of sessions to answer "was this one started here?"*
- **An index read back from a file is checked against what it indexes.** Drop one that names
  nothing rather than clamping it onto the nearest element, which invents a reference the writer
  never made; collapse a repeat too, since a list documented as one entry per thing is not one.
  *`loadCompactions` clamped an out-of-range index onto the last message, which then read as a
  compaction summary, and the next request carried exactly one message.*

## Ownership

- **A struct that owns memory is passed by pointer.** `Config` owns an `ArenaAllocator`; passing it
  by value is a shallow copy of the owner, and the first `deinit` on a copy is a double free.
- **A slice out of the string pool dies at the next `intern`.** Copy before you leave the function,
  take an index and resolve it where you use it, or read it again after the write. This rule is
  load-bearing in three places
  (`Endpoint.targetFor`, `Session.repairTail`, `Server.serveTurn`) and all three had to be fixed
  once.
- **`deinit` once, in the owner.** Between an `errdefer` in a loop and an `errdefer` outside it,
  check which one frees what: `Session.listIn` got this right, and that is the shape to copy.

## One source of truth

- **A name that means something is spelled once.** A tool's name is its `Call` tag: parsing walks
  `@typeInfo`, and the one tool table refers to the tags, so the schema and the heading cannot spell
  a tool differently. A union arm with no table row is a compile error.
  *`parseCallNamed` walked a hand-written tuple, so a new tool silently became `unknown` while
  `specs` offered it.*
- **A command is its arm, and how it takes an argument is the arm's type.** `Command.of` walks the
  union, so a command is typed as `/<tag>` and takes the rest of the line exactly when its payload
  says so, and `take`'s switch refuses to compile until a new arm is handled.
  *`of` compared the line against `/compact` and then cut a `/model` prefix by hand, so a third
  command would have been a third branch and a fourth another.*
- **A name from a service is matched as the service spells it, not normalized.** `find` compared a
  provider with `-` and `_` taken as equal, so a configured `opencode_go` reached the catalog's
  `opencode-go` and there were two spellings of one provider in the configuration, the credentials
  and the cache. The catalog already says how a provider is spelled; a name of the user's own is a
  provider billy does not know, and is reported as one.
- **A header every request carries is spelled once.** The user agent was `billy` to the catalog and
  `billy/1.0` to a provider. Both are `http.user_agent`.
- **A service is a row in the table, not a file of its own.** The five web providers repeated the same
  request, auth header, retry and reply walk, and the two tools kept separate provider enums and
  credential maps. One `web.Provider`, one descriptor table and one driver per tool leave the
  per-provider file with the body and reply type that really are its own; a sixth service is a row,
  not another control-flow branch.
- **A frontend is told what a turn did, not left to work it out.** `take` names a session from
  its first line and reports the name with the prompt, so the page announces it and the terminal
  ignores it. *`Server` used to call `Agent.nameFromPrompt` itself and test "first turn" on its own
  before the turn, so session-naming policy lived in an HTTP route and "first turn" was spelled in
  four places.*
- **Two frontends show the same call the same way.** The fallback for a bash header with no
  description lived only in `html.zig`, so the terminal and the page disagreed. Shared vocabulary
  belongs in `Tools.Heading`.

## Comments

- **A comment that its code contradicts is a bug, and the worst kind**: it is believed. Six of them
  were found in one pass (`Config.set`'s "every field is reachable", `loadCompactions`'s "dropped",
  the `Registry`'s purpose, `html.zig`'s escaping invariant, `max_result_len`'s "lines",
  `diff.zig`'s retired script). When you change behaviour, change the sentence in the same commit.
- **Explain the non-obvious choice in one or two sentences.** Good: why the two flushes of an SSE
  frame, why the pool is not deduplicated, why the `Registry` exists, why an image may carry a
  `data:` address and a link may not. Bad: six lines restating a field name.
- **A doc block ends at the blank line before the next declaration.** A detached comment silently
  becomes the next type's documentation.
- **Name things the way the types are named.** The file that is a struct is capitalised, so it is
  imported as the struct (`Agent`, not `agent`), and `root.zig` exports it that way too. Alias a
  module by its stem: `diff`, not `diffing`.

## Tests

- **One helper per format, taking inputs and the expected result.** `expectMarkdown`,
  `expectDescribe`, `expectRead`, `expectReplace`, `expectTranscript`, `expectHeader` are the house
  style: the test is a list of cases, and the helper owns the setup. Copy it rather than writing a
  second setup.
- **A rule that is stated in a comment gets a test.** The `error: ` prefix rule had one, in
  `Tools.zig`, and `read` still broke it — because the test only covered `web_fetch`. Test the rule
  per implementation, not once per rule.
- **Except a rule whose whole point is to log.** `std.testing` fails a test that logs at `err`, so a
  path that reports cannot be exercised from a test at all: check those by running the binary, and
  let the one test that does exist (`main.fail` returning 1 without logging) guard the end of the
  path. Test the mechanism on either side of the log instead: `failureNotice`'s wording and the
  `Emitter` count are both tested without the `ask` path that logs.
- **Tests live next to the code.** Fixtures shared by more than one file belong in one place, not
  copied; `Mock`, `TestServer` and `TestSetup` may only be used from a test, since they run on
  `std.testing.allocator`.
- **Assert the thing the comment claims.** A test named after a behaviour that only checks a proxy
  for it (a `<span>` is present, a count is non-zero) is how the stale doc survives.

## Checking by hand

- **Point billy's directories somewhere disposable before running it.** `XDG_DATA_HOME`,
  `XDG_CONFIG_HOME` and `XDG_CACHE_HOME` are what it reads and writes, and the real ones are the
  user's: a `billy config` run to see a message changed a setting in their actual configuration.
  Set all three at a temporary directory, and `HOME` with them.

## Style

- A signature that returns an error it cannot produce makes every caller write a `try` that cannot
  fail, and widens the error set of everything above it. `Tools.init` returns `!Tools` and cannot
  fail; drop the `!`.
- `writeAll` for a constant, `print` when there is something to format.
- `if (!x)` not `if (x == false)`.
- A log message carries no newline of its own; the log format adds one.
- Brace the arms of a parser; one braceless chain is not a style.
