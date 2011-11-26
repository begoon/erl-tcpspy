#!/bin/sh
ERLANG_HOME=~/opt/erlang-r14b04
$ERLANG_HOME/bin/escript `dirname $0`/tcp_proxy.erl $*

