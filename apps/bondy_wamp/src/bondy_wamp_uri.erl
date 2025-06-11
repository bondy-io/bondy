%% -----------------------------------------------------------------------------
%%  Copyright (c) 2015-2021 Leapsight. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%%
%% @end
%% =============================================================================
-module(bondy_wamp_uri).
-include("bondy_wamp.hrl").

-type t()               ::  binary().
-type rule()            ::  loose
                            | loose_prefix
                            | loose_allow_empty
                            | prefix
                            | allow_empty
                            | strict
                            | strict_prefix
                            | strict_allow_empty.
-type match_strategy()  ::  binary().

-export_type([t/0]).
-export_type([rule/0]).

-export([is_valid/1]).
-export([is_valid/2]).
-export([validate/1]).
-export([validate/2]).
-export([components/1]).
-export([match/3]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Sames as `is_valid(Uri, bondy_wamp_config:get(uri_strictness))'.
%% @end
%% -----------------------------------------------------------------------------
-spec is_valid(uri()) -> boolean().

is_valid(Uri) ->
    is_valid(Uri, bondy_wamp_config:get(uri_strictness)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_valid(Uri :: uri(), RuleOrStrategy :: rule() | match_strategy()) ->
    boolean() | no_return().

is_valid(Uri, Strategy) when is_binary(Strategy) ->
    is_valid(Uri, rule_for_strategy(Strategy));

is_valid(<<>>, Rule) when is_atom(Rule) ->
    loose_prefix == Rule;

is_valid(Uri, Rule) when is_binary(Uri), is_atom(Rule) ->
    re:run(Uri, uri_regex(Rule)) =/= nomatch;

is_valid(_, _) ->
    false.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec validate(Uri :: binary()) -> Uri :: t().

validate(Uri) ->
    maybe_error(is_valid(Uri), Uri).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec validate(Uri :: binary(), Arg :: rule() | match_strategy()) ->
    Uri :: t().

validate(Uri, Arg) ->
    maybe_error(is_valid(Uri, Arg), Uri).


%% -----------------------------------------------------------------------------
%% @doc Matches a ground uri `Uri' with `Pattern'. `Uri' cannot be the empty
%% uri.
%% @end
%% -----------------------------------------------------------------------------
-spec match(Uri :: t(), Pattern :: t(), Strategy :: match_strategy()) -> any().

match(<<>>, _, Strategy) when Strategy =/= ?PREFIX_MATCH ->
    error(badarg);

match(Uri, Uri, ?EXACT_MATCH)
when is_binary(Uri) andalso byte_size(Uri) > 0 ->
    true;

match(_, <<>>, ?PREFIX_MATCH) ->
    %% The any prefix matches everything
    true;

match(Uri, Pattern, ?PREFIX_MATCH)
when is_binary(Uri) ->
    binary:longest_common_prefix([Uri, Pattern]) >= byte_size(Pattern);

match(Uri, Pattern, ?WILDCARD_MATCH)
when is_binary(Uri) andalso byte_size(Uri) > 0 ->
    subsumes(
        binary:split(Pattern, [<<$.>>], [global]),
        binary:split(Uri, [<<$.>>], [global])
    );

match(Uri, _, _)
when is_binary(Uri) andalso byte_size(Uri) > 0 ->
    false;

match(_, _, _) ->
    error(badarg).


%% -----------------------------------------------------------------------------
%% @doc
%% Example:
%% components(<<"com.mycompany.foo.bar">>) ->
%% [<<"com.mycompany">>, <<"foo">>, <<"bar">>].
%% @end
%% -----------------------------------------------------------------------------
-spec components(t()) -> [binary()] | no_return().

components(Uri) ->
    case binary:split(Uri, <<".">>, [global]) of
        [TopLevelDomain, AppName | Rest] when length(Rest) > 0 ->
            Domain = <<TopLevelDomain/binary, $., AppName/binary>>,
            [Domain | Rest];
        _Other ->
            %% Invalid Uri
            error({?WAMP_INVALID_URI, Uri})
    end.




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
uri_regex(Rule) ->
    Regex = persistent_term:get({?MODULE, Rule}, undefined),
    uri_regex(Rule, Regex).


%% @private
uri_regex(loose = Rule, undefined) ->
    {ok, Regex} = re:compile("^([^\s\\.#]+\\.)*([^\s\\.#]+)$"),
    ok = persistent_term:put({?MODULE, Rule}, Regex),
    Regex;

uri_regex(loose_prefix = Rule, undefined) ->
    {ok, Regex} = re:compile("^([^\s\\.#]+\\.)*([^\s\\.#]+)[.]?$"),
    ok = persistent_term:put({?MODULE, Rule}, Regex),
    Regex;

uri_regex(loose_allow_empty = Rule, undefined) ->
    {ok, Regex} = re:compile("^(([^\s\\.#]+\\.)|\\.)*([^\s\\.#]+)?$"),
    ok = persistent_term:put({?MODULE, Rule}, Regex),
    Regex;

uri_regex(strict = Rule, undefined) ->
    {ok, Regex} = re:compile("^([0-9a-z_]+\\.)*([0-9a-z_]+)$"),
    ok = persistent_term:put({?MODULE, Rule}, Regex),
    Regex;

uri_regex(strict_prefix = Rule, undefined) ->
    {ok, Regex} = re:compile("^([0-9a-z_]+\\.)*([0-9a-z_]+)[.]?$"),
    ok = persistent_term:put({?MODULE, Rule}, Regex),
    Regex;

uri_regex(strict_allow_empty = Rule, undefined) ->
    {ok, Regex} = re:compile("^(([0-9a-z_]+\\.)|\\.)*([0-9a-z_]+)?$"),
    ok = persistent_term:put({?MODULE, Rule}, Regex),
    Regex;

uri_regex(prefix, undefined) ->
    Rule = case bondy_wamp_config:get(uri_strictness) of
        loose -> loose_prefix;
        strict -> strict_prefix
    end,
    uri_regex(Rule, undefined);

uri_regex(allow_empty, undefined) ->
    Rule = case bondy_wamp_config:get(uri_strictness) of
        loose -> loose_allow_empty;
        strict -> strict_allow_empty
    end,
    uri_regex(Rule, undefined);

uri_regex(_, undefined) ->
    error(badrule);

uri_regex(_, Regex) ->
    Regex.


%% @private
-spec subsumes(
    Pattern :: binary() | [binary()],
    Uri :: binary() | [binary()]) -> boolean().

subsumes(Term, Term) ->
    true;

subsumes(Term1, Term2) when length(Term1) =/= length(Term2) ->
    false;

subsumes([H|T1], [H|T2]) ->
    subsumes(T1, T2);

subsumes([<<>>|T1], [_|T2]) ->
    subsumes(T1, T2);

subsumes([], []) ->
    true;

subsumes(_, _) ->
    false.


%% @private
maybe_error(true, Uri) ->
    Uri;

maybe_error(false, Uri) ->
    error({invalid_uri, Uri}).


%% @private
rule_for_strategy(Strategy) ->
    rule_for_strategy(Strategy, bondy_wamp_config:get(uri_strictness)).


rule_for_strategy(?EXACT_MATCH, Rule) -> Rule; %% loose | strict
rule_for_strategy(?PREFIX_MATCH, loose) -> loose_prefix;
rule_for_strategy(?PREFIX_MATCH, strict) -> strict_prefix;
rule_for_strategy(?WILDCARD_MATCH, loose) -> loose_allow_empty;
rule_for_strategy(?WILDCARD_MATCH, strict) -> strict_allow_empty;
rule_for_strategy(_, _) -> error(badstrategy).


