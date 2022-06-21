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

