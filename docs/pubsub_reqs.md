# PubSub Requirements

Assume we have the following topics and subscriptions
#### Topics
```erlang
[
    {t1, com.williamhill.topic.bets},
    {t2, com.williamhill.topic.valuations},
    {t3, com.williamhill.topic.events.dfba5fe0-c668-11e5-9eaf-0002a5d5c51b.prices},
    {t4, com.williamhill.topic.events.dfba5fe0-c668-11e5-9eaf-0002a5d5c51b.results},
    {t5, com.williamhill.topic.events.dfba5fe0-c668-11e5-9eaf-0002a5d5c51b.scorecard}
]
```

##### Scenarios
* Adding a new topic when there are existing subscriptions to prefixes of that topic
    * We need to

#### Subscriptions
```erlang
[
    {s1, com.williamhill.topic.bets, [{'=', <<"customer_id">>, 1988726}]},
    {s2, com.williamhill.topic.valuations, [{'=', <<"customer_id">>, 1988726}]},
    {s3, com.williamhill.topic.events.dfba5fe0-c668-11e5-9eaf-0002a5d5c51b.\*, []}
]
```

### Inverted Index
We can create an inverted index like this:

1. For each subscription we create an index entry `{{Pos, Component}, SubscriptionId}`

```erlang
    #subscription{id = Id, topic_uri=TopicUri, criteria = Criteria} = Subs,
    [<<>>, <<>> | Tokens] = binary:split(TopicUri, [<<"com.williamhill.topic">>, <<".">>], [global]),
    Entries0 = [{{Pos, T}, SubsId},
        || Pos <- lists:seq(1, length(Tokens)), T <- Tokens],
    Fields = case Criteria of
        [] ->
            %% if this is not present the algorithm will not consider a match
            %%
            [{{all, true}, SubsId}];
        _ ->
            [{{K, V}, SubsId} || {'=', K, V} <- Criteria]
    end,
    Entries1 = lists:append(Fields, Entries0),
    Tab = ets:new(index, [bag, public]),
    true = ets:insert(Tab, Entries).
```

We end up with the following bag:

```erlang
[
    %% We compact the base uri

    {{<<"realm1">>, <<"com.williamhill">>, 1, <<"bets">>}, SessionId, Pid, s1},
    {{<<"realm1">>, <<"com.williamhill">>, 1, <<"events">>}, SessionId, Pid, s2},
    {{<<"realm1">>, <<"com.williamhill">>, 1, <<"valuations">>}, SessionId, Pid, s2},
    {{<<"realm1">>, <<"com.williamhill">>, 2, <<"dfba5fe0-c668-11e5-9eaf-0002a5d5c51b">>}, SessionId, Pid, s3},
    {{<<"realm1">>, <<"com.williamhill">>, 3, <<"*">>}, SessionId, Pid, s3}
    %% {{<<"realm1">>, <<"customer_id">>, 1988726}, s1},
    %% {{<<"realm1">>, customer_id, 1988726}, s2},
    %% {{<<"realm1">>, all, true}, s3} % to enable matching any field
]
```


## Matching
{<<"com.williahill.topic.bets">>, #{customer_id = 29390}}

We need to record selectivity stats so that we can plan the query

and(
    match_subscribers({1,<<"com.williahill.topic">>}),
    match_subscribers({2,<<"bets">>}),
    (match_subscribers({customer_id,29390}) or match_subscribers
),

math_subscribers would throw an abort exception to stop execution when there are no matches.






for a publishing com.williahill.foo.a.x

```erlang
OR(
    %% exact
    match({com.williahill, 1, foo.a.x}),
    %% prefixes
    match({com.williahill, 1, foo}),
    ANDALSO(
        match(com.williamhill, 1, foo)),
        match(com.williamhill, 1, a))
    ),
    ANDALSO(
        match(com.williamhill, 1, foo)),
        match(com.williamhill, 1, a))
        match(com.williamhill, 1, x))
    ),
    ),
    AND(
        OR(match(com.williamhill, 1, wildcard), match(com.williamhill, 1, foo)),
        OR(match(com.williamhill, 2, wildcard), match(com.williamhill, 2, a)),
        OR(match(com.williamhill, 2, wildcard), match(com.williamhill, 2, x))
    )
)
```

{com.williamhill, foo.a.x} -> [..subscriptores...] = A
{com.williamhill, 1, foo} -> [..subscriptores...] = B --- foo.*
{com.williamhill, 2, a} -> [..subscriptores...] = C --- foo.a | foo.a.* | *.a | *.a.*
{com.williahill, 3, *} -> [] = D

{com.williamhill, foo} -> []
{com.williamhill, foo.a} -> []
{com.williamhill, foo.a.x} -> []
{com.williamhill, foo.b} -> []



{com.williamhill, foo} -> []
{com.williamhill, foo, a} -> []
{com.williamhill, foo, a, x} -> []
{com.williamhill, foo, wildcard, x} -> []

1 foo         -->     {com.williamhill, foo}
2 foo.*       -->     {com.williamhill, foo, *}
3 foo.a.*     -->     {com.williamhill, foo, a, *}
4 foo._.x     -->     {com.williamhill, foo, <<>>, x}
5 _.a         -->     {com.williamhill, <<>>, a}
6 _.a.x       -->     {com.williamhill, <<>>, a, x}
7 _._.x       -->     {com.williamhill, <<>>, <<>>, x}
8 _.a.*       -->     {com.williamhill, <<>>, a, *}
9 foo.a.x     -->     {com.williamhill, foo, a, x}
10 _.*         -->    {com.williamhill, <<>>, *}  

When I publish:
com.williamhill.foo ->  foo

com.williamhill.foo.a -> foo.*, _.a

com.williamhill.foo.a.x -> foo.*, foo.a.*. foo._.x, _.a.x


com.williamhill.foo.a.x

%% 1 and 5 should not match

OR (
    %% 2,3,9
    {=, '$1', {com.williamhill, foo, a, x}},
    {=, '$1', {com.williamhill, foo, a, *}},
    {=, '$1', {com.williamhill, foo, *}}.
    %% 4,6,7
    AND(
        {=, element(1, '$1'), <<"com.williahill">>}.
        {=, size('$1'), 4},
        OR({=, element(2,'$1'), foo}, {=, element(2,'$1'), <<>>}),
        OR({=, element(3,'$1'), a}, {=, element(3,'$1'), <<>>})
        OR({=, element(4,'$1'), x}, {=, element(4,'$1'), <<>>})
    )
)


if we wanted to support prefix together with wilcard (not in RFC)

OR (
    %% 2,3,9
    {=, '$1', {com.williamhill, foo, a, x}},
    {=, '$1', {com.williamhill, foo, a, *}},
    {=, '$1', {com.williamhill, foo, *}}.
    %% 4,6,7
    AND(
        {=, element(1, '$1'), <<"com.williahill">>}.
        {=, size('$1'), 4},
        OR({=, element(2,'$1'), foo}, {=, element(2,'$1'), <<>>}),
        OR({=, element(3,'$1'), a}, {=, element(3,'$1'), <<>>})
        OR({=, element(4,'$1'), x}, {=, element(4,'$1'), <<>>})
    ),
    AND(
        {=, element(1, '$1'), <<"com.williahill">>}.
        OR({=, element(2,'$1'), foo}, {=, element(2,'$1'), <<>>}),
        {=, element(3,'$1'), <<"*">>}
    ),
    AND(
        {=, element(1, '$1'), <<"com.williahill">>}.
        OR({=, element(2,'$1'), foo}, {=, element(2,'$1'), <<>>}),
        OR({=, element(3,'$1'), a}, {=, element(3,'$1'), <<>>})
        {=, element(4,'$1'), <<"*">>}
    )
)
