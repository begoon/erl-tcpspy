ERLANG_HOME=~/opt/erlang-r14b04/bin
ESCRIPT=$(ERLANG_HOME)/escript

run:
	$(ESCRIPT) tcp_proxy.erl 50000 pop.yandex.ru 110

usage:
	$(ESCRIPT) tcp_proxy.erl

