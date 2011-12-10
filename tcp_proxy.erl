% TCP/IP proxy
% Copyright (c) 2011 by Alexander Demin

-module(tcp_proxy).
-export([main/1]).

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
    ListenOptions = [binary, {packet, 0}, {reuseaddr, true}, {active, true}],
    case gen_tcp:listen(ListenPort, ListenOptions) of
        {ok, ListenSocket} ->
            io:format("Listener started ~s~n", [socket_info(ListenSocket)]),
            spawn(fun() -> 
                acceptor(ListenSocket, CalleeHost, CalleePort, 0) 
            end),
            receive _ -> void end;
        {error, Reason} ->
            io:format("Unable to start listener, error '~p'~n", [Reason])
    end.

format_socket_info(Info) ->
    {ok, {{A, B, C, D}, Port}} = Info,
    lists:flatten(io_lib:format("~p.~p.~p.~p-~p", [A, B, C, D, Port])).

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
          spawn(fun() -> 
              acceptor(ListenSocket, RemoteHost, RemotePort, ConnN + 1) 
          end),
          case gen_tcp:connect(RemoteHost, RemotePort, [binary, {packet, 0}]) of
              {ok, RemoteSocket} ->
                  process_connection(ConnN, LocalSocket, RemoteSocket);
              {error, Reason} ->
                  io:format("Unable to connect to ~s:~s (error: '~p')", 
                            [RemoteHost, RemotePort, Reason])
          end;
      {error, Reason} ->
          io:format("Socket accept error '~w'~n", [Reason])
    end.

-record(loggers, {logger, localBinaryLogger, remoteBinaryLogger}).

process_connection(ConnN, LocalSocket, RemoteSocket) ->
    LocalInfo = peer_info(LocalSocket),
    RemoteInfo = peer_info(RemoteSocket),
    Logger = start_connection_logger(ConnN, LocalInfo, RemoteInfo),
    LocalBinaryLogger = start_binary_logger(ConnN, LocalInfo),
    RemoteBinaryLogger = start_binary_logger(ConnN, RemoteInfo),
    StartTime = calendar:local_time(),
    Logger ! {connected, StartTime},
    Loggers = #loggers{
        logger = Logger,
        localBinaryLogger = LocalBinaryLogger,
        remoteBinaryLogger = RemoteBinaryLogger
    },
    pass_through(LocalSocket, RemoteSocket, Loggers, 0),
    EndTime = calendar:local_time(),
    Logger ! {finished, StartTime, EndTime},
    % Stop the logger.
    Logger ! {stop, self(), ack},
    receive ack -> void end,
    % Stop the binary logger for local socket.
    LocalBinaryLogger ! {stop, self(), ack},
    receive ack -> void end,
    % Stop the binary logger for remote socket.
    RemoteBinaryLogger ! {stop, self(), ack},
    receive ack -> void end.

pass_through(LocalSocket, RemoteSocket, Loggers, PacketN) ->
    receive
        {tcp, LocalSocket, Packet} ->
            Loggers#loggers.logger ! {received, from_local, Packet, PacketN},
            gen_tcp:send(RemoteSocket, Packet),
            Loggers#loggers.logger ! {sent, to_remote, PacketN},
            Loggers#loggers.localBinaryLogger ! {Packet},
            pass_through(LocalSocket, RemoteSocket, Loggers, PacketN + 1);
        {tcp, RemoteSocket, Packet} ->
            Loggers#loggers.logger ! {received, from_remote, Packet, PacketN},
            gen_tcp:send(LocalSocket, Packet),
            Loggers#loggers.logger ! {sent, to_local, PacketN},
            Loggers#loggers.remoteBinaryLogger ! {Packet},
            pass_through(LocalSocket, RemoteSocket, Loggers, PacketN + 1);
        {tcp_closed, RemoteSocket} -> 
            Loggers#loggers.logger ! {disconnected, from_remote};
        {tcp_closed, LocalSocket} -> 
            Loggers#loggers.logger ! {disconnected, from_local}
    end.

start_binary_logger(ConnN, From) ->
    {{Y, M, D}, {H, MM, S}} = calendar:local_time(),
    LogName = lists:flatten(
                  % YYYY.MM.DD-hh.hh.ss-ConnN-From.log
                  io_lib:format("log-binary-~4.10.0B.~2.10.0B.~2.10.0B-"
                                "~2.10.0B.~2.10.0B.~2.10.0B-~4.10.0B-"
                                "~s.log", 
                                [Y, M, D, H, MM, S, ConnN, From])),
    LogWriter = fun(Packet) ->
        append_to_binary_file(Packet, LogName)
    end,
    spawn_link(fun() -> binary_logger(LogWriter) end).

binary_logger(LogWriter) ->
    receive
        {stop, CallerPid, Ack} ->
            CallerPid ! Ack;
        {Packet} ->
            LogWriter(Packet),
            binary_logger(LogWriter)
    end.

append_to_binary_file(Packet, FileName) ->
    {ok, File} = file:open(FileName, [write, append, binary, raw]),
    file:write(File, Packet),
    file:close(File).

start_connection_logger(ConnN, From, To) ->
    {{Y, M, D}, {H, MM, S}} = calendar:local_time(),
    LogName = lists:flatten(
                  % YYYY.MM.DD-hh.hh.ss-ConnN-From-To.log
                  io_lib:format("log-~4.10.0B.~2.10.0B.~2.10.0B-"
                                "~2.10.0B.~2.10.0B.~2.10.0B-~4.10.0B-"
                                "~s-~s.log", 
                                [Y, M, D, H, MM, S, ConnN, From, To])),
    spawn_link(fun() -> connection_logger(ConnN, From, To, LogName) end).

peertype_to_name(from_local, LocalInfo, _RemoteInfo) -> LocalInfo;
peertype_to_name(from_remote, _LocalInfo, RemoteInfo) -> RemoteInfo;
peertype_to_name(to_local, LocalInfo, _RemoteInfo) -> LocalInfo;
peertype_to_name(to_remote, _LocalInfo, RemoteInfo) -> RemoteInfo.

connection_logger(ConnN, From, To, LogName) when is_list(LogName) ->
    Putter = fun(Message) ->
        append_message_to_file(Message, LogName)
    end,
    connection_logger(ConnN, From, To, Putter);

connection_logger(ConnN, FromInfo, ToInfo, LogWriter) ->
    receive
        {received, From, Packet, PacketN} ->
            PeerName = peertype_to_name(From, FromInfo, ToInfo),
            Message = fun(Printer) -> 
                Printer("Received (#~p) ~p byte(s) from ~s~n", 
                        [PacketN, byte_size(Packet), PeerName]),
                binary_to_hex_via_printer(Packet, Printer)
            end,
            write_message(ConnN, FromInfo, ToInfo, LogWriter, Message);
        {sent, To, PacketN} ->
            PeerName = peertype_to_name(To, FromInfo, ToInfo),
            Message = fun(Printer) ->
                Printer("Sent (#~p) to ~s~n", [PacketN, PeerName])
            end,
            write_message(ConnN, FromInfo, ToInfo, LogWriter, Message);
        {connected, Time} ->
            When = format_date_time(Time),
            Message = fun(Printer) ->
                Printer("Connected to ~s at ~s~n", [ToInfo, When])
            end,
            write_message(ConnN, FromInfo, ToInfo, LogWriter, Message);
        {disconnected, From} ->
            PeerName = peertype_to_name(From, FromInfo, ToInfo),
            Message = fun(Printer) ->
                Printer("Disconnected from ~s~n", [PeerName])
            end,
            write_message(ConnN, FromInfo, ToInfo, LogWriter, Message);
        {finished, StartTime, EndTime} ->
            Duration = calendar:time_difference(StartTime, EndTime),
            When = format_date_time(EndTime),
            Message = fun(Printer) ->
                Printer("Finished at ~s, duration ~s~n",
                        [When, format_duration(Duration)])
            end,
            write_message(ConnN, FromInfo, ToInfo, LogWriter, Message);
        {stop, CallerPid, Ack} ->
            CallerPid ! Ack 
    end.

write_message(ConnN, FromInfo, ToInfo, LogWriter, Message) ->
   LogWriter(Message),
   connection_logger(ConnN, FromInfo, ToInfo, LogWriter).

append_message_to_file(Putter, LogName) ->
    {_, File} = file:open(LogName, [write, append]),
    Printer = fun(Format, Args) ->
        io:format(Format, Args),
        io:format(File, Format, Args)
    end,
    Putter(Printer),
    file:close(File).
       
% -----------------------------------------------------------------------------

-define(WIDTH, 16).

binary_to_hex_via_printer(Bin, Printer) ->
    binary_to_hex(Bin, Printer, 0).

binary_to_hex(<<Bin:?WIDTH/binary, Rest/binary>>, Printer, Offset) ->
    binary_to_dump_line(Bin, Printer, Offset),
    binary_to_hex(Rest, Printer, Offset + ?WIDTH);

binary_to_hex(Bin, Printer, Offset) ->
    Pad = fun() -> Printer("~*c", [(?WIDTH - byte_size(Bin)) * 3, 32]) end,
    binary_to_dump_line(Bin, Printer, Pad, Offset).

binary_to_dump_line(Bin, Printer, Offset) ->
    binary_to_dump_line(Bin, Printer, fun() -> ok end, Offset).

binary_to_dump_line(Bin, Printer, Pad, Offset) ->
    Printer("~4.16.0B: ", [Offset]),
    Printer("~s", [binary_to_hex_line(Bin)]),
    Pad(),
    Printer("| ~s~n", [binary_to_char_line(Bin)]).

binary_to_hex_line(Bin) -> [[(byte_to_hex(<<B>>) ++ " ") || << B >> <= Bin]].

byte_to_hex(<< N1:4, N2:4 >>) ->
    [integer_to_list(N1, 16), integer_to_list(N2, 16)].

binary_to_char_line(Bin) -> [[mask_invisiable_chars(B) || << B >> <= Bin]].

mask_invisiable_chars(X) when (X >= 32 andalso X < 128) -> X;
mask_invisiable_chars(_) -> $..

