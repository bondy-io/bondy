-module(ramp_packing).
-include("ramp.hrl").

-export([pack/1]).
-export([unpack/1]).

pack(#error{} = M) ->
    #error{
        request_type = ReqType,
        request_id = ReqId,
        details = Details,
        error_uri = ErrorUri,
        arguments = Args,
        payload = Payload
    } = M,
    T = pack_optionals(Args, Payload),
    [?ERROR, ReqType, ReqId, Details, ErrorUri | T];

pack(#publish{} = M) ->
    #publish{
        request_id = ReqId,
        options = Options,
        topic_uri = TopicUri,
        arguments = Args,
        payload = Payload
    } = M,
    T = pack_optionals(Args, Payload),
    [?PUBLISH, ReqId, Options, TopicUri | T];

pack(#event{} = M) ->
    #event{
        subscription_id = SubsId,
        publication_id = PubId,
        details = Details,
        arguments = Args,
        payload = Payload
    } = M,
    T = pack_optionals(Args, Payload),
    [?EVENT, SubsId, PubId, Details | T];

pack(#call{} = M) ->
    #call{
        request_id = ReqId,
        options = Options,
        procedure_uri = ProcedureUri,
        arguments = Args,
        payload = Payload
    } = M,
    T = pack_optionals(Args, Payload),
    [?CALL, ReqId, Options, ProcedureUri | T];

pack(#result{} = M) ->
    #result{
        request_id = ReqId,
        details = Details,
        arguments = Args,
        payload = Payload
    } = M,
    T = pack_optionals(Args, Payload),
    [?RESULT, ReqId, Details | T];

pack(#invocation{} = M) ->
    #invocation{
        request_id = ReqId,
        registration_id = RegId,
        details = Details,
        arguments = Args,
        payload = Payload
    } = M,
    T = pack_optionals(Args, Payload),
    [?INVOCATION, ReqId, RegId, Details | T];

pack(#yield{} = M) ->
    #yield{
        request_id = ReqId,
        options = Options,
        arguments = Args,
        payload = Payload
    } = M,
    T = pack_optionals(Args, Payload),
    [?YIELD, ReqId, Options | T];

pack(M) when is_tuple(M) ->
    [_H|T] = tuple_to_list(M),
    [pack_message_type(element(1, M)), T].



unpack([?HELLO, RealmUri, Details]) ->
    #hello{
        realm_uri = validate_uri(RealmUri),
        details = validate_dict(Details)
    };

unpack([?WELCOME, SessionId, Details]) ->
    #welcome{
        session_id = validate_id(SessionId),
        details = validate_dict(Details)
    };

unpack([?ABORT, Details, ReasonUri]) ->
    #abort{
        details = validate_dict(Details),
        reason_uri = validate_uri(ReasonUri)
    };

unpack([?GOODBYE, Details, ReasonUri]) ->
    #goodbye{
        details = validate_dict(Details),
        reason_uri = validate_uri(ReasonUri)
    };

unpack([?ERROR, ReqType, ReqId, Details, ErrorUri]) ->
    #error{
        request_type = ReqType,
        request_id = validate_id(ReqId),
        details = validate_dict(Details),
        error_uri = validate_uri(ErrorUri)
    };

unpack([?ERROR, ReqType, ReqId, Details, ErrorUri, Args]) when is_list(Args) ->
    #error{
        request_type = ReqType,
        request_id = validate_id(ReqId),
        details = validate_dict(Details),
        error_uri = validate_uri(ErrorUri),
        arguments = Args
    };

unpack([?ERROR, ReqType, ReqId, Details, ErrorUri, Args, Payload])
 when is_list(Args), is_map(Payload) ->
    #error{
        request_type = ReqType,
        request_id = validate_id(ReqId),
        details = validate_dict(Details),
        error_uri = validate_uri(ErrorUri),
        arguments = Args,
        payload = Payload
    };

unpack([?PUBLISH, ReqId, Options, TopicUri]) ->
    #publish{
        request_id = validate_id(ReqId),
        options = validate_dict(Options),
        topic_uri = validate_uri(TopicUri)
    };

unpack([?PUBLISH, ReqId, Options, TopicUri, Args]) ->
    #publish{
        request_id = validate_id(ReqId),
        options = validate_dict(Options),
        topic_uri = validate_uri(TopicUri),
        arguments = Args
    };

unpack([?PUBLISH, ReqId, Options, TopicUri, Args, Payload]) ->
    #publish{
        request_id = validate_id(ReqId),
        options = validate_dict(Options),
        topic_uri = validate_uri(TopicUri),
        arguments = Args,
        payload = Payload
    };

unpack([?PUBLISHED, ReqId, PubId]) ->
    #published{
        request_id = validate_id(ReqId),
        publication_id = validate_id(PubId)
    };

unpack([?SUBSCRIBE, ReqId, Options, TopicUri]) ->
    #subscribe{
        request_id = validate_id(ReqId),
        options = validate_dict(Options),
        topic_uri = validate_uri(TopicUri)
    };

unpack([?SUBSCRIBED, ReqId, SubsId]) ->
    #subscribed{
        request_id = validate_id(ReqId),
        subscription_id = validate_id(SubsId)
    };

unpack([?UNSUBSCRIBE, ReqId, SubsId]) ->
    #unsubscribe{
        request_id = validate_id(ReqId),
        subscription_id = validate_id(SubsId)
    };

unpack([?UNSUBSCRIBED, ReqId]) ->
    #unsubscribed{
        request_id = validate_id(ReqId)
    };

unpack([?EVENT, SubsId, PubId, Details]) ->
    #event{
        subscription_id = validate_id(SubsId),
        publication_id = validate_id(PubId),
        details = validate_dict(Details)
    };

unpack([?EVENT, SubsId, PubId, Details, Args]) ->
    #event{
        subscription_id = validate_id(SubsId),
        publication_id = validate_id(PubId),
        details = validate_dict(Details),
        arguments = Args
    };

unpack([?EVENT, SubsId, PubId, Details, Args, Payload]) ->
    #event{
        subscription_id = validate_id(SubsId),
        publication_id = validate_id(PubId),
        details = validate_dict(Details),
        arguments = Args,
        payload = Payload
    };

unpack([?CALL, ReqId, Options, ProcedureUri]) ->
    #call{
        request_id = validate_id(ReqId),
        options = validate_dict(Options),
        procedure_uri = ProcedureUri
    };

unpack([?CALL, ReqId, Options, ProcedureUri, Args]) ->
    #call{
        request_id = validate_id(ReqId),
        options = validate_dict(Options),
        procedure_uri = validate_uri(ProcedureUri),
        arguments = Args
    };

unpack([?CALL, ReqId, Options, ProcedureUri, Args, Payload]) ->
    #call{
        request_id = validate_id(ReqId),
        options = validate_dict(Options),
        procedure_uri = validate_uri(ProcedureUri),
        arguments = Args,
        payload = Payload
    };

unpack([?RESULT, ReqId, Details]) ->
    #result{
        request_id = validate_id(ReqId),
        details = validate_dict(Details)
    };

unpack([?RESULT, ReqId, Details, Args]) ->
    #result{
        request_id = validate_id(ReqId),
        details = validate_dict(Details),
        arguments = Args
    };

unpack([?RESULT, ReqId, Details, Args, Payload]) ->
    #result{
        request_id = validate_id(ReqId),
        details = validate_dict(Details),
        arguments = Args,
        payload = Payload
    };

unpack([?REGISTER, ReqId, Options, ProcedureUri]) ->
    #register{
        request_id = validate_id(ReqId),
        options = validate_dict(Options),
        procedure_uri = ProcedureUri
    };

unpack([?REGISTERED, ReqId, RegId]) ->
    #registered{
        request_id = validate_id(ReqId),
        registration_id = validate_id(RegId)
    };

unpack([?UNREGISTER, ReqId, RegId]) ->
    #unregister{
        request_id = validate_id(ReqId),
        registration_id = validate_id(RegId)
    };

unpack([?UNREGISTERED, ReqId]) ->
    #unregistered{
        request_id = validate_id(ReqId)
    };

unpack([?INVOCATION, ReqId, RegId, Details]) ->
    #invocation{
        request_id = validate_id(ReqId),
        registration_id = validate_id(RegId),
        details = validate_dict(Details)
    };

unpack([?INVOCATION, ReqId, RegId, Details, Args]) ->
    #invocation{
        request_id = validate_id(ReqId),
        registration_id = validate_id(RegId),
        details = validate_dict(Details),
        arguments = Args
    };

unpack([?INVOCATION, ReqId, RegId, Details, Args, Payload]) ->
    #invocation{
        request_id = validate_id(ReqId),
        registration_id = validate_id(RegId),
        details = validate_dict(Details),
        arguments = Args,
        payload = Payload
    };

unpack([?YIELD, ReqId, Options]) ->
    #yield{
        request_id = validate_id(ReqId),
        options = validate_dict(Options)
    };

unpack([?YIELD, ReqId, Options, Args]) ->
    #yield{
        request_id = validate_id(ReqId),
        options = validate_dict(Options),
        arguments = Args
    };

unpack([?YIELD, ReqId, Options, Args, Payload]) ->
    #yield{
        request_id = validate_id(ReqId),
        options = validate_dict(Options),
        arguments = Args,
        payload = Payload
    }.


%% =============================================================================
%% PRIVATE
%% =============================================================================

pack_optionals(undefined, undefined) -> [];
pack_optionals(Args, undefined) -> [Args];
pack_optionals(Args, Payload) -> [Args, Payload].


validate_dict(Map) ->
    lists:any(fun is_invalid_dict_key/1, maps:keys(Map)) == false
    orelse error({invalid_dict, Map}).


is_invalid_dict_key(_Key) ->
    %% TODO
    false.


validate_id(Id) ->
    ramp_id:is_valid(Id) == true orelse error({invalid_id, Id}).

validate_uri(Uri) ->
    ramp_uri:is_valid(Uri) == true orelse error({invalid_uri, Uri}).

%% @private
pack_message_type(hello) -> ?HELLO;
pack_message_type(welcome) -> ?WELCOME;
pack_message_type(abort) -> ?ABORT;
pack_message_type(challenge) -> ?CHALLENGE;
pack_message_type(authenticate) -> ?AUTHENTICATE;
pack_message_type(goodbye) -> ?GOODBYE;
pack_message_type(heartbeat) -> ?HEARTBEAT;
pack_message_type(error) -> ?ERROR;
pack_message_type(publish) -> ?PUBLISH;
pack_message_type(published) -> ?PUBLISHED;
pack_message_type(subscribe) -> ?SUBSCRIBE;
pack_message_type(subscribed) -> ?SUBSCRIBED;
pack_message_type(unsubscribe) -> ?UNSUBSCRIBE;
pack_message_type(unsubscribed) -> ?UNSUBSCRIBED;
pack_message_type(event) -> ?EVENT;
pack_message_type(call) -> ?CALL;
pack_message_type(cancel) -> ?CANCEL;
pack_message_type(result) -> ?RESULT;
pack_message_type(register) -> ?REGISTER;
pack_message_type(registered) -> ?REGISTERED;
pack_message_type(unregister) -> ?UNREGISTER;
pack_message_type(unregistered) -> ?UNREGISTERED;
pack_message_type(invocation) -> ?INVOCATION;
pack_message_type(interrupt) -> ?INTERRUPT;
pack_message_type(yield) -> ?YIELD.
