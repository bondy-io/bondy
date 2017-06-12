# LEAPSIGHT BONDY

## Running a single node
```bash
rebar3 shell
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