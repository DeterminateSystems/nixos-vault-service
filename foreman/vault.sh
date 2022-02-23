#!/bin/sh

set -eux

exec vault server -dev -dev-root-token-id=abc123
