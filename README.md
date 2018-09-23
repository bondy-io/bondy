

# Bondy: A Distributed WAMP Router and API Gateway

Bondy is an open source scaleable and robust networking platform for distributed microservices and IoT applications written in Erlang. It implements the open Web Application Messaging Protocol (WAMP) offering both Publish and Subscribe (PubSub) and routed Remote Procedure Calls (RPC) communication patterns. It also provides a built-in HTTP/REST API Gateway.

Bondy is Apache2 licensed.

**DOCS COMING SOON**

## Quick Start
Bondy requires Erlang/OTP 20.3.8 (support for 21 on the way) and `rebar3`.

The fastest way to get going is to have the [rebar3_run](https://www.rebar3.org/docs/using-available-plugins#section-run-release) plugin.

### Run a first node
We will start a node named `bondy1@127.0.0.1` which uses the following variables from the config file (`config/test1/vars.config`).

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
rebar3 as test1 run
```

### Create a Realm
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

### Disable Security
We will disable security to avoid setting up credentials at this moment.

```curl
curl -X "DELETE" "http://localhost:18081/realms/com.myrealm/security_enabled" \
     -H 'Content-Type: application/json; charset=utf-8' \
     -H 'Accept: application/json; charset=utf-8'
```

### Run a second node
We start a second node named `bondy2@127.0.0.1` which uses the following variables from the config file (`config/test2/vars.config`).

|Transport|Description|Port|
|---|---|---|
|HTTP|REST API GATEWAY|18180|
|HTTP|REST API GATEWAY|18183|
|HTTP|REST Admin API|18181|
|HTTPS|REST Admin API|18184|
|Websockets|WAMP|18180|
|TCP|WAMP Raw Socket|18182|
|TLS|WAMP Raw Socket|18185|

```bash
rebar3 as test2 run
```

### Connect the two
In `bondy1@127.0.0.1` erlang's shell type:

```erlang
(bondy2@127.0.0.1)1> bondy_peer_service:join('bondy2@127.0.0.1').
```

One minute after joining the cluster the nodes the Active Anti-entropy service will trigger an exchange after which the Realm we have created in `bondy1@127.0.0.1` will have been replicated to `bondy2@127.0.0.1`.


## References

* Read more about [WAMP](wamp-proto.org)

## Important links

* #bondy on slack (coming soon!)
* Bondy Documentation and Guides (coming soon!)
* [Follow us on twitter @leapsight](https://twitter.com/leapsight)
