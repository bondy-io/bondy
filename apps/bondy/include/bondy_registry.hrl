-define(REGISTRY_POOL, {bondy_registry, pool}).
%% At the moment certain operations on the bondy_registrie_trie rely on art
%% tries which do not offer concurrent reads (it will never offer concurrent
%% writes). So we use this macro to disable concurrent reads till we fix it.
-define(TRIE_CONCURRENT_MATCH, false).
-define(CONCURRENT_ADD(Type), ?CONCURRENT_MATCH(Type)).
-define(CONCURRENT_DELETE(Type), ?CONCURRENT_ADD(Type)).
-define(CONCURRENT_MATCH(Type),
    %% Adding an entry requires matching against art tries, even for
    %% exact matching policy when pattern_based_registration is enabled.
    ?TRIE_CONCURRENT_MATCH
    orelse (
        Type == registration andalso
        not bondy_config:get([wamp, dealer, features, pattern_based_registration])
    )
).
