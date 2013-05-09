%% -------------------------------------------------------------------
%%
%% riak_kv_counter: Counter logic to bridge riak_object and riak_kv_pncounter
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(riak_kv_counter).

-export([update/3, merge/1, value/1]).

-include("riak_kv_wm_raw.hrl").

%% @doc A counter is a two tuple of a `riak_kv_pncounter'
%% stored in a `riak_object'
%% with the tag `riak_kv_pncounter' as the first element.
%% Since counters can be stored with any name, in any bucket, there is a
%% chance that some sibling value for a counter is
%% not a `riak_kv_pncounter' in that case, we keep the sibling
%% for later resolution by the user.
%%
%% @TODO How do we let callers now about the sibling values?
-spec update(riak_object:riak_object(), binary(), integer()) ->
                    riak_object:riak_object().
update(RObj, Actor, Amt) ->
    {Meta, Counter0, NonCounterSiblings} = merge_object(RObj),
    Counter = case Amt of
                  0 -> Counter0;
                  _ -> update_counter(Counter0, Actor, Amt)
              end,
    update_object(RObj, Meta, Counter, NonCounterSiblings).

%% @doc Unlike regular, opaque `riak_object' values, conflicting
%% counter writes can be merged by Riak, thanks to their internal
%% CRDT PN-Counter structure.
-spec merge(riak_object:riak_object()) ->
                   riak_object:riak_object().
merge(RObj) ->
    {Meta, Counter, NonCounterSiblings} = merge_object(RObj),
    update_object(RObj, Meta, Counter, NonCounterSiblings).

%% @doc Currently _IGNORES_ all non-counter sibling values
-spec value(riak_object:riak_object()) ->
                   integer().
value(RObj) ->
    Contents = riak_object:get_contents(RObj),
    {_Meta, Counter, _NonCounterSiblings} = merge_contents(Contents),
    case Counter of
        undefined -> 0;
        _ ->
            riak_kv_pncounter:value(Counter)
    end.

%% Merge contents _AND_ meta
merge_object(RObj) ->
    Contents = riak_object:get_contents(RObj),
    merge_contents(Contents).

%% Only merge the values of actual PN-Counters
%% If a non-CRDT datum is present, keep it as a sibling value
merge_contents(Contents) ->
    lists:foldl(fun merge_value/2,
                {undefined, undefined, []},
               Contents).

%% worker for `merge_contents/1'
merge_value({MD, {riak_kv_pncounter, Counter}}, {undefined, undefined, NonCounterSiblings}) ->
    {MD, Counter, NonCounterSiblings};
merge_value({MD, {riak_kv_pncounter, Counter}}, {MergedMeta, Mergedest, NonCounterSiblings}) ->
    {merge_meta(MD, MergedMeta), riak_kv_pncounter:merge(Counter, Mergedest), NonCounterSiblings};
merge_value(NonCounter, {MD, Mergedest, NonCounterSiblings}) ->
    {MD, Mergedest, [NonCounter | NonCounterSiblings]}.

update_counter(undefined, Actor, Amt) ->
    update_counter(riak_kv_pncounter:new(), Actor, Amt);
update_counter(Counter, Actor, Amt) ->
    Op = counter_op(Amt),
    riak_kv_pncounter:update(Op, Actor, Counter).

counter_op(Amt) when Amt < 0 ->
    {decrement, Amt * -1};
counter_op(Amt) ->
    {increment, Amt}.

%% This uses an exported but marked INTERNAL
%% function of `riak_object:set_contents' to preserve
%% non-counter sibling values and Metadata
%% NOTE: if `Meta' is `undefined' then this
%% is a new counter.
update_object(RObj, _, undefined, _Siblings) ->
    RObj;
update_object(RObj, Meta, Counter, []) ->
    RObj2 = riak_object:update_value(RObj, {riak_kv_pncounter, Counter}),
    RObj3 = riak_object:update_metadata(RObj2, counter_meta(Meta)),
    riak_object:apply_updates(RObj3);
update_object(RObj, Meta, Counter, SiblingValues) ->
    %% keep non-counter siblings, too
    riak_object:set_contents(RObj, [{counter_meta(Meta), {riak_kv_pncounter, Counter}} | SiblingValues]).

counter_meta(undefined) ->
    Now = os:timestamp(),
    M = dict:new(),
    M2 = dict:store(?MD_LASTMOD, Now, M),
    dict:store(?MD_VTAG, riak_kv_util:make_vtag(Now), M2);
counter_meta(Meta) ->
    Meta.

%% Just a simple take the largest for meta values based on last mod
merge_meta(Meta1, Meta2) ->
    case later(lastmod(Meta1), lastmod(Meta2)) of
        true ->
            Meta1;
        false ->
            Meta2
    end.

lastmod(Meta) ->
    dict:fetch(?MD_LASTMOD, Meta).

later(TS1, TS2) ->
    case timer:now_diff(TS1, TS2) of
        Before when Before < 0 ->
            false;
        _ ->
            true
    end.
