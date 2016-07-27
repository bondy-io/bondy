-module(juno_rest_utils).

-type state_fun() :: fun((any()) -> any()).
-export_type([state_fun/0]).


-export([is_authorized/2]).
-export([location_uri/2]).
-export([set_resp_error_body/2]).
-export([bindings_to_map/2]).
-export([set_resp_link_header/4]).
-export([set_resp_link_header/2]).

%% The StateFun should receive
-spec is_authorized(Req :: cowboy_req:req(), StateFun :: state_fun()) ->
   {stop | true | {false, binary()}, cowboy_req:req(), any()}.
is_authorized(Req0, StateFun) ->
    Realm = cowboy_req:header(<<"www-authenticate">>, Req0),
    try
        case wamp_uri:is_valid(Realm) of
            true ->
                {true, Req0, StateFun(Realm)};
            false ->
                throw({unknown_realm, Realm})
        end
    catch
        throw:{unknown_realm, Realm} = Reason ->
            % We set a useless WWWAuthHeader
            Req1 = set_resp_error_body(Reason, Req0),
            {{false, <<"unknown_realm">>}, Req1, StateFun(undefined)};
        _:Reason ->
            % We force a JSON error object as body
            Req1 = set_resp_error_body(Reason, Req0),
            Req2 = cowboy_req:reply(500, Req1),
            {stop, Req2, StateFun(undefined)}
    end.

set_resp_error_body(Reason, Req) ->
    Body = juno_json_utils:error(Reason),
    %% cowboy_req:reply(500, [?CT_JSON], Body, Req).
    cowboy_req:set_resp_body(Body, Req).


-spec location_uri(ID :: binary(), Req :: cowboy_req:req()) ->
    URI :: binary().
location_uri(ID, Req) ->
    Path = cowboy_req:path(Req),
    <<Path/binary, "/", ID/binary>>.


-spec bindings_to_map(Bindings :: list(), Map :: map()) ->
    NewMap :: map().
bindings_to_map(Bindings, Map) when is_list(Bindings), is_map(Map) ->
    bindings_to_map(Bindings, Map, #{}).

%% @private
bindings_to_map([], _, Acc) ->
    Acc;
bindings_to_map([{K, V} | T], Map, Acc0) ->
    Field = maps:get(K, Map),
    Acc1 = maps:put(Field, V, Acc0),
    bindings_to_map(T, Map, Acc1).


-spec set_resp_link_header(
        [{binary(), iodata(), iodata()}], Req :: cowboy_req:req()) ->
    NewReq :: cowboy_req:req().
set_resp_link_header([Link], Req) ->
    set_resp_link_header(resp_link_value(Link), Req);
set_resp_link_header(L, Req) ->
    Value = resp_link_values(L, []),
    cowboy_req:set_resp_header(<<"link">>, Value, Req).



-spec set_resp_link_header(
        binary(), iodata(), iodata(), Req :: cowboy_req:req()) ->
    NewReq :: cowboy_req:req().
set_resp_link_header(URI, Rel, Title, Req) ->
    Value = resp_link_value({URI, Rel, Title}),
    cowboy_req:set_resp_header(<<"link">>, Value, Req).


resp_link_values([], Acc) ->
    Acc;
resp_link_values([H | T], Acc0) ->
    Acc1 = [resp_link_value(H), $, | Acc0],
    resp_link_values(T, Acc1).


resp_link_value({URI, Rel, Title}) ->
    [
        $<, URI, $>, $;, $\s,
        "rel=", $", Rel, $", $;, $\s,
        "title=", $", Title, $"
    ].




