# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Generated apps now surface pipeline success/failure inside the session
  card once a run finishes. `script.sh.erb` captures Nextflow's real exit
  code (working around `set -euo pipefail`) and writes a `pipeline_status`
  file next to `output.log`; the new `completed.html.erb` (rendered by
  OnDemand only once `session.completed?`, via its `session_completed_view`
  mechanism -- distinct from `view.html.erb`, which stops being rendered the
  moment the job leaves the "running" state) reads it and shows a green
  "Success" or red "ERROR (exit code N)" banner. This is a workaround for an
  OnDemand/OodCore limitation: the session card's own status pill has no
  failed/error state, so Slurm `FAILED`/`CANCELLED`/etc. all render as
  "Completed" regardless of the pipeline's actual outcome.
- `script.sh.erb` traps `SIGTERM` so cancelling a session (OOD's cancel/
  delete button, which runs `scancel`) still produces a `pipeline_status` of
  `ERROR (cancelled)` for `completed.html.erb` to show. Without the trap,
  Slurm signals the whole job step -- this script and the Nextflow child --
  at once, so the exit-code handling at the bottom of the script was never
  reached and cancelled runs showed no banner at all.

- Documented [`sweavs111/ood_cache_reset`](https://github.com/sweavs111/ood_cache_reset),
  the standalone OOD sys app that backs every generated app's "cache reset
  utility" link (`form.template.erb`) and completes the handshake
  `form.js`'s `resetBatchConnectFormOnce` already implemented client-side.
  Deploys once per OOD instance into `apps/sys/cache_reset`, from its own
  repo rather than being vendored here.
- `NF2OOD_CACHE_RESET_PATH` config variable: the base path of the cache
  reset utility baked into `form.template.erb`'s "Saved form values" link.
  Defaults to `/pun/sys/cache_reset`; override it (e.g. to a per-user
  `/pun/dev/<user>/cache_reset` sandbox deploy) while testing the utility
  without hand-editing the template.
- `nf2ood` now generates a "nf-core Pipelines" landing page app
  (`output_dir/nf-core`) after every run, linking to every currently
  generated pipeline app grouped by subcategory. It's derived from
  `output_dir/*/manifest.yml` on each run (via the new
  `gen_landing_page.py` and `landing_page_template/`), so it stays in sync
  as pipelines are added, updated, or removed without a separate step.
- `NF2OOD_APPS_URL_PREFIX` config variable: the base path the landing page
  links each pipeline card to. Defaults to `/pun/sys/dashboard/apps/show`;
  override it (e.g. to `/pun/dev/<user>`) while testing apps that haven't
  been deployed to `apps/sys` yet.

### Fixed

- The "Working directory" field on generated apps now resolves
  `NF2OOD_DEFAULT_DIRECTORY` at form-render time inside each viewing user's
  own Open OnDemand process, the same way schema-derived directory fields
  already did, instead of being baked into `form.template.erb` once at
  generation time from whatever `NF2OOD_DEFAULT_DIRECTORY` expanded to in
  the operator's own shell (e.g. their personal scratch directory via
  `$USER`) -- previously every user of every generated app saw the
  operator's own directory as the default, not their own. When
  `NF2OOD_DEFAULT_DIRECTORY` isn't set in that process's environment, it now
  defaults to the viewing user's own scratch directory
  (`/share/$GROUP/$USER`, using `GROUP`/`USER`/`HOME` the same way a normal
  Hazel login shell would) rather than `$HOME`, since a Nextflow work
  directory routinely needs far more than `$HOME`'s 1 GB quota -- falling
  back to `$HOME` only if `GROUP` isn't present in that environment. The
  field's help text now also calls out the 30-day scratch purge so users
  know to copy results they want to keep to RS1.
- Generated app directories, the landing page app, and the top-level
  `--output` directory are now normalized to `755` (dirs) / `644` (files)
  after generation, so every file is "other"-readable once the output tree
  is copied out to an Open OnDemand host and read there by the OOD service
  account rather than by whoever ran `nf2ood`. Previously, permissions on
  generated apps depended on the operator's umask and on `nfcore_ood_template`'s
  own checked-in modes (some of which lacked "other" read entirely); `cp -R`
  can only narrow permissions via umask, never widen them, so a template
  file missing other-read stayed that way in every app generated from it.
  Nothing under a generated app is executed directly (OOD renders the
  `.erb`/`.yml`/`.html`/`.js`/`.png` files as templates/data and writes its
  own `script.sh` elsewhere at submit time), so no file needs an execute bit.
- Fixed several files under `nfcore_ood_template/` that were checked into
  git as executable (`100755`) despite being plain data/template files
  (`README.md`, `manifest.yml`, `form.template.erb`, `submit.yml.erb`,
  `view.html.erb`, etc.) and removed a stray `.DS_Store` that had been
  accidentally tracked.

### Removed

- The "local" Nextflow executor option, and its `partition`/`num_cores`/
  `num_memory` form fields, have been removed from generated apps -- `slurm`
  is now the only executor. `NF2OOD_PARTITION_YML` is no longer a required
  (or used) config variable; sites that had a partition partial configured
  for it can leave that file in place unused, or delete it.
- The offline test-data staging pipeline (`download_nfcore_pipeline.sh
  --with-testdata`, `gen_local_testconfig.py`, `pipeline2testbranch.tsv`,
  `testdata-extra/<pipeline>.tsv`, and the `NF2OOD_TESTDATA_ROOT`/
  `NF2OOD_TESTDATA_REPO_URL` config variables) has been removed. It
  generated a `local_test.config` that the runtime script never actually
  read -- the "Run pipeline's built-in test profile" checkbox has always
  used the real `-profile test`, routed through the `xfer` partition for
  outbound internet, instead.

## [1.4.0] - 2026-06-25

This release simplifies how generated Open OnDemand apps handle nf-core
schema fields that allow multiple scalar types such as integer-or-boolean.

### Changed

- Multi-type scalar schema fields now generate as a single text input
  instead of an extra enable/disable controller field.
- Mixed-type values are converted in a predictable order when
  `nf-params.json.erb` is rendered: number first, then boolean, otherwise
  left as a string.
- For mixed-type fields with a boolean branch default or `const`, the
  generated form now uses that boolean value as the default text input.

## [1.3.0] - 2026-06-22

This release simplifies generated Open OnDemand forms and makes Nextflow
version choices static at generation time rather than hardcoded in the
template.

### Added

- `nf2ood` now runs `module avail` during app generation and bakes the
  discovered Nextflow module versions directly into each generated
  `form.yml.erb`.

### Changed

- Generated forms no longer include header images in `form_header`.
- The base form template now uses a placeholder for the `Nextflow version`
  field, which is filled during generation instead of being maintained as a
  fixed list in the template.

## [1.2.0] - 2026-06-09

This release adds a user-selectable Nextflow version control to generated
Open OnDemand apps so older nf-core pipeline releases can run against a
compatible Nextflow module version.

### Added

- Generated apps now expose a top-level `Nextflow version` control.
- The form template attempts to discover available Nextflow module versions
  automatically from `module avail`, avoiding hardcoded version lists when
  the OOD host can inspect the module tree.
- Runtime wrapper logic now loads `nextflow/<selected_version>` when the user
  chooses an explicit version.

### Changed

- The generated form now keeps `bc_email_on_started` and `nextflow_version`
  in the rendered `form:` order reliably.
- The `Nextflow version` field defaults to the newest discovered module
  version instead of a separate `Site default` placeholder.
- Help text for `Nextflow version` now explains the backward-compatibility use
  case for older nf-core pipeline releases.
- `Email when job starts` now appears at the end of the generated form.
- Top-level styling and icons now apply to both `Nextflow version` and
  `Email when job starts`.

## [1.1.0] - 2026-05-14

This release focuses on portability for non-Tufts HPC centers, robustness of
the generation step, and code-quality cleanups in the bash driver and Python
helpers.

### Added

- `-V` flag prints the tool version (`nf2ood 1.1.0`) and exits.
- `-n` / `--dry-run` previews what would be generated without touching the
  output directory.
- `-p` / `--pipeline NAME` and `-v` / `--version VER` filters (both
  repeatable) for regenerating a single app in place. When either filter is
  active, unrelated apps in the output directory are preserved and `--force`
  becomes a no-op with a warning.
- `-s` / `--subcategory-map` flag plus a new top-level
  `pipeline2subcategory.tsv` data file that holds the pipeline-to-OOD
  subcategory mapping previously embedded as a 50-line `case` statement
  inside `nf2ood`.
- `-m` short alias for `--image-map`.
- `-i` / `--input` is now optional; defaults to `$NF2OOD_PIPELINE_ROOT` so
  the common workflow (`download_nfcore_pipeline.sh` -> `nf2ood`) does not
  need to repeat the path.
- End-of-run summary listing `Generated` / `Failed-skipped` /
  `Non-version dirs ignored` counts and per-entry lists. `nf2ood` exits
  non-zero if any pipeline failed.

### Changed

- `nf2ood.env` is now gitignored; the checked-in example is
  `nf2ood.env.example`. New workflow:
  `cp nf2ood.env.example nf2ood.env && source ./nf2ood.env`.
- Site environment variables are validated up front:
  - **REQUIRED** (die at startup, pointing at `nf2ood.env.example`):
    `NF2OOD_PIPELINE_ROOT`, `NF2OOD_SINGULARITY_CACHEDIR`,
    `NF2OOD_PARTITION_YML`.
  - **SOFT (warn)**: `NF2OOD_SLURM_PROFILE` falls back to `default` with a
    one-shot warning when unset.
  - **SOFT**: `NF2OOD_CLUSTER`, `NF2OOD_DEFAULT_DIRECTORY`,
    `NF2OOD_MODULE_NAME`, `NF2OOD_CONTAINER_MODULE`, `NF2OOD_ENV_FILE`
    keep cross-site safe defaults.
- `NF2OOD_MODULE_NAME=""` and `NF2OOD_CONTAINER_MODULE=""` are now honored
  as "skip this `module load`", letting sites with system-installed
  Nextflow / Singularity / Apptainer opt out of the corresponding module
  load. The runtime wrapper continues to auto-skip the whole block on
  compute nodes with no `module` command at all.
- Version-directory filter tightened from "starts with a digit" to a
  SemVer-ish regex (`^[0-9]+\.[0-9]`), so `dev`, `latest`, `main`, etc.
  are skipped automatically (reported as informational, not warnings).
- README restructured for site-agnostic onboarding: new "Quick start"
  recipe, "Configuration reference" grouped by REQUIRED / SOFT (warn) /
  SOFT, dedicated "Subcategory mapping" section, "Institutional profile
  (Tufts example)" heading making the Tufts framing explicit.
- App-customization rewritten as a single Python pass. New
  `customize_app.py` walks the known set of template files and applies
  every `--set TOKEN=VALUE` substitution at once, replacing ~24 per-app
  `perl -0pi -e` shellouts with one Python invocation per app.
- The Ruby ERB header for `nf-params.json.erb` (the `to_bool` / `to_number`
  helpers and the surrounding params hash) lives in
  `nfcore_ood_template/nf-params.template.erb` with an
  `__NF_PARAMS_ENTRIES__` placeholder, instead of being a Python
  triple-quoted string in `json2ood.py`.
- `.gitignore` expanded with common macOS / Windows OS files, IDE
  droppings, Python build/cache, logs, and merge debris.

### Removed

- Nextflow Tower / Seqera Platform `tower_access_token` widget and the
  related `-with-tower` runtime handling. Sites that still need this can
  fork the template; the helpers were never used at Tufts.
- Duplicate `resetBatchConnectFormOnce` definition and standalone
  `DOMContentLoaded` listener in `nfcore_ood_template/form.js`.
- `perl` runtime dependency. Token substitution is now Python.
- Tufts-flavored hardcoded fallback paths in `nf2ood` and
  `download_nfcore_pipeline.sh`. Affected variables now either fail-fast
  (REQUIRED) or use neutral cross-site defaults.

### Fixed

- A missing `nextflow_schema.json` for one pipeline no longer aborts the
  whole run. The pipeline is warned, skipped, and reported in the summary;
  `nf2ood` exits non-zero overall but all sibling pipelines still get a
  chance to generate.
- `json2ood.py` now loads on Python 3.8 / 3.9, which are still common on
  HPC login and compute nodes. (A `str | int | float | bool | None`
  runtime expression had crashed module load there.)
- `generate_app` failures (for example a `json2ood.py` crash on a
  malformed schema) are now reliably caught and reported as
  Failed/skipped. Previously bash's `set -e` suppression inside `if` test
  contexts caused such failures to be silently absorbed: the app was
  counted as generated even though its `form.yml.erb` and
  `template/nf-params.json.erb` were missing. The partial app directory
  is also cleaned up on failure so future runs do not see half-rendered
  state.

### Upgrading from previous versions

1. `git pull` and `cp nf2ood.env.example nf2ood.env`, then edit your
   local `nf2ood.env` so the three REQUIRED variables point at your site
   paths.
2. If your site does not have Nextflow or Singularity as environment
   modules, add `export NF2OOD_MODULE_NAME=""` and/or
   `export NF2OOD_CONTAINER_MODULE=""` to your `nf2ood.env`.
3. Generated apps will no longer contain a Tower access token field.
   Existing OOD apps continue to work; regenerate them with `nf2ood -p
   <name>` to pick up this and other template changes.
4. The `--input` argument is no longer required as long as
   `NF2OOD_PIPELINE_ROOT` is set; existing scripts that pass `--input`
   explicitly continue to work unchanged.

## [1.0.0] - initial public release

First public release of `nf2ood`. Generates Open OnDemand batch-connect
apps from locally downloaded nf-core pipelines, including the download
step (`download_nfcore_pipeline.sh`) and the schema-to-form converter
(`json2ood.py`). No explicit version tag; see git history for details.

[Unreleased]: https://github.com/TuftsRT/nfcore2ood/compare/v1.4.0...HEAD
[1.4.0]: https://github.com/TuftsRT/nfcore2ood/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/TuftsRT/nfcore2ood/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/TuftsRT/nfcore2ood/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/TuftsRT/nfcore2ood/compare/5d20ce7...v1.1.0
[1.0.0]: https://github.com/TuftsRT/nfcore2ood/tree/5d20ce7
