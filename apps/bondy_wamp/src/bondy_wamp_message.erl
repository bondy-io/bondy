%% -----------------------------------------------------------------------------
%%  Copyright (c) 2015-2021 Leapsight. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%%
%% @end
%% =============================================================================
-module(bondy_wamp_message).
-include("bondy_wamp.hrl").

-type t()               ::  wamp_call()
                            | wamp_cancel()
                            | wamp_error()
                            | wamp_interrupt()
                            | wamp_invocation()
                            | wamp_publish()
                            | wamp_published()
                            | wamp_register()
                            | wamp_registered()
                            | wamp_result()
                            | wamp_subscribe()
                            | wamp_subscribed()
                            | wamp_unregister()
                            | wamp_unregistered()
                            | wamp_unsubscribe()
                            | wamp_unsubscribed()
                            | wamp_yield().

-type error_source()    ::  wamp_subscribe()
                            | wamp_unsubscribe()
                            | wamp_publish()
                            | wamp_register()
                            | wamp_unregister()
                            | wamp_call()
                            | wamp_invocation()
                            | wamp_cancel().

%% -type payload_opts()    ::  [payload_opt()]
%%                             | #{
%%                                 args => list(),
%%                                 kwargs => map(),
%%                                 partial => {encoding(), binary()}
%%                             }.
%% -type payload_opt()     ::  {args, list()}
%%                             | {kwargs, map()}
%%                             | {partial, {encoding(), binary()}}.

-type partial()        :: {encoding(), binary()}.

-export_type([t/0]).
-export_type([partial/0]).
-export_type([error_source/0]).

%% Message types
-export([abort/2]).
-export([authenticate/2]).
-export([call/3]).
-export([call/4]).
-export([call/5]).
-export([cancel/2]).
-export([challenge/2]).
-export([error/4]).
-export([error/5]).
-export([error/6]).
-export([error_from/3]).
-export([error_from/4]).
-export([error_from/5]).
-export([event/3]).
-export([event/4]).
-export([event/5]).
-export([event_received/3]).
-export([subscriber_received/3]).
-export([goodbye/2]).
-export([hello/2]).
-export([interrupt/2]).
-export([invocation/3]).
-export([invocation/4]).
-export([invocation/5]).
-export([is_message/1]).
-export([options/1]).
-export([publish/3]).
-export([publish/4]).
-export([publish/5]).
-export([published/2]).
-export([register/3]).
-export([registered/2]).
-export([request_id/1]).
-export([request_type/1]).
-export([result/2]).
-export([result/3]).
-export([result/4]).
-export([subscribe/3]).
-export([subscribed/2]).
-export([unregister/2]).
-export([unregistered/1]).
-export([unregistered/2]).
-export([unsubscribe/2]).
-export([unsubscribed/1]).
-export([welcome/2]).
-export([yield/2]).
-export([yield/3]).
-export([yield/4]).

%% Utils
-export([copy_event/2]).
-export([decode_partial/1]).
-export([details/1]).
-export([event_from/4]).
-export([is_partial/1]).
-export([partial/1]).
-export([set_args/2]).
-export([set_kwargs/2]).
-export([set_partial/2]).
-export([invocation_from/4]).
-export([result_from/3]).

%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_message(any()) -> boolean().

is_message(Term) when is_record(Term, abort) -> true;
is_message(Term) when is_record(Term, authenticate) -> true;
is_message(Term) when is_record(Term, call) -> true;
is_message(Term) when is_record(Term, cancel) -> true;
is_message(Term) when is_record(Term, challenge) -> true;
is_message(Term) when is_record(Term, error) -> true;
is_message(Term) when is_record(Term, event) -> true;
is_message(Term) when is_record(Term, goodbye) -> true;
is_message(Term) when is_record(Term, hello) -> true;
is_message(Term) when is_record(Term, interrupt) -> true;
is_message(Term) when is_record(Term, invocation) -> true;
is_message(Term) when is_record(Term, publish) -> true;
is_message(Term) when is_record(Term, published) -> true;
is_message(Term) when is_record(Term, register) -> true;
is_message(Term) when is_record(Term, registered) -> true;
is_message(Term) when is_record(Term, result) -> true;
is_message(Term) when is_record(Term, subscribe) -> true;
is_message(Term) when is_record(Term, subscribed) -> true;
is_message(Term) when is_record(Term, unregister) -> true;
is_message(Term) when is_record(Term, unregistered) -> true;
is_message(Term) when is_record(Term, unsubscribe) -> true;
is_message(Term) when is_record(Term, unsubscribed) -> true;
is_message(Term) when is_record(Term, welcome) -> true;
is_message(Term) when is_record(Term, yield) -> true;
is_message(_) -> false.


%% -----------------------------------------------------------------------------
%% @doc
%% If Details argument is not valid fails with an exception
%% @end
%% -----------------------------------------------------------------------------
-spec hello(uri(), map()) -> wamp_hello() | no_return().

hello(RealmUri, Details) when is_binary(RealmUri) ->
    #hello{
        realm_uri = bondy_wamp_uri:validate(RealmUri),
        details = bondy_wamp_details:new(hello, Details)
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec welcome(id(), map()) -> wamp_welcome() | no_return().

welcome(SessionId, Details)   ->
    #welcome{
        session_id = bondy_wamp_utils:validate_id(SessionId),
        details = bondy_wamp_details:new(welcome, Details)
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
%% "ABORT" gets sent only _before_ a _Session_ is established
-spec abort(map(), uri()) -> wamp_abort() | no_return().

abort(Details, ReasonUri) ->
    #abort{
        reason_uri = bondy_wamp_uri:validate(ReasonUri),
        details = bondy_wamp_details:new(abort, Details)
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec challenge(binary(), map()) -> wamp_challenge() | no_return().

challenge(AuthMethod, Extra) when is_map(Extra) ->
    #challenge{
        auth_method = AuthMethod,
        extra = Extra
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authenticate(binary(), map()) -> wamp_authenticate() | no_return().

authenticate(Signature, Extra) when is_map(Extra) ->
    #authenticate{
        signature = Signature,
        extra = Extra
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
%% "GOODBYE" is sent only _after_ a _Session_ is already established.
-spec goodbye(map(), uri()) -> wamp_goodbye() | no_return().

goodbye(Details, ReasonUri) ->
    #goodbye{
        reason_uri = bondy_wamp_uri:validate(ReasonUri),
        details = bondy_wamp_details:new(goodbye, Details)
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec error(pos_integer(), id(), map(), uri()) -> wamp_error() | no_return().

error(ReqType, ReqId, Details, ErrorUri) ->
    error(ReqType, ReqId, Details, ErrorUri, undefined, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec error(pos_integer(), id(), map(), uri(), list() | partial()) ->
    wamp_error() | no_return().

error(ReqType, ReqId, Details, ErrorUri, Args) when is_list(Args) ->
    error(ReqType, ReqId, Details, ErrorUri, Args, undefined);

error(ReqType, ReqId, Details, ErrorUri, {Enc, Bin} = Partial)
when is_atom(Enc), is_binary(Bin) ->
    M = error(ReqType, ReqId, Details, ErrorUri),
    M#error{partial = Partial}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec error(
    pos_integer(),
    id(),
    map(),
    uri(),
    list() | undefined,
    map() | undefined) ->
    wamp_error() | no_return().

error(ReqType, ReqId, Details0, ErrorUri, Args0, KWArgs0)
when is_map(Details0) ->
    Details = bondy_wamp_details:new(error, Details0),
    {Args, KWArgs} = validate_payload(Args0, KWArgs0, Details),

    #error{
        request_type = ReqType,
        request_id = bondy_wamp_utils:validate_id(ReqId),
        details = Details,
        error_uri = bondy_wamp_uri:validate(ErrorUri),
        args = Args,
        kwargs = KWArgs
    }.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec error_from(error_source(), map(), uri()) -> wamp_error() | no_return().

error_from(M, Details, ErrorUri) ->
    error_from(M, Details, ErrorUri, undefined, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec error_from(error_source(), map(), uri(), list()) ->
    wamp_error() | no_return().

error_from(M, Details, ErrorUri, Args) ->
    error_from(M, Details, ErrorUri, Args, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec error_from(
    error_source(),
    map(),
    uri(),
    list() | undefined,
    map() | undefined) ->
    wamp_error() | no_return().


error_from(#register{request_id = ReqId}, Details, ErrorUri, Args, KWArgs) ->
    error(?REGISTER, ReqId, Details, ErrorUri, Args, KWArgs);

error_from(#unregister{request_id = ReqId}, Details, ErrorUri, Args, KWArgs) ->
    error(?UNREGISTER, ReqId, Details, ErrorUri, Args, KWArgs);

error_from(#call{} = M, Details0, ErrorUri, Args, KWArgs) ->
    ReqId = M#call.request_id,
    Details = maybe_merge_details(M#call.options, Details0),
    error(?CALL, ReqId, Details, ErrorUri, Args, KWArgs);

error_from(#cancel{request_id = ReqId}, Details, ErrorUri, Args, KWArgs) ->
    error(?CANCEL, ReqId, Details, ErrorUri, Args, KWArgs);

error_from(#invocation{} = M, Details0, ErrorUri, Args, KWArgs) ->
    ReqId = M#invocation.request_id,
    Details = maybe_merge_details(M#invocation.details, Details0),
    error(?INVOCATION, ReqId, Details, ErrorUri, Args, KWArgs);

error_from(#subscribe{request_id = ReqId}, Details, ErrorUri, Args, KWArgs) ->
    error(?SUBSCRIBE, ReqId, Details, ErrorUri, Args, KWArgs);

error_from(#unsubscribe{request_id = ReqId}, Details, ErrorUri, Args, KWArgs) ->
    error(?UNSUBSCRIBE, ReqId, Details, ErrorUri, Args, KWArgs);

error_from(#publish{} = M, Details0, ErrorUri, Args, KWArgs) ->
    ReqId = M#publish.request_id,
    Details = maybe_merge_details(M#publish.options, Details0),
    error(?PUBLISH, ReqId, Details, ErrorUri, Args, KWArgs).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec publish(id(), map(), uri()) -> wamp_publish() | no_return().

publish(ReqId, Options, TopicUri) ->
    publish(ReqId, Options, TopicUri, undefined, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec publish(id(), map(), uri(), list()) -> wamp_publish() | no_return().

publish(ReqId, Options, TopicUri, Args) when is_list(Args) ->
    publish(ReqId, Options, TopicUri, Args, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec publish(id(), map(), uri(), list() | undefined, map() | undefined) ->
    wamp_publish() | no_return().

publish(ReqId, Options0, TopicUri, Args0, KWArgs0) ->
    Options = bondy_wamp_options:new(publish, Options0),
    {Args, KWArgs} = validate_payload(Args0, KWArgs0, Options),

    #publish{
        request_id = bondy_wamp_utils:validate_id(ReqId),
        options = Options,
        topic_uri = bondy_wamp_uri:validate(TopicUri),
        args = Args,
        kwargs = KWArgs
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec published(id(), id()) -> wamp_published() | no_return().

published(ReqId, PubId) ->
    #published{
        request_id = bondy_wamp_utils:validate_id(ReqId),
        publication_id = bondy_wamp_utils:validate_id(PubId)
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec subscribe(id(), map(), uri()) -> wamp_subscribe() | no_return().

subscribe(ReqId, Options0, TopicUri) when is_map(Options0) ->
    Options = bondy_wamp_options:new(subscribe, Options0),
    Match = maps:get(match, Options, ?EXACT_MATCH),

    #subscribe{
        request_id = bondy_wamp_utils:validate_id(ReqId),
        options = Options,
        topic_uri = bondy_wamp_uri:validate(TopicUri, Match)
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec subscribed(id(), id()) -> wamp_subscribed() | no_return().

subscribed(ReqId, SubsId) ->
    #subscribed{
        request_id = bondy_wamp_utils:validate_id(ReqId),
        subscription_id = bondy_wamp_utils:validate_id(SubsId)
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec unsubscribe(id(), id()) -> wamp_unsubscribe() | no_return().

unsubscribe(ReqId, SubsId) ->
    #unsubscribe{
        request_id = bondy_wamp_utils:validate_id(ReqId),
        subscription_id = bondy_wamp_utils:validate_id(SubsId)
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec unsubscribed(id()) -> wamp_unsubscribed() | no_return().

unsubscribed(ReqId) ->
    #unsubscribed{
        request_id = bondy_wamp_utils:validate_id(ReqId)
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec event(id(), id(), map()) -> wamp_event() | no_return().

event(SubsId, PubId, Details) ->
    event(SubsId, PubId, Details, undefined, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec event(id(), id(), map(), list()) -> wamp_event() | no_return().

event(SubsId, PubId, Details, Args) when is_list(Args) ->
    event(SubsId, PubId, Details, Args, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec event(id(), id(), map(), list() | undefined, map() | undefined) ->
    wamp_event() | no_return().

event(SubsId, PubId, Details0, Args0, KWArgs0) ->
    Details = bondy_wamp_details:new(event, Details0),
    {Args, KWArgs} = validate_payload(Args0, KWArgs0, Details),

    #event{
        subscription_id = bondy_wamp_utils:validate_id(SubsId),
        publication_id = bondy_wamp_utils:validate_id(PubId),
        details = Details,
        args = Args,
        kwargs = KWArgs
    }.


%% -----------------------------------------------------------------------------
%% @deprecated
%% %% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec copy_event(wamp_event(), SubsId :: id()) ->  wamp_event() | no_return().

copy_event(#event{} = Event, SubsId) ->
    Event#event{subscription_id = bondy_wamp_utils:validate_id(SubsId)}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec event_from(wamp_publish(), id(), id(), map()) ->
    wamp_event() | no_return().

event_from(#publish{} = M, SubsId, PubId, Details) ->
    #event{
        subscription_id = SubsId,
        publication_id = PubId,
        details = Details,
        args = M#publish.args,
        kwargs = M#publish.kwargs,
        partial =  M#publish.partial
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec event_received(id(), map(), uri()) -> wamp_event_received() | no_return().

event_received(PubId, Details0, Payload) when is_map(Details0) ->
    Details = bondy_wamp_details:new(event_received, Details0),

    #event_received{
        publication_id = bondy_wamp_utils:validate_id(PubId),
        details = Details,
        payload = Payload
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec subscriber_received(id(), map(), uri()) -> wamp_subscriber_received() | no_return().

subscriber_received(PubId, Details0, Payload) when is_map(Details0) ->
    Details = bondy_wamp_details:new(subscriber_received, Details0),

    #subscriber_received{
        publication_id = bondy_wamp_utils:validate_id(PubId),
        details = Details,
        payload = Payload
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec call(id(), map(), uri()) -> wamp_call() | no_return().

call(ReqId, Options, ProcedureUri) ->
    call(ReqId, Options, ProcedureUri, undefined, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec call(id(), map(), uri(), list()) -> wamp_call() | no_return().

call(ReqId, Options, ProcedureUri, Args) when is_list(Args) ->
    call(ReqId, Options, ProcedureUri, Args, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec call(id(), map(), uri(), list() | undefined, map() | undefined) ->
    wamp_call() | no_return().

call(ReqId, Options0, ProcedureUri, Args0, KWArgs0) ->
    Options = bondy_wamp_options:new(call, Options0),
    {Args, KWArgs} = validate_payload(Args0, KWArgs0, Options),

    #call{
        request_id = bondy_wamp_utils:validate_id(ReqId),
        options = Options,
        procedure_uri = bondy_wamp_uri:validate(ProcedureUri),
        args = Args,
        kwargs = KWArgs
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec cancel(id(), map()) -> wamp_cancel() | no_return().

cancel(ReqId, Options) ->
    #cancel{
        request_id = bondy_wamp_utils:validate_id(ReqId),
        options = bondy_wamp_options:new(cancel, Options)
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec result(id(), map()) -> wamp_result() | no_return().

result(ReqId, Details) ->
    result(ReqId, Details, undefined, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec result(id(), map(), list()) -> wamp_result() | no_return().

result(ReqId, Details, Args) when is_list(Args) ->
    result(ReqId, Details, Args, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec result(id(), map(), list() | undefined, map() | undefined) ->
    wamp_result() | no_return().

result(ReqId, Details0, Args0, KWArgs0) when is_map(Details0) ->
    Details = bondy_wamp_details:new(result, Details0),
    {Args, KWArgs} = validate_payload(Args0, KWArgs0, Details),

    #result{
        request_id = bondy_wamp_utils:validate_id(ReqId),
        details = Details,
        args = Args,
        kwargs = KWArgs
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec result_from(wamp_yield(), id(), map()) -> wamp_result() | no_return().

result_from(#yield{} = M, RegId, Details0) ->
    Details = bondy_wamp_details:new(result, Details0),

    #invocation{
        request_id = bondy_wamp_utils:validate_id(RegId),
        details = Details,
        args = M#yield.args,
        kwargs = M#yield.kwargs,
        partial = M#yield.partial
    }.

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec register(id(), map(), uri()) -> wamp_register() | no_return().

register(ReqId0, Options0, ProcedureUri) ->
    ReqId = bondy_wamp_utils:validate_id(ReqId0),
    Options = bondy_wamp_options:new(register, Options0),
    Match = maps:get(match, Options, ?EXACT_MATCH),

    #register{
        request_id = ReqId,
        options = Options,
        procedure_uri = bondy_wamp_uri:validate(ProcedureUri, Match)
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec registered(id(), id()) -> wamp_registered() | no_return().

registered(ReqId, RegId) ->
    #registered{
        request_id = bondy_wamp_utils:validate_id(ReqId),
        registration_id = bondy_wamp_utils:validate_id(RegId)
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec unregister(id(), id()) -> wamp_unregister() | no_return().

unregister(ReqId, RegId) ->
    #unregister{
        request_id = bondy_wamp_utils:validate_id(ReqId),
        registration_id = bondy_wamp_utils:validate_id(RegId)
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
% -spec registration_revocation(id(), id()) -> wamp_unregister() | no_return().

% registration_revocation(RegId, Reason) when is_binary(Reason) ->
%     Id = bondy_wamp_utils:validate_id(RegId),
%     #unregister2{
%         request_id = 0,
%         details = #{registration => Id, reason => Reason}
%     }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec unregistered(id()) -> wamp_unregistered() | no_return().

unregistered(ReqId) ->
    #unregistered{
        request_id = bondy_wamp_utils:validate_id(ReqId)
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec unregistered(id(), map()) -> wamp_unregistered() | no_return().

unregistered(ReqId, Details) when is_map(Details) ->
    #unregistered{
        request_id = bondy_wamp_utils:validate_id(ReqId),
        details = Details
    }.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec invocation(id(), id(), map()) -> wamp_invocation() | no_return().

invocation(ReqId, RegId, Details) ->
    invocation(ReqId, RegId, Details, undefined, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec invocation(id(), id(), map(), list()) -> wamp_invocation() | no_return().

invocation(ReqId, RegId, Details, Args) when is_list(Args) ->
    invocation(ReqId, RegId, Details, Args, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec invocation(id(), id(), map(), list() | undefined, map() | undefined) ->
    wamp_invocation() | no_return().

invocation(ReqId, RegId, Details0, Args0, KWArgs0) ->
    Details = bondy_wamp_details:new(invocation, Details0),
    {Args, KWArgs} = validate_payload(Args0, KWArgs0, Details),

    #invocation{
        request_id = bondy_wamp_utils:validate_id(ReqId),
        registration_id = bondy_wamp_utils:validate_id(RegId),
        details = Details,
        args = Args,
        kwargs = KWArgs
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec invocation_from(wamp_call(), id(), id(), map()) ->
    wamp_invocation() | no_return().

invocation_from(#call{} = M, ReqId, RegId, Details0) ->
    Details = bondy_wamp_details:new(invocation, Details0),

    #invocation{
        request_id = bondy_wamp_utils:validate_id(ReqId),
        registration_id = bondy_wamp_utils:validate_id(RegId),
        details = Details,
        args = M#call.args,
        kwargs = M#call.kwargs,
        partial = M#call.partial
    }.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec interrupt(id(), map()) -> wamp_interrupt() | no_return().

interrupt(ReqId, Options) ->
    #interrupt{
        request_id = bondy_wamp_utils:validate_id(ReqId),
        options = bondy_wamp_options:new(interrupt, Options)
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec yield(id(), map()) -> wamp_yield() | no_return().

yield(ReqId, Options) ->
    yield(ReqId, Options, undefined, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec yield(id(), map(), list()) -> wamp_yield() | no_return().

yield(ReqId, Options, Args) when is_list(Args) ->
    yield(ReqId, Options, Args, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec yield(id(), map(), list() | undefined, map() | undefined) ->
    wamp_yield() | no_return().

yield(ReqId, Options0, Args0, KWArgs0) ->
    Options = bondy_wamp_options:new(yield, Options0),
    {Args, KWArgs} = validate_payload(Args0, KWArgs0, Options),

    #yield{
        request_id = bondy_wamp_utils:validate_id(ReqId),
        options = Options,
        args = Args,
        kwargs = KWArgs
    }.



-spec options(
    wamp_call()
    | wamp_cancel()
    | wamp_interrupt()
    | wamp_publish()
    | wamp_register()
    | wamp_subscribe()
    | wamp_yield()
    ) -> map() | no_return().

options(#call{options = Val}) -> Val;
options(#cancel{options = Val}) -> Val;
options(#interrupt{options = Val}) -> Val;
options(#publish{options = Val}) -> Val;
options(#register{options = Val}) -> Val;
options(#subscribe{options = Val}) -> Val;
options(#yield{options = Val}) -> Val;
options(_) ->
    error(badarg).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec details(
    wamp_hello()
    | wamp_welcome()
    | wamp_abort()
    | wamp_goodbye()
    | wamp_result()
    | wamp_invocation()
    | wamp_event_received()
    | wamp_subscriber_received()
    ) -> map() | no_return().

details(#hello{details = Val}) -> Val;
details(#welcome{details = Val}) -> Val;
details(#abort{details = Val}) -> Val;
details(#goodbye{details = Val}) -> Val;
details(#result{details = Val}) -> Val;
details(#invocation{details = Val}) -> Val;
details(#event_received{details = Val}) -> Val;
details(#subscriber_received{details = Val}) -> Val;
details(_) ->
    error(badarg).



-spec request_id(t()) -> map() | no_return().

request_id(#call{request_id = Val}) -> Val;
request_id(#cancel{request_id = Val}) -> Val;
request_id(#error{request_id = Val}) -> Val;
request_id(#interrupt{request_id = Val}) -> Val;
request_id(#invocation{request_id = Val}) -> Val;
request_id(#publish{request_id = Val}) -> Val;
request_id(#published{request_id = Val}) -> Val;
request_id(#register{request_id = Val}) -> Val;
request_id(#registered{request_id = Val}) -> Val;
request_id(#result{request_id = Val}) -> Val;
request_id(#subscribe{request_id = Val}) -> Val;
request_id(#subscribed{request_id = Val}) -> Val;
request_id(#unregister{request_id = Val}) -> Val;
request_id(#unregistered{request_id = Val}) -> Val;
request_id(#unsubscribe{request_id = Val}) -> Val;
request_id(#unsubscribed{request_id = Val}) -> Val;
request_id(#yield{request_id = Val}) -> Val;
request_id(_) ->
    error(badarg).



-spec request_type(t()) -> map() | no_return().

request_type(#call{}) -> ?CALL;
request_type(#cancel{}) -> ?CANCEL;
request_type(#error{}) -> ?ERROR;
request_type(#interrupt{}) -> ?INTERRUPT;
request_type(#invocation{}) -> ?INVOCATION;
request_type(#publish{}) -> ?PUBLISH;
request_type(#published{}) -> ?PUBLISHED;
request_type(#register{}) -> ?REGISTER;
request_type(#registered{}) -> ?REGISTERED;
request_type(#result{}) -> ?RESULT;
request_type(#subscribe{}) -> ?SUBSCRIBE;
request_type(#subscribed{}) -> ?SUBSCRIBED;
request_type(#unregister{}) -> ?UNREGISTER;
request_type(#unregistered{}) -> ?UNREGISTERED;
request_type(#unsubscribe{}) -> ?UNSUBSCRIBE;
request_type(#unsubscribed{}) -> ?UNSUBSCRIBED;
request_type(#yield{}) -> ?YIELD;
request_type(_) ->
    error(badarg).


-spec is_partial(t()) -> boolean().

is_partial(#call{partial = Val}) -> Val =/= undefined;
is_partial(#error{partial = Val}) -> Val =/= undefined;
is_partial(#invocation{partial = Val}) -> Val =/= undefined;
is_partial(#publish{partial = Val}) -> Val =/= undefined;
is_partial(#result{partial = Val}) -> Val =/= undefined;
is_partial(#yield{partial = Val}) -> Val =/= undefined;
is_partial(_) ->
    error(badarg).


-spec partial(t()) -> {encoding(), binary()} | undefined.

partial(#call{partial = Val}) -> Val;
partial(#error{partial = Val}) -> Val;
partial(#invocation{partial = Val}) -> Val;
partial(#publish{partial = Val}) -> Val;
partial(#result{partial = Val}) -> Val;
partial(#yield{partial = Val}) -> Val;
partial(_) -> undefined.


%% Only support json partials for now
-spec set_partial(t(), {json, binary()}) -> t().

set_partial(#call{} = M, {json, Bin} = Partial) when is_binary(Bin) ->
    M#call{partial = Partial};

set_partial(#error{} = M, {json, Bin} = Partial) when is_binary(Bin) ->
    M#error{partial = Partial};

set_partial(#invocation{} = M, {json, Bin} = Partial) when is_binary(Bin) ->
    M#invocation{partial = Partial};

set_partial(#publish{} = M, {json, Bin} = Partial) when is_binary(Bin) ->
    M#publish{partial = Partial};

set_partial(#result{} = M, {json, Bin} = Partial) when is_binary(Bin) ->
    M#result{partial = Partial};

set_partial(#yield{} = M, {json, Bin} = Partial) when is_binary(Bin) ->
    M#yield{partial = Partial};

set_partial(_, _) ->
    error(badarg).


%% Only support json partials for now
-spec decode_partial(t()) -> t().

decode_partial(#call{partial = Partial} = M) when Partial =/= undefined ->
    do_decode_partial(M, Partial);

decode_partial(#error{partial = Partial} = M) when Partial =/= undefined ->
    do_decode_partial(M, Partial);

decode_partial(#invocation{partial = Partial} = M) when Partial =/= undefined ->
    do_decode_partial(M, Partial);

decode_partial(#publish{partial = Partial} = M) when Partial =/= undefined ->
    do_decode_partial(M, Partial);

decode_partial(#result{partial = Partial} = M) when Partial =/= undefined ->
    do_decode_partial(M, Partial);

decode_partial(#yield{partial = Partial} = M) when Partial =/= undefined ->
    do_decode_partial(M, Partial);

decode_partial(M) ->
    M.


-spec set_args(t(), list()) -> t().

set_args(#call{} = M, Args) when is_list(Args) ->
    M#call{args = Args};

set_args(#error{} = M, Args) when is_list(Args) ->
    M#error{args = Args};

set_args(#invocation{} = M, Args) when is_list(Args) ->
    M#invocation{args = Args};

set_args(#publish{} = M, Args) when is_list(Args) ->
    M#publish{args = Args};

set_args(#result{} = M, Args) when is_list(Args) ->
    M#result{args = Args};

set_args(#yield{} = M, Args) when is_list(Args) ->
    M#yield{args = Args};

set_args(_, _) ->
    error(badarg).


-spec set_kwargs(t(), map()) -> t().

set_kwargs(#call{} = M, KWArgs) when is_map(KWArgs) ->
    M#call{kwargs = KWArgs};

set_kwargs(#error{} = M, KWArgs) when is_map(KWArgs) ->
    M#error{kwargs = KWArgs};

set_kwargs(#invocation{} = M, KWArgs) when is_map(KWArgs) ->
    M#invocation{kwargs = KWArgs};

set_kwargs(#publish{} = M, KWArgs) when is_map(KWArgs) ->
    M#publish{kwargs = KWArgs};

set_kwargs(#result{} = M, KWArgs) when is_map(KWArgs) ->
    M#result{kwargs = KWArgs};

set_kwargs(#yield{} = M, KWArgs) when is_map(KWArgs) ->
    M#yield{kwargs = KWArgs};

set_kwargs(_, _) ->
    error(badarg).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
validate_payload([Payload] = Args, undefined, #{ppt_scheme := _})
when is_binary(Payload) ->
    {Args, undefined};

validate_payload(_, _, #{ppt_scheme := _}) ->
    error(badarg);

validate_payload([], undefined, _) ->
    {undefined, undefined};

validate_payload([], KWArgs, _) ->
    {undefined, validate_kwargs(KWArgs)};

validate_payload(Args, KWArgs, _) ->
    {Args, validate_kwargs(KWArgs)}.


%% @private
validate_kwargs(undefined) ->
    undefined;

validate_kwargs(KWArgs) when is_map(KWArgs) andalso map_size(KWArgs) =:= 0 ->
    undefined;

validate_kwargs(KWArgs) when is_map(KWArgs) ->
    KWArgs.


%% @private
maybe_merge_details(MessageAttrs, Details) ->
    Attrs = [ppt_cipher, ppt_keyid, ppt_scheme, ppt_serializer],
    maps:merge(Details, maps:with(Attrs, MessageAttrs)).


%% @private
do_decode_partial(M0, {json, Bin}) ->
    case bondy_wamp_json:decode_tail(Bin) of
        [] ->
            set_partial(M0, undefined);

        [Args] ->
            M1 = set_partial(M0, undefined),
            set_args(M1, Args);

        [Args, KWArgs] ->
            M1 = set_partial(M0, undefined),
            M2 = set_args(M1, Args),
            set_kwargs(M2, KWArgs)
    end.
