#!/bin/sh

set -eux

rm -f role_id
unset VAULT_ADDR
cd terraform
terraform init
terraform apply -auto-approve
sleep infinity
