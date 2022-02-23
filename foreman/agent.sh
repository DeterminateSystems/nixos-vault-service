#!/bin/sh

set -eux


unset VAULT_ADDR
# Give terraform-apply-force.sh time to delete the role_id
sleep 0.1
while [ ! -f role_id ]; do
    sleep 0.1
done

vault agent -config=./agent-config.hcl
