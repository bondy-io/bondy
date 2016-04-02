%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2016. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%% A Dealer is one of the two roles a Router plays. In particular a Dealer is
%% the middleman between an Caller and a Callee in an RPC interaction,
%% i.e. it works as a generic router for remote procedure calls
%% decoupling Callers and Callees.
%%
%% Callees register procedures they provide with Dealers.  Callers
%% initiate procedure calls first to Dealers.  Dealers route calls
%% incoming from Callers to Callees implementing the procedure called,
%% and route call results back from Callees to Callers.
%%
%% A Caller issues calls to remote procedures by providing the procedure
%% URI and any arguments for the call. The Callee will execute the
%% procedure using the supplied arguments to the call and return the
%% result of the call to the Caller.
%%
%% The Caller and Callee will usually run application code, while the
%% Dealer works as a generic router for remote procedure calls
%% decoupling Callers and Callees.
%%
%% Juno does not provide message transformations to ensure stability and safety.
%% As such, any required transformations should be handled by Callers and
%% Callees directly (notice that a Callee can be a middleman implementing the
%%  required transformations).
%% @end
%% =============================================================================
-module(juno_dealer).
-include_lib("wamp/include/wamp.hrl").


%% API
-export([handle_message/2]).


%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec handle_message(M :: message(), Ctxt :: map()) -> ok.
handle_message(#register{} = _M, _Ctxt) ->
    %% ReqId = M#register.request_id,
    %% Opts = M#register.options,
    %% ProcUri = M#register.procedure_uri,
    ok;

handle_message(#unregister{} = _M, _Ctxt) ->
    %% ReqId = M#register.request_id,
    %% RegId = M#register.registration_id,
    ok;

handle_message(#call{} = _M, _Ctxt) ->
    %% ReqId = M#call.request_id,
    %% Opts = M#call.options,
    %% ProcUri = M#call.procedure_uri,
    %% Args = M#call.arguments,
    %% Pay = M#call.Payload,
    ok.
