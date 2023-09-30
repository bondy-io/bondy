#!/bin/sh

ip=$NODE_IP
if [ -z $ip ]
then
  # if ip is empty, extract the IP associated with fly-local-6pn from /etc/hosts
  # "cut -f 1" gets the first field (separated by spaces/tabs) from each line
  ip=$(grep fly-local-6pn /etc/hosts | cut -f 1)
  # if ip is still empty (means fly-local-6pn was not found in /etc/hosts)
  if [ -z $ip ]
  then
    # assign the output of `hostname -i` (which is the IP of the current machine) to ip
    ip=$(hostname -i)
  fi
fi

# Assign the value of FLY_APP_NAME, and if that doesn't exist either, assign
# "bondy" to node_name
node_name="${FLY_APP_NAME:=bondy}"

export BONDY_ERL_NODENAME=$node_name@$ip
bondy foreground