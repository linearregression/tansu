%% Copyright (c) 2016 Peter Morgan <peter.james.morgan@gmail.com>
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(tansu_api).

-export([info/0]).
-export([kv_delete/1]).
-export([kv_get/1]).
-export([kv_set/2]).
-export([kv_set/3]).
-export([kv_subscribe/1]).
-export([kv_test_and_delete/2]).
-export([kv_test_and_set/3]).
-export([kv_test_and_set/4]).
-export([kv_unsubscribe/1]).


info() ->
    tansu_consensus:info().

kv_delete(Key) ->
    tansu_consensus:ckv_delete(category(), Key).

kv_get(Key) ->
    tansu_consensus:ckv_get(category(), Key).

kv_set(Key, Value) ->
    kv_set(Key, Value, #{}).

kv_set(Key, Value, Options) ->
    tansu_consensus:ckv_set(category(), Key, Value, Options).

kv_test_and_delete(Key, ExistingValue) ->
    tansu_consensus:ckv_test_and_delete(category(), Key, ExistingValue).

kv_test_and_set(Key, ExistingValue, NewValue) ->
    kv_test_and_set(Key, ExistingValue, NewValue, #{}).

kv_test_and_set(Key, ExistingValue, NewValue, Options) ->
    tansu_consensus:ckv_test_and_set(category(), Key, ExistingValue, NewValue, Options).

kv_subscribe(Key) ->
    tansu_sm:subscribe(category(), Key).

kv_unsubscribe(Key) ->
    tansu_sm:unsubscribe(category(), Key).

category() ->
    user.
