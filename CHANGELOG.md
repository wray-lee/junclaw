# Changelog

## Unreleased

### Changed

- `agent.harness` now defaults to `"dsh"`, the in-process dsh engine
  (`src/harness/dsh_native/`). Set `"harness": "native"` to keep the original
  engine.
- The DeepSeek-Harness sidecar value moved from `"dsh"` to `"dsh-sidecar"`.
  It still requires a `-Dharness_dsh=true` build. Configs that meant the
  sidecar must change `"dsh"` to `"dsh-sidecar"`.
- `"dsh-native"` is kept as an alias for `"dsh"`; saving a config writes the
  canonical `"dsh"`.
