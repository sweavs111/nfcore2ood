# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo does

`nf2ood` generates Open OnDemand (OOD) batch-connect apps from locally
downloaded nf-core pipelines. It has two stages, kept deliberately separate:

1. `download_nfcore_pipeline.sh` downloads an nf-core pipeline/revision into
   a local pipeline tree (via `nf-core pipelines download`) and symlinks each
   pipeline's `configs/` to a shared, centrally-maintained copy. With
   `--with-testdata`, it also clones that pipeline's nf-core/test-datasets
   branch (`pipeline2testbranch.tsv` maps pipeline -> branch when they
   differ) into `NF2OOD_TESTDATA_ROOT/<pipeline>`, plus any one-off URLs in
   `testdata-extra/<pipeline>.tsv` for params pinned to a commit outside
   that branch.
2. `nf2ood` scans that pipeline tree, finds each `nextflow_schema.json`, and
   generates one OOD batch-connect app directory per pipeline version. If a
   `--with-testdata` clone exists for the pipeline, it also runs
   `gen_local_testconfig.py` to rewrite that pipeline's `conf/test.config`
   (and the samplesheet its `input` param points at) into a local,
   network-free `local_test.config` bundled into the app -- see "Offline
   test profile" below.

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

`nf2ood` validates three **REQUIRED** env vars up front and dies with a
clear message if unset (`validate_environment`): `NF2OOD_PIPELINE_ROOT`,
`NF2OOD_SINGULARITY_CACHEDIR`, `NF2OOD_PARTITION_YML`. `NF2OOD_SLURM_PROFILE`
is **SOFT (warn)** — falls back to `default` with a one-shot warning. Every
other `NF2OOD_*` var (`NF2OOD_CLUSTER`, `NF2OOD_DEFAULT_DIRECTORY`,
`NF2OOD_MODULE_NAME`, `NF2OOD_CONTAINER_MODULE`, `NF2OOD_ENV_FILE`) is
**SOFT** with a safe cross-site default via `config_value()`. Module name
vars use `${VAR-default}` (no colon) specifically so an explicit empty
string means "skip this `module load`" — see the comment in
`nf2ood:customize_generated_app`. When adding a new site-configurable value,
follow this same three-tier pattern and document it in both
`nf2ood.env.example` and the README's Configuration reference table.

The generated `template/script.sh.erb` re-sources `NF2OOD_ENV_FILE` **at job
runtime** on the compute node (falling back to the `__TOKEN__` baked in at
generation time if that file isn't there/readable) — this is how a site can
change e.g. `NF2OOD_SLURM_PROFILE` without regenerating every app, as long
as the same env file path is visible from both the OOD host and compute
nodes.

### Offline test profile

Every generated app has a "Run pipeline's built-in test profile" checkbox
(`use_test_profile` in `form.template.erb`, wired up in `script.sh.erb`).
nf-core's own `-profile test` pulls its dataset from
`raw.githubusercontent.com/nf-core/test-datasets`, which fails on sites
where compute nodes have no outbound internet.

`gen_local_testconfig.py` closes that gap when a pipeline was downloaded
with `--with-testdata`: it regex-rewrites every
`raw.githubusercontent.com/nf-core/test-datasets/<ref>/...` URL in the
pipeline's `conf/test.config` to the matching local path under
`NF2OOD_TESTDATA_ROOT/<pipeline>`, recursing once into the samplesheet the
`input` param points at (which embeds the same URL pattern for per-sample
fastq columns). `nf2ood` calls it per app (`stage_local_testconfig`) and
writes the result to `template/local_test.config`, a no-op if no local
clone exists for that pipeline. At runtime, `script.sh.erb` uses
`local_test.config` via `-c` and drops `test` from `-profile` when the file
is present; otherwise it falls back to `-profile test` unchanged. Because
the rewrite is a generic URL substitution rather than a per-pipeline
mapping, it works for any pipeline once `--with-testdata` has staged its
branch -- the one documented exception is a param pinned to a commit
outside that branch (nf-core/rnaseq's `kraken_db`), handled via
`testdata-extra/<pipeline>.tsv`.

### Subcategory mapping

`determine_subcategory` (in `nf2ood`) looks up the pipeline name in
`pipeline2subcategory.tsv` (`-s/--subcategory-map` to override); falls back
to the pipeline slug for `nf-core-*` names or `bioinformatics` otherwise.
`pipeline2image.tsv` maps pipeline names to a workflow diagram URL for
`view.html.erb`; both are simple two-column TSVs read with the same
`lookup_tsv_value` bash helper (case-insensitive key match, `#`-comments).

## Repository layout

```
nf2ood                        # orchestrator (bash)
json2ood.py                   # schema -> form.yml.erb / nf-params.json.erb
customize_app.py              # __TOKEN__ substitution over the app dir
gen_local_testconfig.py       # conf/test.config -> offline local_test.config
download_nfcore_pipeline.sh   # stage 1: nf-core pipeline downloader (+ --with-testdata)
nf2ood.env.example            # checked-in site config template (nf2ood.env is gitignored)
pipeline2subcategory.tsv      # pipeline -> OOD subcategory
pipeline2image.tsv            # pipeline -> workflow diagram URL (view.html.erb)
pipeline2testbranch.tsv       # pipeline -> nf-core/test-datasets branch (--with-testdata)
testdata-extra/<pipeline>.tsv # per-pipeline test asset URLs outside its test-datasets branch
nfcore_ood_template/          # the OOD batch-connect app template, copied per app
  form.template.erb           # static base fields json2ood.py appends generated groups to
  nf-params.template.erb      # Ruby helpers + __NF_PARAMS_ENTRIES__ placeholder
  form.js                     # client-side form behavior (cache-reset-on-query-param, icons, etc.)
  manifest.yml / submit.yml.erb / view.html.erb
  template/before.sh.erb      # OOD batch-connect conn_params setup
  template/script.sh.erb      # the actual `nextflow run` launch script
```

Each `<pipeline>-<version>` directory under a generated `--output` tree is a
full, independent OOD app copy — there's no shared runtime dependency
between generated apps beyond the site's `NF2OOD_ENV_FILE`.
