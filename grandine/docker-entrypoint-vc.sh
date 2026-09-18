#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R gdvalidator:gdvalidator /var/lib/grandine/validator
  exec gosu gdvalidator docker-entrypoint-vc.sh "$@"
fi


__normalize_int() {
  local v=$1
  if [[ "${v}" =~ ^[0-9]+$ ]]; then
    v=$((10#${v}))
  fi
  printf '%s' "${v}"
}


if [[ ! -f /var/lib/grandine/validator/wallet-password.txt ]]; then
  echo "Creating password for Grandine key wallet"
  head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1 > /var/lib/grandine/validator/wallet-password.txt
fi

if [[ "${NETWORK}" =~ ^https?:// ]]; then
  echo "Custom testnet at ${NETWORK}"
  repo=$(awk -F'/tree/' '{print $1}' <<< "${NETWORK}")
  branch=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f1)
  config_dir=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f2-)
  echo "This appears to be the ${repo} repo, branch ${branch} and config directory ${config_dir}."
  if [[ ! -d "/var/lib/grandine/validator/testnet/${config_dir}" ]]; then
    mkdir -p /var/lib/grandine/validator/testnet
    cd /var/lib/grandine/validator/testnet
    git init --initial-branch="${branch}"
    git remote add origin "${repo}"
    git config core.sparseCheckout true
    echo "${config_dir}" > .git/info/sparse-checkout
    git pull origin "${branch}"
  fi
  config_dir_path="/var/lib/grandine/validator/testnet/${config_dir}"
  __network="--configuration-directory=${config_dir_path} --network=custom"
else
  __network="--network=${NETWORK}"
fi

# CL_NODE may be a comma-separated failover list; Grandine takes the URLs space-separated
__beacon_nodes="--beacon-node-urls ${CL_NODE//,/ }"

# Check whether we should use MEV Boost
if [[ "${MEV_BOOST}" = "true" ]]; then
  __mev_boost="--builder-url ${MEV_NODE:-http://mev-boost:18550}"
  echo "MEV Boost enabled"
  build_factor="$(__normalize_int "${EPBS_BUILD_FACTOR}")"
  case "${build_factor}" in
    0)
      __mev_boost=""
      __mev_factor=""
      echo "Disabled MEV Boost because EPBS_BUILD_FACTOR is 0."
      echo "WARNING: This conflicts with MEV_BOOST true. Set factor in a range of 1 to 100"
      ;;
    [1-9]|[1-9][0-9])
      __mev_factor="--default-builder-boost-factor ${build_factor}"
      echo "Enabled MEV Build Factor of ${build_factor}"
      ;;
    100)
      __mev_factor="--default-builder-boost-factor 18446744073709551615"
      echo "Always prefer MEV builder blocks, EPBS_BUILD_FACTOR 100"
      ;;
    "")
      __mev_factor=""
      echo "Use default --default-builder-boost-factor"
      ;;
    *)
      __mev_factor=""
      echo "WARNING: EPBS_BUILD_FACTOR has an invalid value of \"${build_factor}\""
      ;;
  esac
else
  __mev_boost=""
  __mev_factor=""
fi

# Check whether we should enable doppelganger protection
if [[ "${DOPPELGANGER}" = "true" ]]; then
  __doppel="--detect-doppelgangers"
  echo "Doppelganger protection enabled, VC will pause for 2 epochs"
else
  __doppel=""
fi

# Web3signer URL
if [[ "${WEB3SIGNER}" = "true" ]]; then
  __w3s_url="--web3signer-urls ${W3S_NODE}"
  while true; do
    if curl -s -m 5 "${W3S_NODE}" &> /dev/null; then
        echo "web3signer is up, starting Grandine"
        break
    else
        echo "Waiting for web3signer to be reachable..."
        sleep 5
    fi
  done
else
  __w3s_url=""
fi

if [[ "${DEFAULT_GRAFFITI}" = "true" ]]; then
  __graffiti_args=()
else
  __graffiti_args=(--graffiti "${GRAFFITI}")
fi

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${__network} ${__beacon_nodes} ${__w3s_url} "${__graffiti_args[@]}" ${__mev_boost} ${__mev_factor} ${__doppel} ${VC_EXTRAS}
