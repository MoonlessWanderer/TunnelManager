# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034
# Tunnel Manager — load libraries in dependency order.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '%s\n' "load.sh is a library and must be sourced." >&2
  exit 1
fi

if [[ -n "${TM_LOAD_LOADED:-}" ]]; then
  return 0
fi
TM_LOAD_LOADED=1

_tm_load_dir=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=common.sh
source "${_tm_load_dir}/common.sh"
# shellcheck source=validate.sh
source "${_tm_load_dir}/validate.sh"
# shellcheck source=config.sh
source "${_tm_load_dir}/config.sh"
# shellcheck source=preflight.sh
source "${_tm_load_dir}/preflight.sh"
# shellcheck source=plan.sh
source "${_tm_load_dir}/plan.sh"
# shellcheck source=options.sh
source "${_tm_load_dir}/options.sh"
# shellcheck source=os.sh
source "${_tm_load_dir}/os.sh"
# shellcheck source=net.sh
source "${_tm_load_dir}/net.sh"
# shellcheck source=firewall.sh
source "${_tm_load_dir}/firewall.sh"
# shellcheck source=wireguard.sh
source "${_tm_load_dir}/wireguard.sh"
# shellcheck source=gre.sh
source "${_tm_load_dir}/gre.sh"
# shellcheck source=haproxy.sh
source "${_tm_load_dir}/haproxy.sh"
# shellcheck source=forward.sh
source "${_tm_load_dir}/forward.sh"
# shellcheck source=tunnel.sh
source "${_tm_load_dir}/tunnel.sh"
# shellcheck source=apply.sh
source "${_tm_load_dir}/apply.sh"
# shellcheck source=backup.sh
source "${_tm_load_dir}/backup.sh"
# shellcheck source=health.sh
source "${_tm_load_dir}/health.sh"
# shellcheck source=service.sh
source "${_tm_load_dir}/service.sh"
# shellcheck source=update.sh
source "${_tm_load_dir}/update.sh"
# shellcheck source=bbr.sh
source "${_tm_load_dir}/bbr.sh"
# shellcheck source=usage.sh
source "${_tm_load_dir}/usage.sh"
# shellcheck source=menu.sh
source "${_tm_load_dir}/menu.sh"
# shellcheck source=dispatch.sh
source "${_tm_load_dir}/dispatch.sh"
