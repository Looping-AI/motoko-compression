# AGENTS Instructions

## Project Overview

This is an ICP (Internet Computer Protocol) canister built with Motoko, focused on compression algorithms for on-chain data.

- **Language**: Motoko (`src/main.mo`)
- **Package manager**: `mops` for Motoko dependencies
- **Build tool**: `icp` CLI (`@icp-sdk/icp-cli`)

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

Use `icp build` to verify Motoko source code without deploying:

```bash
# Check Motoko files for compilation errors
icp build compression
```

If you modified Motoko test files, run:

```bash
# Run Motoko unit tests
mops test
```

## Motoko Conventions

- Model function parameter order: place the state/collection parameter first, aligning with `mo:core` idioms (e.g. `Map.get(map, compare, key)`).
- `Nat` is a subtype of `Int` (`Nat <: Int`): do not add explicit casts when a function parameter is typed `Int` and the caller has a `Nat`.
- Prefer `query` functions for read-only operations to save cycles.
- Use `Result<T, E>` for fallible operations; variant names are `#ok`/`#err`.

## When to Request Feedback (CRITICAL)

STOP and REQUEST USER FEEDBACK before proceeding in these situations:

### Design Decision Blockers

- Architecture changes that affect the public canister API
- Algorithm design choices with multiple valid trade-offs (speed vs. compression ratio)
- Breaking changes to existing canister interfaces

### Technical Blockers

- Multiple solution paths exist with unclear "best" choice
- External dependency limitations
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

## Architecture

The canister entry point is `src/main.mo`. Keep guard rails (authentication, authorization, validation) at the actor level, not buried inside helper functions.
