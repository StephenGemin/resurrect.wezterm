#!/usr/bin/env bash
# Copy saved state from MLFlexer's original resurrect.wezterm into this fork's
# default state directory. macOS/Linux only — see migrate-from-mlflexer.ps1 for Windows.
#
# Non-destructive: only copies files, never deletes or overwrites. Does not touch
# your wezterm.lua — update the `wezterm.plugin.require(...)` URL yourself.
#
# Always prints a full diagnostic report. If anything looks wrong, paste the whole
# output into a GitHub issue — that's the intent, no need to reproduce locally.

set -euo pipefail
shopt -s nullglob nocaseglob

SCRIPT_VERSION="1.0.0"
COPIED=0
SKIPPED=0
OLD_DIRS_FOUND=0

log_ok()   { printf '[OK]   %s\n' "$1"; }
log_skip() { printf '[SKIP] %s\n' "$1"; }
log_info() { printf '[INFO] %s\n' "$1"; }
log_fail() { printf '[FAIL] %s\n' "$1" >&2; }

on_error() {
	local exit_code=$?
	log_fail "unexpected error at line ${BASH_LINENO[0]} (exit code ${exit_code}): ${BASH_COMMAND}"
	print_summary "FAILED"
	exit "${exit_code}"
}
trap on_error ERR

print_summary() {
	local status="$1"
	echo
	echo "===== Migration Report ====="
	echo "status:            ${status}"
	echo "old plugin dirs:   ${OLD_DIRS_FOUND}"
	echo "new state dir:     ${NEW_STATE_DIR:-<not resolved>}"
	echo "files copied:      ${COPIED}"
	echo "files skipped:     ${SKIPPED} (already present at destination)"
	echo
	echo "next steps:"
	echo "  1. In your wezterm.lua, point require() at this fork:"
	echo "       wezterm.plugin.require(\"https://github.com/StephenGemin/resurrect.wezterm\")"
	echo "  2. Restart WezTerm (or run wezterm.reload_configuration())."
	echo "  3. Once you've confirmed your old sessions show up via the fuzzy restore picker,"
	echo "     you can delete the old MLFlexer plugin directory manually."
	echo "============================="
	echo "If something looks wrong, paste this whole output into a GitHub issue."
}

echo "===== resurrect.wezterm migrate-from-mlflexer.sh v${SCRIPT_VERSION} ====="
echo "[INFO] date:        $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '<unavailable>')"
echo "[INFO] uname -a:    $(uname -a 2>/dev/null || echo '<unavailable>')"
echo "[INFO] bash:        ${BASH_VERSION:-<unavailable>}"
echo "[INFO] HOME:        ${HOME:-<unset>}"
echo "[INFO] XDG_DATA_HOME: ${XDG_DATA_HOME:-<unset>}"
if command -v wezterm >/dev/null 2>&1; then
	echo "[INFO] wezterm:     $(wezterm --version 2>/dev/null || echo '<version query failed>')"
else
	echo "[INFO] wezterm:     <not found on PATH>"
fi
echo

OS="$(uname -s 2>/dev/null || echo 'unknown')"
case "${OS}" in
Darwin)
	PLUGINS_DIR="${HOME}/Library/Application Support/wezterm/plugins"
	NEW_STATE_DIR="${HOME}/Library/Application Support/wezterm/resurrect"
	;;
Linux)
	DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
	PLUGINS_DIR="${DATA_HOME}/wezterm/plugins"
	NEW_STATE_DIR="${DATA_HOME}/wezterm/resurrect"
	;;
*)
	log_fail "unsupported OS '${OS}'. This script supports macOS and Linux; use migrate-from-mlflexer.ps1 on Windows."
	print_summary "UNSUPPORTED_OS"
	exit 1
	;;
esac

log_info "OS detected:        ${OS}"
log_info "plugins directory:  ${PLUGINS_DIR}"
log_info "new state directory: ${NEW_STATE_DIR}"
echo

if [ ! -d "${PLUGINS_DIR}" ]; then
	log_info "plugins directory does not exist yet — nothing to migrate."
	print_summary "NOTHING_TO_MIGRATE"
	exit 0
fi

# WezTerm encodes the require() URL into the clone directory name (including "."),
# so match loosely rather than assuming "resurrect.wezterm" appears literally.
OLD_PLUGIN_DIRS=("${PLUGINS_DIR}"/*MLFlexer*resurrect*)

if [ "${#OLD_PLUGIN_DIRS[@]}" -eq 0 ]; then
	log_info "no MLFlexer plugin directory found under ${PLUGINS_DIR} — nothing to migrate."
	print_summary "NOTHING_TO_MIGRATE"
	exit 0
fi

for old_dir in "${OLD_PLUGIN_DIRS[@]}"; do
	log_info "found old plugin dir: ${old_dir}"
	old_state_dir="${old_dir}/state"

	if [ ! -d "${old_state_dir}" ]; then
		log_info "no state/ subdirectory in ${old_dir} — skipping."
		continue
	fi

	OLD_DIRS_FOUND=$((OLD_DIRS_FOUND + 1))

	for type in workspace window tab; do
		src_dir="${old_state_dir}/${type}"
		[ -d "${src_dir}" ] || { log_info "no ${src_dir}, skipping ${type}"; continue; }

		dest_dir="${NEW_STATE_DIR}/${type}"
		mkdir -p "${dest_dir}"

		files=("${src_dir}"/*.json)
		if [ "${#files[@]}" -eq 0 ]; then
			log_info "no *.json files in ${src_dir}"
			continue
		fi

		for f in "${files[@]}"; do
			base="$(basename "${f}")"
			dest="${dest_dir}/${base}"
			if [ -e "${dest}" ]; then
				log_skip "${type}/${base} (already exists at destination)"
				SKIPPED=$((SKIPPED + 1))
			else
				cp -p "${f}" "${dest}"
				log_ok "${type}/${base} -> ${dest}"
				COPIED=$((COPIED + 1))
			fi
		done
	done
done

print_summary "SUCCESS"
