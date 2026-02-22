#!/bin/bash

set -eup pipefail

echo
echo "### Updating repo"
echo
git stash save
git pull --rebase
git stash pop

echo
echo "### Rebuilding container image"
echo
./build.sh
