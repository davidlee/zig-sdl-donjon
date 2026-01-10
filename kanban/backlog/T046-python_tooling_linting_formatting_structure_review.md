# T046: Python Tooling - Linting, Formatting, Structure Review
Created: 2026-01-10

## Problem statement / value driver
`scripts/cue_to_zig.py` has grown substantial (~1300 lines) without linting or formatting tooling. As data generation logic expands, maintainability becomes a concern.

### Scope - goals
- Add ruff for linting and formatting
- Review script structure for potential refactoring
- Integrate into `just check` workflow

### Scope - non-goals
- Major rewrites or splitting into multiple files (unless clearly warranted)
- Adding type checking (mypy) - consider separately if needed

## Background
- Running on NixOS - dependencies via uv or flake.nix
- Script handles CUE→Zig codegen and data auditing
- Currently no Python tooling in project

### Key files
- `scripts/cue_to_zig.py` - main script
- `flake.nix` - nix development environment
- `justfile` - build commands

## Changes Required
1. Add ruff to dev environment (uv or flake)
2. Configure ruff (pyproject.toml or ruff.toml)
3. Run initial lint/format pass
4. Add `just lint-python` or integrate into `just check`
5. Review structure, document any refactoring opportunities

### Open Questions
- uv vs flake for Python deps? (user preference)
- Strictness level for ruff rules?

## Tasks / Sequence of Work
1. [ ] Decide dependency approach (uv/flake)
2. [ ] Add ruff to dev environment
3. [ ] Configure ruff
4. [ ] Initial lint/format pass
5. [ ] Integrate into just workflow
6. [ ] Structure review and notes

## Test / Verification Strategy
- `ruff check scripts/` passes
- `ruff format scripts/` produces no changes
- `just check` includes Python linting
