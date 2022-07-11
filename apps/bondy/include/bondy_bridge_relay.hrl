-define(SOCKET_DATA(Tag), Tag == tcp orelse Tag == ssl).
-define(SOCKET_ERROR(Tag), Tag == tcp_error orelse Tag == ssl_error).
-define(CLOSED_TAG(Tag), Tag == tcp_closed orelse Tag == ssl_closed).
% -define(PASSIVE_TAG(Tag), Tag == tcp_passive orelse Tag == ssl_passive).



-type hello() ::
    {hello, RealmUri :: uri(), Details :: map()}.

-type challenge() ::
    {challenge,Method :: binary(), ChallengeExtra :: map()}.

-type authenticate() ::
    {authenticate, Signature :: binary(), Extra :: map()}.

-type abort() ::
    {abort,
        SessionId :: bondy_session_id:t() | undefined,
        Reason :: atom(),
        Details :: map()
    }.

-type welcome() ::
    {welcome, SessionId :: bondy_session_id:t(), Details :: map()}.

-type goodbye() ::
    {goodbye,
        SessionId :: bondy_session_id:t(),
        Reason :: atom() | uri(),
        Details :: map()
    }.

-type fwd() ::
    {forward, M :: any()}.

-type recv() ::
    {receive_message, SessionId :: bondy_session_id:t(), M :: any()}.

