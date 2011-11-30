% TCP/IP proxy
% Copyright (c) 2011 by Alexander Demin

-module(tcp_proxy).
-export([]).

-define(WIDTH, 16).

main([ListenPort, RemoteHost, RemotePort]) ->
     ListenPortN = list_to_integer(ListenPort),
     start(ListenPortN, RemoteHost, list_to_integer(RemotePort));

main(_) -> usage().

usage() ->
    io:format("~n~s local_port remote_port remote_host~n~n", [?FILE]),
    io:format("Example:~n~n", []),
    io:format("tcp_proxy.erl 50000 google.com 80~n~n", []).

start(ListenPort, CalleeHost, CalleePort) ->
    io:format("Start listening on port ~p and forwarding data to ~s:~p~n",
              [ListenPort, CalleeHost, CalleePort]),
    %register(binary_logger, spawn(fun() -> binary_logger0() end)),
    {ok, ListenSocket} = gen_tcp:listen(ListenPort, [binary, {packet, 0}, 
                                                    {reuseaddr, true}, 
                                                    {active, true}]),
    io:format("Listener socket is started ~s~n", [socket_info(ListenSocket)]),
    spawn(fun() -> acceptor(ListenSocket, CalleeHost, CalleePort, 0) end),
    wait().

% Infinine loop to make sure that the main thread doesn't exit.
wait() -> receive _ -> true end, wait().

format_socket_info(Info) ->
    {ok, {{A, B, C, D}, Port}} = Info,
    lists:flatten(io_lib:format("~p.~p.~p.~p:~p", [A, B, C, D, Port])).

peer_info(Socket) -> format_socket_info(inet:peername(Socket)).

socket_info(Socket) -> format_socket_info(inet:sockname(Socket)).

format_date_time({{Y, M, D}, {H, MM, S}}) ->
    lists:flatten(
       io_lib:format("~4.10.0B.~2.10.0B.~2.10.0B-~2.10.0B.~2.10.0B.~2.10.0B", 
                     [Y, M, D, H, MM, S])).

format_duration({Days, {H, M, S}}) ->
    lists:flatten(
       io_lib:format("~2.10.0B-~2.10.0B.~2.10.0B.~2.10.0B", [Days, H, M, S])).
  
acceptor(ListenSocket, RemoteHost, RemotePort, ConnN) ->
    case gen_tcp:accept(ListenSocket) of
      {ok, LocalSocket} -> 
          spawn(fun() -> acceptor(ListenSocket, RemoteHost, RemotePort, ConnN + 1) end),
          LocalInfo = peer_info(LocalSocket),
          case gen_tcp:connect(RemoteHost, RemotePort, [binary, {packet, 0}]) of
              {ok, RemoteSocket} ->
                  RemoteInfo = peer_info(RemoteSocket),
                  Logger = start_connection_logger(ConnN, LocalInfo, RemoteInfo), 
                  StartTime = calendar:local_time(),
                  logger ! {message, "~4.10.0B: Connected to ~s at ~s~n", 
                            [ConnN, RemoteInfo, format_date_time(StartTime)]},
                  passthrough_data_between(LocalSocket, RemoteSocket, Logger),
                  EndTime = calendar:local_time(),
                  Duration = calendar:time_difference(StartTime, EndTime),
                  logger ! {message, "~4.10.0B: Finished at ~s, duration ~s~n", 
                            [ConnN, format_date_time(EndTime), 
                             format_duration(Duration)], ConnN},
              logger ! stop;
              {error, Reason} ->
                  io:format("Unable to connect to ~s:~s (error: ~p)", 
                            [RemoteHost, RemotePort, Reason])
          end;
      {error, Reason} ->
          io:format("Socket accept error '~w'~n", [Reason])
    end.

passthrough_between(LocalSocket, RemoteSocket, Logger) ->
    passthrough_between(LocalSockeet, RemoteSocket, Logger, 0).

passthrough_between(LocalSocket, RemoteSocket, Logger, PacketN) ->
    receive
        {tcp, RemoteSocket, Packet} ->
            logger ! {received, from_remote, Packet, PacketN},
            gen_tcp:send(LocalSocket, Packet),
            logger ! {sent, to_local, PacketN},
            passthrough_between(LocalSocket, RemoteSocket, Logger, PacketN + 1);
        {tcp, LocalSocket, Packet} ->
            logger ! {received, from_local, Packet, PacketN},
            gen_tcp:send(RemoteSocket, Bin),
            logger ! {sent, to_remote, PacketN},
            passthrough_between(LocalSocket, RemoteSocket, Logger, PacketN + 1);
        {tcp_closed, RemoteSocket} -> 
            logger ! {message, "~4.10.0B: Disconnected from ~s~n", [ConnN, RemoteInfo], ConnN};
        {tcp_closed, LocalSocket} -> 
            logger ! {message, "~4.10.0B: Disconnected from ~s~n", [ConnN, LocalInfo], ConnN}
    end.

% ------------------------------------------------------------------------------------------

% Binary logger

append_to_binary_log_file(Bin, ConnN, From, LogNameFormat) ->
    LogName = io_lib:format(LogNameFormat, [From, ConnN]),
    {ok, File} = file:open(LogName, [write, append, binary, raw]),
    file:write(File, Bin),
    file:close(File).

binary_logger0() ->
    {{Y, M, D}, {H, MM, S}} = calendar:local_time(),
    LogNameFormat = lists:flatten(io_lib:format(?LogNameTemplate, 
                                                ["binary-~s-", Y, M, D, H, MM, S])),
    LogNameExample = io_lib:format(LogNameFormat, ["host", 0]),
    io:format("Started file binary logger to [~s]~n", [LogNameExample]),
    binary_logger(LogNameFormat).

binary_logger(LogNameFormat) ->
    receive
        {Bin, ConnN, From} ->
            append_to_binary_log_file(Bin, ConnN, From, LogNameFormat),
            binary_logger(LogNameFormat)
    end.

% Logger thread

% This function launches pre-connection dump logger.
start_connection_logger(ConnN, From, To) ->
    {{Y, M, D}, {H, MM, S}} = calendar:local_time(),
    LogName = lists:flatten(
                  % YYYY.MM.DD-hh.hh.ss-ConnN-From-To.log
                  io_lib:format("log-~4.10.0B.~2.10.0B.~2.10.0B-"
                                "~2.10.0B.~2.10.0B.~2.10.0B-~4.10.0B-"
                                "~s-~s.log")., 
                                [Y, M, D, H, MM, S, ConnN, From, To])),
    spawn(fun() -> connection_logger(ConnN, From, To, LogName) end).

connection_logger(ConnN, Origin, Dest, LogName) ->
    receive
        {received, From, Packet, PacketN} ->
            FromInfo = if 
                From == from_local -> Origin;
                From == from_remote -> Dest
            end,
            put_log_entry(
                fun(Printer) -> 
                    Printer("~4.10.0B: Received (#~p) ~p byte(s) from ~s~n", 
                            [ConnN, PacketN, byte_size(Packet), FromInfo]),
                    binary_to_hex_via_printer(Packet, Printer, ConnN)
                end,
                LogName),
            %binary_logger ! {Packet, ConnN, From},
            connection_logger(ConnN, Origin, Dest, LogName);
        {sent, To, PacketN} ->
            ToInfo = if 
                To == to_local -> Origin;
                To == to_remote -> Dest
            end,
            put_log_entry(
                fun(Printer) -> 
                    Printer("~4.10.0B: Sent (#~p) to ~s~n", [ConnN, PacketN, ToInfo]),
                end,
                LogName);
            connection_logger(ConnN, Origin, Dest, LogName);
        {message, Format, Args} ->
                fun(Printer) -> Printer(Format, Args) end,
            connection_logger(ConnN, Origin, Dest, LogName);            
        exit -> ok
    end

put_log_entry(Putter, LogName) ->
    {_, File} = file:open(LogName, [write, append]),
    Printer = fun(Format, Args) ->
        io:format(Format, Args),
        io:format(File, Format, Args)
    end,
    Putter(Printer),
    file:close(File).
       
% -----------------------------------------------------------------------------

binary_to_hex_via_console(Bin, Prefix) ->
    binary_to_hex_via_printer(Bin, fun(F, P) -> io:format(F, P) end, Prefix).

binary_to_hex_via_printer(Bin, Printer, Prefix) ->
    binary_to_hex(Bin, Printer, 0, io_lib:format("~4.10.0B: ", [Prefix])).

binary_to_hex(<<Bin:16/binary, Rest/binary>>, Printer, Offset, Prefix) ->
    binary_to_dump_line(Bin, Printer, Offset, Prefix),
    binary_to_hex(Rest, Printer, Offset + 16, Prefix);

binary_to_hex(Bin, Printer, Offset, Prefix) ->
    Pad = fun() -> Printer("~*c", [(16 - byte_size(Bin)) * 3, 32]) end,
    binary_to_dump_line(Bin, Printer, Pad, Offset, Prefix).

binary_to_dump_line(Bin, Printer, Offset, Prefix) ->
    binary_to_dump_line(Bin, Printer, fun() -> ok end, Offset, Prefix).

binary_to_dump_line(Bin, Printer, Pad, Offset, Prefix) ->
    Printer("~s~4.16.0B: ", [Prefix, Offset]),
    Printer("~s", [binary_to_hex_line(Bin)]),
    Pad(),
    Printer("| ~s~n", [binary_to_char_line(Bin)]).

binary_to_hex_line(Bin) -> [[byte_to_hex(<<B>>) ++ " " || << B >> <= Bin]].

byte_to_hex(<< N1:4, N2:4 >>) ->
    [integer_to_list(N1, 16), integer_to_list(N2, 16)].

binary_to_char_line(Bin) -> [[mask_invisiable_chars(B) || << B >> <= Bin]].

mask_invisiable_chars(X) when (X >= 32 andalso X < 128) -> X;
mask_invisiable_chars(_) -> $..
