# Getting Started

## Installation



## Babel Configuration

- `bucket_types.index_collection` - the Riak KV bucket type to be use for the Index Collection buckets. **It must be of map datatype.**
- `bucket_types.index_data` - the Riak KV bucket type to be use for the Index Data buckets. **It must be of map datatype.**
- `reliable` - contains the config for the Reliable library which is an included application
    - `instance_name` - arguably the most important parameter as it works as a namespace ensuring two instances of a same application (service , microservice) do not access the same Reliable queue. So if you deploy 5 instances of your "account" service each instance should have a different instance name e.g. "account-1"..."account-5"

The `index_collection` and `index_data` bucket types need to be created in Riak KV for Babel to work.

If you use the names "index_collection" and "index_data" respectively for those two buckets you will need to run the following two commands to setup Riak KV:

```bash
riak-admin bucket-type create index_collection '{"props":{"datatype":"map", "n_val":3, "pw":"quorum", "pr":"quorum"}}'

riak-admin bucket-type activate index_collection
```

```bash
riak-admin bucket-type create index_data '{"props":{"datatype":"map", "n_val":3, "pw":"quorum", "pr":"quorum", "notfound_ok":false, "basic_quorum":true}}'

riak-admin bucket-type activate index_data
```



### Example

```erlang
{babel, [
    {bucket_types, [
        {index_collection, <<"index_collection">>},
        {index_data, <<"index_data">>}
    ]},
    {reliable, [
        {backend, reliable_riak_store_backend},
        {riak_host, "127.0.0.1"},
        {riak_port, 8087},
        {instance_name, <<"account-1">>},
				{instances, [<<"account-0">>, <<"account-1">>, <<"account-2">>]},
        {number_of_partitions, 5}
    ]}
]}.
```


