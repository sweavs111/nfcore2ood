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
with_testdata="false"
testdata_branch=""
testdata_repo_url="${NF2OOD_TESTDATA_REPO_URL:-https://github.com/nf-core/test-datasets.git}"

usage() {
  cat <<EOF
Usage: $(basename "$0") --name PIPELINE --revision VERSION [options]

Options:
  -n, --name PIPELINE         nf-core pipeline name without the nf-core- prefix
  -r, --revision VERSION      nf-core pipeline revision
      --install-root PATH     Base install root
      --configs-dir PATH      Central configs directory to symlink
                               Maintain configs once here for all pipelines
      --container-engine NAME Container engine for nf-core download
      --engine-module NAME    Module name for the container engine
      --nfcore-module NAME    Module name for nf-core
      --with-testdata         Also clone nf-core/test-datasets so the
                               generated app's "Run pipeline's built-in test
                               profile" checkbox can run offline (compute
                               nodes typically have no outbound internet).
                               See gen_local_testconfig.py.
      --testdata-branch NAME  test-datasets branch to clone (default: looked
                               up in pipeline2testbranch.tsv, falling back to
                               PIPELINE). Only meaningful with --with-testdata.
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
    --with-testdata)
      with_testdata="true"
      shift
      ;;
    --testdata-branch)
      testdata_branch="$2"
      shift 2
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

# install_root defaults to the parent of NF2OOD_PIPELINE_ROOT when not set
# via --install-root. NF2OOD_PIPELINE_ROOT is required (no Tufts-flavored
# fallback) so misconfigured sites fail fast with a clear message.
if [[ -z "${install_root}" ]]; then
  if [[ -z "${NF2OOD_PIPELINE_ROOT:-}" ]]; then
    echo "Error: NF2OOD_PIPELINE_ROOT is not set and --install-root was not given." >&2
    echo "       Run 'source ./nf2ood.env' (after 'cp nf2ood.env.example nf2ood.env')." >&2
    exit 1
  fi
  install_root="$(dirname "${NF2OOD_PIPELINE_ROOT}")"
fi

# Configs are maintained centrally under <install_root>/configs.
# Each downloaded pipeline replaces its local configs directory with a symlink
# to that shared copy so site updates only need to happen in one place.
if [[ -z "${configs_dir}" ]]; then
  configs_dir="${install_root}/configs"
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

pipeline_dir="${install_root}/pipelines/nf-core-${pipeline_name}"
version_dir="${pipeline_dir}/${revision}"
cache_dir="${install_root}/singularity-images"

#export NXF_SINGULARITY_CACHEDIR="${cache_dir}"
export NXF_SINGULARITY_CACHEDIR="$NF2OOD_SINGULARITY_CACHEDIR"

# Sites that run `nf-core` via a Singularity/Apptainer wrapper (e.g. an
# environment-modules container wrapper) only auto-bind the current working
# directory into the container - everything else is read-only. That leaves
# NF2OOD_SINGULARITY_CACHEDIR unwritable (and even invisible) inside the
# container whenever it isn't a descendant of pipeline_dir, which is where
# we `cd` to below. Explicitly bind both trees so nf-core can write to
# either, without clobbering any bind path the site/user already set.
bind_paths="${install_root}"
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

# ---------------------------------------------------------------------------
# --with-testdata: stage a local clone of nf-core/test-datasets so the
# generated app's built-in test profile can run without outbound internet.
# Kept as plain functions (rather than a separate script) since it shares
# SCRIPT_DIR/pipeline_name/install_root with the rest of this file and has
# no reason to run on its own.
# ---------------------------------------------------------------------------
lookup_testdata_branch() {
  # pipeline2testbranch.tsv maps a pipeline name to its nf-core/test-datasets
  # branch when the two names differ. Falls back to the pipeline name itself,
  # which is correct for most pipelines (e.g. rnaseq -> rnaseq branch).
  local pipeline_name=$1
  local tsv="${SCRIPT_DIR}/pipeline2testbranch.tsv"
  local key value
  if [[ -f "${tsv}" ]]; then
    while IFS=$'\t' read -r key value _; do
      key=${key//$'\r'/}
      [[ -z "${key//[[:space:]]/}" || "${key:0:1}" == "#" ]] && continue
      if [[ "${key,,}" == "${pipeline_name,,}" ]]; then
        printf '%s\n' "${value//$'\r'/}"
        return 0
      fi
    done < "${tsv}"
  fi
  printf '%s\n' "${pipeline_name}"
}

stage_testdata() {
  local pipeline_name=$1
  local install_root=$2
  local branch=$3
  local repo_url=$4

  if [[ -z "${branch}" ]]; then
    branch="$(lookup_testdata_branch "${pipeline_name}")"
  fi

  local testdata_root="${NF2OOD_TESTDATA_ROOT:-${install_root}/testdata}"
  local testdata_dir="${testdata_root}/${pipeline_name}"

  echo "Staging local test data: nf-core/test-datasets@${branch} -> ${testdata_dir}"
  mkdir -p "${testdata_root}"

  if [[ -d "${testdata_dir}/.git" ]]; then
    git -C "${testdata_dir}" fetch origin "${branch}"
    git -C "${testdata_dir}" checkout -q "${branch}"
    git -C "${testdata_dir}" reset --hard "origin/${branch}"
  else
    rm -rf "${testdata_dir}"
    git clone --single-branch --branch "${branch}" "${repo_url}" "${testdata_dir}"
  fi

  # A pipeline's conf/test.config can pin a param to a commit that isn't
  # part of its own test-datasets branch at all (nf-core/rnaseq's kraken_db
  # is the known example -- it lives on a different branch's history). List
  # such one-off URLs in testdata-extra/<pipeline_name>.tsv (one URL per
  # line) and they're fetched here, preserving the URL's own path under
  # testdata_dir -- gen_local_testconfig.py's URL rewrite doesn't need to
  # know these came from a different place than the branch clone.
  local extra_tsv="${SCRIPT_DIR}/testdata-extra/${pipeline_name}.tsv"
  if [[ -f "${extra_tsv}" ]]; then
    echo "Fetching extra test assets listed in ${extra_tsv}"
    local url rel_path dest
    while IFS= read -r url; do
      url=${url//$'\r'/}
      [[ -z "${url}" || "${url:0:1}" == "#" ]] && continue
      rel_path="${url#https://raw.githubusercontent.com/nf-core/test-datasets/}"
      rel_path="${rel_path#*/}" # strip the leading <branch-or-sha>/ segment
      dest="${testdata_dir}/${rel_path}"
      mkdir -p "$(dirname "${dest}")"
      echo "  ${url} -> ${dest}"
      curl -fL -o "${dest}" "${url}"
    done < "${extra_tsv}"
  fi

  chmod -R 775 "${testdata_dir}" || true
}

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
fi

chmod -R 775 "${version_dir}"
if [[ -d "${cache_dir}" ]]; then
  chmod -R 775 "${cache_dir}"
fi

if [[ "${with_testdata}" == "true" ]]; then
  stage_testdata "${pipeline_name}" "${install_root}" "${testdata_branch}" "${testdata_repo_url}"
fi

echo "Done"
