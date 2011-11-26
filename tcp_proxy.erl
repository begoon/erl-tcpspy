% TCP/IP proxy
% Copyright (c) 2011 by Alexander Demin

-module(tcp_proxy).

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
    register(file_logger, spawn(fun() -> start_file_logger() end)),
    register(binary_logger, spawn(fun() -> binary_logger0() end)),
    register(logger, spawn(fun() -> logger() end)),
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

acceptor(ListenSocket, RemoteHost, RemotePort, ConnN) ->
    case gen_tcp:accept(ListenSocket) of
      {ok, LocalSocket} -> 
          spawn(fun() -> acceptor(ListenSocket, RemoteHost, RemotePort, ConnN + 1) end),
          LocalInfo = peer_info(LocalSocket),
          logger ! {message, "~4.10.0B: Incoming connection from ~s~n", [ConnN, LocalInfo], ConnN},
          case gen_tcp:connect(RemoteHost, RemotePort, [binary, {packet, 0}]) of
            {ok, RemoteSocket} ->
              RemoteInfo = peer_info(RemoteSocket),
              logger ! {message, "~4.10.0B: Connected to ~s~n", [ConnN, RemoteInfo], ConnN},
              exchange_data(LocalSocket, RemoteSocket, LocalInfo, RemoteInfo, ConnN, 0),
              logger ! {message, "~4.10.0B: Finished~n", [ConnN], ConnN};
            {error, Reason} ->
              logger ! {message, "~4.10.0B: Unable to connect to ~s:~s (error: ~p)", 
                       [ConnN, RemoteHost, RemotePort, Reason], ConnN}
          end;
      {error, Reason} ->
          logger ! {message, "Socket accept error '~w'~n", [Reason], ConnN}
    end.

exchange_data(LocalSocket, RemoteSocket, LocalInfo, RemoteInfo, ConnN, PacketN) ->
    receive
        {tcp, RemoteSocket, Bin} ->
            logger ! {received, ConnN, Bin, RemoteInfo, PacketN},
            gen_tcp:send(LocalSocket, Bin),
            logger ! {sent, ConnN, LocalInfo, PacketN},
            exchange_data(LocalSocket, RemoteSocket, LocalInfo, RemoteInfo, ConnN, PacketN + 1);
        {tcp, LocalSocket, Bin} ->
            logger ! {received, ConnN, Bin, LocalInfo, PacketN},
            gen_tcp:send(RemoteSocket, Bin),
            logger ! {sent, ConnN, RemoteInfo, PacketN},
            exchange_data(LocalSocket, RemoteSocket, LocalInfo, RemoteInfo, ConnN, PacketN + 1);
        {tcp_closed, RemoteSocket} -> 
            logger ! {message, "~4.10.0B: Disconnected from ~s~n", [ConnN, RemoteInfo], ConnN};
        {tcp_closed, LocalSocket} -> 
            logger ! {message, "~4.10.0B: Disconnected from ~s~n", [ConnN, LocalInfo], ConnN}
    end.

emit_message(Msg, ConnN) ->
    io:format("~s", [Msg]),
    file_logger ! {Msg, ConnN}.

% ------------------------------------------------------------------------------------------

-define(LogNameTemplate,
        "log-~s~4.10.0B.~2.10.0B.~2.10.0B-~2.10.0B.~2.10.0B.~2.10.0B-~~4.10.0B.log").

% Text logger

append_to_log_file(Msg, ConnN, LogNameFormat) ->
    LogName = io_lib:format(LogNameFormat, [ConnN]),
    {ok, File} = file:open(LogName, [write, append]),
    io:format(File, "~s", [Msg]),
    file:close(File).

start_file_logger() ->
    {{Y, M, D}, {H, MM, S}} = calendar:local_time(),
    LogNameFormat = lists:flatten(io_lib:format(?LogNameTemplate, ["", Y, M, D, H, MM, S])),
    LogNameExample = io_lib:format(LogNameFormat, [0]),
    io:format("Started file logger to [~s]~n", [LogNameExample]),
    file_logger(LogNameFormat).

file_logger(LogNameFormat) ->
    receive
        {Msg, ConnN} ->
            append_to_log_file(Msg, ConnN, LogNameFormat),
            file_logger(LogNameFormat)
    end.

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

logger() ->
    receive
        {received, ConnN, Packet, From, PacketN} -> 
            Lines = io_lib:format("~4.10.0B: Received (#~p) ~p byte(s) from ~s~n", 
                                  [ConnN, PacketN, byte_size(Packet), From])
                    ++ dump_binary(ConnN, Packet),
            emit_message(Lines, ConnN),
            binary_logger ! {Packet, ConnN, From},
            logger();
        {sent, ConnN, ToSocket, PacketN} -> 
            Msg = io_lib:format("~4.10.0B: Sent (#~p) to ~s~n", 
                                [ConnN, PacketN, [ToSocket]]),
            emit_message(Msg, ConnN),
            logger();
        {message, Format, Args, ConnN} ->
            Msg = io_lib:format(Format, Args),
            emit_message(Msg, ConnN),
            logger()
    end.

% -----------------------------------------------------------------------------

dump_list(_, [], _) -> [];
dump_list(Prefix, L, Offset) ->
    {H, T} = lists:split(lists:min([?WIDTH, length(L)]), L),
    io_lib:format("~4.10.0B: ~4.16.0B: ~-*s| ~-*s~n", 
                  [Prefix, Offset,
                  ?WIDTH * 3, dump_numbers(H),
                  ?WIDTH, dump_chars(H)])
    ++ dump_list(Prefix, T, Offset + 16).

dump_numbers(L) ->
    lists:flatten([io_lib:format("~2.16.0B ", [X]) || X <- L]).

dump_chars(L) ->
    lists:map(fun(X) ->
                if X >= 32 andalso X < 128 -> X;
                   true -> $.
                end
              end, L).

dump_binary(Prefix, Bin) ->
    dump_list(Prefix, binary_to_list(Bin), 0).
