%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2016. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%%
%% @end
%% =============================================================================
-module(juno_message).
-include("juno.hrl").

-export([hello/2]).
-export([welcome/2]).
-export([abort/2]).
-export([challenge/2]).
-export([authenticate/2]).
-export([goodbye/2]).
-export([error/4, error/5, error/6]).
-export([publish/3, publish/4, publish/5]).
-export([published/2]).
-export([subscribe/3]).
-export([subscribed/2]).
-export([unsubscribe/2]).
-export([unsubscribed/1]).
-export([event/3, event/4, event/5]).
-export([call/3, call/4, call/5]).
-export([cancel/2]).
-export([result/2, result/3, result/4]).
-export([register/3]).
-export([registered/2]).
-export([unregister/2]).
-export([unregistered/1]).
-export([invocation/3, invocation/4, invocation/5]).
-export([interrupt/2]).
-export([yield/2, yield/3, yield/4]).



-spec hello(uri(), map()) -> #hello{}.
hello(RealmUri, Details) ->
    #hello{
        realm_uri = RealmUri,
        details = Details
    }.


-spec welcome(id(), map()) -> #welcome{}.
welcome(SessionId, Details) ->
    #welcome{
        session_id = SessionId,
        details = Details
    }.

%% "ABORT" gets sent only _before_ a _Session_ is established, while
-spec abort(map(), uri()) -> #abort{}.
abort(Details, ReasonUri) ->
    #abort{
        details = Details,
        reason_uri = ReasonUri
    }.


-spec challenge(binary(), map()) -> #challenge{}.
challenge(AuthMethod, Extra) ->
    #challenge{
        auth_method = AuthMethod,
        extra = Extra
    }.


-spec authenticate(binary(), map()) -> #authenticate{}.
authenticate(Signature, Extra) ->
    #authenticate{
        signature = Signature,
        extra = Extra
    }.

%% "GOODBYE" is sent only _after_ a _Session_ is already established.
-spec goodbye(map(), uri()) -> #goodbye{}.
goodbye(Details, ReasonUri) ->
    #goodbye{
        details = Details,
        reason_uri = ReasonUri
    }.


-spec error(binary(), id(), map(), uri()) -> #error{}.
error(ReqType, ReqId, Details, ErrorUri) ->
    #error{
        request_type = ReqType,
        request_id = ReqId,
        details = Details,
        error_uri = ErrorUri
    }.


-spec error(binary(), id(), map(), uri(), list()) -> #error{}.
error(ReqType, ReqId, Details, ErrorUri, Args) ->
    #error{
        request_type = ReqType,
        request_id = ReqId,
        details = Details,
        error_uri = ErrorUri,
        arguments = Args
    }.


-spec error(binary(), id(), map(), uri(), list(), map()) -> #error{}.
error(ReqType, ReqId, Details, ErrorUri, Args, Payload) ->
    #error{
        request_type = ReqType,
        request_id = ReqId,
        details = Details,
        error_uri = ErrorUri,
        arguments = Args,
        payload = Payload
    }.


-spec publish(id(), map(), uri()) -> #publish{}.
publish(ReqId, Options, TopicUri) ->
    #publish{
        request_id = ReqId,
        options = Options,
        topic_uri = TopicUri
    }.


-spec publish(id(), map(), uri(), list()) -> #publish{}.
publish(ReqId, Options, TopicUri, Args) ->
    #publish{
        request_id = ReqId,
        options = Options,
        topic_uri = TopicUri,
        arguments = Args
    }.


-spec publish(id(), map(), uri(), list(), map()) -> #publish{}.
publish(ReqId, Options, TopicUri, Args, Payload) ->
    #publish{
        request_id = ReqId,
        options = Options,
        topic_uri = TopicUri,
        arguments = Args,
        payload = Payload
    }.


-spec published(id(), id()) -> #published{}.
published(ReqId, PubId) ->
    #published{
        request_id = ReqId,
        publication_id = PubId
    }.


-spec subscribe(id(), map(), uri()) -> #subscribe{}.
subscribe(ReqId, Options, TopicUri) ->
    #subscribe{
        request_id = ReqId,
        options = Options,
        topic_uri = TopicUri
    }.


-spec subscribed(id(), id()) -> #subscribed{}.
subscribed(ReqId, SubsId) ->
    #subscribed{
        request_id = ReqId,
        subscription_id = SubsId
    }.


-spec unsubscribe(id(), id()) -> #unsubscribe{}.
unsubscribe(ReqId, SubsId) ->
    #unsubscribe{
        request_id = ReqId,
        subscription_id = SubsId
    }.


-spec unsubscribed(id()) -> #unsubscribed{}.
unsubscribed(ReqId) ->
    #unsubscribed{
        request_id = ReqId
    }.


-spec event(id(), id(), map()) -> #event{}.
event(SubsId, PubId, Details) ->
    #event{
        subscription_id = SubsId,
        publication_id = PubId,
        details = Details
    }.


-spec event(id(), id(), map(), list()) -> #event{}.
event(SubsId, PubId, Details, Args) ->
    #event{
        subscription_id = SubsId,
        publication_id = PubId,
        details = Details,
        arguments = Args
    }.


-spec event(id(), id(), map(), list(), map()) -> #event{}.
event(SubsId, PubId, Details, Args, Payload) ->
    #event{
        subscription_id = SubsId,
        publication_id = PubId,
        details = Details,
        arguments = Args,
        payload = Payload
    }.


-spec call(id(), map(), uri()) -> #call{}.
call(ReqId, Options, ProcedureUri) ->
    #call{
        request_id = ReqId,
        options = Options,
        procedure_uri = ProcedureUri
    }.


-spec call(id(), map(), uri(), list()) -> #call{}.
call(ReqId, Options, ProcedureUri, Args) ->
    #call{
        request_id = ReqId,
        options = Options,
        procedure_uri = ProcedureUri,
        arguments = Args
    }.


-spec call(id(), map(), uri(), list(), map()) -> #call{}.
call(ReqId, Options, ProcedureUri, Args, Payload) ->
    #call{
        request_id = ReqId,
        options = Options,
        procedure_uri = ProcedureUri,
        arguments = Args,
        payload = Payload
    }.


-spec cancel(id(), map()) -> #cancel{}.
cancel(ReqId, Options) ->
    #cancel{
        request_id = ReqId,
        options = Options
    }.


-spec result(id(), map()) -> #result{}.
result(ReqId, Details) ->
    #result{
        request_id = ReqId,
        details = Details
    }.


-spec result(id(), map(), list()) -> #result{}.
result(ReqId, Details, Args) ->
    #result{
        request_id = ReqId,
        details = Details,
        arguments = Args
    }.


-spec result(id(), map(), list(), map()) -> #result{}.
result(ReqId, Details, Args, Payload) ->
    #result{
        request_id = ReqId,
        details = Details,
        arguments = Args,
        payload = Payload
    }.


-spec register(id(), map(), uri()) -> #register{}.
register(ReqId, Options, ProcedureUri) ->
    #register{
        request_id = ReqId,
        options = Options,
        procedure_uri = ProcedureUri
    }.


-spec registered(id(), id()) -> #registered{}.
registered(ReqId, RegId) ->
    #registered{
        request_id = ReqId,
        registration_id = RegId
    }.


-spec unregister(id(), id()) -> #unregister{}.
unregister(ReqId, RegId) ->
    #unregister{
        request_id = ReqId,
        registration_id = RegId
    }.


-spec unregistered(id()) -> #unregistered{}.
unregistered(ReqId) ->
    #unregistered{
        request_id = ReqId
    }.


-spec invocation(id(), id(), map()) -> #invocation{}.
invocation(ReqId, RegId, Details) ->
    #invocation{
        request_id = ReqId,
        registration_id = RegId,
        details = Details
    }.


-spec invocation(id(), id(), map(), list()) -> #invocation{}.
invocation(ReqId, RegId, Details, Args) ->
    #invocation{
        request_id = ReqId,
        registration_id = RegId,
        details = Details,
        arguments = Args
    }.


-spec invocation(id(), id(), map(), list(), map()) -> #invocation{}.
invocation(ReqId, RegId, Details, Args, Payload) ->
    #invocation{
        request_id = ReqId,
        registration_id = RegId,
        details = Details,
        arguments = Args,
        payload = Payload
    }.


-spec interrupt(id(), map()) -> #interrupt{}.
interrupt(ReqId, Options) ->
    #interrupt{
        request_id = ReqId,
        options = Options
    }.


-spec yield(id(), map()) -> #yield{}.
yield(ReqId, Options) ->
    #yield{
        request_id = ReqId,
        options = Options
    }.


-spec yield(id(), map(), list()) -> #yield{}.
yield(ReqId, Options, Args) ->
    #yield{
        request_id = ReqId,
        options = Options,
        arguments = Args
    }.


-spec yield(id(), map(), list(), map()) -> #yield{}.
yield(ReqId, Options, Args, Payload) ->
    #yield{
        request_id = ReqId,
        options = Options,
        arguments = Args,
        payload = Payload
    }.
