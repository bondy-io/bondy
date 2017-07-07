# LEAPSIGHT BONDY RANDOM NOTES

## Running a single node

### Compiling
```bash
rebar3 release
```

### Running
```bash
_build/default/rel/bondy/bin/bondy start
```

```
%% We make sure the magenta realm exists
Realm = bondy_realm:get(<<"magenta">>).
%% We disable security until we migrate to CHASKI as client
%% as the current client does not support authentication
%% this does not disable OAUTH2 at the Gateway level
bondy_realm:disable_security(Realm).
%% Each application that accesses the API needs require credentials.
%% For simplicity we will allows connections from all users from any IP 
%% using a Password
bondy_api_gateway:add_client(<<"magenta">>, <<"1234">>, <<"5678">>, #{}).
bondy_security:add_source(<<"magenta">>, all, {{0,0,0,0},0}, password, []).
bondy_api_gateway:add_client(<<"magenta">>, <<"1234">>, <<"5678">>, #{}).
%% We load the magenta api spec
bondy_api_gateway:load("/Volumes/Lojack/magenta_bondy_specs/magenta_api.bondy.json").
```


## Using a WS Client

```
/connect ws://localhost:18080/ws wamp.2.json
/send \[1,"realm1",{"authid":"admin", "roles":{"caller":{}, "subscriber":{}, "publisher":{}, "callee":{"shared_registration":true}}}]
/send \[5,"foo",{}]
```


## Bulding a cluster of 3 nodes

```bash
make gen_nodes
```

Then in three separate shells run 
```bash
make node1
```

```bash
make node2
```

```bash
make node3
```
These will leave you in the bondy console (Erlang Shell)

At the moment joining the nodes in a cluster is done manually through the Erlang Shell.

In any the shell of node1 run:
```erlang
plumtree_service:join('bondy_2@127.0.0.1').
plumtree_service:join('bondy_3@127.0.0.1').
plumtree_metadata:put({foo,bar}, <<"fede">>, #{name => fede}).
```

Test data replication

In any one shell type:

```erlang
plumtree_metadata:put({foo,bar}, <<"fede">>, #{name => fede}).
```

And in the other shells do:

```erlang
plumtree_metadata:get({foo,bar}, <<"fede">>).
```

## Making a local call

Open a bondy shell 

```
C = #{realm_uri => <<"magenta">>, awaiting_calls => sets:new(), peer => {{127,0,0,1}, 8080}, session => bondy_session:new({{127,0,0,1}, 8080}, <<"magenta">>, #{roles => #{caller => #{features => #{}}}}), timeout => 5000}.
bondy:call(<<"com.example.add2">>, #{}, [1,1], #{}, C).

bondy:call(<<"com.leapsight.bondy.security.users.add">>, #{}, [#{username => <<"chaski">>, password => <<"chaski">>, groups => []}], #{}, C).

bondy:call(<<"com.leapsight.bondy.security.users.list">>, #{}, [], #{}, C).

C1 = #{realm_uri => <<"com.leapsight.bondy">>, awaiting_calls => sets:new(), peer => {{127,0,0,1}, 8080}, session => bondy_session:new({{127,0,0,1}, 8080}, <<"magenta">>, #{roles => #{caller => #{features => #{}}}}), timeout => 5000}.
bondy:call(<<"com.leapsight.bondy.api_gateway.add_client">>, #{}, [<<"magenta">>, #{<<"description">> => <<"a test client">>}], #{}, C1).
```