
REBAR            = rebar3

.PHONY: genvars compile test xref dialyzer

genvars:
	@cp config/prod/legacy_vars.config vars.generated

compile-no-deps:
	${REBAR} compile

test: compile
	${REBAR} ct

xref: compile
	${REBAR} xref skip_deps=true

dialyzer: compile
	${REBAR} dialyzer

devrun:
	${REBAR} as dev release

	cp examples/config/security_config.json _build/dev/rel/bondy/etc/security_config.json

	cp examples/config/broker_bridge_config.json _build/dev/rel/bondy/etc/broker_bridge_config.json

	priv/tools/replace-env-vars -i config/dev/bondy.conf -o _build/dev/rel/bondy/etc/bondy.conf

	_build/dev/rel/bondy/bin/bondy console


test1:
	rebar3 as test1 release
	_build/test1/rel/bondy/bin/bondy console

test2:
	rebar3 as test2 release
	_build/test2/rel/bondy/bin/bondy console

test3:
	rebar3 as test3 release
	_build/test3/rel/bondy/bin/bondy console

prod:
	rebar3 as prod release
	_build/prod/rel/bondy/bin/bondy console
