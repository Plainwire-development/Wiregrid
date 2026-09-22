-module(wiregrid_hot).
-export([
    counter_add/3,
    counter_add_clamped/3,
    counter_get/2,
    session_counter_add/4,
    session_counter_get/3
]).

counter_add(Table, Key, Delta) when is_integer(Delta) ->
    try ets:update_counter(Table, Key, {2, Delta}, {Key, 0}) of
        Value -> {ok, Value}
    catch
        error:badarg -> {error, unavailable}
    end.

counter_add_clamped(Table, Key, Delta) when is_integer(Delta), Delta < 0 ->
    try ets:update_counter(Table, Key, {2, Delta, 0, 0}, {Key, 0}) of
        Value -> {ok, Value}
    catch
        error:badarg -> {error, unavailable}
    end;
counter_add_clamped(Table, Key, Delta) ->
    counter_add(Table, Key, Delta).

counter_get(Table, Key) ->
    try ets:lookup(Table, Key) of
        [{Key, Value}] when is_integer(Value) -> Value;
        _ -> 0
    catch
        error:badarg -> 0
    end.

%% A threshold of 0 only clamps a negative step. A positive step with that
%% same threshold is reset to 0 whenever the result would exceed 0, which
%% would freeze every session counter.
session_counter_add(Table, SessionId, Position, Delta)
        when is_integer(Position), Position >= 2, Position =< 7,
             is_integer(Delta), Delta < 0 ->
    try ets:update_counter(Table, SessionId, {Position, Delta, 0, 0}) of
        Value -> {ok, Value}
    catch
        error:badarg -> {error, unavailable}
    end;
session_counter_add(Table, SessionId, Position, Delta)
        when is_integer(Position), Position >= 2, Position =< 7, is_integer(Delta) ->
    try ets:update_counter(Table, SessionId, {Position, Delta}) of
        Value -> {ok, Value}
    catch
        error:badarg -> {error, unavailable}
    end.

session_counter_get(Table, SessionId, Position)
        when is_integer(Position), Position >= 2, Position =< 7 ->
    try ets:lookup(Table, SessionId) of
        [Tuple] when tuple_size(Tuple) >= Position -> element(Position, Tuple);
        _ -> 0
    catch
        error:badarg -> 0
    end.
