# AGENTS Instructions

## Project Overview

This is a **Motoko library package** implementing compression algorithms (Gzip, DEFLATE, LZSS, Huffman) for the Internet Computer. It is intended for use by other canisters via `mops add compression`.

- **Language**: Motoko
- **Package manager**: `mops` for Motoko dependencies
- **Build tool**: `icp` CLI (`@icp-sdk/icp-cli`) — used only for compilation checks

## Important: Package Manager

Use `npm` for global CLI tool installs.

Examples:

- `npm install -g @icp-sdk/icp-cli` — ICP CLI
- `npm install -g ic-mops` — Mops package manager

Mops commands:

- `mops install` — Install Motoko dependencies
- `mops test` — Run Motoko unit tests
- `mops add <package>` — Add a Motoko package

## Library Dependencies

### mo:base is Deprecated — Use mo:core

NEVER use `mo:base` — it is deprecated and unmaintained. Use `mo:core` instead.

- `mo:core` is the modern successor to `mo:base`.
- All standard modules are available in `mo:core` (Array, Blob, Principal, Text, etc.)
- If you encounter compatibility issues, check the module definitions in `.mops/core@{version}/src/` for the correct API.

## How to Verify Your Work

Always start by checking for errors using the `get_errors` tool. This catches compilation errors, type issues, and lint warnings.

### For Motoko Code

Run the test suite after every change:

```bash
mops test
```

To check compilation without deploying:

```bash
icp build compression
```

## Motoko Conventions

- Model function parameter order: place the state/collection parameter first, aligning with `mo:core` idioms (e.g. `Map.get(map, compare, key)`).
- `Nat` is a subtype of `Int` (`Nat <: Int`): do not add explicit casts when a function parameter is typed `Int` and the caller has a `Nat`.
- Prefer `query` functions for read-only operations to save cycles.
- Use `Result<T, E>` for fallible operations; variant names are `#ok`/`#err`.

## When to Request Feedback (CRITICAL)

STOP and REQUEST USER FEEDBACK before proceeding in these situations:

### Design Decision Blockers

- Architecture changes that affect the public library API
- Algorithm design choices with multiple valid trade-offs (speed vs. compression ratio)
- Dependency decisions where multiple options exist (e.g. replacing an external package with inline logic)

### Technical Blockers

- Multiple solution paths exist with unclear "best" choice
- External dependency limitations (package not compatible with mo:core or moc version)
- Workarounds needed that compromise original requirements

### How to Request Feedback

When you encounter a blocking decision, use the `ask_questions` tool to surface the decision before proceeding. Do not ask in free text — the tool formats the question clearly.

Steps:

1. Stop immediately — do not implement a solution
2. Use `ask_questions`: frame the situation, present 2-3 options (with pros/cons), mark your recommended option
3. Wait for user decision before coding

## Testing Practices

### Prefer `expect` Over `assert`

In Motoko tests, use `expect` syntax instead of `assert`. The `expect` API provides better error messages with actual vs expected values.

Refer to `.mops/test@{version}/README.md` for complete `expect` documentation and examples.
