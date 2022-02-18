![Bondy logo](https://github.com/Leapsight/bondy/blob/develop/doc/assets/bondy_bg.png?raw=true)

![License](https://img.shields.io/github/license/leapsight/bondy?style=for-the-badge)
![Architecture](https://img.shields.io/badge/architecture-linux%2Famd64%20%7C%20linux%2Farm64%20%7C%20macOS%2Fintel%20%7C%20macOS%2FM1-lightgrey?style=for-the-badge)
![Version](https://img.shields.io/badge/version-1.0.0--beta.31-blue?style=for-the-badge)<br>
![Docker Pulls](https://img.shields.io/docker/pulls/leapsight/bondy?style=for-the-badge)
![GitHub Workflow Status (branch)](https://img.shields.io/github/workflow/status/leapsight/bondy/CI/master?label=docker%3Amaster&style=for-the-badge)
![GitHub Workflow Status (branch)](https://img.shields.io/github/workflow/status/leapsight/bondy/CI/develop?label=docker%3Adevelop&style=for-the-badge)

# Bondy

### The distributed application networking platform
Bondy is an open source, always-on and scalable application networking platform for modern distributed architectures.  It is an all-in-one event and service mesh with support for multiple communication patterns, multiple protocols and secure multi-tenancy.

Bondy implements the open Web Application Messaging Protocol (WAMP) offering both Publish and Subscribe (PubSub) and routed Remote Procedure Calls (RPC) communication patterns.

<p align="center">
     <img src="https://github.com/Leapsight/bondy/blob/develop/doc/assets/bondy_cluster.png?raw=true" alt="drawing" width="600"/>
</p>

## Documentation

For our work-in-progress documentation go to [http://docs.getbondy.io](http://docs.getbondy.io).

## Quick Start

### Docker
The fastest way to get started is by using our official docker images.

1. Make sure you have [Docker](https://www.docker.com/get-started) installed and running.
2. Download the [examples/custom_config](https://github.com/Leapsight/bondy/tree/develop/examples/custom_config/etc) folder to a location of your choice, then `cd` to that location and run the following command (If you already cloned the Bondy repository then just `cd` to the location of the repo).


```shell
docker run \
--rm \
-e BONDY_ERL_NODENAME=bondy1@127.0.0.1 \
-e BONDY_ERL_DISTRIBUTED_COOKIE=bondy \
-u 0:1000 \
-p 18080:18080 \
-p 18081:18081 \
-p 18082:18082 \
-p 18083:18083 \
-p 18084:18084 \
-p 18085:18085 \
-v "$(PWD)/examples/custom_config/etc:/bondy/etc" \
-v "/tmp/data:/bondy/data" \
leapsight/bondy:master
```

### Building from source
#### Requirements

* [Erlang](https://www.erlang.org/) 24 or later
* [Rebar3](https://rebar3.readme.io/) 3.17.0 or later
* openssl
* libssl
* [Libsodium](https://github.com/jedisct1/libsodium)
* libsnappy
* liblz4


#### Building

Clone this repository and `cd` to the location where you cloned it.

To generate a Bondy release to be used in production execute the following command which will generate a tarball containing the release at `$(PWD)/_build/prod/rel/`.

```shell
rebar3 as prod tar
```

Untar and copy the resulting tarball to the location where you want to install Bondy e.g. `~/tmp/bondy`.

```shell
tar -zxvf _build/prod/rel/bondy-1.0.0-beta.28.tar.qz -C ~/tmp/bondy
```

#### Running

To run Bondy, `cd` to the location where you installed it e.g. `~/tmp/bondy` and run the following command which will print all the options.

```shell
bin/bondy
```

For example, to run Bondy with output to stdout do

```shell
bin/bondy foreground
```

And to run Bondy with an interactive Erlang shell do

```shell
bin/bondy console
```

## Local cluster testing

### Run a first node

We will start a node named `bondy1@127.0.0.1` which uses the following variables from the config file (`config/test/node_1_vars.config`).

|Transport|Description|Port|
|---|---|---|
|HTTP|REST API GATEWAY|18080|
|HTTP|REST API GATEWAY|18083|
|HTTP|REST Admin API|18081|
|HTTPS|REST Admin API|18084|
|Websockets|WAMP|18080|
|TCP|WAMP Raw Socket|18082|
|TLS|WAMP Raw Socket|18085|


```bash
make node1
```

#### Create a Realm

WAMP is a session-based protocol. Each session belongs to a Realm.

```curl
curl -X "POST" "http://localhost:18081/realms/" \
     -H 'Content-Type: application/json; charset=utf-8' \
     -H 'Accept: application/json; charset=utf-8' \
     -d $'{
  "uri": "com.myrealm",
  "description": "My First Realm"
}'
```

#### Disable Security

We will disable security to avoid setting up credentials at this moment.

```curl
curl -X "DELETE" "http://localhost:18081/realms/com.myrealm/security_enabled" \
     -H 'Content-Type: application/json; charset=utf-8' \
     -H 'Accept: application/json; charset=utf-8'
```

#### Run a second node

We start a second node named `bondy2@127.0.0.1` which uses the following variables from the config file (`config/test/node_2_vars.config`).

|Transport|Description|Port|
|:---|:---|:---|
|HTTP|REST API GATEWAY|18180|
|HTTP|REST API GATEWAY|18183|
|HTTP|REST Admin API|18181|
|HTTPS|REST Admin API|18184|
|Websockets|WAMP|18180|
|TCP|WAMP Raw Socket|18182|
|TLS|WAMP Raw Socket|18185|

```bash
make node2
```

After a minute the two nodes will automatically connect.
From now on all new Bondy control plane state changes will be propagated in real-time through broadcasting.
One minute after joining the cluster, the Active Anti-entropy service will trigger an exchange after which the Realm we have created in `bondy1@127.0.0.1` will have been replicated to `bondy2@127.0.0.1`.

### Run a third node

```bash
make node3
```

## Resources

* [http://docs.getbondy.io](http://docs.getbondy.io).
* [WAMP Specification](wamp-proto.org)
* [Follow us on twitter @leapsight](https://twitter.com/leapsight)
* Recorded webinars
     * [Implementing a polyglot microservices architecture](https://www.youtube.com/watch?v=XxJ1IS8mo84)<br>Date: 10 July 2019

---

Copyright by Leapsight, material licensed under the CC-BY-SA 4.0,
provided as-is without any warranties, Bondy documentation (http://docs.getbondy.io).