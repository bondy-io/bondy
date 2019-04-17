-module(bondy_http_utils).


-export([client_ip/1]).
-export([real_ip/1]).
-export([forwarded_for/1]).




%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc Returns a binary representation of the IP or <<"unknown">>.
%% @end
%% -----------------------------------------------------------------------------
-spec client_ip(Req :: cowboy_req:req()) -> binary() | undefined.

client_ip(Req) ->
    case real_ip(Req) of
        undefined -> forwarded_for(Req);
        Value -> Value
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec real_ip(cowboy_req:req()) -> binary() | undefined.

real_ip(Req) ->
    cowboy_req:header(<<"x-real-ip">>, Req, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec forwarded_for(cowboy_req:req()) -> binary() | undefined.

forwarded_for(Req) ->
    case cowboy_req:parse_header(<<"x-forwarded-for">>, Req, undefined) of
        [H|_] -> H;
        Val -> Val
    end.