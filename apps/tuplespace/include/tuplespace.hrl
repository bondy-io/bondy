
-define(QUEUE_TABLE_NAME, queue).

-define(REGISTRY_TABLE_NAME, table_registry).

-define(QUEUE_TABLE(Term),
    tuplespace:locate_table(?QUEUE_TABLE_NAME, Term)).

-define(REGISTRY_TABLE(Term),
    tuplespace:locate_table(?REGISTRY_TABLE_NAME, Term)).

-define(TABLE_SPECS, [
    {?QUEUE_TABLE_NAME, ?TABLE_PROPS(ordered_set, true, true, 1)},
    {?REGISTRY_TABLE_NAME, ?TABLE_PROPS(set, true, true)}
]).

-define(TABLE_PROPS(Type, RC, WC), [
    Type,
    {keypos, 2},
    named_table,
    public,
    {read_concurrency, RC},
    {write_concurrency, WC}
]).

-define(TABLE_PROPS(Type, RC, WC, Pos), [
    Type,
    {keypos, Pos},
    named_table,
    public,
    {read_concurrency, RC},
    {write_concurrency, WC}
]).


%% @doc The table_registry record maps a name to an ets tid.
%% This entries are stored in the tuplespace REGISTRY_TABLE
-record(table_registry, {
    name            ::  any(),
    tid             ::  non_neg_integer()
}).
