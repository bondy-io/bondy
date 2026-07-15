-include("bondy_doc.hrl").

-define(ROOT_KEY, <<"$root">>).

-define(T2B_OPTS, [{minor_version, 2}]).

-type optional(T) :: T | undefined.
-type hash() :: binary().
-type key() :: any().
-type value() :: any().
-type level() :: non_neg_integer().
-type epoch() :: integer().
