#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${NF2OOD_ENV_FILE:-${SCRIPT_DIR}/nf2ood.env}"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

pipeline_name=""
revision=""
install_root=""
configs_dir=""
container_engine="${NF2OOD_CONTAINER_MODULE:-singularity}"
engine_module="${NFCORE_ENGINE_MODULE:-}"
nfcore_module="${NFCORE_MODULE_NAME:-nf-core}"
patch_dir="${NF2OOD_PATCH_DIR-${SCRIPT_DIR}/site/patches}"
patches_only=0

usage() {
  cat <<EOF
Usage: $(basename "$0") --name PIPELINE --revision VERSION [options]

Options:
  -n, --name PIPELINE         nf-core pipeline name without the nf-core- prefix
  -r, --revision VERSION      nf-core pipeline revision
      --install-root PATH     Legacy single-tree layout: download into
                               PATH/pipelines and use PATH/configs
                               (default: NF2OOD_PIPELINE_ROOT and
                               NF2OOD_CUSTOM_CONFIG_BASE from nf2ood.env)
      --configs-dir PATH      Central configs directory to symlink
                               Maintain configs once here for all pipelines
                               (default: NF2OOD_CUSTOM_CONFIG_BASE)
      --container-engine NAME Container engine for nf-core download
      --engine-module NAME    Module name for the container engine
      --nfcore-module NAME    Module name for nf-core
      --patch-dir PATH        Site patches to apply after download, as
                               PATH/<name>/<revision>/*.patch
                               (default: NF2OOD_PATCH_DIR, else
                               site/patches next to this script; "" = none)
      --patches-only          Skip the download; only apply site patches to
                               an already-downloaded --name/--revision
  -h, --help                  Show this help
EOF
}

while (($# > 0)); do
  case "$1" in
    -n|--name)
      pipeline_name="$2"
      shift 2
      ;;
    -r|--revision)
      revision="$2"
      shift 2
      ;;
    --install-root)
      install_root="$2"
      configs_dir="${install_root}/configs"
      shift 2
      ;;
    --configs-dir)
      configs_dir="$2"
      shift 2
      ;;
    --container-engine)
      container_engine="$2"
      shift 2
      ;;
    --engine-module)
      engine_module="$2"
      shift 2
      ;;
    --nfcore-module)
      nfcore_module="$2"
      shift 2
      ;;
    --patch-dir)
      patch_dir="$2"
      shift 2
      ;;
    --patches-only)
      patches_only=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${pipeline_name}" || -z "${revision}" ]]; then
  echo "Both --name and --revision are required." >&2
  usage
  exit 1
fi

# Every path comes straight from its own nf2ood.env variable rather than being
# guessed as a sibling of NF2OOD_PIPELINE_ROOT, so pipelines, configs and the
# container cache can live on different filesystems (e.g. pipelines under
# /usr/local/usrapps while configs and containers stay on /gpfs_backup).
# NF2OOD_PIPELINE_ROOT is required (no Tufts-flavored fallback) so
# misconfigured sites fail fast with a clear message. --install-root keeps
# the old single-tree layout (<root>/pipelines, <root>/configs) available.
if [[ -n "${install_root}" ]]; then
  pipeline_root="${install_root}/pipelines"
elif [[ -n "${NF2OOD_PIPELINE_ROOT:-}" ]]; then
  pipeline_root="${NF2OOD_PIPELINE_ROOT}"
else
  echo "Error: NF2OOD_PIPELINE_ROOT is not set and --install-root was not given." >&2
  echo "       Run 'source ./nf2ood.env' (after 'cp nf2ood.env.example nf2ood.env')." >&2
  exit 1
fi

# Configs are maintained centrally in one place -- by default the same local
# nf-core/configs checkout the generated apps pass as --custom_config_base.
# Each downloaded pipeline replaces its local configs directory with a symlink
# to that shared copy so site updates only need to happen in one place.
# NF2OOD_CUSTOM_CONFIG_BASE may be a URL on sites without a local mirror;
# there is nothing to symlink then.
if [[ -z "${configs_dir}" && "${NF2OOD_CUSTOM_CONFIG_BASE:-}" == /* ]]; then
  configs_dir="${NF2OOD_CUSTOM_CONFIG_BASE}"
fi

pipeline_dir="${pipeline_root}/nf-core-${pipeline_name}"
version_dir="${pipeline_dir}/${revision}"
# nf-core download puts the pipeline code in <revision>/<revision with _>/.
code_dir="${version_dir}/${revision//./_}"

# Site patches fix problems in a downloaded pipeline that config can't reach
# (e.g. a module's output declarations). Each patch is a unified diff
# relative to the pipeline code dir (patch -p1). Re-runnable: a patch that
# already reverses cleanly is skipped; one that neither applies nor reverses
# (e.g. a new revision changed the file) is an error, so a stale patch is
# never silently dropped.
apply_site_patches() {
  local dir="${patch_dir:+${patch_dir}/${pipeline_name}/${revision}}"
  [[ -n "${dir}" && -d "${dir}" ]] || return 0
  local patches=("${dir}"/*.patch)
  [[ -e "${patches[0]}" ]] || return 0
  [[ -d "${code_dir}" ]] || { echo "Error: pipeline code dir ${code_dir} not found; can't apply patches." >&2; return 1; }
  command -v patch >/dev/null 2>&1 || { echo "Error: 'patch' not found; can't apply ${dir}/*.patch." >&2; return 1; }
  local p
  for p in "${patches[@]}"; do
    if patch --dry-run -R -p1 -f -s -d "${code_dir}" < "${p}" >/dev/null 2>&1; then
      echo "Patch already applied: ${p}"
    elif patch --dry-run -p1 -f -s -d "${code_dir}" < "${p}" >/dev/null 2>&1; then
      patch -p1 -f -s --no-backup-if-mismatch -d "${code_dir}" < "${p}"
      echo "Applied patch: ${p}"
    else
      echo "Error: patch ${p} does not apply to ${code_dir}; update or remove it." >&2
      return 1
    fi
  done
}

if (( patches_only )); then
  apply_site_patches
  echo "Done"
  exit 0
fi

if command -v module >/dev/null 2>&1; then
  if [[ -n "${engine_module}" ]]; then
    module load "${engine_module}"
  elif ! command -v "${container_engine}" >/dev/null 2>&1; then
    echo "Warning: ${container_engine} not found on PATH and no --engine-module was provided." >&2
  fi

  if [[ -n "${nfcore_module}" ]] && ! command -v nf-core >/dev/null 2>&1; then
    module load "${nfcore_module}"
  fi
fi

if ! command -v nf-core >/dev/null 2>&1; then
  echo "nf-core command not found." >&2
  exit 1
fi

export NXF_SINGULARITY_CACHEDIR="$NF2OOD_SINGULARITY_CACHEDIR"

# Sites that run `nf-core` via a Singularity/Apptainer wrapper (e.g. an
# environment-modules container wrapper) only auto-bind the current working
# directory into the container - everything else is read-only. That leaves
# NF2OOD_SINGULARITY_CACHEDIR unwritable (and even invisible) inside the
# container whenever it isn't a descendant of pipeline_dir, which is where
# we `cd` to below. Explicitly bind both trees so nf-core can write to
# either, without clobbering any bind path the site/user already set.
bind_paths="${pipeline_root}"
if [[ -n "${NF2OOD_SINGULARITY_CACHEDIR:-}" ]]; then
  bind_paths="${bind_paths},${NF2OOD_SINGULARITY_CACHEDIR}"
fi
export APPTAINER_BINDPATH="${bind_paths}${APPTAINER_BINDPATH:+,${APPTAINER_BINDPATH}}"
export SINGULARITY_BINDPATH="${APPTAINER_BINDPATH}"

# `nf-core pipelines download` shells out to `nextflow inspect` to enumerate
# each pipeline's container images, which fully parses nextflow.config.
# Recent Nextflow releases default to the newer, stricter (v2) config/DSL
# parser, which rejects legacy Groovy constructs still shipped in many older
# nf-core pipeline revisions (e.g. `def check_max(obj, type) { ... }`) and is
# also more eager about validating *every* `includeConfig` in the file,
# including ones behind profiles that were never selected - some pipeline
# revisions ship a profile whose includeConfig path doesn't actually exist
# (e.g. nf-core/viralrecon 3.0.0's `test_full_sispa` profile), which only
# the stricter parser trips over. NFCORE_NXF_SYNTAX_PARSER lets a site pin
# the legacy parser for this download step without affecting the Nextflow
# version/parser used when pipelines actually run. Set explicitly to "" to
# leave Nextflow's own default in effect.
nxf_syntax_parser="${NFCORE_NXF_SYNTAX_PARSER-v1}"
if [[ -n "${nxf_syntax_parser}" ]]; then
  export NXF_SYNTAX_PARSER="${nxf_syntax_parser}"
fi

mkdir -p "${pipeline_dir}"
cd "${pipeline_dir}"

echo "Downloading nf-core/${pipeline_name} ${revision} to ${version_dir}"

nf-core pipelines download "${pipeline_name}" \
  -r "${revision}" \
  --outdir "${revision}" \
  -d 8 \
  -s "${container_engine}" \
  --force \
  -u amend \
  -x none

cd "${version_dir}"

if [[ -d "${configs_dir}" ]]; then
  echo "Using central configs from ${configs_dir}"
  rm -rf configs
  ln -s "${configs_dir}" configs
elif [[ -n "${configs_dir}" ]]; then
  echo "Warning: configs directory ${configs_dir} not found; leaving the pipeline's own configs in place." >&2
fi

apply_site_patches

chmod -R 775 "${version_dir}"

echo "Done"
