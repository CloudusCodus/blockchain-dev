#!/usr/bin/env bash
# Runs terraform in terraform/ with the Hetzner API token from
# ~/.config/hcloud/token, so the token never appears on the command line.
#   scripts/tf.sh plan | apply | destroy | output
set -euo pipefail
cd "$(dirname "$0")/../terraform"
TF_VAR_hcloud_token=$(tr -d '\n\r ' < ~/.config/hcloud/token)
export TF_VAR_hcloud_token
exec terraform "$@"
