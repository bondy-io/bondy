#!/bin/bash

set -e

NAME="bondy"
HOSTNAME=`hostname -f`
BASE_REL="/opt/app"
CONFIG_FILE="$BASE_REL/etc/bondy.conf"
SCRIPT="$BASE_REL/bin/bondy"
NODE_NAME="$NAME@$HOSTNAME"

# functions
trap_with_arg() {
    func="$1" ; shift
    for sig ; do
        trap "$func $sig" "$sig"
    done
}

func_trap() {
    echo "Trapped $1: Stopping $NAME ..."
    $SCRIPT stop;
    echo "Exit"
    exit 0
}

# Change configuration
echo "Using nodename $NODE_NAME"
sed -i "s/^nodename = bondy@127.0.0.1/nodename = $NODE_NAME/" $CONFIG_FILE

# Trap SIGTERM and SIGINT and tail the log file indefinitely
echo "Starting $NAME"
"$SCRIPT" foreground &
PID=$!

echo "Process $NAME started, trap signals (TERM,INT)"
tail --pid $PID -f /dev/null &
trap_with_arg func_trap TERM INT
wait $!

echo "Process $NAME exit!"


