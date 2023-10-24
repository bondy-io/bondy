#!/bin/sh

export BONDY_ERL_NODENAME=bondy@${FLY_PRIVATE_IP}
export BONDY_REGION=${FLY_REGION}
export BONDY_HOST_ID=${FLY_MACHINE_ID}

# Disable swap
swapoff -a

