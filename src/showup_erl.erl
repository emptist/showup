-module(showup_erl).

-export([arguments/0, halt/1, run/2, sleep_ms/1]).

%% The command line arguments, without the program name.
%%
%% `init:get_plain_arguments/0` is used rather than `init:get_arguments/0`
%% because it keeps the arguments in order and leaves flags such as `-a`
%% untouched, which `init:get_arguments/0` turns into atoms. An escript keeps
%% its own path as the first argument, which is dropped here.
-spec arguments() -> [binary()].
arguments() ->
    to_binaries(user_arguments()).

user_arguments() ->
    case init:get_argument(escript) of
        {ok, _} -> drop_first(init:get_plain_arguments());
        _ -> init:get_plain_arguments()
    end.

drop_first([_Script | Arguments]) -> Arguments;
drop_first([]) -> [].

to_binaries(Arguments) -> [unicode:characters_to_binary(A) || A <- Arguments].

%% Stops the runtime with the given exit status.
-spec halt(non_neg_integer()) -> no_return().
halt(Status) ->
    erlang:halt(Status).

-spec sleep_ms(non_neg_integer()) -> ok.
sleep_ms(Milliseconds) ->
    timer:sleep(Milliseconds).

%% Runs an executable directly, without a shell, and captures its output.
%%
%% Arguments are passed as a list, so they never need quoting or escaping.
-spec run(file:filename_all(), [string()]) -> {ok, string()} | {error, string()}.
run(Executable, Arguments) ->
    try erlang:open_port(
        {spawn_executable, Executable},
        [
            {args, Arguments},
            binary,
            exit_status,
            hide,
            stderr_to_stdout,
            use_stdio
        ]
    ) of
        Port ->
            {Status, Output} = collect(Port, <<>>),
            case Status of
                0 -> {ok, binary_to_list(Output)};
                _ -> {error, describe(Status, Output)}
            end
    catch
        Class:Reason ->
            {error, lists:flatten(io_lib:format(
                "could not run ~ts: ~p:~p",
                [Executable, Class, Reason]
            ))}
    end.

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, Status}} ->
            {Status, Acc}
    end.

describe(Status, Output) ->
    case string:trim(binary_to_list(Output), both, "\r\n \t") of
        "" -> lists:flatten(io_lib:format("exit status ~B", [Status]));
        Message -> Message
    end.
