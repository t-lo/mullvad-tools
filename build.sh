#!/bin/bash

# Subshell since we're changing directories
(
  cd "$(dirname "$0")"
  docker build -t mullvad .
)
