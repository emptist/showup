-module(showup_erl).

-export([arguments/0, halt/1, run/2]).

%% Everything in here is something no core library offers. Sleeping is
%% gleam/erlang/process, and gleam/erlang/port has a port type but no way to
%% open one, so running a program still means writing it here.
%%
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

%% Runs an executable directly, without a shell, and captures its output.
%%
%% Arguments are passed as a list, so they never need quoting or escaping.
%%
%% Both the output and the error message are binaries rather than lists of
%% characters, because that is what a Gleam string is on Erlang and anything
%% that treats it as a binary fails at runtime otherwise.
-spec run(file:filename_all(), [string()]) -> {ok, binary()} | {error, binary()}.
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
                0 -> {ok, Output};
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
    case trim(Output) of
        <<>> -> list_to_binary(io_lib:format("exit status ~B", [Status]));
        Message -> Message
    end.

%% `string:trim/3` may hand back a list of characters, so the result is put
%% back into a binary for the caller.
trim(Binary) when is_binary(Binary) ->
    case string:trim(Binary, both, "\r\n \t") of
        Trimmed when is_binary(Trimmed) -> Trimmed;
        Trimmed -> list_to_binary(Trimmed)
    end.
