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

-module(tansu_consensus_leader).
-export([add_server/2]).
-export([append_entries/2]).
-export([append_entries_response/2]).
-export([end_of_term/1]).
-export([log/2]).
-export([remove_server/2]).
-export([request_vote/2]).
-export([transition_to_follower/1]).
-export([vote/2]).

add_server(_, #{change := _, match_indexes := _, next_indexes := _} = Data) ->
    %% change already in progress
    {next_state, leader, Data};
add_server(URI, #{match_indexes := _, next_indexes := _} = Data) ->
    {next_state, leader, tansu_consensus:do_add_server(URI, Data)}.

remove_server(_, #{change := _, match_indexes := _, next_indexes := _} = Data) ->
    %% change already in progress
    {next_state, leader, Data}.

log(Command, #{match_indexes := _, next_indexes := _} = Data) ->
    {next_state, leader, tansu_consensus:do_log(Command, Data)}.

%% If RPC request or response contains term T > currentTerm: set
%% currentTerm = T, convert to follower (§5.1)
%% TODO
append_entries(#{term := Term}, #{id := Id,
                                  match_indexes := _,
                                  next_indexes := _,
                                  term := Current} = Data) when Term > Current ->
    {next_state, follower, maps:without(
                             [match_indexes, next_indexes],
                             tansu_consensus:do_call_election_after_timeout(
                               tansu_consensus:do_drop_votes(
                                 Data#{term := tansu_ps:term(Id, Term)})))};

%% Reply false if term < currentTerm (§5.1)
append_entries(#{term := Term,
                 prev_log_index := PrevLogIndex,
                 prev_log_term := PrevLogTerm,
                 leader := Leader},
               #{term := Current,
                 match_indexes := _,
                 next_indexes := _,
                 id := Id} = Data) when Term < Current ->
    tansu_consensus:do_send(
      tansu_rpc:append_entries_response(
        Leader, Id, Current, PrevLogIndex, PrevLogTerm, false),
      Leader,
      Data),
    {next_state, leader, Data};

%% Append entries from another leader in the current term.
append_entries(#{prev_log_index := PrevLogIndex,
                 prev_log_term := PrevLogTerm,
                 leader := Leader} = AppendEntries,
               #{term := Current,
                 match_indexes := _,
                 next_indexes := _,
                 id := Id} = Data) ->
    %% Looks like we've found another leader in our term, report as a
    %% warning.
    error_logger:warning_report([{module, ?MODULE},
                                 {line, ?LINE},
                                 {description, found_another_leader},
                                 {append_entries, AppendEntries},
                                 {data, Data}]),
    %% Refuse to append the entries that we have been given.
    tansu_consensus:do_send(
      tansu_rpc:append_entries_response(
        Leader, Id, Current, PrevLogIndex, PrevLogTerm, false),
      Leader,
      Data),
    %% Remain "the" leader.
    {next_state, leader, Data}.


append_entries_response(#{term := Term}, #{id := Id, term := Current} = Data) when Term > Current ->
    {next_state, follower, maps:without(
                             [match_indexes, next_indexes],
                             tansu_consensus:do_call_election_after_timeout(
                               tansu_consensus:do_drop_votes(
                                 Data#{term := tansu_ps:term(Id, Term)})))};

append_entries_response(#{term := Term}, #{term := Current} = Data) when Term < Current ->
    {next_state, leader, Data};

append_entries_response(#{success := false,
                          prev_log_index := LastIndex,
                          follower := Follower},
                        #{match_indexes := _,
                          next_indexes := NextIndexes} = Data) ->
    {next_state, leader, Data#{next_indexes := NextIndexes#{Follower := LastIndex + 1}}};

append_entries_response(#{success := true,
                          prev_log_index := PrevLogIndex,
                          follower := Follower},
                        #{match_indexes := Match,
                          next_indexes := Next,
                          last_applied := LastApplied,
                          state_machine := SM,
                          commit_index := Commit0} = Data) ->

    case commit_index_majority(Match#{Follower => PrevLogIndex}, Commit0) of
        Commit1 when Commit1 > LastApplied ->
            {next_state,
             leader,
             Data#{state_machine => do_apply_to_state_machine(
                                      LastApplied + 1,
                                      Commit1,
                                      SM),
                   match_indexes := Match#{Follower => PrevLogIndex},
                   next_indexes := Next#{Follower => PrevLogIndex + 1},
                   commit_index => Commit1,
                   last_applied => Commit1}};

        _ ->
            {next_state,
             leader,
             Data#{
               match_indexes := Match#{Follower => PrevLogIndex},
               next_indexes := Next#{Follower => PrevLogIndex + 1}}}
    end.


end_of_term(#{term := T0,
              commit_index := CI,
              id := Id,
              match_indexes := _,
              next_indexes := NI,
              state_machine := StateMachine,
              last_applied := LA} = D0) ->
    T1 = tansu_ps:increment(Id, T0),
    {next_state, leader,
     tansu_consensus:do_end_of_term_after_timeout(
       D0#{
         term => T1,
         next_indexes := maps:fold(
                           fun
                               (Follower, Index, A) when LA >= Index ->
                                   case tansu_log:first() of
                                       #{index := LastIndexInSnapshot, command := #{m := tansu_sm, f := apply_snapshot, a := [Name]}, term := SnapshotTerm} when Index =< LastIndexInSnapshot ->
                                           
                                           {ok, Snapshot} = file:read_file(Name),

                                           tansu_consensus:do_send(
                                             tansu_rpc:install_snapshot(
                                               T1,
                                               Id,
                                               LastIndexInSnapshot,
                                               SnapshotTerm,
                                               0,
                                               0,
                                               {Name, StateMachine, Snapshot},
                                               true),
                                             Follower,
                                             D0),
                                           
                                           A#{Follower => LastIndexInSnapshot+1};
                                       
                                       _ ->

                                           Batch = min(tansu_config:batch_size(append_entries), LA - Index),
                                           Entries = tansu_log:read(Index, Index + Batch),
                                           tansu_consensus:do_send(
                                             tansu_rpc:append_entries(
                                               T1,
                                               Id,
                                               Index-1,
                                               tansu_log:term_for_index(Index-1),
                                               CI,
                                               Entries),
                                             Follower,
                                             D0),
                                           A#{Follower => Index + Batch + 1}
                                   end;

                               (Follower, Index, A) ->
                                   tansu_consensus:do_send(
                                     tansu_rpc:append_entries(
                                       T1,
                                       Id,
                                       Index-1,
                                       tansu_log:term_for_index(Index-1),
                                       CI,
                                       []),
                                     Follower,
                                     D0),
                                   A#{Follower => Index}
                           end,
                           #{},
                           NI)})}.

%% If RPC request or response contains term T > currentTerm: set
%% currentTerm = T, convert to follower (§5.1)
%% TODO
vote(#{term := Term}, #{id := Id,
                        match_indexes := _,
                        next_indexes := _,
                        term := Current} = Data) when Term > Current ->
    {next_state, follower, maps:without(
                             [match_indexes, next_indexes],
                             tansu_consensus:do_call_election_after_timeout(
                               tansu_consensus:do_drop_votes(
                                 Data#{term := tansu_ps:term(Id, Term)})))};

%% Votes from an earlier term are dropped.
vote(#{term := Term}, #{term := Current} = Data) when Term < Current ->
    {next_state, leader, Data};

vote(#{term := T, elector := Elector, granted := true},
     #{term := T,
       commit_index := CI,
       match_indexes := _,
       next_indexes := NI} = Data) ->
    {next_state, leader, Data#{next_indexes := NI#{Elector => CI + 1}}};

vote(#{term := T, elector := Elector, granted := false},
     #{term := T, against := Against} = Data) ->
    {next_state, leader, Data#{against := [Elector | Against]}}.


%% If RPC request or response contains term T > currentTerm: set
%% currentTerm = T, convert to follower (§5.1)
%% TODO
request_vote(#{term := Term},
             #{id := Id,
               match_indexes := _,
               next_indexes := _,
               term := Current} = Data) when Term > Current ->
    {next_state, follower, maps:without(
                             [match_indexes, next_indexes],
                             tansu_consensus:do_call_election_after_timeout(
                               tansu_consensus:do_drop_votes(
                                 Data#{term := tansu_ps:term(Id, Term)})))};

request_vote(#{term := Term,
               candidate := Candidate},
             #{id := Id,
               commit_index := CI,
               match_indexes := _,
               next_indexes := NI} = Data) ->
    tansu_consensus:do_send(
      tansu_rpc:vote(Id, Term, false),
      Candidate,
      Data),
    {next_state, leader, Data#{next_indexes := NI#{Candidate => CI + 1}}}.


commit_index_majority(Values, CI) ->
    commit_index_majority(
      lists:reverse(ordsets:from_list(maps:values(Values))),
      maps:values(Values),
      CI).

commit_index_majority([H | T], Values, CI) when H > CI ->
    case [I || I <- Values, I >= H] of
        Majority when length(Majority) > (length(Values) / 2) ->
            H;
        _ ->
            commit_index_majority(T, Values, CI)
    end;
commit_index_majority(_, _, CI) ->
    CI.


do_apply_to_state_machine(LastApplied, CommitIndex, State) ->
    do_apply_to_state_machine(lists:seq(LastApplied, CommitIndex), State).

do_apply_to_state_machine([H | T], undefined) ->
    case tansu_log:read(H) of
        #{command := #{f := F, a := A}} ->
            {_, State} = apply(tansu_sm, F, A),
            do_apply_to_state_machine(T, State);

        #{command := #{f := F}} ->
            {_, State} = apply(tansu_sm, F, []),
            do_apply_to_state_machine(T, State)
    end;

do_apply_to_state_machine([H | T], S0) ->
    case tansu_log:read(H) of
        #{command := #{f := F, a := A, from := From}} ->
            {Result, S1}  = apply(tansu_sm, F, A ++ [S0]),
            gen_fsm:reply(From, Result),
            do_apply_to_state_machine(T, S1);

        #{command := #{f := F, a := A}} ->
            {_, S1} = apply(tansu_sm, F, A ++ [S0]),
            do_apply_to_state_machine(T, S1);

        #{command := #{f := F, from := From}} ->
            {Result, S1} = apply(tansu_sm, F, [S0]),
            gen_fsm:reply(From, Result),
            do_apply_to_state_machine(T, S1);

        #{command := #{f := F}} ->
            {_, S1} = apply(tansu_sm, F, [S0]),
            do_apply_to_state_machine(T, S1)
    end;

do_apply_to_state_machine([], State) ->
    State.


transition_to_follower(Data) ->
    maps:without(
      [match_indexes, next_indexes],
      tansu_consensus:do_call_election_after_timeout(
        tansu_consensus:do_drop_votes(Data))).
