-module(ramp_message).
-include("ramp.hrl").

-export([hello/2]).
-export([welcome/2]).
-export([abort/2]).
-export([challenge/2]).
-export([authenticate/2]).
-export([goodbye/2]).
-export([heartbeat/0]).
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



hello(RealmUri, Details) ->
    #hello{
        realm_uri = RealmUri,
        details = Details
    }.

welcome(SessionId, Details) ->
    #welcome{
        session_id = SessionId,
        details = Details
    }.

abort(Details, ReasonUri) ->
    #abort{
        details = Details,
        reason_uri = ReasonUri
    }.

challenge(AuthMethod, Extra) ->
    #challenge{
        auth_method = AuthMethod,
        extra = Extra
    }.

authenticate(Signature, Extra) ->
    #authenticate{
        signature = Signature,
        extra = Extra
    }.

goodbye(Details, ReasonUri) ->
    #goodbye{
        details = Details,
        reason_uri = ReasonUri
    }.

heartbeat() ->
    ok.

error(ReqType, ReqId, Details, ErrorUri) ->
    #error{
        request_type = ReqType,
        request_id = ReqId,
        details = Details,
        error_uri = ErrorUri
    }.

error(ReqType, ReqId, Details, ErrorUri, Args) ->
    #error{
        request_type = ReqType,
        request_id = ReqId,
        details = Details,
        error_uri = ErrorUri,
        arguments = Args
    }.

error(ReqType, ReqId, Details, ErrorUri, Args, Payload) ->
    #error{
        request_type = ReqType,
        request_id = ReqId,
        details = Details,
        error_uri = ErrorUri,
        arguments = Args,
        payload = Payload
    }.

publish(ReqId, Options, TopicUri) ->
    #publish{
        request_id = ReqId,
        options = Options,
        topic_uri = TopicUri
    }.

publish(ReqId, Options, TopicUri, Args) ->
    #publish{
        request_id = ReqId,
        options = Options,
        topic_uri = TopicUri,
        arguments = Args
    }.

publish(ReqId, Options, TopicUri, Args, Payload) ->
    #publish{
        request_id = ReqId,
        options = Options,
        topic_uri = TopicUri,
        arguments = Args,
        payload = Payload
    }.

published(ReqId, PubId) ->
    #published{
        request_id = ReqId,
        publication_id = PubId
    }.

subscribe(ReqId, Options, TopicUri) ->
    #subscribe{
        request_id = ReqId,
        options = Options,
        topic_uri = TopicUri
    }.

subscribed(ReqId, SubsId) ->
    #subscribed{
        request_id = ReqId,
        subscription_id = SubsId
    }.

unsubscribe(ReqId, SubsId) ->
    #unsubscribe{
        request_id = ReqId,
        subscription_id = SubsId
    }.

unsubscribed(ReqId) ->
    #unsubscribed{
        request_id = ReqId
    }.

event(SubsId, PubId, Details) ->
    #event{
        subscription_id = SubsId,
        publication_id = PubId,
        details = Details
    }.

event(SubsId, PubId, Details, Args) ->
    #event{
        subscription_id = SubsId,
        publication_id = PubId,
        details = Details,
        arguments = Args
    }.

event(SubsId, PubId, Details, Args, Payload) ->
    #event{
        subscription_id = SubsId,
        publication_id = PubId,
        details = Details,
        arguments = Args,
        payload = Payload
    }.

call(ReqId, Options, ProcedureUri) ->
    #call{
        request_id = ReqId,
        options = Options,
        procedure_uri = ProcedureUri
    }.

call(ReqId, Options, ProcedureUri, Args) ->
    #call{
        request_id = ReqId,
        options = Options,
        procedure_uri = ProcedureUri,
        arguments = Args
    }.

call(ReqId, Options, ProcedureUri, Args, Payload) ->
    #call{
        request_id = ReqId,
        options = Options,
        procedure_uri = ProcedureUri,
        arguments = Args,
        payload = Payload
    }.

cancel(ReqId, Options) ->
    #cancel{
        request_id = ReqId,
        options = Options
    }.

result(ReqId, Details) ->
    #result{
        request_id = ReqId,
        details = Details
    }.

result(ReqId, Details, Args) ->
    #result{
        request_id = ReqId,
        details = Details,
        arguments = Args
    }.

result(ReqId, Details, Args, Payload) ->
    #result{
        request_id = ReqId,
        details = Details,
        arguments = Args,
        payload = Payload
    }.

register(ReqId, Options, ProcedureUri) ->
    #register{
        request_id = ReqId,
        options = Options,
        procedure_uri = ProcedureUri
    }.

registered(ReqId, RegId) ->
    #registered{
        request_id = ReqId,
        registration_id = RegId
    }.

unregister(ReqId, RegId) ->
    #unregister{
        request_id = ReqId,
        registration_id = RegId
    }.

unregistered(ReqId) ->
    #unregistered{
        request_id = ReqId
    }.

invocation(ReqId, RegId, Details) ->
    #invocation{
        request_id = ReqId,
        registration_id = RegId,
        details = Details
    }.

invocation(ReqId, RegId, Details, Args) ->
    #invocation{
        request_id = ReqId,
        registration_id = RegId,
        details = Details,
        arguments = Args
    }.

invocation(ReqId, RegId, Details, Args, Payload) ->
    #invocation{
        request_id = ReqId,
        registration_id = RegId,
        details = Details,
        arguments = Args,
        payload = Payload
    }.

interrupt(ReqId, Options) ->
    #interrupt{
        request_id = ReqId,
        options = Options
    }.

yield(ReqId, Options) ->
    #yield{
        request_id = ReqId,
        options = Options
    }.

yield(ReqId, Options, Args) ->
    #yield{
        request_id = ReqId,
        options = Options,
        arguments = Args
    }.

yield(ReqId, Options, Args, Payload) ->
    #yield{
        request_id = ReqId,
        options = Options,
        arguments = Args,
        payload = Payload
    }.
