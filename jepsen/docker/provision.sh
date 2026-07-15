#!/bin/bash
# Idempotent one-shot provisioner: install ssh on each node, install
# Java + Leiningen on the control container, drop in the shared ssh
# key. Safe to re-run.

set -e

docker compose exec --no-TTY control /root/shared/init-control.sh &
docker compose exec --no-TTY n1 /root/shared/init-node.sh &
docker compose exec --no-TTY n2 /root/shared/init-node.sh &
docker compose exec --no-TTY n3 /root/shared/init-node.sh &

wait
