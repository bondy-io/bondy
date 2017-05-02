%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2017. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%%
%% @end
%% =============================================================================
-module(juno_cowboy_utils).

-export[(set_error_resp_body/2)].
-export[(location_uri/2)].



set_error_resp_body(Reason, Req) ->
    Body = cowboy_utils:error(Reason),
    cowboy_req:set_resp_body(Body, Req).


-spec location_uri(Id :: binary(), Req :: cowboy_req:req()) ->
    URI :: binary().
location_uri(Id, Req) when is_binary(Id) ->
    Path = cowboy_req:path(Req),
    <<Path/binary, "/", Id/binary>>;

location_uri(Id, Req) when is_integer(Id) ->
    location_uri(integer_to_binary(Id), Req).
