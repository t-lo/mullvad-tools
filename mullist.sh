#!/bin/bash
# vim: ts=2 sw=2 et

set -euo pipefail
scriptdir="$(cd "$(dirname "$0")"; pwd;)"

function usage() {
  echo "Usage:"
  echo
  echo "  $0 [<peer>]"
  echo "    List all known peers."
  echo "    If <peer> was provided, list properties of <peer>."
  echo
  echo "  $0 help" 
  echo "    Print this help."
  echo
}
# --

case "${1:-}" in
  help|h|--help|-h) usage; exit;;
esac

docker run -i \
           --rm \
           mullvad list "${@}"
