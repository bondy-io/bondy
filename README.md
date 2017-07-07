# API GATEWAY & NETWORKING PLATFORM FOR DISTRIBUTED AND MICROSERVICES APPLICATIONS

BONDY is an open source networking platform for distributed and MicroServices and IoT applications written in Erlang, implementing primarily the open Web Application Messaging Protocol (WAMP) offering both Publish and Subscribe (PubSub) and routed Remote Procedure Calls (RPC).

## Installing from source

```bash
make rel
```

This will generate an Erlang release at 

## Configuration
On the first startup Bondy creates the root realm called "com.leapsight.bondy" and user with username `admin` and password `bondy` with local network access.

## Add an API Client

If you want to define your own `client_id` and `client_secret` for a realm called `com.myapi` do:
```bash
curl -X "POST" "http://localhost:18081/realms/com.myapi/clients" \
     -H "Content-Type: application/json; charset=utf-8" \
     -H "Accept: application/json; charset=utf-8" \
     -d $'{
  "client_id": "1234",
  "client_secret": "4567",
  "description": "A test client"
}'
```

To generate random `client_id` and `client_secret` do:
```bash
curl -X "POST" "http://localhost:18081/realms/com.myapi/clients" \
     -H "Content-Type: application/json; charset=utf-8" \
     -H "Accept: application/json; charset=utf-8" \
     -d $'{
  "description": "A test client"
}'
```

An example return will be the following JSON object:

```json
{
    "client_id": "6aoztZ9SUM65RZhBiNQXmEWbCJgWCdoBeYVPB4KSwgE8eEK3",
    "client_secret": "RdfuJNEEhS6eUSxDMcdIrLZcUz4NMgg49ImZ6XWwNDyId0LCADQkjsNiGh0nm8r2",
    "description": "A test client"
}
```

## Add a Resource Owner (end-user)
```bash
curl -X "POST" "http://localhost:18081/realms/magenta/resource_owners" \
     -H "Content-Type: application/json; charset=utf-8" \
     -H "Accept: application/json; charset=utf-8" \
     -d $'{
  "username": "ale",
  "password": "1234",
  "user_id": 2,
  "account_id": 1
}'
```

## Adding an Api Spec
```bash
curl -X "POST" "http://localhost:18081/services/load_api_spec" \
     -H "Content-Type: application/json; charset=utf-8" \
     -H "Accept: application/json; charset=utf-8" \
     -d "@/Volumes/Lojack/magenta_bondy_specs/magenta_api.bondy.json"
```

