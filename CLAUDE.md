# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo does

`nf2ood` generates Open OnDemand (OOD) batch-connect apps from locally
downloaded nf-core pipelines. It has two stages, kept deliberately separate:

1. `download_nfcore_pipeline.sh` downloads an nf-core pipeline/revision into
   a local pipeline tree (via `nf-core pipelines download`) and symlinks each
   pipeline's `configs/` to a shared, centrally-maintained copy.
2. `nf2ood` scans that pipeline tree, finds each `nextflow_schema.json`, and
   generates one OOD batch-connect app directory per pipeline version.

All site-specific values (paths, cluster name, Slurm profile, module names)
live in `nf2ood.env` (gitignored), copied from `nf2ood.env.example` (checked
in, Tufts values). Both scripts `source ./nf2ood.env` — nothing else should
hardcode a site path.

## Common commands

```bash
# One-time setup
cp nf2ood.env.example nf2ood.env   # then edit for your site
source ./nf2ood.env

# Download a pipeline
./download_nfcore_pipeline.sh --name taxprofiler --revision 1.2.6

# Generate all apps (--input defaults to $NF2OOD_PIPELINE_ROOT)
./nf2ood --output /path/to/generated-apps

# Regenerate just one app after a pipeline update (reuses the output dir,
# leaves other apps alone; -f/--force is ignored when filtering)
./nf2ood --output /path/to/generated-apps --pipeline rnaseq --version 3.18.0

# Dry run (no files written)
./nf2ood --output /path/to/generated-apps --dry-run

# Print the tool version
./nf2ood -V
```

There is no test suite, linter, or build step in this repo — verify changes
by running `./nf2ood --dry-run` against a real (or fixture) pipeline tree, or
by generating into a scratch output directory and inspecting the rendered
`form.yml.erb` / `template/nf-params.json.erb`.

## Architecture / generation pipeline

`nf2ood` (bash) is the orchestrator; it never renders YAML/JSON itself and
delegates that to two Python scripts:

1. **`nf2ood` main loop** (`nf2ood:list_pipelines` → `list_versions` →
   `generate_app`): walks `$INPUT_DIR/<pipeline>/<version>/`, filters to
   SemVer-ish version dirs, applies `--pipeline`/`--version` filters, and
   calls `generate_app` per (pipeline, version) pair. Per-app failures are
   caught (`if generate_app ...`, not bare `set -e`) and accumulated into a
   summary rather than aborting the whole run.
2. **`generate_app`** copies `nfcore_ood_template/` → the new app dir, then
   runs `json2ood.py` to turn `nextflow_schema.json` into
   `form.yml.erb`/`template/nf-params.json.erb`, then calls
   `customize_generated_app` → `customize_app.py` to fill in `__TOKEN__`
   placeholders (pipeline name/version, cluster, paths, module names, etc.)
   across the copied template files.
3. **`json2ood.py`** (`normalize_schema` → `GroupSpec`/`FieldSpec`) reads
   `definitions`/`$defs` from the nf-core JSON schema, skips known
   non-pipeline-parameter groups (`SKIPPED_DEFINITION_NAMES`) and hidden
   fields (`DEFAULT_HIDDEN_PROPERTY_NAMES`), infers an OOD widget type per
   field (`infer_widget_type`: `select`/`check_box`/`text_field`/
   `path_selector`/`number_field`/`mixed_text_field` for scalar-or-boolean
   union types), and renders:
   - `form.yml.erb`: appended to the static `form.template.erb` base (which
     already has `bc_num_hours`, the Slurm partition partial, `executor`,
     etc.). Each schema group becomes a `check_box` toggle with
     `data-hide-<field>-when-un-checked` rules on its member fields (OOD
     3.1+ behavior) so unchecking a group hides its fields.
   - `template/nf-params.json.erb`: field values are spliced into
     `nf-params.template.erb` at the `__NF_PARAMS_ENTRIES__` placeholder,
     each wrapped in a `to_bool`/`to_number`/`to_number_or_bool` Ruby lambda
     matching its widget type so form strings coerce to the right JSON type.
   - Field names are normalized (`normalize_key`): lowercased, non-alphanumeric
     runs become `_`, and digits are moved to the end of each token — this
     keeps generated field ids stable so OOD's hide/show `data-` selectors
     don't break on names like `fasta1` vs `1fasta`.
4. **`customize_app.py`** does one substitution pass (not a `perl -0pi -e`
   loop) over an explicit allowlist of text files in the app dir
   (`SUBSTITUTION_TARGETS`), replacing every `--set __TOKEN__=VALUE` pair.
   Binary assets (e.g. `icon.png`) are never opened as text because they're
   simply not in that list.

### Config precedence (site adaptation)

`nf2ood` validates two **REQUIRED** env vars up front and dies with a
clear message if unset (`validate_environment`): `NF2OOD_PIPELINE_ROOT`,
`NF2OOD_SINGULARITY_CACHEDIR`. `NF2OOD_SLURM_PROFILE` is **SOFT (warn)** —
falls back to `default` with a one-shot warning. Every
other `NF2OOD_*` var nf2ood itself reads (`NF2OOD_CLUSTER`,
`NF2OOD_MODULE_NAME`, `NF2OOD_CONTAINER_MODULE`, `NF2OOD_ENV_FILE`,
`NF2OOD_CACHE_RESET_PATH`, `NF2OOD_APPS_URL_PREFIX`) is
**SOFT** with a safe cross-site default via `config_value()`. Module name
vars use `${VAR-default}` (no colon) specifically so an explicit empty
string means "skip this `module load`" — see the comment in
`nf2ood:customize_generated_app`. When adding a new site-configurable value,
follow this same three-tier pattern and document it in both
`nf2ood.env.example` and the README's Configuration reference table.

`NF2OOD_DEFAULT_DIRECTORY` is the one exception: it is deliberately *not*
read by `nf2ood`/`config_value()` at generation time, and setting it in
`nf2ood.env` does nothing. The schema-derived `path_selector` fields
(`json2ood.py:infer_widget_type`'s `path_selector` branch) emit a live ERB
expression — `ENV.fetch('NF2OOD_DEFAULT_DIRECTORY', ENV.fetch('HOME', '/'))`
— evaluated per-request inside the *viewing user's own* Open OnDemand PUN
process. This was a deliberate fix: an earlier version baked
`NF2OOD_DEFAULT_DIRECTORY` into `form.template.erb` via the usual
`--set __TOKEN__=VALUE` substitution pass, which froze in whatever path
expanded in the shell of whoever ran `nf2ood` (e.g. their own scratch dir
via `$USER`) and then served that same literal path to every user of every
generated app. If a site wants one shared default directory for all users
instead of each user's own `$HOME`, export `NF2OOD_DEFAULT_DIRECTORY` in the
environment Open OnDemand's Passenger/PUN processes run with — not in
`nf2ood.env`.

The static `workdir` field in `form.template.erb` (the Nextflow launch
directory, distinct from a pipeline's own `--outdir`/`--input` parameters)
goes one step further: if `NF2OOD_DEFAULT_DIRECTORY` isn't set in that
process's environment, it falls back to the viewing user's own scratch
directory (`/share/#{ENV['GROUP']}/#{ENV['USER']}`) rather than `$HOME`,
falling back further to `$HOME` only if `GROUP` isn't present. `GROUP` is
exported by `/etc/profile.d/hpc.sh` (`export GROUP=$(id -gn)`) for every
Hazel login shell, the same mechanism that gives `HOME`/`USER`; this
assumes Open OnDemand's PUN launch sources that same login-profile chain.
`$HOME`'s 1 GB quota is too small for a real Nextflow work directory, and
scratch is exactly where the handbook's own recommended workflow says job
working directories belong -- at the cost of the 30-day scratch purge,
which the field's help text calls out. This scratch fallback deliberately
does *not* apply to the schema-derived `path_selector` fields above (e.g. a
pipeline's `--outdir`), which still fall back to `$HOME` only, since those
are user-chosen input/output locations rather than throwaway work dirs.

The generated `template/script.sh.erb` re-sources `NF2OOD_ENV_FILE` **at job
runtime** on the compute node (falling back to the `__TOKEN__` baked in at
generation time if that file isn't there/readable) — this is how a site can
change e.g. `NF2OOD_SLURM_PROFILE` without regenerating every app, as long
as the same env file path is visible from both the OOD host and compute
nodes.

### Built-in test profile

Every generated app has a "Run pipeline's built-in test profile" checkbox
(`use_test_profile` in `form.template.erb`, wired up in `script.sh.erb`).
nf-core's own `-profile test` pulls its dataset from
`raw.githubusercontent.com/nf-core/test-datasets`, which fails on sites
where compute nodes have no outbound internet. `submit.yml.erb` routes the
launch job to the `xfer` partition (the one partition with outbound
internet) whenever the checkbox is checked, so `-profile test`'s network
calls just work -- no local mirroring of test data is attempted, since some
pipelines hardcode additional test assets directly in their own workflow
code, outside `conf/test.config` or the samplesheet entirely, so no amount
of local URL-rewriting could guarantee catching everything a given pipeline
version needs anyway.

### Subcategory mapping

`determine_subcategory` (in `nf2ood`) looks up the pipeline name in
`pipeline2subcategory.tsv` (`-s/--subcategory-map` to override); falls back
to the pipeline slug for `nf-core-*` names or `bioinformatics` otherwise.
`pipeline2image.tsv` maps pipeline names to a workflow diagram URL for
`view.html.erb`; both are simple two-column TSVs read with the same
`lookup_tsv_value` bash helper (case-insensitive key match, `#`-comments).

### Cache reset utility

`form.template.erb`'s "Saved form values" notice links every generated app
to `__NF2OOD_CACHE_RESET_PATH__/?app_slug=<slug>&return_url=...`
(`NF2OOD_CACHE_RESET_PATH`, default `/pun/sys/cache_reset` — see Config
precedence above), and `form.js`'s `resetBatchConnectFormOnce` implements
the client half of the handshake (blanks all visible fields when reloaded
with `?cache_reset=1`). The other half — an OOD app that actually deletes
the cached
`~/ondemand/data/sys/dashboard/batch_connect/cache/<role>_<app_slug>.json`
file and redirects back with `cache_reset=1&cache_reset_at=<epoch>` — lives
in its own repo,
[`sweavs111/ood_cache_reset`](https://github.com/sweavs111/ood_cache_reset)
(a dependency-free-Ruby-stdlib port of Tufts' `TuftsRT/tufts_ood_cache_reset`),
rather than being vendored here — it's a generic Batch Connect utility with
its own release cycle, not specific to nf-core pipelines. Unlike everything
else nf2ood touches, it's not generated per pipeline — production deploys
land once per OOD instance, straight into `apps/sys/cache_reset` (root-owned,
so that's a manual clone + `rsync` + `sudo` step; see that repo's README).
While testing it, deploy it instead to a per-user `~/ondemand/dev/cache_reset`
sandbox (no `sudo` needed) and set `NF2OOD_CACHE_RESET_PATH` to the matching
`/pun/dev/<user>/cache_reset` path in `nf2ood.env` — regenerating apps then
points every link at the sandbox copy instead of hand-editing
`form.template.erb` and having to remember to revert it before the real
`apps/sys/cache_reset` deploy.

### Landing page

`nf2ood` writes one more app per run (skipped on `--dry-run`):
`output_dir/nf-core`, a static "nf-core Pipelines" index page grouping
every currently-generated app into cards by subcategory. Unlike the
per-pipeline apps, it isn't driven by a list this run generated -- `nf2ood:
generate_landing_page` calls `gen_landing_page.py`, which globs
`output_dir/*/manifest.yml`, keeps only manifests with `role:
batch_connect` (this is also what excludes the landing app's own manifest,
which has no `role` key, from a later re-run), and groups by each
manifest's `subcategory` field. Because it re-derives its content from
`output_dir` on every invocation rather than being handed the app list,
it stays correct after a filtered `-p`/`-v` run (the new/updated app just
shows up) as well as a full run (stale apps disappear along with their
directories). Each card links to
`NF2OOD_APPS_URL_PREFIX/<app-dir-name>` (default
`/pun/sys/dashboard/apps/show`, same soft-default/override pattern as
`NF2OOD_CACHE_RESET_PATH` -- flip it to a `/pun/dev/<user>` sandbox prefix
while testing). Static assets (`manifest.yml`, `index.template.html` with
its `__SECTIONS__` splice point, same convention as
`nf-params.template.erb`'s `__NF_PARAMS_ENTRIES__`) live in
`landing_page_template/`; `icon.png` isn't duplicated there and is instead
copied from `nfcore_ood_template/icon.png` at generation time. This step is
best-effort -- a failure only logs a warning, since the pipeline apps it
links to already generated successfully either way.

## Repository layout

```
nf2ood                        # orchestrator (bash)
json2ood.py                   # schema -> form.yml.erb / nf-params.json.erb
customize_app.py              # __TOKEN__ substitution over the app dir
gen_landing_page.py           # output_dir/*/manifest.yml -> output_dir/nf-core landing page
download_nfcore_pipeline.sh   # stage 1: nf-core pipeline downloader
nf2ood.env.example            # checked-in site config template (nf2ood.env is gitignored)
pipeline2subcategory.tsv      # pipeline -> OOD subcategory
pipeline2image.tsv            # pipeline -> workflow diagram URL (view.html.erb)
nfcore_ood_template/          # the OOD batch-connect app template, copied per app
  form.template.erb           # static base fields json2ood.py appends generated groups to
  nf-params.template.erb      # Ruby helpers + __NF_PARAMS_ENTRIES__ placeholder
  form.js                     # client-side form behavior (cache-reset-on-query-param, icons, etc.)
  manifest.yml / submit.yml.erb / view.html.erb
  template/before.sh.erb      # OOD batch-connect conn_params setup
  template/script.sh.erb      # the actual `nextflow run` launch script
landing_page_template/        # static assets for the generated landing page
  manifest.yml                # unparameterized; copied as-is
  index.template.html         # __SECTIONS__ splice point for per-subcategory cards
```

Each `<pipeline>-<version>` directory under a generated `--output` tree is a
full, independent OOD app copy — there's no shared runtime dependency
between generated apps beyond the site's `NF2OOD_ENV_FILE`.
