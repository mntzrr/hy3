# Contributing

This is a personal fork of [outfoxxed/hy3](https://github.com/outfoxxed/hy3). See `FORK.md`
for what it adds and how it tracks upstream, and `AGENTS.md` for the practical notes on
working in this codebase — especially how to test changes without taking down a live session.

## AI assistance

**AI-assisted contributions are accepted.** Use whatever tools you like.

**Do not name the tool in the commit history.** No `Co-Authored-By:` trailer for an assistant,
no `Assisted-by:` line, no "generated with …" footer, no mention in the subject or body.

The reason is not squeamishness about the tooling — it is that a commit log is a poor place for
vendor names. Every such trailer turns project history into advertising for whichever assistant
happened to be in use, permanently and unremovably, and it says nothing useful about the change
itself. Which editor, compiler, or assistant produced a diff is not information a future reader
of `git log` or `git blame` needs.

What does belong in a commit message: what changed, and why. If the reasoning is subtle, write
it down — that is worth far more than knowing what typed it.

Authorship and responsibility sit with the person committing, regardless of how the code was
produced. That means you have read the change, you understand it, and you have tested it. An
assistant's output is a draft, not a contribution.

This policy governs commits authored in this fork. Commits inherited from upstream keep their
original trailers — rebasing onto `upstream/master` must not rewrite upstream history, and
upstream's own conventions are upstream's business.

### Enforcing it

`.githooks/commit-msg` rejects assistant attribution. Hooks are not cloned, so enable it per
checkout:

```sh
git config core.hooksPath .githooks
```

It exists because writing the rule down twice was not enough: three commits carrying the
trailer reached the remote in a single session, added by an assistant whose own defaults
instruct it to. A convention that competes with a tool's built-in behaviour needs something
that fails the commit.

It checks the message git will actually keep — comments and anything below a `-v` scissors line
are ignored — and it does not object to a `Co-Authored-By:` naming a person. `--no-verify`
bypasses it, which is the intended route for an upstream commit being replayed through a
conflict, and for a commit that has to quote the policy itself.

## Commits

- Prefix fork-only commits `fork:` so the series stays identifiable across rebases onto
  upstream. `FORK.md` explains the conventions that keep those rebases conflict-free.
- Keep the subject in the imperative mood, and explain the *why* in the body when it is not
  obvious from the diff.

## Testing

Do not iterate against a live Hyprland session — unloading a layout plugin that owns every
tiled window has crashed the compositor here. Use the throwaway instance:

```sh
cmake -DCMAKE_BUILD_TYPE=Release -B build && cmake --build build
test/nested.sh start 2
test/smoke.sh
test/nested.sh stop
```

`AGENTS.md` lists the verification traps that have produced false passes in this project. Read
them before trusting a hand-run check.
