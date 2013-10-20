%%%-----------------------------------------------------------------------------
%%% @author Sven Heyll <sven.heyll@lindenbaum.eu>
%%% @copyright (C) 2011, 2012 Sven Heyll
%%% @doc
%%% The module name 'em' stands for 'Erly Mock'.
%%%
%%% <p>This mocking library works similar to Easymock.</p>
%%%
%%% <p>After a mock process is started by {@link new/0} it can be
%%% programmed to expect function calls and to react to them in two
%%% ways: <ul><li>by returning a value</li><li>by executing an arbitrary
%%% function</li></ul>
%%% This is done with {@link strict/4}, {@link strict/5}, {@link stub/4}, {@link stub/5}
%%% </p>
%%%
%%% <p>Before the code under test is executed, the mock must be told
%%% that the programming phase is over by {@link replay/1}.</p>
%%%
%%% <p>In the next phase the code under test is run, and might or
%%% might not call the functions mocked.
%%% The mock process checks that all functions programmed with
%%% {@link strict/4}, {@link strict/5} are called in the
%%% correct order, with the expected arguments and reacts in the way
%%% defined during the programming phase. If a mocked function is called
%%% although another function was expected, or if an expected function
%%% was called with different arguments, the mock process dies and
%%% prints a comprehensive error message before failing the test.</p>
%%%
%%% <p>At the end of a unit test {@link await_expectations/1} is called to
%%% await all invocations defined during the programming phase.</p>
%%%
%%% <p>An alternative to {@link await_expectations/1} is {@link verify/1}. It is
%%% called to check for missing invocations at the end of the programming phase,
%%% if any expected invocations are missing at verify will throw an exception.</p>
%%%
%%% <p>When the mock process exits it tries hard to remove all modules, that
%%% were dynamically created and loaded during the programming phase.</p>
%%%
%%% NOTE: This library works by purging the modules mocked and replacing
%%% them with dynamically created and compiled code, so be careful what
%%% you mock, i.e. it brings chaos to mock modules from kernel. This also
%%% implies, that tests that mock the same modules must be run sequentially.
%%%
%%% Apart from that, it is very advisable to <b>only mock owned modules</b>
%%% anyway.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2011,2012 Sven Heyll
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in
%%% all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%%% THE SOFTWARE.
%%%
%%%-----------------------------------------------------------------------------

-module(em).

-behaviour(gen_fsm).

%% public API ---
-export([new/0,
         strict/4,
         strict/5,
         stub/4,
         stub/5,
         replay/1,
         await/2,
         await_expectations/1,
         verify/1,
         any/0,
         zelf/0,
         nothing/2,
		 call_log/1]).

%% gen_fsm callbacks ---
-export([programming/3,
         replaying/3,
         no_expectations/3,
         terminate/3,
         init/1,
         code_change/4,
         handle_event/3,
         handle_info/3,
         handle_sync_event/4]).

%% !!!NEVER CALL THIS FUNCTION!!! ---
-export([invoke/4]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%% important types
%%

%%------------------------------------------------------------------------------
%% The type that defines the argument list passed to strict() or stub().
%% Each list element is either a value that will be matched to the actual value
%% of the parameter at that position, or a predicate function which will be
%% applied to the actual argument.
%%------------------------------------------------------------------------------
-type args() :: [ fun((any()) ->
                             true | false)
                     | term()].

%%------------------------------------------------------------------------------
%% The type that defines the response to a mocked function call. A response is
%% either that a value is returned, or the application of a function to the
%% actual arguments.
%%------------------------------------------------------------------------------
-type answer() :: {function, fun(([any()]) -> any())}
                  | {return, any()} .

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%% API
%%

%%------------------------------------------------------------------------------
%% @doc
%% Spawn a linked mock process and return the pid. <p>This is usually the
%% first thing to do in each unit test. The resulting pid is used in the other
%% functions below.</p> <p>NOTE: only a single mock proccess is required for a
%% single unit test case. One mock process can mock an arbitrary number of
%% different modules.</p> <p>When the mock process dies, all uploaded modules
%% are purged from the code server, and all cover compiled modules are
%% restored.</p> <p>When the process that started the mock exits, the mock
%% automatically cleans up and exits.</p> <p>After new() the mock is in
%% 'programming' state.</p>
%% @end
%%------------------------------------------------------------------------------
-spec new() ->
                 pid().
new() ->
    {ok, Pid} = gen_fsm:start_link(?MODULE, [erlang:self()], []),
    Pid.

%%------------------------------------------------------------------------------
%% @doc
%% Add an expectation during the programming phase for a specific function
%% invokation.
%%
%% <p>All expectations defined by 'strict' define an order in which the
%% application must call the mocked functions, hence the name 'strict' as oposed
%% to 'stub' (see below).</p>
%%
%% <p>The parameters are:
%% <ul>
%% <li><code>M</code> the mock pid, returned by {@link new/0}</li>
%% <li><code>Mod</code> the module of the function to mock</li>
%% <li><code>Fun</code> the name of the function to mock</li>
%% <li><code>Args</code> a list of expected arguments.
%% Each list element is either a value that will be matched to the actual value
%% of the parameter at that position, or a predicate function which will be
%% applied to the actual argument.</li>
%% </ul></p>
%%
%% <p>This function returns a reference that identifies the expectation. This
%% reference can be passed to {@link await/2} which blocks until the expected
%% invokation happens.</p>
%%
%% <p> The return value, that the application will get when calling the mocked
%% function in the replay phase is simply the atom <code>ok</code>. This
%% differentiates this function from {@link strict/5}, which allows the
%% definition of a custom response function or a custom return value.  </p>
%%
%% NOTE: This function may only be called between <code>new/0</code> and {@link
%% replay/1} - that is during the programming phase.
%%
%% @end
%%------------------------------------------------------------------------------
-spec strict(pid(), atom(), atom(), args()) ->
                    reference().
strict(M, Mod, Fun, Args)
  when is_pid(M), is_atom(Mod), is_atom(Fun), is_list(Args) ->
    strict(M, Mod, Fun, Args, {return, ok}).

%%------------------------------------------------------------------------------
%% @doc
%% This function behaves like {@link strict/4}
%% and additionally accepts a return value or an answer function. That parameter
%% <code>Answer</code> may be:
%% <ul>
%% <li><code>{return, SomeValue}</code> This causes the mocked function invocation to
%% return the specified value.</li>
%% <li><code>{function, fun(([Arg1, ... , ArgN]) -> SomeValue)}</code> This defines
%% a function to be called when the mocked invokation happens.
%% That function is applied to all captured actual arguments.  For convenience these
%% are passed as a list, so the user can simply write <code>fun(_) -> ...</code>
%% when the actual values are not needed.
%% The function will be executed by the process that calls the mocked function, not
%% by the mock process. Hence the function may access <code>self()</code> and may
%% throw an exception, which will then correctly appear in the process under test,
%% allowing unit testing of exception handling.
%% Otherwise the value returned by the function is passed through as the value
%% returned from the invocation.
%% </li>
%% </ul>
%% @end
%%------------------------------------------------------------------------------
-spec strict(pid(), atom(), atom(), args(), answer()) ->
                    reference().
strict(M, Mod, Fun, Args, Answer = {return, _})
  when is_pid(M), is_atom(Mod), is_atom(Fun), is_list(Args) ->
    gen_fsm:sync_send_event(M, {strict, Mod, Fun, Args, Answer});
strict(M, Mod, Fun, Args, Answer = {function, _})
  when is_pid(M), is_atom(Mod), is_atom(Fun), is_list(Args) ->
    gen_fsm:sync_send_event(M, {strict, Mod, Fun, Args, Answer}).

%%------------------------------------------------------------------------------
%% @doc
%% Defines a what happens when a function is called whithout recording any
%% expectations. The invocations defined by this function may happen in any order
%% any number of times. The way, the invocation is defined is analog to
%% @see strict/4. <code>strict/4</code>
%% @end
%%------------------------------------------------------------------------------
-spec stub(pid(), atom(), atom(), args()) ->
                  ok.
stub(M, Mod, Fun, Args)
  when is_pid(M), is_atom(Mod), is_atom(Fun), is_list(Args) ->
    stub(M, Mod, Fun, Args, {return, ok}).

%%------------------------------------------------------------------------------
%% @doc
%% This is similar <code>stub/4</code> except that it, like
%% <code>strict/5</code> allows the definition of a return value
%% or an answer function.
%% @see stub/4. <code>stub/4</code>
%% @see strict/5. <code>strict/5</code>
%% @end
%%------------------------------------------------------------------------------
-spec stub(pid(), atom(), atom(), args(), answer()) ->
                  ok.
stub(M, Mod, Fun, Args, Answer = {return, _})
  when is_pid(M), is_atom(Mod), is_atom(Fun), is_list(Args) ->
    ok = gen_fsm:sync_send_event(M, {stub, Mod, Fun, Args, Answer});
stub(M, Mod, Fun, Args, Answer = {function, _})
  when is_pid(M), is_atom(Mod), is_atom(Fun), is_list(Args) ->
    ok = gen_fsm:sync_send_event(M, {stub, Mod, Fun, Args, Answer}).

%%------------------------------------------------------------------------------
%% @doc
%% This is used to express the expectation that no function of a certain module
%% is called. This will cause each function call on a module to throw an 'undef'
%% exception.
%% @end
%%------------------------------------------------------------------------------
-spec nothing(pid(), atom()) ->
		     ok.
nothing(M, Mod) when is_pid(M), is_atom(Mod) ->
   ok = gen_fsm:sync_send_event(M, {nothing, Mod}).

%%------------------------------------------------------------------------------
%% @doc
%% Finishes the programming phase and switches to the replay phase where the
%% actual code under test may run and invoke the functions mocked. This may
%% be called only once, and only in the programming phase. This also loads
%% (or replaces) the modules of the functions mocked.
%% In the replay phase the code under test may call all mocked functions.
%% If the application calls a mocked function with invalid arguments, or
%% if the application calls a function not expected on a mocked module, the mock
%% process dies and - if used in a typical edoc test suite - fails the test.
%% @end
%%------------------------------------------------------------------------------
-spec replay(M :: term()) -> ok.
replay(M) ->
    ok = gen_fsm:sync_send_event(M, replay).

%%------------------------------------------------------------------------------
%% @doc
%% Block until a specific invokation defined via {@link strict/4} during the
%% programming phase was made. <p>The handle for the specific invokation is the
%% value returned by {@link strict/4}.</p> <p>The return value contains the
%% parameters and the pid of the recorded invokation. This function maybe called
%% anytime before or after the referenced invokation has actually
%% happened.</p><p>If the handle is not valid, an error is returned.</p>
%% @end
%% ------------------------------------------------------------------------------
-spec await(M :: term(), Handle :: reference()) ->
                   {success,
                    InvPid :: pid(),
                    Args :: [term()]} |
                   {error, invalid_handle}.
await(M, Handle) ->
    gen_fsm:sync_send_all_state_event(M, {await, Handle}, 5000).

%%------------------------------------------------------------------------------
%% @doc
%% Wait until all invokations defined during the programming phase were made.
%% After this functions returns, the mock can be expected to exit and clean up
%% all modules installed.
%% @end
%%------------------------------------------------------------------------------
-spec await_expectations(M :: term()) -> ok.
await_expectations(M) ->
    ok = gen_fsm:sync_send_all_state_event(M, await_expectations, 5000).

%%------------------------------------------------------------------------------
%% @doc
%% Finishes the replay phase. If the code under test did not cause all expected
%% invokations defined by {@link strict/4} or {@link strict/5}, the
%% call will fail with <code>badmatch</code> with a comprehensive error message.
%% Otherwise the mock process exits normally, returning <code>ok</code>.
%% @end
%%------------------------------------------------------------------------------
-spec verify(M :: term()) -> ok.
verify(M) ->
    ok = gen_fsm:sync_send_event(M, verify).

%%------------------------------------------------------------------------------
%% @doc
%% Utility function that can be used as a match function in an argument list
%% to match any value.
%% @end
%%------------------------------------------------------------------------------
-spec any() ->
                 fun((any()) ->
                    true).
any() ->
    fun(_) ->
            true
    end.

%%------------------------------------------------------------------------------
%% @doc
%% Utility function that can be used as a match function in an
%% argument list to match <code>self()</code>, e.g. when it matches the pid of the
%% process, that calls the funtion during the replay phase.
%% @end
%%------------------------------------------------------------------------------
-spec zelf() ->
                  atom().
zelf() ->
    '$$em zelf$$'.

%%------------------------------------------------------------------------------
%% @doc
%% retrieve a list of functions since the creation of the module.
%% <p>The log will track the calls regardless whether they are done for a strict
%% or stub function. In case the answers are not evaluated, as an function used 
%% here may have side effects and depend on the process in which it is evaluated.
%% </p>
%% @end
%%------------------------------------------------------------------------------
-spec call_log(M :: term()) ->  [{Mod :: atom(),
								  Func :: atom(),
								  Args :: [term()],
								  Answer :: term()}].
call_log(M) -> gen_fsm:sync_send_all_state_event(M, get_call_log).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%% internal state
%%

-record(expectation,
        {id :: reference(),
         m :: atom(),
         f :: atom(),
         a :: args(),
         answer :: answer(),
         listeners :: [GenFsmFrom :: term()]}).

-record(state, {
          test_proc :: pid(),
          strict :: [#expectation{}],
          strict_log :: [{strict_log,
                          ERef :: reference(),
                          IPid :: pid(),
                          Args :: [term()]}],
          stub  :: [#expectation{}],
		  call_log :: [{Mod :: atom(),
						Func :: atom(),
						Args :: [term()],
						Answer :: term()}],
	  blacklist :: [atom()],
          mocked_modules :: [{atom(), {just, term()}|nothing}],
          await_invokations_reply :: nothing | {just, term()}
         }).

-type statedata() :: #state{}.

-define(ERLYMOCK_COMPILED, erlymock_compiled).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%% gen_fsm callbacks
%%i

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
-spec init([TestProc :: term()]) ->
                  {ok, atom(), StateData :: statedata()}.
init([TestProc]) ->
    process_flag(sensitive, true),
    erlang:trace(self(), false, [all]),
    {ok,
     programming,
     #state{
        test_proc = TestProc,
        strict = [],
        strict_log = [],
        stub = [],
		call_log =[],
        blacklist = [],
        mocked_modules = [],
        await_invokations_reply = nothing}}.


%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
-spec programming(Event :: term(), From :: term(), State :: statedata()) ->
                         {reply, Reply :: term(), NextState :: atom(),
                          NewStateData :: statedata()}.
programming({strict, Mod, Fun, Args, Answer},
            _From,
            State = #state{strict = Strict}) ->
    InvRef = make_ref(),
    {reply,
     InvRef,
     programming,
     State#state{
       strict = [#expectation{id = InvRef,
                              m = Mod,
                              f = Fun,
                              a = Args,
                              answer = Answer,
                              listeners = []}
                 |Strict]}};

programming({stub, Mod, Fun, Args, Answer},
            _From,
            State = #state{stub = Stub}) ->
    {reply,
     ok,
     programming,
     State#state{
       stub = [#expectation{m = Mod, f = Fun, a = Args, answer = Answer}|Stub]}};

programming({nothing, Mod},
            _From,
            State = #state{blacklist = BL}) ->
    {reply,
     ok,
     programming,
     State#state{
       blacklist = [Mod | BL]}};

programming(replay,
            _From,
            State = #state{strict = Strict}) ->
    MMs = install_mock_modules(State),
    {reply,
     ok,
     case Strict of
         [] -> no_expectations;
         _ -> replaying
     end,
     State#state{
       strict = lists:reverse(Strict),
       mocked_modules = MMs}}.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
-spec replaying(Event :: term(), From :: term(), StateData :: statedata()) ->
                       {reply, Reply :: term(), NextState :: atom(),
                        NewStateData :: statedata()} |
                       {stop, Reason :: term(), Reply :: term(),
                        NewStateData :: statedata()}.
replaying(I = {invokation, Mod, Fun, Args, IPid},
          From,
          State = #state{
            await_invokations_reply = AwInvRepl,
            strict = [#expectation{
                         id     = ERef,
                         m      = Mod,
                         f      = Fun,
                         a      = EArgs,
                         answer = Answer,
                         listeners = Listeners}
                      |Rest],
			call_log = CallLog})
  when length(EArgs) == length(Args) ->
    case check_args(Args, EArgs, IPid) of
        true ->
            gen_fsm:reply(From, Answer),
            [gen_fsm:reply(Listener, {success, IPid, Args})
             || Listener <- Listeners],
            NextState = case Rest of
                            [] -> no_expectations;
                            _ ->
                                replaying
                        end,
            if NextState =:= replaying orelse AwInvRepl =:= nothing ->
                    {next_state, NextState,
                     State#state{strict=Rest,
                                 strict_log =
                                     [{strict_log, ERef, IPid, Args}
                                      | State#state.strict_log],
								 call_log = [{Mod,Fun,Args,Answer}|CallLog]}};
               true ->
                    {just, AIR} = AwInvRepl,
                    gen_fsm:reply(AIR, ok),
                    {stop, normal, State}
            end;
        {error, Index, Expected, Actual} ->
            Reason = {unexpected_function_parameter,
                      {error_in_parameter, Index},
                      {expected, Expected},
                      {actual, Actual},
                      I},
            {stop, Reason, Reason, State}
    end;

replaying(I = {invokation, M, F, A, _IPid},
          _From,
          State = #state{
	    strict = [E|_],
		call_log = CallLog}) ->
    case handle_stub_invokation(I, State#state.stub) of
	{ok, Answer} ->
	    {reply, Answer, replaying, 
		 State#state{call_log = [{M, F, A, Answer}|CallLog]}};

	error ->
	    Reason = {unexpected_invokation, {actual, I}, {expected, E}},
	    {stop, Reason, Reason, State}
    end;

replaying(verify, _From, State) ->
    Reason = {invokations_missing, State#state.strict},
    {stop, Reason, Reason, State}.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
-spec no_expectations(Event :: term(), From :: term(),
                      StateData :: statedata()) ->
                             {reply, Reply :: term(), NextState :: atom(),
                              NewStateData :: statedata()} |
                             {stop, Reason :: term(), Reply :: term(),
                              NewStateData :: statedata()}.
no_expectations(I = {invokation, M, F, A, _IPid}, _From, State) ->
    case handle_stub_invokation(I, State#state.stub) of
        {ok, Answer} ->
            {reply, Answer, no_expectations, 
			 State#state{call_log = [{M, F, A, Answer}| State#state.call_log]}};

        error ->
            Reason = {unexpected_invokation, {actual, I}},
            {stop, Reason, Reason, State}
    end;

no_expectations(verify, _From, State) ->
    {stop, normal, ok, State}.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
-spec terminate(Reason :: term(), StateName :: atom(),
                StateData :: statedata()) -> no_return().
terminate(Reason, _StateName, State = #state{test_proc = TestProc}) ->
    unload_mock_modules(State),
    exit(TestProc, Reason).

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
-spec code_change(OldVsn :: term(), StateName :: atom(), State :: statedata(),
                  Extra :: term()) ->
                         {ok, NextState :: atom(), NewStateData :: statedata()}.
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
-spec handle_sync_event(Event :: term(), From :: term(), StateName :: atom(),
                        StateData :: statedata()) ->
                               {stop, normal, ok, NewStateData :: statedata()}
                                   | {next_state, StateName :: atom(),
                                      NewStateData :: statedata()}.
handle_sync_event({await, H}, From, StateName, State) ->
    {next_state, StateName, add_invokation_listener(From, H, State)};
handle_sync_event(await_expectations, _From, no_expectations, State) ->
    {stop, normal, ok, State};
handle_sync_event(await_expectations, From, StateName,
                  State =  #state{await_invokations_reply = nothing}) ->
    {next_state, StateName, State#state{await_invokations_reply = {just, From}}};
handle_sync_event(get_call_log, _From, StateName, State) ->
	{reply, lists:reverse(State#state.call_log), StateName, State};
handle_sync_event(_Evt, _From, _StateName, State) ->
    {stop, normal, ok, State}.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
-spec handle_info(Info :: term(), StateName :: atom(),
                  StateData :: statedata()) ->
                         {stop, normal, NewStateData :: statedata()}.
handle_info(_Info, _StateName, State) ->
    {stop, normal, State}.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
-spec handle_event(Msg :: term(), StateName :: atom(),
                   StateData :: statedata()) ->
                          {stop, normal, NewStateData :: statedata()}.
handle_event(_Msg, _StateName, State) ->
    {stop, normal, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%% api for generated mock code
%%

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
-spec invoke(M :: term(), Mod :: term(), Fun :: fun(), Args :: list()) ->
                    {Value :: term()}.
invoke(M, Mod, Fun, Args) ->
    case gen_fsm:sync_send_event(M, {invokation, Mod, Fun, Args, self()}) of
        {return, Value} ->
            Value;
        {function, F} ->
            F(Args)
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%% internal functions
%%
%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
unload_mock_modules(#state{mocked_modules = MMs}) ->
    [begin
   code:purge(Mod),
	 code:delete(Mod),
	 code:purge(Mod),
         case MaybeBin of
              nothing ->
                 ignore;
             {just, {Mod, CoverCompiledBinary}} ->
                 code:load_binary(Mod, cover_compiled, CoverCompiledBinary)
         end
     end
     || {Mod, MaybeBin} <- MMs].

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
install_mock_modules(#state{strict = ExpectationsStrict,
                            stub = ExpectationsStub,
			    blacklist = BlackList}) ->
    Expectations = ExpectationsStub ++ ExpectationsStrict,
    ModulesToMock = lists:usort([M || #expectation{m = M} <- Expectations] ++ BlackList),
    assert_not_mocked(ModulesToMock),
    [install_mock_module(M, Expectations) || M <- ModulesToMock].

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
install_mock_module(Mod, Expectations) ->
    MaybeBin = get_cover_compiled_binary(Mod),
    ModHeaderSyn = [erl_syntax:attribute(erl_syntax:atom(module),
					 [erl_syntax:atom(Mod)]),
                    erl_syntax:attribute(erl_syntax:atom(?ERLYMOCK_COMPILED),
					 [erl_syntax:atom(true)]),
                    erl_syntax:attribute(erl_syntax:atom(compile),
                                         [erl_syntax:list(
                                            [erl_syntax:atom(export_all)])])],
    Funs = lists:usort(
             [{F, length(A)} || #expectation{m = M, f = F, a = A} <- Expectations,
                                M == Mod]),
    FunFormsSyn = [mock_fun_syn(Mod, F, A) || {F, A} <- Funs],

    {ok, Mod, Code} =
        compile:forms([erl_syntax:revert(F)
                       || F <- ModHeaderSyn ++ FunFormsSyn]),

    code:purge(Mod),
    code:delete(Mod),
    code:purge(Mod),
    {module, _} = load_module(Mod, Code),
    {Mod, MaybeBin}.


%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
mock_fun_syn(Mod, F, Args) ->
    ArgsSyn = var_list_syn(Args),
    FunSyn = erl_syntax:atom(F),
    erl_syntax:function(
       FunSyn,
       [erl_syntax:clause(ArgsSyn,
                          none,
                          body_syn(Mod, FunSyn, ArgsSyn))]).

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
var_list_syn(Args) ->
    [erl_syntax:variable(list_to_atom("Arg_" ++ integer_to_list(I)))
     || I <- lists:seq(0, Args - 1)].

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
body_syn(Mod, FunSyn, ArgsSyn) ->
    SelfStr = pid_to_list(erlang:self()),
    SelfSyn = erl_syntax:application(
                erl_syntax:atom(erlang),
                erl_syntax:atom(list_to_pid),
                [erl_syntax:string(SelfStr)]),
    [erl_syntax:application(
       erl_syntax:atom(?MODULE),
       erl_syntax:atom(invoke),
       [SelfSyn,
        erl_syntax:atom(Mod),
        FunSyn,
        erl_syntax:list(ArgsSyn)])].

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
check_args(Args, ArgSpecs, InvokationPid) ->
    try
        [begin
             if
                 is_function(E) ->
                     case E(A) of
                         true ->
                             ok;
                         _ ->
                             throw({error, I, E, A})
                     end;
                 true ->
                     case E of

                         '$$em zelf$$' ->
                             if A =/= InvokationPid ->
                                     throw({error, I, E, A});
                                true ->
                                     ok
                             end;

                         A ->
                             ok;

                         _Otherwise ->
                             throw({error, I, E, A})
                     end
             end
         end
         || {I, A, E} <- lists:zip3(lists:seq(1, length(Args)),
                                    Args,
                                    ArgSpecs)] of
        _ ->
            true
    catch
        _:E ->
            E
    end.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
handle_stub_invokation({invokation, Mod, Fun, Args, IPid}, Stubs) ->
    case [MatchingStub
          || MatchingStub = #expectation {m = M, f = F, a = A} <- Stubs,
             M == Mod, F == Fun, length(Args) == length(A),
             check_args(Args, A, IPid) == true] of

        [#expectation{answer = Answer}|_] ->
            {ok, Answer};

        _ ->
            error
    end.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
-spec get_cover_compiled_binary(atom()) ->
                                       {just, term()} | nothing.
get_cover_compiled_binary(Mod) ->
    case code:which(Mod) of
        cover_compiled ->
            case ets:info(cover_binary_code_table) of
                undefined ->
                    nothing;
                _ ->
                    case ets:lookup(cover_binary_code_table, Mod) of
                        [Binary] ->
                            {just, Binary};
                        _ ->
                            nothing
                    end
            end;
        _ ->
            nothing
    end.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
add_invokation_listener(From, Ref, State = #state{strict=Strict,
                                                  strict_log = StrictSucc}) ->
    %% if the invokation does not exist, check the strict_history
    case lists:keyfind(Ref, 2, Strict) of
        false ->
            case lists:keyfind(Ref, 2, StrictSucc) of
                false ->
                    gen_fsm:reply(From, {error, invalid_handle});

                {strict_log, _ERef, IPid, Args} ->
                    gen_fsm:reply(From, {success, IPid, Args})
            end,
            State;

        E = #expectation{listeners = Ls} ->
            NewE = E#expectation{listeners = [From|Ls]},
            NewStrict = lists:keyreplace(Ref, 2, Strict, NewE),
            State#state{strict = NewStrict}
    end.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
assert_not_mocked(Mods) ->
    [case assert_not_mocked_(M) of
         ok -> ok;
         {error, {already_mocked, Mod}} ->
             throw({em_error_module_already_mocked, Mod})
     end || M <- Mods],
    ok.
assert_not_mocked_(Mod) ->
    try Mod:module_info(attributes) of
        Attrs ->
            case lists:keyfind(?ERLYMOCK_COMPILED, 1 , Attrs) of
                false ->
                    ok;
                _ ->
                    {error, {already_mocked, Mod}}
            end
    catch
        _:_ ->
            ok
    end.
