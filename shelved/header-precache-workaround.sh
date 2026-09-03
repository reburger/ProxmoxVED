#!/usr/bin/env bash
# ==============================================================================
# SHELVED WORKAROUND: Development Header Pre-Caching
# ==============================================================================
#
# Context:
# In community-scripts, get_header() in community-scripts/core hardcodes lookups
# to https://raw.githubusercontent.com/community-scripts/core/main/headers/ct/<appname>.
# When developing new scripts in a fork (e.g. reburger/ProxmoxVED), the header
# does not exist in core/main yet, causing a brief "curl 404" flash on screen
# before _cs_clear wipes it, resulting in no ASCII header display.
#
# Once a PR is merged upstream into community-scripts, CI syncs the header into
# the core repo, making this workaround unnecessary.
#
# If you need to test the ASCII header in a standalone fork prior to upstream merge,
# insert this block immediately before `header_info "$APP"` in ct/<appname>.sh:
#
# ------------------------------------------------------------------------------

# For ct/dotnetxaspwebapi.sh:
_hdr_cache="$(declare -f community_scripts_dir >/dev/null 2>&1 && community_scripts_dir || echo /usr/local/community-scripts)/headers/ct/dotnetxaspwebapi"
if [[ ! -s "$_hdr_cache" ]]; then
  mkdir -p "$(dirname "$_hdr_cache")" 2>/dev/null || true
  if [[ -f "$(dirname "${BASH_SOURCE[0]}")/headers/dotnetxaspwebapi" ]]; then
    cp "$(dirname "${BASH_SOURCE[0]}")/headers/dotnetxaspwebapi" "$_hdr_cache" 2>/dev/null || true
  else
    curl -fsSL "${COMMUNITY_SCRIPTS_URL:-https://raw.githubusercontent.com/reburger/ProxmoxVED/main}/ct/headers/dotnetxaspwebapi" -o "$_hdr_cache" 2>/dev/null || true
  fi
fi

# For ct/dotnetxaspwebapimulti.sh:
_hdr_cache="$(declare -f community_scripts_dir >/dev/null 2>&1 && community_scripts_dir || echo /usr/local/community-scripts)/headers/ct/dotnetxaspwebapimulti"
if [[ ! -s "$_hdr_cache" ]]; then
  mkdir -p "$(dirname "$_hdr_cache")" 2>/dev/null || true
  if [[ -f "$(dirname "${BASH_SOURCE[0]}")/headers/dotnetxaspwebapimulti" ]]; then
    cp "$(dirname "${BASH_SOURCE[0]}")/headers/dotnetxaspwebapimulti" "$_hdr_cache" 2>/dev/null || true
  else
    curl -fsSL "${COMMUNITY_SCRIPTS_URL:-https://raw.githubusercontent.com/reburger/ProxmoxVED/main}/ct/headers/dotnetxaspwebapimulti" -o "$_hdr_cache" 2>/dev/null || true
  fi
fi
