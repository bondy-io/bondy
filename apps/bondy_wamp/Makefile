.PHONY: lint test dialyzer

all: lint test dialyzer

lint:
	rebar3 as lint lint

test:
	rebar3 ct

dialyzer:
	rebar3 dialyzer