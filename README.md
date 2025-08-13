![Bondy logo](https://github.com/bondy-io/bondy/blob/develop/doc/assets/bondy_bg.png?raw=true)

![Version](https://img.shields.io/badge/version-1.0.0--rc.2-blue?style=for-the-badge
)<br>
![Docker Pulls](https://img.shields.io/docker/pulls/leapsight/bondy?style=for-the-badge)
![Docker Build (master)](https://img.shields.io/github/actions/workflow/status/bondy-io/bondy/docker_image_build.yaml?&branch=master&label=docker-master&style=for-the-badge)
![Docker Build (develop)](https://img.shields.io/github/actions/workflow/status/bondy-io/bondy/docker_image_build.yaml?&branch=develop&label=docker-develop&style=for-the-badge)
![Docker Build (latest-tag)](https://img.shields.io/github/actions/workflow/status/bondy-io/bondy/docker_image_build.yaml?&tag=version-1.0.0-rc.42&label=docker-1.0.0-rc.42&style=for-the-badge)
<br>![Architectures](https://img.shields.io/badge/architecture-linux%2Famd64%20%7C%20linux%2Farm64%20%7C%20macOS%2Fintel%20%7C%20macOS%2FM1-lightgrey?style=for-the-badge)


# Bondy

### The distributed application networking platform
Bondy is an open source, always-on and scalable application networking platform connecting all elements of a distributed application—offering service and event mesh capabilities combined.

From web and mobile apps to IoT devices and backend microservices, Bondy allows everything to talk using one simple and secured communication protocol in a decoupled and dynamic way.

Bondy implements the open Web Application Messaging Protocol (WAMP).

<br><br>
<p align="center">
     <img src="https://github.com/bondy-io/bondy/blob/develop/doc/assets/bondy_cluster.png?raw=true" alt="drawing" width="600"/>
</p>
<br><br>

## Documentation

For our work-in-progress documentation for v1.0.0 go to [https://developer.bondy.io](http://developer.bondy.io).

## Supported WAMP features

### Authentication

* [x] Anonymous
* [x] Cryptosign
* [x] Ticket
* [x] WAMP-CRA
* [ ] WAMP-SCRAM (WIP)
* [ ] Cookie

In addition Bondy provides:

* [x] HTTP OAuth2
* [x] HTTP Password
* [x] Same Sign-on -- use a single set of credentials to sign on to multiple realms
* [x] Single Sign-on -- combines Same Sign-on with Ticket authentication. The resulting ticket can be used to sign on to multiple realms.

### Advanced RPC features
* [x] Call Canceling
* [x] Call Timeouts
* [x] Call Trust Levels
* [x] Caller Identification
* [x] Pattern-based registration
* [x] Shared Registration
     * [x] Load Balancing
          * [x] Random
          * [x] Round robin
     * [x] Hot Stand-by
          * [x] First
          * [x] Last
* [ ] Payload Passthru Mode (WIP)
* [ ] Registration Revocation (WIP)
* [ ] Progressive Call Results
* [ ] Progressive Calls


### Advanced Pub/Sub features
* [x] Event Retention
* [x] Pattern-based Subscriptions
* [x] Publication Trust Levels
* [x] Publisher Exclusion
* [x] Publisher Identification
* [x] Subscriber Black- and Whitelisting
* [ ] Payload Passthru Mode (WIP)
* [ ] Sharded Subscriptions
* [ ] Subscription Revocation

### Transport

* [x] WebSockets
* [x] RawSockets
* [ ] E2E encryption

### Transport Serialization

* [x] JSON
* [x] Msgpack
* [x] BERT
* [x] Erlang (subset)
* [ ] JSON batched
* [ ] Msgpack batched

## How is Bondy different than other WAMP routers?

Bondy provides a unique combination of features which sets it apart from other application networking solutions and WAMP routers in terms of *scalability, reliability, high-performance, development and operational simplicity.*

- **Distributed by design** – As opposed to other WAMP Router implementations, Bondy was designed as a reliable distributed router, ensuring continued operation in the event of node or network failures through clustering and data replication.
- **Scalability** – Bondy is written in Erlang/OTP which provides the underlying operating system to handle concurrency and scalability requirements, allowing Bondy to scale to thousands and even millions of concurrent connections on a single node. Its distributed architecture also allows for horizontal scaling by simply adding nodes to the cluster.
- **Decentralised peer-to-peer master-less clustering** – All nodes in a Bondy cluster are equal, thanks to the underlying clustering and networking technology which provides a decentralised master-less architecture. This includes all nodes acting as relays enabling Transparent routing. All nodes can also act as Bridge Relays to enable per-realm inter-cluster routing (aka Bondy Edge [Experimental]).
- **Transparent routing** - Bondy will route any Caller/Publisher (sender) messages to any Callee/Subscriber (receiver) regardless of their session location in the cluster. When using Full Mesh topology (default), this results in a single hop between sender and receiver. When using the upcoming Peer-to-Peer topology this results in one or multiple hops between sender and receiver.
- **Low latency data replication** – All nodes in a Bondy cluster share a global state which is replicated through a highly scalable and low latency eventually consistency model which combines causality tracking, real-time epidemic broadcasting (gossip) and periodic active anti-entropy. Bondy uses [Partisan](https://partisan.dev)), a high-performance Distributed Erlang replacement that enables various network topologies and supports large clusters (Partisan has been demonstrated to scale up to 1,024 Erlang nodes, and provide better scalability and reduced latency than Distributed Erlang).
- **Ease of use** – Bondy is easy to operate due to its operational simplicity enabled by its peer-to-peer nature, the lack of special nodes, automatic data replication and self-healing.
- **Embedded HTTP API Gateway** – Bondy embeds a powerful API Gateway that can translate HTTP actions to WAMP routed RPC and PubSub operations. The API Gateway leverages the underlying storage and replication technology to deploy the API Specifications to the cluster nodes in real-time.
- **Embedded Identity Management & Authentication** - Each realm manages user identity and authentication using multiple WAMP and HTTP authentication methods. Identity data is replicated across the cluster to ensure always-on and low-latency operations.
- **Embedded Role-based Access Control (RBAC)** – Each realm embeds a RBAC subsystem controlling access to realm resources and authorizing message routing through the definition of groups and the assignment of permissions. RBAC data is replicated across the cluster to ensure always-on and low-latency operations.
- **Embedded Broker Bridge** – Bondy embeds a Broker Bridge that can manage a set of WAMP subscribers that re-publish WAMP events to an external non-WAMP system e.g. another message broker (Kafka Bridge implemented).

## Quick Start

### Docker
The fastest way to get started is by using our official docker images.

1. Make sure you have [Docker](https://www.docker.com/get-started) installed and running.
2. Download the [examples/custom_config](https://github.com/bondy-io/bondy/tree/develop/examples/custom_config/etc) folder to a location of your choice, then `cd` to that location and run the following command (If you already cloned the Bondy repository then just `cd` to the location of the repo).


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
* macOS (Intel|Apple Silicon) or Linux (amd64|arm64)
* [Erlang](https://www.erlang.org/) 26.2.5.6 (Support for OTP 27 is on its way)
* [Rebar3](https://rebar3.readme.io/) 3.22.1 or later
* openssl
* libssl
* libsnappy
* liblz4
* libcrypto


#### Building

Clone this repository and `cd` to the location where you cloned it.

To generate a Bondy release to be used in production execute the following command which will generate a tarball containing the release at `$(PWD)/_build/prod/rel/`.

```shell
make release
```

Untar and copy the resulting tarball to the location where you want to install Bondy e.g. `~/tmp/bondy`.

```shell
tar -zxvf _build/prod/rel/bondy-1.0.0-rc.42.tar.qz -C ~/tmp/bondy
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
* [bondy.io](https://www.bondy.io)
* [developer.bondy.io](https://developer.bondy.io) - for documentation and more
* [WAMP Specification](wamp-proto.org)
* [Follow us on twitter @bondyIO](https://twitter.com/bondyIO)
* Recorded webinars
     * [Implementing a polyglot microservices architecture](https://www.youtube.com/watch?v=XxJ1IS8mo84)<br>Date: 10 July 2019

---

Copyright by Leapsight, material licensed under the CC-BY-SA 4.0,
provided as-is without any warranties, Bondy documentation (https://developer.bondy.io).
