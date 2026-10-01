bondy_msgpack
=====

A MessagePack encoder and decoder for Erlang/OTP: `bondy_msgpack:encode/1` and
`bondy_msgpack:decode/1`, plus the per-type encoders `encode_integer/1`,
`encode_float/1`, `encode_binary/1` and `encode_string/1`. The Erlang mapping
is documented in the `bondy_msgpack` module.

Build
-----

    $ rebar3 compile

Test
----

    $ rebar3 ct
    $ rebar3 as test proper

`bondy_msgpack_SUITE` runs the published MessagePack test suite vendored in
`test/bondy_msgpack_SUITE_data/` (see its README for the source and the two
documented exclusions). The `msgpack` library is a test-only dependency, the
reference implementation `prop_bondy_msgpack` compares against.
