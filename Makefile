
REBAR            = rebar3

.PHONY: compile test xref dialyzer

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

	tools/replace-env-vars -i config/dev/bondy.conf -o _build/dev/rel/bondy/etc/bondy.conf

	_build/dev/rel/bondy/bin/bondy console