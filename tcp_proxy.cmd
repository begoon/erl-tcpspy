@echo off
set ERLANG_HOME=c:\prg86\erl5.8.5
%ERLANG_HOME%\bin\escript.exe tcp_proxy.erl %1 %2 %3 %4 %5 %6
