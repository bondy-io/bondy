
## Comments

A comment must say something the code cannot. If deleting a comment loses no
information, it should not have been written.

Do not write:
- Restatements of the next line or of the function name.
- Narration: "Step 1:", "First we...", "Now we...", "Loop through...".
- Ad-hoc separators inside a function or between two related clauses. Section
  banners that group a module into sections are welcome, in the house form:

  ```erlang
  %% =============================================================================
  %% Properties
  %% =============================================================================
  ```

  A banner holds a title only: no prose, no planning ids.
- Changelog or process notes: "refactored to", "added for", "was previously".
- Comments addressed to me rather than to a future reader.
- Parameter or return descriptions that repeat the type signature.
- Commented-out code. Delete it; git has it.

Do write, when true:
- Why this approach, when an obvious alternative was rejected.
- Invariants and preconditions the types do not express.
- References to a spec, RFC section, paper, or issue that explains the shape.
- Hazards: ordering, concurrency, partial failure, resource ownership.
- `TODO`/`FIXME` with an issue reference.

Public API documentation is not a comment and is exempt: `-doc`/`-moduledoc`
in Erlang, `@doc`/`@moduledoc` in Bondy. Document exported
functions. Do not document private ones unless the reason is non-obvious.

Default to zero comments in a function body. Prose belongs in the module doc.

### No archaeology

The type system (`bondy_type_*`, `bondy_class_*`, `bondy_shape_*`,
`lib/type/**`) carries about 19K comment lines against 46K code lines, nearly
all of them machine-written. They record how the code came to be, not what it
is. Do not add to them. The rules below apply to comments **and** to
`-doc`/`-moduledoc`/`@doc`/`@moduledoc`: the API-doc exemption is from
*deletion*, not from these rules.

- **Write the contract, never the history.** Do not describe what the code used
  to do, what was wrong with it, what you fixed, or what "is now" true:
  "previously", "no longer", "the old path", "now routes through",
  "is landed", "was missing", "the fix", or dates. "This clause did not set
  `realm_uri`, so consumers had to parse the id" is history; "a realm-class
  alarm names its tenant in `realm_uri`" is the contract. Git holds the history.
- **No planning identifiers.** Never write roadmap or ledger ids in code or
  in-code docs: `TS.123`, `W3`, `D5`, `R.12`, `LOG F8`, "rung", "increment",
  "step 2 of", review or guard ordinals used as names. Never write a `_design/`
  or `_reports/` path. Describe the concept. To point at a decision, cite a
  BDDR, the book (by file path and title), a paper, or a test.
- **A claim names its evidence** (engineering rule 2). "Proven", "by
  construction", "byte-identical", "equivalent to", "cannot disagree",
  "`X` is `Y`", and "the single authority" each need the test, property, or
  guard that checks them, named in the same sentence. Without that evidence,
  write it as intent ("is meant to be", "the intended end state") or leave it
  out. The `bondy_membership_walk` moduledoc stated that `do_walk` *is*
  `walk(R, ·)` and cited an ADR. `do_walk` never calls the driver, and the ADR
  was never written. That is the failure this rule exists to stop.
- **Budgets.** A body comment is at most three lines; eight is the ceiling.
  Anything longer is a design note: put the invariant in the moduledoc in one
  sentence, and put the argument in a BDDR. Do not cite another module's
  *private* function. That reference rots first, and nothing flags it when it
  does.
- **One home per explanation.** If the same rationale would appear at two
  sites, it belongs in the owning module's doc, and the other site gets
  nothing.
- **Keep comments true when you change code.** When you change code, fix or
  delete every comment and doc the change falsifies, in the same edit. Do not
  append a note explaining the change.

Before you finish any task that edits `src/`, `lib/`, or `test/`, list the
comment and doc lines your diff **adds**:

```sh
git diff -U0 | grep -E '^\+\s*(%%|@doc|@moduledoc|-doc|-moduledoc)'
```

Check each line against the test at the top of this section and the rules
above. If it fails either, delete it. To clean up existing comments, use the
`comment-hygiene` skill: it verifies that a cleanup diff removed only comments,
and that the Erlang token stream is unchanged.

## Erlang Style

- One `-export` per function.
- `%%` for comments (never `%`).
- CamelCase variables; OTP module structure.
- Use `~""` binary-string sigil, not `<<"">>`.
- OTP27 `-moduledoc`/`-doc` triple-quoted strings.
- Never `ets:tab2list` + `lists:filter` when `ets:select` with a match-spec works.
