# Changelog

All notable changes to this project are documented in this file.

## [1.0.0] - 2026-05-28

### Added

- Submission governance artifacts for public repository delivery:
  - CODE_OF_CONDUCT.md
  - RETROSPECTIVE.md
  - docs/operations/ONDEVICE_RUNBOOK.md
  - docs/operations/OBSERVABILITY.md
  - docs/model/MODEL_CARD.md
  - docs/demo/DEMO_VIDEO.md
- Dependabot configuration for GitHub Actions and Python dependencies.
- Main branch release workflow for on-device iOS build/test gate.

### Security

- PR/Push security checks include Bandit and pip-audit workflows.
- Dependabot update policy introduced.

### CI/CD

- Existing PR gate workflows already enforce lint/test/security checks.
- Main branch release workflow added for on-device delivery pipeline.

### Docs

- Added operational runbook for healthcheck, rollback, and release steps.
- Added observability guidance for logs/metrics/dashboard on iOS.

## [0.5.0] - 2026-05-11

- Baseline release before final submission hardening.
