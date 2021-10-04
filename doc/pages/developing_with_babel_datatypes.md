# Developing with Babel Datatypes

This tutorial is based on Riak KV [Documentation for Maps](https://docs.riak.com/riak/kv/2.2.3/developing/data-types/maps.1.html)

?> This section assumes you have a basic understanding of Riak Data Types a.k.a. conflict-free replicated datatypes (CRDTs), concepts and the required [setup](https://docs.riak.com/riak/kv/2.2.3/developing/data-types/index.html#getting-started-with-riak-data-types) of the Riak KV database to use them.

# Maps

Maps are the most versatile of the Riak data types because all other data types can be embedded within them, *including maps themselves*. This enables the creation of complex, custom data types from a few basic building blocks.

Using counters, sets, and maps within maps are similar to working with those types at the bucket level.

## Create a Map

Creating a map in Babel is identical to creating a map in Riak Client.

<!-- panels:start -->

<!-- div:left-panel -->

```erlang
Map = riakc_map:new().
```

<!-- div:left-panel -->

```erlang
Map = babel_map:new().
```

<!-- panels:start -->

But there is where the similarities end.

## Modifying a Map

```erlang
Map1 = riakc_map:update(
	{<<"first_name">>, register},
  fun(R) ->
		riakc_register:set(
			<<"Ahmed">>, R
		)
	end,
  Map
),

Map2 = riakc_map:update(
	{<<"phone_number">>, register},
  fun(R) ->
		riakc_register:set(
			<<"5551234567">>, R
		)
	end,
  Map1
).
```

Did you notice something?  In Babel **you don't need to define the type of the map keys in each operation**, i.e. instead of writing `{<<"first_name">>, register}` , you write `<<"first_name">>` . But how does Babel know which is the type of the value associated with the key? The short answer is: *you tell Babel that information when reading and writing to the database.* You do that through a [Type Spec](https://www.notion.so/Developing-with-Babel-Data-Types-d6d2961e81d94b2a839c9ba8709bb2a0) [](https://www.notion.so/Babel-Docs-9d88e860091b4de7977ad5a805ed3490), the specification of the  mapping  between Riak Data Types and Babel Data Types that we will explore later in this section.

Key names still need to be binaries in Babel Maps.

Also, **did you notice we do not need a function object to mutate a property?** Setting values for properties in Babel feels exactly like it does when using Erlang data structures like maps or orddicts.

In fact, with Babel we can go further and **use other Erlang types and not just binaries.**

```erlang
Map3 = riakc_map:update(
	{<<"age">>, register},
  fun(R) ->
		riakc_register:set(
			<<"34">>, R
		)
	end,
  Map2
).
```

Now that feels good! But it does not stop there, lets see an area were Babel really shines: embedded maps.

In Riak Client, embedding maps result in a nested call that is difficult to understand and hence difficult to maintain.

```erlang
Map4 = riakc_map:update(
    {<<"preferences">>, map},
    fun(Prefs) ->
				riakc_map:update(
					{<<"notifications">>, map},
					fun(Notif) ->
						riakc_map:update(
							{<<"push_notifications_enabled">>, flag},
							fun(Flag) -> riakc_flag:enable(Flag) end,
							Notif
						)
	        end,
					Prefs
				)
		end,
    Map3
),
```

But in babel, it is as simple as:

```erlang
Map4 = babel_map:set(
	[<<"preferences">>, <<"notifications">>, <<"push_notifications_enabled">>]
	true,
	Map3
).
```

If the value at the end of the path is not currently set, Babel creates a new embedded map. However, if there was already a value at the end of the path the set operation will replace it with a new map. This does not happen in Riak Maps as properties are tagged with a type, but what will happen is you will end up with two properties having the same key and different types.

Babel Map offers additional functions to work with embedded data types such as sets, counters, and flags, such as `add_element/3` , `del_element/2` which allow keys and paths as first argument and assume there is a Babel Set value.

## Reading the values in a Map

Now that we have the map, we might want to read the values before storing the object in Riak, but that is impossible with Riak Maps:

```erlang
1> riakc_map:fetch({<<"preferences">>, map}, Map4).
** exception error: no function clause matching
orddict:fetch({<<"a">>,register},[]) (orddict.erl, line 80)
```

**WHAT?**
Just in case you never used Riak Data Types before, the above result is not a bug, it is intentional. In Riak Client you can only read your map "mutations" (updates and removes) after you stored the object in the database.

 But do not worry, Babel has your back:

```erlang
1> PrefsMap = babel_map:get(<<"preferences">>, Map3).
#babel_map{values = ...}
2> NotifMap = babel_map:get(<<"notifications">>, PrefsMap).
3> babel_map:get(<<"push_notifications_enabled">>, NotifMap).
true
```

In fact, we can always go further:

```erlang
2> Path = [
    <<"preferences">>, <<"notifications">>, <<"push_notifications_enabled">>
].
3> babel_map:get(Path, Map4).
true
```

Not only that, imagine we want to collect the value of a number of properties from Map4, we can do that using the `babel_map:collect/2` function.

```erlang
4> Keys = [
	<<"first_name">>,
	<<"age">>,
	[<<"preferences">>, <<"notifications">>, <<"push_notifications_enabled">>]
].
5> babel_map:collect(Keys, Map4).
6> [<<"Ahmed">>, 24, true]
```

## Reading and Writing

In order to read and/or write a Babel Data Type in Riak KV we need to define a mapping between a Riak Data Type and a Babel Data Type. The case of a Babel Map, because it can embed other data types, is more complex and requires the use of a Type Specification or "type spec" for short.

### Type Specs

A type spec is a map where the keys are the Babel Map keys i.e. binary names and the values are a 2-tuple where the first element is the Riak Data Type  and the second element is the Babel Type of the value respectively associated with the key i.e. `#{Key => {RiakType, BabelType}}` .

Babel Types are specified in the babel_map.erl module.

So in the example we have been using, the map spec could be:

```erlang
Spec = #{
	<<"first_name">> => {register, binary},
	<<"last_name">> => {register, binary},
	<<"phone_number">> => {register, binary},
	<<"age">> => {register, integer},
	<<"preferences">> => {map, PrefSpec},
}.

PrefSpec = #{
	<<"notifications">> => {map, NotifSpec}
}.

NotifSpec = #{
	<<"push_notifications_enabled">> => {flag, boolean}
}.
```

There is also a special case, when you are storing a map with unknown keys, for example, lets say you want to store a set of emails for Ahmed with a tag denoting whether the email is a personal or a work address.

```erlang
[
	#{
		<<"email">> => <<"ahmed@me.com">>,
		<<"tag">> => <<"personal">>
	},
	#{
		<<"email">> => <<"ahmed@example.org">>,
		<<"tag">> => <<"work">>
	}
].
```

That cannot be done using Babel Sets (nor Riak Sets) , since they can only store binary values.

We could store that using a different representation: a map of registers.

```erlang
#{
	<<"ahmed@me.com">> => <<"personal">>,
	<<"ahmed@example.org">> => <<"work">>
}
```

But in order to define the type spec we have a problem: how can we define a type spec for a map where we do not know the keys in advance? Assuming the value for those keys are always of the same type, Babel Map offers a solution: the key wildcard `'_'`. Using the key wildcard the type spec would be:

```erlang
#{'_' => {register, binary}}
```

The meaning of which is, *"every key in this Riak Map is of type register and we want to convert it to a Babel Map binary"*. Babel map will use the spec to turn registers into binaries and vice-versa.

Now, did you notice the mapping for the key named `age`?

```erlang
#{
	<<"age">> => {register, integer}
}
```

This is were type specs really shine. The value for `age` is transformed from binary to integer and viceversa automatically by Babel map during object retrieval and storage.

Now we can retrieve and store maps from/to Riak.

### Retrieving a Map

Babel uses Riak Client to communicate with the database, so in principle retrieving a map looks exactly the same using Babel, with an additional step.

```erlang
Map = riakc_pb_socket:fetch_type(
	Conn,
	{BucketType, Bucket},
	Key,
	[]
).
```

However, you can use Babel's more concise API, that does it all for you:

```erlang
babel:get({BucketType, Bucket}, Key, TSpec, #{connection => Conn}).
```

### Storing a Map

As with Riak Map, storing a map requires an additional call, to transform the map into a set of Riak operations. And in the case of a Babel Map we need to provide the type spec so that Babel knows how to turn a map into a set of Riak operations.

```erlang
Ops = riakc_map:to_op(Map),
riakc_pb_socket:update_type(
	Conn,
	{BucketType, Bucket},
	Key,
	Ops,
	[]
).
```

Alternatively, you can use Babel's more concise API:

```erlang
babel:put({BucketType, Bucket}, Key, Map, TSpec, #{connection => Conn}).
```

# Sets

Sets are collections of unique binary values (such as strings). All of the values in a set are unique.

## Create a Set

```erlang
CitiesSet = riakc_set:new()
```

## Add to a Set

```erlang
CitiesSet1 = riakc_set:add_element(
	<<"Toronto">>, CitiesSet
),
CitiesSet2 = riakc_set:add_element(
	<<"Montreal">>, CitiesSet1
).
```

Babel Sets allow you to store atom, list, integer and floats values too! The only limitation is they all need to be of the same type.

```erlang
NerdyWords = babel_set:new([foo, bar, baz]).
```

## Remove from a Set

```erlang
CitiesSet3 = riakc_set:del_element(
	<<"Montreal">>, CitiesSet2
),
CitiesSet4 = riakc_set:add_element(
	<<"Hamilton">>, CitiesSet3
),
CitiesSet5 = riakc_set:add_element(
	<<"Ottawa">>, CitiesSet4
).
```

## Read from a Set

## Retrieve a Set

Retreiving a Set from Riak KV works like retreiving any other data type.

```erlang
{ok, Set} = riakc_pb_socket:fetch_type(
	Pid,
	{<<"sets">>,<<"travel">>},
	<<"cities">>
).
```

You can now convert the Riak Set into a Babel Set

```erlang
TypeSpec = binary,
Set = babel_set:from_riak_set(Set, TypeSpec).
```

However, there is an alternative:

```erlang
TypeSpec = binary,
{ok, Set} = babel:get(
	{<<"sets">>,<<"travel">>},
	<<"cities">>,
	TypeSpec,
	#{connection => Pid}
).
```

## Find a Set Member

```erlang
riakc_set:size(Set)
```

## Size of a Set

```erlang
riakc_set:size(Set)
```

# Counters

- [ ]  Not implemented yet

# Flags

- [ ]  Not implemented yet