#!/usr/bin/env bash
#
# Pre-install every Nextflow plugin the staged nf-core pipelines declare into
# one shared, read-only plugin directory, so pipelines run fully offline
# (NXF_OFFLINE=true) on compute nodes -- including for users who have never
# run Nextflow before and have an empty NXF_HOME.
#
# Generated OOD apps point NXF_PLUGINS_DIR at this directory (NF2OOD_PLUGINS_DIR
# in nf2ood.env); it is deliberately not set for general CLI use. Run this
# script after staging a new pipeline with download_nfcore_pipeline.sh. It
# needs outbound internet: run it on a login node or an xfer job.
#
# Each plugin is installed into a scratch staging dir first, smoke-tested by
# loading it in an offline `nextflow run`, and only then moved into place.
# A half-downloaded or half-extracted plugin therefore never lands in the
# shared dir (Nextflow trusts any existing plugin dir and never re-fetches
# it -- a partial nf-schema-2.7.2 install caused
# "Class definition not found: nextflow/validation/ValidationObserver").

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${NF2OOD_ENV_FILE:-${SCRIPT_DIR}/nf2ood.env}"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

pipeline_root="${NF2OOD_PIPELINE_ROOT:-/gpfs_backup/bioinfo_data/nf-core_ood/pipelines}"
plugins_dir="${NF2OOD_PLUGINS_DIR:-}"
nextflow_module="${NF2OOD_MODULE_NAME-nextflow}"
nextflow_version="${NF2OOD_NEXTFLOW_VERSION:-26.04.3}"
# Nextflow core plugins that pipelines load implicitly rather than via a
# plugins {} block -- e.g. nf-amazon whenever a config references an s3://
# path (the igenomes_base default in sarek, rnaseq, ...). Their versions are
# pinned by the Nextflow release itself; for a new Nextflow version, read
# them off the "core-plugins:" line near the top of any .nextflow.log.
extra_plugins="${NF2OOD_EXTRA_PLUGINS:-nf-amazon@3.9.1}"
force=0
check_only=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Installs every plugin declared by pipelines under the pipeline root (plus
NF2OOD_EXTRA_PLUGINS) into the shared plugin directory.

Options:
      --pipeline-root PATH  Staged pipelines (default: ${pipeline_root})
      --plugins-dir PATH    Shared plugin dir (default: ${plugins_dir})
      --extra LIST          Extra comma-separated plugin ids (default: ${extra_plugins})
      --force               Reinstall plugins that are already present
      --check               Only smoke-test what is already installed
  -h, --help                Show this help
EOF
}

while (($# > 0)); do
  case "$1" in
    --pipeline-root) pipeline_root="$2"; shift 2 ;;
    --plugins-dir)   plugins_dir="$2"; shift 2 ;;
    --extra)         extra_plugins="$2"; shift 2 ;;
    --force)         force=1; shift ;;
    --check)         check_only=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "${plugins_dir}" ]] || { echo "ERROR: set NF2OOD_PLUGINS_DIR in nf2ood.env or pass --plugins-dir" >&2; exit 1; }
[[ -d "${pipeline_root}" ]] || { echo "ERROR: pipeline root not found: ${pipeline_root}" >&2; exit 1; }

if [[ $(type -t module || true) == "function" && -n "${nextflow_module}" ]]; then
  module load "${nextflow_module}/${nextflow_version}"
fi
command -v nextflow >/dev/null || { echo "ERROR: nextflow not on PATH" >&2; exit 1; }

export NXF_DISABLE_CHECK_LATEST=true

# Plugin ids from each pipeline's plugins { id 'name@version' } block.
declared_plugins() {
  local config
  for config in "${pipeline_root}"/*/*/*/nextflow.config; do
    [[ -f "${config}" ]] || continue
    awk '/^[[:space:]]*plugins[[:space:]]*\{/ {in_block=1}
         in_block {print}
         in_block && /\}/ {in_block=0}' "${config}" \
      | grep -oE "id[[:space:](]+['\"][^'\"]+['\"]" \
      | sed -E "s/^id[[:space:](]+['\"]//; s/['\"]\$//" \
      | sed "s|\$|\t${config#"${pipeline_root}"/}|"
  done
}

# Load one plugin in an offline no-op run. Nextflow starts every plugin and
# its observer factories at session init, so a missing class fails here.
smoke_test() {
  local id="$1" dir="$2" tmp rc=0
  local dist="${NXF_DIST:-${NXF_HOME:-${HOME}/.nextflow}/framework}"
  tmp="$(mktemp -d)"
  printf 'workflow { }\n' > "${tmp}/main.nf"
  printf "plugins { id '%s' }\n" "${id}" > "${tmp}/nextflow.config"
  (
    cd "${tmp}"
    NXF_OFFLINE=true NXF_PLUGINS_DIR="${dir}" NXF_HOME="${tmp}/home" \
      NXF_DIST="${dist}" nextflow -q run main.nf >"${tmp}/out.log" 2>&1
  ) || rc=$?
  if ((rc != 0)); then
    echo "    smoke test FAILED for ${id}:" >&2
    sed 's/^/      /' "${tmp}/out.log" >&2
  fi
  rm -rf "${tmp}"
  return "${rc}"
}

mapfile -t declared < <(declared_plugins)
ids=()
for line in "${declared[@]}"; do
  id="${line%%$'\t'*}"
  if [[ "${id}" != *@* ]]; then
    echo "WARN: ${line#*$'\t'} declares '${id}' without a version; installing" \
         "the latest release. Offline runs can only resolve it if exactly that" \
         "version is present -- consider pinning it." >&2
  fi
  ids+=("${id}")
done
IFS=',' read -ra extra_ids <<< "${extra_plugins}"
ids+=("${extra_ids[@]}")
mapfile -t ids < <(printf '%s\n' "${ids[@]}" | sed '/^$/d' | sort -u)

echo "Plugin dir : ${plugins_dir}"
echo "Plugins    : ${ids[*]}"

failed=0

if ((check_only)); then
  for id in "${ids[@]}"; do
    echo "--> checking ${id}"
    smoke_test "${id}" "${plugins_dir}" || failed=1
  done
  exit "${failed}"
fi

mkdir -p "${plugins_dir}"
# Stage beside the destination so the final mv is a same-filesystem rename.
staging="$(mktemp -d "${plugins_dir}/.staging.XXXXXX")"
trap 'rm -rf "${staging}"' EXIT

for id in "${ids[@]}"; do
  if [[ "${id}" == *@* && -d "${plugins_dir}/${id/@/-}" ]] && ((! force)); then
    echo "--> ${id}: already installed, skipping (use --force to reinstall)"
    continue
  fi
  echo "--> ${id}: installing"
  before="$(ls "${staging}")"
  if ! NXF_PLUGINS_DIR="${staging}" nextflow plugin install "${id}"; then
    echo "    install FAILED for ${id}" >&2
    failed=1
    continue
  fi
  if ! smoke_test "${id}" "${staging}"; then
    failed=1
    continue
  fi
  # Move every dir this install created (the plugin plus any dependency).
  for new in $(comm -13 <(echo "${before}") <(ls "${staging}")); do
    [[ -d "${staging}/${new}" ]] || continue
    if [[ -d "${plugins_dir}/${new}" ]]; then
      if ((force)); then
        mv "${plugins_dir}/${new}" "${staging}/${new}.old"
      else
        continue
      fi
    fi
    chmod -R u+rwX,go+rX,go-w "${staging}/${new}"
    mv "${staging}/${new}" "${plugins_dir}/${new}"
    echo "    installed ${plugins_dir}/${new}"
  done
done

echo
echo "Final check of the shared plugin dir:"
for id in "${ids[@]}"; do
  if smoke_test "${id}" "${plugins_dir}"; then
    echo "  OK   ${id}"
  else
    echo "  FAIL ${id}"
    failed=1
  fi
done

exit "${failed}"
