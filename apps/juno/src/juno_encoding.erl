%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2016. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%% Handles the packing/unpacking and encoding/decoding of WAMP messages.
%% @end
%% =============================================================================
-module(juno_encoding).
-include("juno.hrl").

-define(JSON_BATCHED_SEPARATOR, <<24>>). % ASCII CANCEL

-export([pack/1]).
-export([unpack/1]).
-export([encode/2]).
-export([decode/3]).




%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec decode(Data :: binary(), Format :: atom(), Messages :: list()) ->
    {ok, Messages :: list(tuple()), Rest :: binary()}.
decode(Data, text, json) ->
    decode_text(Data, json, []);
decode(Data, text, erl) ->
    decode_text(Data, erl, []);
decode(Data, binary, json) ->
    decode_binary(Data, json, []);
decode(Data, binary, erl) ->
    decode_binary(Data, erl, []).

%% @private
decode_text(Data, erl, Acc) ->
    Term = binary_to_term(Data),
    M = unpack(Term),
    {[M | Acc], <<>>};
decode_text(Data, json, Acc) ->
    Term = jsx:decode(Data, [return_maps]),
    M = unpack(Term),
    {[M | Acc], <<>>}.

%% @private
decode_binary(_Data, erl, _Acc) ->
    error(not_yet_implemented);

decode_binary(_Data, _, _) ->
    error(not_yet_implemented).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
encode(Message, Encoding) when is_tuple(Message) ->
    encode(pack(Message), Encoding);
encode(Message, erl) when is_list(Message) ->
    term_to_binary(Message);
encode(Message, json) when is_list(Message) ->
    jsx:encode(Message);
encode(Message, msgpack) when is_list(Message) ->
    msgpack:pack(Message, [{format, map}]);
encode(Message, Format) when is_list(Message) ->
    error({not_yet_implemented, Format}).



%% -----------------------------------------------------------------------------
%% @doc
%% Returns a message in WAMP list format.
%% @end
%% -----------------------------------------------------------------------------
-spec pack(message()) -> list().
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
    [pack_message_type(element(1, M)) | T].



%% -----------------------------------------------------------------------------
%% @doc
%% Converts a message from a WAMP list format to an erlang record.
%% See {@link juno_message} for all message types.
%% @end
%% -----------------------------------------------------------------------------
-spec unpack(list()) -> message().
unpack([?HELLO, RealmUri, Details]) ->
    juno_message:hello(validate_uri(RealmUri), validate_dict(Details));

unpack([?WELCOME, SessionId, Details]) ->
    juno_message:welcome(validate_id(SessionId), validate_dict(Details));

unpack([?CHALLENGE, AuthMethod, Extra]) ->
    juno_message:challenge(AuthMethod, Extra);

unpack([?AUTHENTICATE, Signature, Extra]) ->
    juno_message:authenticate(Signature, Extra);

unpack([?ABORT, Details, ReasonUri]) ->
    juno_message:abort(validate_dict(Details), validate_uri(ReasonUri));

unpack([?GOODBYE, Details, ReasonUri]) ->
    juno_message:goodbye(validate_dict(Details), validate_uri(ReasonUri));

unpack([?ERROR, ReqType, ReqId, Details, ErrorUri]) ->
    juno_message:error(
        ReqType,
        validate_id(ReqId),
        validate_dict(Details),
        validate_uri(ErrorUri)
    );

unpack([?ERROR, ReqType, ReqId, Details, ErrorUri, Args]) when is_list(Args) ->
    juno_message:error(
        ReqType,
        validate_id(ReqId),
        validate_dict(Details),
        validate_uri(ErrorUri),
        Args
    );

unpack([?ERROR, ReqType, ReqId, Details, ErrorUri, Args, Payload])
 when is_list(Args), is_map(Payload) ->
    juno_message:error(
        ReqType,
        validate_id(ReqId),
        validate_dict(Details),
        validate_uri(ErrorUri),
        Args,
        Payload
    );

unpack([?PUBLISH, ReqId, Options, TopicUri]) ->
    juno_message:publish(
        validate_id(ReqId), validate_dict(Options), validate_uri(TopicUri));

unpack([?PUBLISH, ReqId, Options, TopicUri, Args]) ->
    juno_message:publish(
        validate_id(ReqId),
        validate_dict(Options),
        validate_uri(TopicUri),
        Args
    );

unpack([?PUBLISH, ReqId, Options, TopicUri, Args, Payload]) ->
    juno_message:publish(
        validate_id(ReqId),
        validate_dict(Options),
        validate_uri(TopicUri),
        Args,
        Payload
    );

unpack([?PUBLISHED, ReqId, PubId]) ->
    juno_message:published(validate_id(ReqId), validate_id(PubId));

unpack([?SUBSCRIBE, ReqId, Options, TopicUri]) ->
    juno_message:subscribe(
        validate_id(ReqId), validate_dict(Options), validate_uri(TopicUri));

unpack([?SUBSCRIBED, ReqId, SubsId]) ->
    juno_message:subscribed(validate_id(ReqId), validate_id(SubsId));

unpack([?UNSUBSCRIBE, ReqId, SubsId]) ->
    juno_message:unsubscribe(validate_id(ReqId), validate_id(SubsId));

unpack([?UNSUBSCRIBED, ReqId]) ->
    juno_message:unsubscribed(validate_id(ReqId));

unpack([?EVENT, SubsId, PubId, Details]) ->
    juno_message:event(
        validate_id(SubsId),
        validate_id(PubId),
        validate_dict(Details)
    );

unpack([?EVENT, SubsId, PubId, Details, Args]) ->
    juno_message:event(
        validate_id(SubsId),
        validate_id(PubId),
        validate_dict(Details),
        Args
    );

unpack([?EVENT, SubsId, PubId, Details, Args, Payload]) ->
    juno_message:event(
        validate_id(SubsId),
        validate_id(PubId),
        validate_dict(Details),
        Args,
        Payload
    );

unpack([?CALL, ReqId, Options, ProcedureUri]) ->
    juno_message:call(
        validate_id(ReqId),
        validate_dict(Options),
        validate_uri(ProcedureUri)
    );

unpack([?CALL, ReqId, Options, ProcedureUri, Args]) ->
    juno_message:call(
        validate_id(ReqId),
        validate_dict(Options),
        validate_uri(ProcedureUri),
        Args
    );

unpack([?CALL, ReqId, Options, ProcedureUri, Args, Payload]) ->
    juno_message:call(
        validate_id(ReqId),
        validate_dict(Options),
        validate_uri(ProcedureUri),
        Args,
        Payload
    );

unpack([?CANCEL, ReqId, Options]) ->
    juno_message:cancel(validate_id(ReqId), validate_dict(Options));

unpack([?INTERRUPT, ReqId, Options]) ->
    juno_message:interrupt(validate_id(ReqId), validate_dict(Options));

unpack([?RESULT, ReqId, Details]) ->
    juno_message:result(validate_id(ReqId), validate_dict(Details));

unpack([?RESULT, ReqId, Details, Args]) ->
    juno_message:result(validate_id(ReqId), validate_dict(Details), Args);

unpack([?RESULT, ReqId, Details, Args, Payload]) ->
    juno_message:result(
        validate_id(ReqId), validate_dict(Details), Args, Payload);


unpack([?REGISTER, ReqId, Options, ProcedureUri]) ->
    juno_message:register(
        validate_id(ReqId), validate_dict(Options), ProcedureUri);

unpack([?REGISTERED, ReqId, RegId]) ->
    juno_message:registered(validate_id(ReqId), validate_id(RegId));

unpack([?UNREGISTER, ReqId, RegId]) ->
    juno_message:unregister(validate_id(ReqId), validate_id(RegId));

unpack([?UNREGISTERED, ReqId]) ->
    juno_message:unregistered(validate_id(ReqId));

unpack([?INVOCATION, ReqId, RegId, Details]) ->
    juno_message:invocation(
        validate_id(ReqId),
        validate_id(RegId),
        validate_dict(Details)
    );

unpack([?INVOCATION, ReqId, RegId, Details, Args]) ->
    juno_message:invocation(
        validate_id(ReqId),
        validate_id(RegId),
        validate_dict(Details),
        Args
    );

unpack([?INVOCATION, ReqId, RegId, Details, Args, Payload]) ->
    juno_message:invocation(
        validate_id(ReqId),
        validate_id(RegId),
        validate_dict(Details),
        Args,
        Payload
    );

unpack([?YIELD, ReqId, Options]) ->
    juno_message:yield(
        validate_id(ReqId),
        validate_dict(Options)
    );

unpack([?YIELD, ReqId, Options, Args]) ->
    juno_message:yield(
        validate_id(ReqId),
        validate_dict(Options),
        Args
    );

unpack([?YIELD, ReqId, Options, Args, Payload]) ->
    juno_message:yield(
        validate_id(ReqId),
        validate_dict(Options),
        Args,
        Payload
    ).


%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
pack_optionals(undefined, undefined) -> [];
pack_optionals(Args, undefined) -> [Args];
pack_optionals(Args, Payload) -> [Args, Payload].


%% @private
validate_dict(Map) ->
    lists:any(fun is_invalid_dict_key/1, maps:keys(Map)) == false
    orelse error({invalid_dict, Map}),
    Map.


%% @private
is_invalid_dict_key(_Key) ->
    %% TODO
    false.


%% @private
validate_id(Id) ->
    juno_id:is_valid(Id) == true orelse error({invalid_id, Id}),
    Id.


%% @private
validate_uri(Uri) ->
    juno_uri:is_valid(Uri) == true orelse error({invalid_uri, Uri}),
    Uri.


%% @private
pack_message_type(hello) -> ?HELLO;
pack_message_type(welcome) -> ?WELCOME;
pack_message_type(abort) -> ?ABORT;
pack_message_type(challenge) -> ?CHALLENGE;
pack_message_type(authenticate) -> ?AUTHENTICATE;
pack_message_type(goodbye) -> ?GOODBYE;
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
