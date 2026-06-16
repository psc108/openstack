#!/bin/bash
#
# fix-route-hijack.sh
#
# Detects and fixes the case where an OpenStack Neutron bridge
# (e.g. brq*) has been left holding a duplicate IP address that
# was assigned via DHCP to the real network interface (e.g. wlp2s0),
# causing the kernel default route to point at a dead/no-carrier
# bridge instead of the live NIC.
#
# Usage:
#   ./fix-route-hijack.sh                # check + fix if needed
#   ./fix-route-hijack.sh --check-only   # report only, no changes
#   ./fix-route-hijack.sh --iface wlp2s0 --test-host 13.40.249.25
#
set -euo pipefail

REAL_IFACE="wlp2s0"
TEST_HOST="1.1.1.1"
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check-only) CHECK_ONLY=1; shift ;;
        --iface) REAL_IFACE="$2"; shift 2 ;;
        --test-host) TEST_HOST="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

echo "== fix-route-hijack: checking routing for ${TEST_HOST} =="

# 1. What interface does the kernel currently think it should use?
ROUTE_LINE=$(ip route get "${TEST_HOST}" 2>/dev/null || true)
if [[ -z "${ROUTE_LINE}" ]]; then
    echo "ERROR: no route at all to ${TEST_HOST} (network unreachable)."
    NEED_DEFAULT_ROUTE=1
else
    echo "Current route: ${ROUTE_LINE}"
    ROUTE_IFACE=$(echo "${ROUTE_LINE}" | grep -oP 'dev \K\S+')
fi

# 2. Get the address/state of the real interface
REAL_INFO=$(ip addr show "${REAL_IFACE}" 2>/dev/null || true)
if [[ -z "${REAL_INFO}" ]]; then
    echo "ERROR: interface ${REAL_IFACE} not found."
    exit 1
fi

REAL_STATE=$(echo "${REAL_INFO}" | head -1 | grep -oP 'state \K\S+')
REAL_IP=$(echo "${REAL_INFO}" | grep -oP 'inet \K[0-9.]+/[0-9]+' | head -1)

if [[ -z "${REAL_IP}" ]]; then
    echo "ERROR: ${REAL_IFACE} has no IPv4 address — is it connected/DHCP'd?"
    exit 1
fi

REAL_IP_ADDR="${REAL_IP%%/*}"
REAL_IP_PREFIX="${REAL_IP##*/}"

echo "Real interface ${REAL_IFACE}: state=${REAL_STATE}, ip=${REAL_IP}"

# 3. Find any OTHER interface (typically brq*) holding the same IP
CONFLICT_IFACE=""
while read -r ifname; do
    [[ "${ifname}" == "${REAL_IFACE}" ]] && continue
    IFACE_INFO=$(ip addr show "${ifname}" 2>/dev/null || true)
    if echo "${IFACE_INFO}" | grep -q "inet ${REAL_IP_ADDR}/"; then
        CONFLICT_IFACE="${ifname}"
        CONFLICT_STATE=$(echo "${IFACE_INFO}" | head -1 | grep -oP 'state \K\S+')
        break
    fi
done < <(ip -o link show | awk -F': ' '{print $2}')

if [[ -z "${CONFLICT_IFACE}" ]]; then
    echo "No conflicting interface found holding ${REAL_IP_ADDR}."
    if [[ -n "${ROUTE_IFACE:-}" && "${ROUTE_IFACE}" == "${REAL_IFACE}" ]]; then
        echo "Routing already correct via ${REAL_IFACE}. Nothing to do."
        exit 0
    fi
fi

if [[ -n "${CONFLICT_IFACE}" ]]; then
    echo "CONFLICT: ${CONFLICT_IFACE} (state=${CONFLICT_STATE}) also holds ${REAL_IP_ADDR}"
fi

if [[ "${ROUTE_IFACE:-}" != "${REAL_IFACE}" ]] || [[ -n "${CONFLICT_IFACE}" ]] || [[ -n "${NEED_DEFAULT_ROUTE:-}" ]]; then
    echo "==> Issue detected: default route is not using ${REAL_IFACE} correctly."
else
    echo "==> No issue detected."
    exit 0
fi

if [[ "${CHECK_ONLY}" -eq 1 ]]; then
    echo "(--check-only set, not making changes)"
    exit 2
fi

echo "== Applying fix =="

# Remove the duplicate address from the conflicting (typically dead) bridge
if [[ -n "${CONFLICT_IFACE}" ]]; then
    echo "Removing ${REAL_IP} from ${CONFLICT_IFACE}..."
    sudo ip addr del "${REAL_IP}" dev "${CONFLICT_IFACE}" || true
fi

# Re-add subnet route on the real interface if missing
SUBNET=$(ip route show | grep "dev ${REAL_IFACE}" | grep -oP '^\S+/[0-9]+' | head -1 || true)
if [[ -z "${SUBNET}" ]]; then
    SUBNET="${REAL_IP_ADDR%.*}.0/${REAL_IP_PREFIX}"
    echo "Re-adding subnet route ${SUBNET} dev ${REAL_IFACE}..."
    sudo ip route add "${SUBNET}" dev "${REAL_IFACE}" src "${REAL_IP_ADDR}" || true
fi

# Re-add default route via the real interface if missing
if ! ip route show default | grep -q "dev ${REAL_IFACE}"; then
    GW=$(ip route show "${SUBNET}" 2>/dev/null | grep -oP 'via \K\S+' || true)
    if [[ -z "${GW}" ]]; then
        # derive gateway as .1 of the subnet (common default)
        GW="${REAL_IP_ADDR%.*}.1"
    fi
    echo "Re-adding default route via ${GW} dev ${REAL_IFACE}..."
    sudo ip route add default via "${GW}" dev "${REAL_IFACE}" || true
fi

echo "== Re-checking =="
ip route get "${TEST_HOST}"

echo "Done."
