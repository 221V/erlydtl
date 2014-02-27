%%%-------------------------------------------------------------------
%%% File:      erlydtl_beam_compiler.erl
%%% @author    Roberto Saccon <rsaccon@gmail.com> [http://rsaccon.com]
%%% @author    Evan Miller <emmiller@gmail.com>
%%% @author    Andreas Stenius <kaos@astekk.se>
%%% @copyright 2008 Roberto Saccon, Evan Miller
%%% @copyright 2014 Andreas Stenius
%%% @doc
%%% ErlyDTL template compiler for beam targets.
%%% @end
%%%
%%% The MIT License
%%%
%%% Copyright (c) 2007 Roberto Saccon, Evan Miller
%%% Copyright (c) 2014 Andreas Stenius
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
%%% @since 2007-12-16 by Roberto Saccon, Evan Miller
%%% @since 2014 by Andreas Stenius
%%%-------------------------------------------------------------------
-module(erlydtl_beam_compiler).
-author('rsaccon@gmail.com').
-author('emmiller@gmail.com').
-author('Andreas Stenius <kaos@astekk.se>').

%% --------------------------------------------------------------------
%% Definitions
%% --------------------------------------------------------------------

-export([compile/3, compile_dir/2, format_error/1]).

%% internal use
-export([
         is_up_to_date/2,

         format/2,
         value_ast/4,
         interpret_args/2
        ]).

-import(erlydtl_compiler, [parse_file/2, do_parse_template/2]).

-import(erlydtl_compiler_utils,
        [unescape_string_literal/1, full_path/2, push_scope/2,
         restore_scope/2, begin_scope/1, begin_scope/2, end_scope/4,
         empty_scope/0, get_current_file/1, add_errors/2,
         add_warnings/2, merge_info/2, call_extension/3,
         init_treewalker/1, resolve_variable/2, resolve_variable/3,
         reset_parse_trail/2, load_library/3, load_library/4]).

-include_lib("merl/include/merl.hrl").
-include("erlydtl_ext.hrl").


%% --------------------------------------------------------------------
%% API
%% --------------------------------------------------------------------

compile(DjangoParseTree, CheckSum, Context) ->
    compile_to_binary(DjangoParseTree, CheckSum, Context).

compile_dir(Dir, Context) ->
    do_compile_dir(Dir, Context).

format_error(no_out_dir) ->
    "Compiled template not saved (need out_dir option)";
format_error(unexpected_extends_tag) ->
    "The extends tag must be at the very top of the template";
format_error(circular_include) ->
    "Circular file inclusion!";
format_error({write_file, Error}) ->
    io_lib:format(
      "Failed to write file: ~s",
      [file:format_error(Error)]);
format_error(compile_beam) ->
    "Failed to compile template to BEAM code";
format_error({unknown_filter, Name, Arity}) ->
    io_lib:format("Unknown filter '~s' (arity ~p)", [Name, Arity]);
format_error({filter_args, Name, {Mod, Fun}, Arity}) ->
    io_lib:format("Wrong number of arguments to filter '~s' (~p:~p): ~p", [Name, Mod, Fun, Arity]);
format_error({missing_tag, Name, {Mod, Fun}}) ->
    io_lib:format("Custom tag '~s' not exported (~p:~p)", [Name, Mod, Fun]);
format_error({bad_tag, Name, {Mod, Fun}, Arity}) ->
    io_lib:format("Invalid tag '~s' (~p:~p/~p)", [Name, Mod, Fun, Arity]);
format_error({load_code, Error}) ->
    io_lib:format("Failed to load BEAM code: ~p", [Error]);
format_error(Error) ->
    erlydtl_compiler:format_error(Error).


%%====================================================================
%% Internal functions
%%====================================================================

do_compile_dir(Dir, Context) ->
    %% Find all files in Dir (recursively), matching the regex (no
    %% files ending in "~").
    Files = filelib:fold_files(Dir, ".+[^~]$", true, fun(F1,Acc1) -> [F1 | Acc1] end, []),
    {ParserResults,
     #dtl_context{ errors=#error_info{ list=ParserErrors } }=Context1}
        = lists:foldl(
            fun (File, {ResultAcc, Ctx}) ->
                    case filename:basename(File) of
                        "."++_ ->
                            {ResultAcc, Ctx};
                        _ ->
                            FilePath = filename:absname(File),
                            case filelib:is_dir(FilePath) of
                                true ->
                                    {ResultAcc, Ctx};
                                false ->
                                    case parse_file(FilePath, Ctx) of
                                        up_to_date -> {ResultAcc, Ctx};
                                        {ok, DjangoParseTree, CheckSum} ->
                                            {[{File, DjangoParseTree, CheckSum}|ResultAcc], Ctx};
                                        {error, Reason} -> {ResultAcc, ?ERR(Reason, Ctx)}
                                    end
                            end
                    end
            end,
            {[], Context},
            Files),
    if length(ParserErrors) == 0 ->
            compile_multiple_to_binary(Dir, ParserResults, Context1);
       true -> Context1
    end.

compile_multiple_to_binary(Dir, ParserResults, Context) ->
    MatchAst = options_match_ast(Context),

    {Functions,
     {AstInfo,
      #treewalker{
         context=#dtl_context{
                    errors=#error_info{ list=Errors }
                   }=Context1 } }
    } = lists:mapfoldl(
          fun ({File, DjangoParseTree, CheckSum},
               {AstInfo, #treewalker{ context=Ctx }=TreeWalker}) ->
                  try
                      FilePath = full_path(File, Ctx#dtl_context.doc_root),
                      {{BodyAst, BodyInfo}, TreeWalker1} = with_dependency(
                                                             {FilePath, CheckSum},
                                                             body_ast(DjangoParseTree, TreeWalker)),
                      FunctionName = filename:rootname(filename:basename(File)),
                      Function1 = ?Q("'@FunctionName@'(Variables) -> _@FunctionName@(Variables, [])."),
                      Function2 = ?Q(["'@FunctionName@'(Variables, RenderOptions) ->",
                                      "  try _@MatchAst, _@body of",
                                      "    Val -> {ok, Val}",
                                      "  catch",
                                      "    Err -> {error, Err}",
                                      "  end."],
                                     [{body, stringify(BodyAst, Ctx)}]),
                      {{FunctionName, Function1, Function2}, {merge_info(AstInfo, BodyInfo), TreeWalker1}}
                  catch
                      throw:Error ->
                          {error, {AstInfo, TreeWalker#treewalker{ context=?ERR(Error, Ctx) }}}
                  end
          end,
          {#ast_info{}, init_treewalker(Context)},
          ParserResults),

    if length(Errors) == 0 ->
            Forms = custom_forms(Dir, Context1#dtl_context.module, Functions, AstInfo),
            compile_forms(Forms, Context1);
       true ->
            Context1
    end.

compile_to_binary(DjangoParseTree, CheckSum, Context) ->
    try body_ast(DjangoParseTree, init_treewalker(Context)) of
        {{BodyAst, BodyInfo}, BodyTreeWalker} ->
            try custom_tags_ast(BodyInfo#ast_info.custom_tags, BodyTreeWalker) of
                {{CustomTagsAst, CustomTagsInfo},
                 #treewalker{
                    context=#dtl_context{
                               errors=#error_info{ list=Errors }
                              } }=CustomTagsTreeWalker}
                  when length(Errors) == 0 ->
                    Forms = forms(
                              {BodyAst, BodyInfo},
                              {CustomTagsAst, CustomTagsInfo},
                              CheckSum,
                              CustomTagsTreeWalker),
                    compile_forms(Forms, CustomTagsTreeWalker#treewalker.context);
                {_, #treewalker{ context=Context1 }} ->
                    Context1
            catch
                throw:Error -> ?ERR(Error, BodyTreeWalker#treewalker.context)
            end
    catch
        throw:Error -> ?ERR(Error, Context)
    end.

compile_forms(Forms, Context) ->
    maybe_debug_template(Forms, Context),
    Options = Context#dtl_context.compiler_options,
    case compile:forms(Forms, Options) of
        Compiled when element(1, Compiled) =:= ok ->
            [ok, Module, Bin|Info] = tuple_to_list(Compiled),
            lists:foldl(
              fun (F, C) -> F(Module, Bin, C) end,
              Context#dtl_context{ bin=Bin },
              [fun maybe_write/3,
               fun maybe_load/3,
               fun (_, _, C) ->
                       case Info of
                           [Ws] when length(Ws) > 0 ->
                               add_warnings(Ws, C);
                           _ -> C
                       end
               end
              ]);
        error ->
            ?ERR(compile_beam, Context);
        {error, Es, Ws} ->
            add_warnings(Ws, add_errors(Es, Context))
    end.

maybe_write(Module, Bin, Context) ->
    case proplists:get_value(out_dir, Context#dtl_context.all_options) of
        false -> Context;
        undefined ->
            ?WARN(no_out_dir, Context);
        OutDir ->
            BeamFile = filename:join([OutDir, [Module, ".beam"]]),
            ?LOG_INFO("Template module: ~w -> ~s\n", [Module, BeamFile], Context),
            case file:write_file(BeamFile, Bin) of
                ok -> Context;
                {error, Reason} ->
                    ?ERR({write_file, Reason}, Context)
            end
    end.

maybe_load(Module, Bin, Context) ->
    case proplists:get_bool(no_load, Context#dtl_context.all_options) of
        true -> Context;
        false -> load_code(Module, Bin, Context)
    end.

load_code(Module, Bin, Context) ->
    code:purge(Module),
    case code:load_binary(Module, atom_to_list(Module) ++ ".erl", Bin) of
        {module, Module} -> Context;
        Error -> ?WARN({load_code, Error}, Context)
    end.

maybe_debug_template(Forms, Context) ->
    %% undocumented option to debug the compiled template
    case proplists:get_bool(debug_info, Context#dtl_context.all_options) of
        false -> nop;
        true ->
            Options = Context#dtl_context.compiler_options,
            ?LOG_DEBUG("Compiler options: ~p~n", [Options], Context),
            try
                Source = erl_prettypr:format(erl_syntax:form_list(Forms)),
                File = lists:concat([proplists:get_value(source, Options), ".erl"]),
                io:format("Saving template source to: ~s.. ~p~n",
                          [File, file:write_file(File, Source)])
            catch
                error:Err ->
                    io:format("Pretty printing failed: ~p~n"
                              "Context: ~n~p~n"
                              "Forms: ~n~p~n",
                              [Err, Context, Forms])
            end
    end.

is_up_to_date(CheckSum, Context) ->
    Module = Context#dtl_context.module,
    {M, F} = Context#dtl_context.reader,
    case catch Module:source() of
        {_, CheckSum} ->
            case catch Module:dependencies() of
                L when is_list(L) ->
                    RecompileList = lists:foldl(
                                      fun ({XFile, XCheckSum}, Acc) ->
                                              case catch M:F(XFile) of
                                                  {ok, Data} ->
                                                      case binary_to_list(erlang:md5(Data)) of
                                                          XCheckSum ->
                                                              Acc;
                                                          _ ->
                                                              [recompile | Acc]
                                                      end;
                                                  _ ->
                                                      [recompile | Acc]
                                              end
                                      end, [], L),
                    case RecompileList of
                        [] -> true;
                        _ -> false
                    end;
                _ ->
                    false
            end;
        _ ->
            false
    end.


%%====================================================================
%% AST functions
%%====================================================================

custom_tags_ast(CustomTags, TreeWalker) ->
    %% avoid adding the render_tag/3 fun if it isn't used,
    %% since we can't add a -compile({nowarn_unused_function, render_tag/3}).
    %% attribute due to a bug in syntax_tools.
    case custom_tags_clauses_ast(CustomTags, TreeWalker) of
        skip ->
            {{erl_syntax:comment(
                ["% render_tag/3 is not used in this template."]),
              #ast_info{}},
             TreeWalker};
        {{CustomTagsClauses, CustomTagsInfo}, TreeWalker1} ->
            {{erl_syntax:function(
                erl_syntax:atom(render_tag),
                CustomTagsClauses),
              CustomTagsInfo},
             TreeWalker1}
    end.

custom_tags_clauses_ast([], _TreeWalker) -> skip;
custom_tags_clauses_ast(CustomTags, TreeWalker) ->
    custom_tags_clauses_ast1(CustomTags, [], [], #ast_info{}, TreeWalker).

custom_tags_clauses_ast1([], _ExcludeTags, ClauseAcc, InfoAcc, TreeWalker) ->
    {{DefaultAst, DefaultInfo}, TreeWalker1} =
        case call_extension(TreeWalker, custom_tag_ast, [TreeWalker]) of
            undefined ->
                {{?Q("(_TagName, _, _) -> []"), InfoAcc}, TreeWalker};
            {{ExtAst, ExtInfo}, ExtTreeWalker} ->
                Clause = ?Q("(TagName, _Variables, RenderOptions) -> _@tag",
                            [{tag, options_match_ast(ExtTreeWalker) ++ [ExtAst]}]),
                {{Clause, merge_info(ExtInfo, InfoAcc)}, ExtTreeWalker}
        end,
    {{lists:reverse([DefaultAst|ClauseAcc]), DefaultInfo}, TreeWalker1};
custom_tags_clauses_ast1([Tag|CustomTags], ExcludeTags, ClauseAcc, InfoAcc, TreeWalker) ->
    case lists:member(Tag, ExcludeTags) of
        true ->
            custom_tags_clauses_ast1(CustomTags, ExcludeTags, ClauseAcc, InfoAcc, TreeWalker);
        false ->
            Context = TreeWalker#treewalker.context,
            CustomTagFile = full_path(Tag, Context#dtl_context.custom_tags_dir),
            case filelib:is_file(CustomTagFile) of
                true ->
                    case parse_file(CustomTagFile, Context) of
                        {ok, DjangoParseTree, CheckSum} ->
                            {{BodyAst, BodyAstInfo}, TreeWalker1} = with_dependency(
                                                                      {CustomTagFile, CheckSum},
                                                                      body_ast(DjangoParseTree, TreeWalker)),
                            MatchAst = options_match_ast(TreeWalker1),
                            Clause = ?Q("(_@Tag@, _Variables, RenderOptions) -> _@MatchAst, _@BodyAst"),
                            custom_tags_clauses_ast1(
                              CustomTags, [Tag|ExcludeTags], [Clause|ClauseAcc],
                              merge_info(BodyAstInfo, InfoAcc), TreeWalker1);
                        {error, Reason} ->
                            empty_ast(?ERR(Reason, TreeWalker))
                    end;
                false ->
                    case call_extension(TreeWalker, custom_tag_ast, [Tag, TreeWalker]) of
                        undefined ->
                            custom_tags_clauses_ast1(
                              CustomTags, [Tag | ExcludeTags],
                              ClauseAcc, InfoAcc, TreeWalker);
                        {{Ast, Info}, TW} ->
                            Clause = ?Q("(_@Tag@, _Variables, RenderOptions) -> _@match, _@Ast",
                                        [{match, options_match_ast(TW)}]),
                            custom_tags_clauses_ast1(
                              CustomTags, [Tag | ExcludeTags], [Clause|ClauseAcc],
                              merge_info(Info, InfoAcc), TW)
                    end
            end
    end.

dependencies_function(Dependencies) ->
    ?Q("dependencies() -> _@Dependencies@.").

translatable_strings_function(TranslatableStrings) ->
    ?Q("translatable_strings() -> _@TranslatableStrings@.").

translated_blocks_function(TranslatedBlocks) ->
    ?Q("translated_blocks() -> _@TranslatedBlocks@.").

variables_function(Variables) ->
    ?Q("variables() -> _@vars.",
       [{vars, merl:term(lists:usort(Variables))}]).

custom_forms(Dir, Module, Functions, AstInfo) ->
    Exported = [erl_syntax:arity_qualifier(erl_syntax:atom(source_dir), erl_syntax:integer(0)),
                erl_syntax:arity_qualifier(erl_syntax:atom(dependencies), erl_syntax:integer(0)),
                erl_syntax:arity_qualifier(erl_syntax:atom(translatable_strings), erl_syntax:integer(0))
                | lists:foldl(
                    fun({FunctionName, _, _}, Acc) ->
                            [erl_syntax:arity_qualifier(erl_syntax:atom(FunctionName), erl_syntax:integer(1)),
                             erl_syntax:arity_qualifier(erl_syntax:atom(FunctionName), erl_syntax:integer(2))
                             |Acc]
                    end, [], Functions)
               ],
    ModuleAst = ?Q("-module('@Module@')."),
    ExportAst = ?Q("-export(['@_Exported'/1])"),

    SourceFunctionAst = ?Q("source_dir() -> _@Dir@."),

    DependenciesFunctionAst = dependencies_function(AstInfo#ast_info.dependencies),
    TranslatableStringsFunctionAst = translatable_strings_function(AstInfo#ast_info.translatable_strings),
    FunctionAsts = lists:foldl(fun({_, Function1, Function2}, Acc) -> [Function1, Function2 | Acc] end, [], Functions),

    [erl_syntax:revert(X)
     || X <- [ModuleAst, ExportAst, SourceFunctionAst, DependenciesFunctionAst, TranslatableStringsFunctionAst
              | FunctionAsts] ++ AstInfo#ast_info.pre_render_asts
    ].

stringify(BodyAst, #dtl_context{ binary_strings=BinaryStrings }) ->
    [?Q("erlydtl_runtime:stringify_final(_@BodyAst, '@BinaryStrings@')")].

forms({BodyAst, BodyInfo}, {CustomTagsFunctionAst, CustomTagsInfo}, CheckSum,
      #treewalker{
         context=#dtl_context{
                    module=Module,
                    parse_trail=[File|_]
                   }=Context
        }=TreeWalker) ->
    MergedInfo = merge_info(BodyInfo, CustomTagsInfo),

    Render0FunctionAst = ?Q("render() -> render([])."),
    Render1FunctionAst = ?Q("render(Variables) -> render(Variables, [])."),

    Render2FunctionAst = ?Q(["render(Variables, RenderOptions) ->",
                             "  try render_internal(Variables, RenderOptions) of",
                             "    Val -> {ok, Val}",
                             "  catch",
                             "    Err -> {error, Err}",
                             "end."
                            ]),

    SourceFunctionAst = ?Q("source() -> {_@File@, _@CheckSum@}."),

    DependenciesFunctionAst = dependencies_function(MergedInfo#ast_info.dependencies),

    TranslatableStringsAst = translatable_strings_function(MergedInfo#ast_info.translatable_strings),

    TranslatedBlocksAst = translated_blocks_function(MergedInfo#ast_info.translated_blocks),

    VariablesAst = variables_function(MergedInfo#ast_info.var_names),

    MatchAst = options_match_ast(TreeWalker),
    BodyAstTmp = MatchAst ++ stringify(BodyAst, Context),
    RenderInternalFunctionAst = ?Q("render_internal(_Variables, RenderOptions) -> _@BodyAstTmp."),

    ModuleAst  = ?Q("-module('@Module@')."),

    ExportAst = erl_syntax:attribute(
                  erl_syntax:atom(export),
                  [erl_syntax:list(
                     [erl_syntax:arity_qualifier(erl_syntax:atom(render), erl_syntax:integer(0)),
                      erl_syntax:arity_qualifier(erl_syntax:atom(render), erl_syntax:integer(1)),
                      erl_syntax:arity_qualifier(erl_syntax:atom(render), erl_syntax:integer(2)),
                      erl_syntax:arity_qualifier(erl_syntax:atom(source), erl_syntax:integer(0)),
                      erl_syntax:arity_qualifier(erl_syntax:atom(dependencies), erl_syntax:integer(0)),
                      erl_syntax:arity_qualifier(erl_syntax:atom(translatable_strings), erl_syntax:integer(0)),
                      erl_syntax:arity_qualifier(erl_syntax:atom(translated_blocks), erl_syntax:integer(0)),
                      erl_syntax:arity_qualifier(erl_syntax:atom(variables), erl_syntax:integer(0))
                     ])
                  ]),

    erl_syntax:revert_forms(
      erl_syntax:form_list(
        [ModuleAst, ExportAst, Render0FunctionAst, Render1FunctionAst, Render2FunctionAst,
         SourceFunctionAst, DependenciesFunctionAst, TranslatableStringsAst,
         TranslatedBlocksAst, VariablesAst, RenderInternalFunctionAst,
         CustomTagsFunctionAst
         |BodyInfo#ast_info.pre_render_asts
        ])).

options_match_ast(#treewalker{ context=Context }=TreeWalker) ->
    options_match_ast(Context, TreeWalker);
options_match_ast(Context) ->
    options_match_ast(Context, undefined).

options_match_ast(Context, TreeWalker) ->
    [
     ?Q("_TranslationFun = proplists:get_value(translation_fun, RenderOptions, none)"),
     ?Q("_CurrentLocale = proplists:get_value(locale, RenderOptions, none)"),
     ?Q("_RecordInfo = _@info", [{info, merl:term(Context#dtl_context.record_info)}])
     | case call_extension(Context, setup_render_ast, [Context, TreeWalker]) of
           undefined -> [];
           Ast when is_list(Ast) -> Ast
       end].

%% child templates should only consist of blocks at the top level
body_ast([{'extends', {string_literal, _Pos, String}} | ThisParseTree], #treewalker{ context=Context }=TreeWalker) ->
    File = full_path(unescape_string_literal(String), Context#dtl_context.doc_root),
    case lists:member(File, Context#dtl_context.parse_trail) of
        true ->
            empty_ast(?ERR(circular_include, TreeWalker));
        _ ->
            case parse_file(File, Context) of
                {ok, ParentParseTree, CheckSum} ->
                    BlockDict = lists:foldl(
                                  fun ({block, {identifier, _, Name}, Contents}, Dict) ->
                                          dict:store(Name, Contents, Dict);
                                      (_, Dict) -> Dict
                                  end,
                                  dict:new(),
                                  ThisParseTree),
                    {Info, TreeWalker1} = with_dependency(
                                            {File, CheckSum},
                                            body_ast(
                                              ParentParseTree,
                                              TreeWalker#treewalker{
                                                context=Context#dtl_context{
                                                          block_dict = dict:merge(
                                                                         fun(_Key, _ParentVal, ChildVal) -> ChildVal end,
                                                                         BlockDict, Context#dtl_context.block_dict),
                                                          parse_trail = [File | Context#dtl_context.parse_trail]
                                                         }
                                               })),
                    {Info, reset_parse_trail(Context#dtl_context.parse_trail, TreeWalker1)};
                {error, Reason} ->
                    empty_ast(?ERR(Reason, TreeWalker))
            end
    end;


body_ast(DjangoParseTree, TreeWalker) ->
    body_ast(DjangoParseTree, empty_scope(), TreeWalker).

body_ast(DjangoParseTree, BodyScope, TreeWalker) ->
    {ScopeId, TreeWalkerScope} = begin_scope(BodyScope, TreeWalker),
    {AstInfoList, TreeWalker1} =
        lists:mapfoldl(
          fun ({'autoescape', {identifier, _, OnOrOff}, Contents}, #treewalker{ context=Context }=TW) ->
                  body_ast(Contents, TW#treewalker{ context=Context#dtl_context{auto_escape = OnOrOff} });
              ({'block', {identifier, Pos, Name}, Contents}, #treewalker{ context=Context }=TW) ->
                  {Block, BlockScope} =
                      case dict:find(Name, Context#dtl_context.block_dict) of
                          {ok, ChildBlock} ->
                              {{ContentsAst, _ContentsInfo}, _ContentsTW} = body_ast(Contents, TW),
                              {ChildBlock,
                               create_scope(
                                 [{block, ?Q("[{super, _@ContentsAst}]")}],
                                 Pos, TW)
                              };
                          _ ->
                              {Contents, empty_scope()}
                      end,
                  body_ast(Block, BlockScope, TW);
              ({'blocktrans', Args, Contents}, TW) ->
                  blocktrans_ast(Args, Contents, TW);
              ({'call', {identifier, _, Name}}, TW) ->
                  call_ast(Name, TW);
              ({'call', {identifier, _, Name}, With}, TW) ->
                  call_with_ast(Name, With, TW);
              ({'comment', _Contents}, TW) ->
                  empty_ast(TW);
              ({'cycle', Names}, TW) ->
                  cycle_ast(Names, TW);
              ({'cycle_compat', Names}, TW) ->
                  cycle_compat_ast(Names, TW);
              ({'date', 'now', {string_literal, _Pos, FormatString}}, TW) ->
                  now_ast(FormatString, TW);
              ({'filter', FilterList, Contents}, TW) ->
                  filter_tag_ast(FilterList, Contents, TW);
              ({'firstof', Vars}, TW) ->
                  firstof_ast(Vars, TW);
              ({'for', {'in', IteratorList, Variable, Reversed}, Contents}, TW) ->
                  {EmptyAstInfo, TW1} = empty_ast(TW),
                  for_loop_ast(IteratorList, Variable, Reversed, Contents, EmptyAstInfo, TW1);
              ({'for', {'in', IteratorList, Variable, Reversed}, Contents, EmptyPartContents}, TW) ->
                  {EmptyAstInfo, TW1} = body_ast(EmptyPartContents, TW),
                  for_loop_ast(IteratorList, Variable, Reversed, Contents, EmptyAstInfo, TW1);
              ({'if', Expression, Contents, Elif}, TW) ->
                  {IfAstInfo, TW1} = body_ast(Contents, TW),
                  {ElifAstInfo, TW2} = body_ast(Elif, TW1),
                  ifelse_ast(Expression, IfAstInfo, ElifAstInfo, TW2);
              ({'if', Expression, Contents}, TW) ->
                  {IfAstInfo, TW1} = body_ast(Contents, TW),
                  {ElseAstInfo, TW2} = empty_ast(TW1),
                  ifelse_ast(Expression, IfAstInfo, ElseAstInfo, TW2);
              ({'ifchanged', '$undefined', Contents}, TW) ->
                  {IfAstInfo, TW1} = body_ast(Contents, TW),
                  {ElseAstInfo, TW2} = empty_ast(TW1),
                  ifchanged_contents_ast(Contents, IfAstInfo, ElseAstInfo, TW2);
              ({'ifchanged', Values, Contents}, TW) ->
                  {IfAstInfo, TW1} = body_ast(Contents, TW),
                  {ElseAstInfo, TW2} = empty_ast(TW1),
                  ifchanged_values_ast(Values, IfAstInfo, ElseAstInfo, TW2);
              ({'ifchangedelse', '$undefined', IfContents, ElseContents}, TW) ->
                  {IfAstInfo, TW1} = body_ast(IfContents, TW),
                  {ElseAstInfo, TW2} = body_ast(ElseContents, TW1),
                  ifchanged_contents_ast(IfContents, IfAstInfo, ElseAstInfo, TW2);
              ({'ifchangedelse', Values, IfContents, ElseContents}, TW) ->
                  {IfAstInfo, TW1} = body_ast(IfContents, TW),
                  {ElseAstInfo, TW2} = body_ast(ElseContents, TW1),
                  ifchanged_values_ast(Values, IfAstInfo, ElseAstInfo, TW2);
              ({'ifelse', Expression, IfContents, ElseContents}, TW) ->
                  {IfAstInfo, TW1} = body_ast(IfContents, TW),
                  {ElseAstInfo, TW2} = body_ast(ElseContents, TW1),
                  ifelse_ast(Expression, IfAstInfo, ElseAstInfo, TW2);
              ({'ifequal', [Arg1, Arg2], Contents}, TW) ->
                  {IfAstInfo, TW1} = body_ast(Contents, TW),
                  {ElseAstInfo, TW2} = empty_ast(TW1),
                  ifelse_ast({'expr', "eq", Arg1, Arg2}, IfAstInfo, ElseAstInfo, TW2);
              ({'ifequalelse', [Arg1, Arg2], IfContents, ElseContents}, TW) ->
                  {IfAstInfo, TW1} = body_ast(IfContents, TW),
                  {ElseAstInfo, TW2} = body_ast(ElseContents,TW1),
                  ifelse_ast({'expr', "eq", Arg1, Arg2}, IfAstInfo, ElseAstInfo, TW2);
              ({'ifnotequal', [Arg1, Arg2], Contents}, TW) ->
                  {IfAstInfo, TW1} = body_ast(Contents, TW),
                  {ElseAstInfo, TW2} = empty_ast(TW1),
                  ifelse_ast({'expr', "ne", Arg1, Arg2}, IfAstInfo, ElseAstInfo, TW2);
              ({'ifnotequalelse', [Arg1, Arg2], IfContents, ElseContents}, TW) ->
                  {IfAstInfo, TW1} = body_ast(IfContents, TW),
                  {ElseAstInfo, TW2} = body_ast(ElseContents, TW1),
                  ifelse_ast({'expr', "ne", Arg1, Arg2}, IfAstInfo, ElseAstInfo, TW2);
              ({'include', {string_literal, _, File}, Args}, #treewalker{ context=Context }=TW) ->
                  include_ast(unescape_string_literal(File), Args, Context#dtl_context.local_scopes, TW);
              ({'include_only', {string_literal, _, File}, Args}, TW) ->
                  {Info, IncTW} = include_ast(unescape_string_literal(File), Args, [], TW),
                  {Info, restore_scope(TW, IncTW)};
              ({'load_libs', Libs}, TW) ->
                  load_libs_ast(Libs, TW);
              ({'load_from_lib', What, Lib}, TW) ->
                  load_from_lib_ast(What, Lib, TW);
              ({'regroup', {ListVariable, Grouper, {identifier, _, NewVariable}}}, TW) ->
                  regroup_ast(ListVariable, Grouper, NewVariable, TW);
              ('end_regroup', TW) ->
                  {{end_scope, #ast_info{}}, TW};
              ({'spaceless', Contents}, TW) ->
                  spaceless_ast(Contents, TW);
              ({'ssi', Arg}, TW) ->
                  ssi_ast(Arg, TW);
              ({'ssi_parsed', {string_literal, _, FileName}}, #treewalker{ context=Context }=TW) ->
                  include_ast(unescape_string_literal(FileName), [], Context#dtl_context.local_scopes, TW);
              ({'string', _Pos, String}, TW) ->
                  string_ast(String, TW);
              ({'tag', Name, Args}, TW) ->
                  tag_ast(Name, Args, TW);
              ({'templatetag', {_, _, TagName}}, TW) ->
                  templatetag_ast(TagName, TW);
              ({'trans', Value}, TW) ->
                  translated_ast(Value, TW);
              ({'widthratio', Numerator, Denominator, Scale}, TW) ->
                  widthratio_ast(Numerator, Denominator, Scale, TW);
              ({'with', Args, Contents}, TW) ->
                  with_ast(Args, Contents, TW);
              ({'scope_as', {identifier, _, Name}, Contents}, TW) ->
                  scope_as(Name, Contents, TW);
              ({'extension', Tag}, TW) ->
                  extension_ast(Tag, TW);
              ({'extends', _}, TW) ->
                  empty_ast(?ERR(unexpected_extends_tag, TW));
              (ValueToken, TW) ->
                  {{ValueAst,ValueInfo},ValueTW} = value_ast(ValueToken, true, true, TW),
                  {{format(ValueAst, ValueTW),ValueInfo},ValueTW}
          end,
          TreeWalkerScope,
          DjangoParseTree),

    Vars = TreeWalker1#treewalker.context#dtl_context.vars,
    {AstList, {Info, TreeWalker2}} =
        lists:mapfoldl(
          fun ({Ast, Info}, {InfoAcc, TreeWalkerAcc}) ->
                  PresetVars = lists:foldl(
                                 fun (X, Acc) ->
                                         case proplists:lookup(X, Vars) of
                                             none -> Acc;
                                             Val -> [Val|Acc]
                                         end
                                 end,
                                 [],
                                 Info#ast_info.var_names),
                  if length(PresetVars) == 0 ->
                          {Ast, {merge_info(Info, InfoAcc), TreeWalkerAcc}};
                     true ->
                          Counter = TreeWalkerAcc#treewalker.counter,
                          Name = list_to_atom(lists:concat([pre_render, Counter])),
                          Ast1 = ?Q("'@Name@'(_@PresetVars@, RenderOptions)"),
                          PreRenderAst = ?Q("'@Name@'(_Variables, RenderOptions) -> _@match, _@Ast.",
                                            [{match, options_match_ast(TreeWalkerAcc)}]),
                          PreRenderAsts = Info#ast_info.pre_render_asts,
                          Info1 = Info#ast_info{pre_render_asts = [PreRenderAst | PreRenderAsts]},
                          {Ast1, {merge_info(Info1, InfoAcc), TreeWalkerAcc#treewalker{counter = Counter + 1}}}
                  end
          end,
          {#ast_info{}, TreeWalker1},
          AstInfoList),

    {Ast, TreeWalker3} = end_scope(
                           fun ([ScopeVars|ScopeBody]) -> [?Q("begin _@ScopeVars, [_@ScopeBody] end")] end,
                           ScopeId, AstList, TreeWalker2),
    {{erl_syntax:list(Ast), Info}, TreeWalker3}.


value_ast(ValueToken, AsString, EmptyIfUndefined, TreeWalker) ->
    case ValueToken of
        {'expr', Operator, Value} ->
            {{ValueAst,InfoValue}, TreeWalker1} = value_ast(Value, false, EmptyIfUndefined, TreeWalker),
            Op = list_to_atom(Operator),
            Ast = ?Q("erlydtl_runtime:_@Op@(_@ValueAst)"),
            {{Ast, InfoValue}, TreeWalker1};
        {'expr', Operator, Value1, Value2} ->
            {{Value1Ast,InfoValue1}, TreeWalker1} = value_ast(Value1, false, EmptyIfUndefined, TreeWalker),
            {{Value2Ast,InfoValue2}, TreeWalker2} = value_ast(Value2, false, EmptyIfUndefined, TreeWalker1),
            Op = list_to_atom(Operator),
            Ast = ?Q("erlydtl_runtime:_@Op@(_@Value1Ast, _@Value2Ast)"),
            {{Ast, merge_info(InfoValue1,InfoValue2)}, TreeWalker2};
        {'string_literal', _Pos, String} ->
            string_ast(unescape_string_literal(String), TreeWalker);
        {'number_literal', _Pos, Number} ->
            case AsString of
                true  -> string_ast(Number, TreeWalker);
                false -> {{erl_syntax:integer(Number), #ast_info{}}, TreeWalker}
            end;
        {'apply_filter', Variable, Filter} ->
            filter_ast(Variable, Filter, TreeWalker);
        {'attribute', _} = Variable ->
            resolve_variable_ast(Variable, EmptyIfUndefined, TreeWalker);
        {'variable', _} = Variable ->
            resolve_variable_ast(Variable, EmptyIfUndefined, TreeWalker);
        {extension, Tag} ->
            extension_ast(Tag, TreeWalker)
    end.

extension_ast(Tag, TreeWalker) ->
    case call_extension(TreeWalker, compile_ast, [Tag, TreeWalker]) of
        undefined ->
            empty_ast(?WARN({unknown_extension, Tag}, TreeWalker));
        Result ->
            Result
    end.


with_dependencies([], Args) ->
    Args;
with_dependencies([Dependency | Rest], Args) ->
    with_dependencies(Rest, with_dependency(Dependency, Args)).

with_dependency(FilePath, {{Ast, Info}, TreeWalker}) ->
    {{Ast, Info#ast_info{dependencies = [FilePath | Info#ast_info.dependencies]}}, TreeWalker}.


empty_ast(TreeWalker) ->
    {{erl_syntax:list([]), #ast_info{}}, TreeWalker}.

blocktrans_ast(ArgList, Contents, TreeWalker) ->
    %% add new scope using 'with' values
    {NewScope, {ArgInfo, TreeWalker1}} =
        lists:mapfoldl(
          fun ({{identifier, _, LocalVarName}, Value}, {AstInfoAcc, TreeWalkerAcc}) ->
                  {{Ast, Info}, TW} = value_ast(Value, false, false, TreeWalkerAcc),
                  {{LocalVarName, Ast}, {merge_info(AstInfoAcc, Info), TW}}
          end,
          {#ast_info{}, TreeWalker},
          ArgList),

    TreeWalker2 = push_scope(NewScope, TreeWalker1),

    %% key for translation lookup
    SourceText = lists:flatten(erlydtl_unparser:unparse(Contents)),
    {{DefaultAst, AstInfo}, TreeWalker3} = body_ast(Contents, TreeWalker2),
    MergedInfo = merge_info(AstInfo, ArgInfo),

    Context = TreeWalker3#treewalker.context,
    case Context#dtl_context.trans_fun of
        none ->
            %% translate in runtime
            {FinalAst, FinalTW} = blocktrans_runtime_ast(
                                    {DefaultAst, MergedInfo},
                                    SourceText, Contents, TreeWalker3),
            {FinalAst, restore_scope(TreeWalker1, FinalTW)};
        BlockTransFun when is_function(BlockTransFun) ->
            %% translate in compile-time
            {FinalAstInfo, FinalTreeWalker, Clauses} = 
                lists:foldr(
                  fun (Locale, {AstInfoAcc, TreeWalkerAcc, ClauseAcc}) ->
                          case BlockTransFun(SourceText, Locale) of
                              default ->
                                  {AstInfoAcc, TreeWalkerAcc, ClauseAcc};
                              Body ->
                                  {ok, DjangoParseTree} = do_parse_template(Body, TreeWalkerAcc#treewalker.context),
                                  {{BodyAst, BodyInfo}, BodyTreeWalker} = body_ast(DjangoParseTree, TreeWalkerAcc),
                                  {merge_info(BodyInfo, AstInfoAcc), BodyTreeWalker,
                                   [?Q("_@Locale@ -> _@BodyAst")|ClauseAcc]}
                          end
                  end,
                  {MergedInfo, TreeWalker2, []},
                  Context#dtl_context.trans_locales),
            FinalAst = ?Q("case _CurrentLocale of _@_Clauses -> _; _ -> _@DefaultAst end"),
            {{FinalAst, FinalAstInfo#ast_info{ translated_blocks = [SourceText] }},
             restore_scope(TreeWalker1, FinalTreeWalker)}
    end.

blocktrans_runtime_ast({DefaultAst, Info}, SourceText, Contents, TreeWalker) ->
    %% Contents is flat - only strings and '{{var}}' allowed.
    %% build sorted list (orddict) of pre-resolved variables to pass to runtime translation function
    USortedVariables = lists:usort(fun({variable, {identifier, _, A}},
                                       {variable, {identifier, _, B}}) ->
                                           A =< B
                                   end, [Var || {variable, _}=Var <- Contents]),
    VarBuilder = fun({variable, {identifier, _, Name}}=Var, TW) ->
                         {{VarAst, _VarInfo}, VarTW}  = resolve_variable_ast(Var, false, TW),
                         {?Q("{_@name, _@VarAst}", [{name, merl:term(atom_to_list(Name))}]), VarTW}
                 end,
    {VarAsts, TreeWalker1} = lists:mapfoldl(VarBuilder, TreeWalker, USortedVariables),
    VarListAst = erl_syntax:list(VarAsts),
    BlockTransAst = ?Q(["if _TranslationFun =:= none -> _@DefaultAst;",
                        "  true -> erlydtl_runtime:translate_block(",
                        "    _@SourceText@, _TranslationFun, _@VarListAst)",
                        "end"]),
    {{BlockTransAst, Info}, TreeWalker1}.

translated_ast({string_literal, _, String}, TreeWalker) ->
    UnescapedStr = unescape_string_literal(String),
    case call_extension(TreeWalker, translate_ast, [UnescapedStr, TreeWalker]) of
        undefined ->
            AstInfo = #ast_info{translatable_strings = [UnescapedStr]},
            case TreeWalker#treewalker.context#dtl_context.trans_fun of
                none -> runtime_trans_ast({{erl_syntax:string(UnescapedStr), AstInfo}, TreeWalker});
                _ -> compiletime_trans_ast(UnescapedStr, AstInfo, TreeWalker)
            end;
        Translated ->
            Translated
    end;
translated_ast(ValueToken, TreeWalker) ->
    runtime_trans_ast(value_ast(ValueToken, true, false, TreeWalker)).

runtime_trans_ast({{ValueAst, AstInfo}, TreeWalker}) ->
    {{?Q("erlydtl_runtime:translate(_@ValueAst, _TranslationFun)"),
      AstInfo}, TreeWalker}.

compiletime_trans_ast(String, AstInfo,
                      #treewalker{
                         context=#dtl_context{
                                    trans_fun=TFun,
                                    trans_locales=TLocales
                                   }=Context
                        }=TreeWalker) ->
    ClAst = lists:foldl(
              fun(Locale, ClausesAcc) ->
                      [?Q("_@Locale@ -> _@translated",
                          [{translated, case TFun(String, Locale) of
                                            default -> string_ast(String, Context);
                                            Translated -> string_ast(Translated, Context)
                                        end}])
                       |ClausesAcc]
              end,
              [], TLocales),
    CaseAst = ?Q(["case _CurrentLocale of",
                  "  _@_ClAst -> _;",
                  " _ -> _@string",
                  "end"],
                 [{string, string_ast(String, Context)}]),
    {{CaseAst, AstInfo}, TreeWalker}.

%% Completely unnecessary in ErlyDTL (use {{ "{%" }} etc), but implemented for compatibility.
templatetag_ast("openblock", TreeWalker) ->
    string_ast("{%", TreeWalker);
templatetag_ast("closeblock", TreeWalker) ->
    string_ast("%}", TreeWalker);
templatetag_ast("openvariable", TreeWalker) ->
    string_ast("{{", TreeWalker);
templatetag_ast("closevariable", TreeWalker) ->
    string_ast("}}", TreeWalker);
templatetag_ast("openbrace", TreeWalker) ->
    string_ast("{", TreeWalker);
templatetag_ast("closebrace", TreeWalker) ->
    string_ast("}", TreeWalker);
templatetag_ast("opencomment", TreeWalker) ->
    string_ast("{#", TreeWalker);
templatetag_ast("closecomment", TreeWalker) ->
    string_ast("#}", TreeWalker).


widthratio_ast(Numerator, Denominator, Scale, TreeWalker) ->
    {{NumAst, NumInfo}, TreeWalker1} = value_ast(Numerator, false, true, TreeWalker),
    {{DenAst, DenInfo}, TreeWalker2} = value_ast(Denominator, false, true, TreeWalker1),
    {{ScaleAst, ScaleInfo}, TreeWalker3} = value_ast(Scale, false, true, TreeWalker2),
    {{format_number_ast(?Q("erlydtl_runtime:widthratio(_@NumAst, _@DenAst, _@ScaleAst)")),
      merge_info(ScaleInfo, merge_info(NumInfo, DenInfo))},
     TreeWalker3}.


string_ast(Arg, #treewalker{ context=Context }=TreeWalker) ->
    {{string_ast(Arg, Context), #ast_info{}}, TreeWalker};
string_ast(Arg, Context) ->
    merl:term(erlydtl_compiler_utils:to_string(Arg, Context)).


include_ast(File, ArgList, Scopes, #treewalker{ context=Context }=TreeWalker) ->
    FilePath = full_path(File, Context#dtl_context.doc_root),
    case parse_file(FilePath, Context) of
        {ok, InclusionParseTree, CheckSum} ->
            {NewScope, {ArgInfo, TreeWalker1}}
                = lists:mapfoldl(
                    fun ({{identifier, _, LocalVarName}, Value}, {AstInfoAcc, TreeWalkerAcc}) ->
                            {{Ast, Info}, TW} = value_ast(Value, false, false, TreeWalkerAcc),
                            {{LocalVarName, Ast}, {merge_info(AstInfoAcc, Info), TW}}
                    end, {#ast_info{}, TreeWalker}, ArgList),

            C = TreeWalker1#treewalker.context,
            {{BodyAst, BodyInfo}, TreeWalker2} = with_dependency(
                                                   {FilePath, CheckSum},
                                                   body_ast(
                                                     InclusionParseTree,
                                                     TreeWalker1#treewalker{
                                                       context=C#dtl_context{
                                                                 parse_trail = [FilePath | C#dtl_context.parse_trail],
                                                                 local_scopes = [NewScope|Scopes]
                                                                }
                                                      })),

            {{BodyAst, merge_info(BodyInfo, ArgInfo)},
             reset_parse_trail(C#dtl_context.parse_trail, TreeWalker2)};
        {error, Reason} ->
            empty_ast(?ERR(Reason, TreeWalker))
    end.

%% include at run-time
ssi_ast(FileName, #treewalker{
                     context=#dtl_context{
                                reader = {Mod, Fun},
                                doc_root = Dir
                               }
                    }=TreeWalker) ->
    {{FileAst, Info}, TreeWalker1} = value_ast(FileName, true, true, TreeWalker),
    {{?Q("erlydtl_runtime:read_file(_@Mod@, _@Fun@, _@Dir@, _@FileAst)"), Info}, TreeWalker1}.

filter_tag_ast(FilterList, Contents, #treewalker{ context=Context }=TreeWalker) ->
    {{InnerAst, Info}, #treewalker{ context=Context1 }=TreeWalker1} = body_ast(
                                        Contents,
                                        TreeWalker#treewalker{
                                          context=Context#dtl_context{ auto_escape = did }
                                         }),
    {{FilteredAst, FilteredInfo}, TreeWalker2} =
        lists:foldl(
          fun ({{identifier, _, Name}, []}, {{AstAcc, InfoAcc}, TreeWalkerAcc})
                when Name =:= 'escape'; Name =:= 'safe'; Name =:= 'safeseq' ->
                  {{AstAcc, InfoAcc}, TreeWalkerAcc#treewalker{ safe = true }};
              (Filter, {{AstAcc, InfoAcc}, TreeWalkerAcc}) ->
                  {{Ast, AstInfo}, TW} = filter_ast1(Filter, AstAcc, TreeWalkerAcc),
                  {{Ast, merge_info(InfoAcc, AstInfo)}, TW}
          end,
          {{?Q("erlang:iolist_to_binary(_@InnerAst)"), Info},
           TreeWalker1#treewalker{
             context=Context1#dtl_context{
                       auto_escape = Context#dtl_context.auto_escape
                      }}},
          FilterList),

    EscapedAst = case search_for_escape_filter(
                        lists:reverse(FilterList),
                        TreeWalker2#treewalker.context) of
                     on -> ?Q("erlydtl_filters:force_escape(_@FilteredAst)");
                     _ -> FilteredAst
                 end,
    {{EscapedAst, FilteredInfo}, TreeWalker2}.

search_for_escape_filter(FilterList, #dtl_context{auto_escape = on}) ->
    search_for_safe_filter(FilterList);
search_for_escape_filter(_, #dtl_context{auto_escape = did}) -> off;
search_for_escape_filter([{{identifier, _, 'escape'}, []}|Rest], _Context) ->
    search_for_safe_filter(Rest);
search_for_escape_filter([_|Rest], Context) ->
    search_for_escape_filter(Rest, Context);
search_for_escape_filter([], _Context) -> off.

search_for_safe_filter([{{identifier, _, Name}, []}|_])
  when Name =:= 'safe'; Name =:= 'safeseq' -> off;
search_for_safe_filter([_|Rest]) -> search_for_safe_filter(Rest);
search_for_safe_filter([]) -> on.

filter_ast(Variable, Filter, #treewalker{ context=Context }=TreeWalker) ->
    %% the escape filter is special; it is always applied last, so we have to go digging for it

    %% AutoEscape = 'did' means we (will have) decided whether to escape the current variable,
    %% so don't do any more escaping

    {{UnescapedAst, Info}, #treewalker{
                              context=Context1
                             }=TreeWalker1} = filter_ast_noescape(
                                                Variable, Filter,
                                                TreeWalker#treewalker{
                                                  context=Context#dtl_context{
                                                            auto_escape = did
                                                           } }),

    EscapedAst = case search_for_escape_filter(Variable, Filter, Context) of
                     on -> ?Q("erlydtl_filters:force_escape(_@UnescapedAst)");
                     _ -> UnescapedAst
                 end,
    {{EscapedAst, Info}, TreeWalker1#treewalker{
                           context=Context1#dtl_context{
                                     auto_escape = Context#dtl_context.auto_escape
                                    }}}.

filter_ast_noescape(Variable, {{identifier, _, Name}, []}, TreeWalker)
  when Name =:= 'escape'; Name =:= 'safe'; Name =:= 'safeseq' ->
    value_ast(Variable, true, false, TreeWalker#treewalker{safe = true});
filter_ast_noescape(Variable, Filter, TreeWalker) ->
    {{ValueAst, Info1}, TreeWalker2} = value_ast(Variable, true, false, TreeWalker),
    {{VarValue, Info2}, TreeWalker3} = filter_ast1(Filter, ValueAst, TreeWalker2),
    {{VarValue, merge_info(Info1, Info2)}, TreeWalker3}.

filter_ast1({{identifier, Pos, Name}, Args}, ValueAst, TreeWalker) ->
    {{ArgsAst, ArgsInfo}, TreeWalker1} =
        lists:foldr(
          fun (Arg, {{AccAst, AccInfo}, AccTreeWalker}) ->
                  {{ArgAst, ArgInfo}, ArgTreeWalker} = value_ast(Arg, false, false, AccTreeWalker),
                  {{[ArgAst|AccAst], merge_info(ArgInfo, AccInfo)}, ArgTreeWalker}
          end,
          {{[], #ast_info{}}, TreeWalker},
          Args),
    case filter_ast2(Name, [ValueAst|ArgsAst], TreeWalker1#treewalker.context) of
        {ok, FilterAst} ->
            {{FilterAst, ArgsInfo}, TreeWalker1};
        Error ->
            empty_ast(?WARN({Pos, Error}, TreeWalker1))
    end.

filter_ast2(Name, Args, #dtl_context{ filters = Filters }) ->
    case proplists:get_value(Name, Filters) of
        {Mod, Fun}=Filter ->
            case erlang:function_exported(Mod, Fun, length(Args)) of
                true -> {ok, ?Q("'@Mod@':'@Fun@'(_@Args)")};
                false ->
                    {filter_args, Name, Filter, length(Args)}
            end;
        undefined ->
            {unknown_filter, Name, length(Args)}
    end.

search_for_escape_filter(Variable, Filter, #dtl_context{auto_escape = on}) ->
    search_for_safe_filter(Variable, Filter);
search_for_escape_filter(_, _, #dtl_context{auto_escape = did}) ->
    off;
search_for_escape_filter(Variable, {{identifier, _, 'escape'}, []} = Filter, _Context) ->
    search_for_safe_filter(Variable, Filter);
search_for_escape_filter({apply_filter, Variable, Filter}, _, Context) ->
    search_for_escape_filter(Variable, Filter, Context);
search_for_escape_filter(_Variable, _Filter, _Context) ->
    off.

search_for_safe_filter(_, {{identifier, _, 'safe'}, []}) ->
    off;
search_for_safe_filter(_, {{identifier, _, 'safeseq'}, []}) ->
    off;
search_for_safe_filter({apply_filter, Variable, Filter}, _) ->
    search_for_safe_filter(Variable, Filter);
search_for_safe_filter(_Variable, _Filter) ->
    on.

finder_function(true) -> {erlydtl_runtime, fetch_value};
finder_function(false) -> {erlydtl_runtime, find_value}.

finder_function(EmptyIfUndefined, TreeWalker) ->
    case call_extension(TreeWalker, finder_function, [EmptyIfUndefined]) of
        undefined -> finder_function(EmptyIfUndefined);
        Result -> Result
    end.

resolve_variable_ast({extension, Tag}, _, TreeWalker) ->
    extension_ast(Tag, TreeWalker);
resolve_variable_ast(VarTuple, EmptyIfUndefined, TreeWalker)
  when is_boolean(EmptyIfUndefined) ->
    resolve_variable_ast(VarTuple, finder_function(EmptyIfUndefined, TreeWalker), TreeWalker);
resolve_variable_ast(VarTuple, FinderFunction, TreeWalker) ->
    resolve_variable_ast1(VarTuple, FinderFunction, TreeWalker).

resolve_variable_ast1({attribute, {{_, Pos, Attr}, Variable}}, {Runtime, Finder}=FinderFunction, TreeWalker) ->
    {{VarAst, VarInfo}, TreeWalker1} = resolve_variable_ast(Variable, FinderFunction, TreeWalker),
    FileName = get_current_file(TreeWalker1),
    {{?Q(["'@Runtime@':'@Finder@'(",
          "  _@Attr@, _@VarAst,",
          "  [{filename, _@FileName@},",
          "   {pos, _@Pos@},",
          "   {record_info, _RecordInfo},",
          "   {render_options, RenderOptions}])"]),
      VarInfo},
     TreeWalker1};

resolve_variable_ast1({variable, {identifier, Pos, VarName}}, {Runtime, Finder}, TreeWalker) ->
    Ast = case resolve_variable(VarName, TreeWalker) of
              undefined ->
                  FileName = get_current_file(TreeWalker),
                  {?Q(["'@Runtime@':'@Finder@'(",
                       "  _@VarName@, _Variables,",
                       "  [{filename, _@FileName@},",
                       "   {pos, _@Pos@},",
                       "   {record_info, _RecordInfo},",
                       "   {render_options, RenderOptions}])"]),
                   #ast_info{ var_names=[VarName] }};
              Val ->
                  {Val, #ast_info{}}
          end,
    {Ast, TreeWalker}.

format(Ast, TreeWalker) ->
    auto_escape(format_number_ast(Ast), TreeWalker).

format_number_ast(Ast) ->
    ?Q("erlydtl_filters:format_number(_@Ast)").


auto_escape(Value, #treewalker{ safe = true }) -> Value;
auto_escape(Value, #treewalker{ context=#dtl_context{ auto_escape = on }}) ->
    ?Q("erlydtl_filters:force_escape(_@Value)");
auto_escape(Value, _) -> Value.

firstof_ast(Vars, TreeWalker) ->
    body_ast(
      [lists:foldr(
         fun ({L, _, _}=Var, [])
               when L=:=string_literal;L=:=number_literal ->
                 Var;
             ({L, _, _}, _)
               when L=:=string_literal;L=:=number_literal ->
                 erlang:error(errbadliteral);
             (Var, []) ->
                 {'ifelse', Var, [Var], []};
             (Var, Acc) ->
                 {'ifelse', Var, [Var], [Acc]}
         end,
         [], Vars)
      ],
      TreeWalker).

ifelse_ast(Expression, {IfContentsAst, IfContentsInfo}, {ElseContentsAst, ElseContentsInfo}, TreeWalker) ->
    Info = merge_info(IfContentsInfo, ElseContentsInfo),
    {{Ast, ExpressionInfo}, TreeWalker1} = value_ast(Expression, false, false, TreeWalker),
    {{?Q(["case erlydtl_runtime:is_true(_@Ast) of",
          "  true -> _@IfContentsAst;",
          "  _ -> _@ElseContentsAst",
          "end"]),
      merge_info(ExpressionInfo, Info)},
     TreeWalker1}.

with_ast(ArgList, Contents, TreeWalker) ->
    {ArgAstList, {ArgInfo, TreeWalker1}} =
        lists:mapfoldl(
          fun ({{identifier, _, _LocalVarName}, Value}, {AstInfoAcc, TreeWalkerAcc}) ->
                  {{Ast, Info}, TW} = value_ast(Value, false, false, TreeWalkerAcc),
                  {Ast, {merge_info(AstInfoAcc, Info), TW}}
          end,
          {#ast_info{}, TreeWalker},
          ArgList),

    NewScope = lists:map(
                 fun ({{identifier, _, LocalVarName}, _Value}) ->
                         {LocalVarName, merl:var(lists:concat(["Var_", LocalVarName]))}
                 end,
                 ArgList),

    {{InnerAst, InnerInfo}, TreeWalker2} =
        body_ast(
          Contents,
          push_scope(NewScope, TreeWalker1)),

    {{?Q("fun (_@args) -> _@InnerAst end (_@ArgAstList)",
         [{args, element(2, lists:unzip(NewScope))}]),
      merge_info(ArgInfo, InnerInfo)},
     restore_scope(TreeWalker1, TreeWalker2)}.

scope_as(VarName, Contents, TreeWalker) ->
    {{ContentsAst, ContentsInfo}, TreeWalker1} = body_ast(Contents, TreeWalker),
    VarAst = merl:var(lists:concat(["Var_", VarName])),
    {Id, TreeWalker2} = begin_scope(
                          {[{VarName, VarAst}],
                           [?Q("_@VarAst = _@ContentsAst")]},
                          TreeWalker1),
    {{Id, ContentsInfo}, TreeWalker2}.

regroup_ast(ListVariable, GrouperVariable, LocalVarName, TreeWalker) ->
    {{ListAst, ListInfo}, TreeWalker1} = value_ast(ListVariable, false, true, TreeWalker),
    LocalVarAst = merl:var(lists:concat(["Var_", LocalVarName])),

    {Id, TreeWalker2} = begin_scope(
                          {[{LocalVarName, LocalVarAst}],
                           [?Q("_@LocalVarAst = erlydtl_runtime:regroup(_@ListAst, _@regroup)",
                               [{regroup, regroup_filter(GrouperVariable, [])}])
                           ]},
                          TreeWalker1),

    {{Id, ListInfo}, TreeWalker2}.

regroup_filter({attribute,{{identifier,_,Ident},Next}},Acc) ->
    regroup_filter(Next,[erl_syntax:atom(Ident)|Acc]);
regroup_filter({variable,{identifier,_,Var}},Acc) ->
    erl_syntax:list([erl_syntax:atom(Var)|Acc]).

to_list_ast(Value, IsReversed) ->
    ?Q("erlydtl_runtime:to_list(_@Value, _@IsReversed)").

to_list_ast(Value, IsReversed, TreeWalker) ->
    case call_extension(TreeWalker, to_list_ast, [Value, IsReversed, TreeWalker]) of
        undefined -> to_list_ast(Value, IsReversed);
        Result -> Result
    end.

for_loop_ast(IteratorList, LoopValue, IsReversed, Contents,
             {EmptyContentsAst, EmptyContentsInfo},
             #treewalker{ context=Context }=TreeWalker) ->
    %% create unique namespace for this instance
    Level = length(Context#dtl_context.local_scopes),
    {Row, Col} = element(2, hd(IteratorList)),
    ForId = lists:concat(["/", Level, "_", Row, ":", Col]),

    Counters = merl:var(lists:concat(["Counters", ForId])),
    Vars = merl:var(lists:concat(["Vars", ForId])),

    %% setup
    VarScope = lists:map(
                 fun({identifier, {R, C}, Iterator}) ->
                         {Iterator, merl:var(
                                      lists:concat(["Var_", Iterator,
                                                    "/", Level, "_", R, ":", C
                                                   ]))}
                 end, IteratorList),
    {Iterators, IteratorVars} = lists:unzip(VarScope),
    IteratorCount = length(IteratorVars),

    {{LoopBodyAst, Info}, TreeWalker1} =
        body_ast(
          Contents,
          push_scope([{'forloop', Counters} | VarScope],
                     TreeWalker)),

    {{LoopValueAst, LoopValueInfo}, TreeWalker2} =
        value_ast(LoopValue, false, true, restore_scope(TreeWalker, TreeWalker1)),

    LoopValueAst0 = to_list_ast(LoopValueAst, merl:term(IsReversed), TreeWalker2),

    ParentLoop = resolve_variable('forloop', erl_syntax:atom(undefined), TreeWalker2),

    %% call for loop
    {{?Q(["case erlydtl_runtime:forloop(",
          "  fun (_@Vars, _@Counters) ->",
          "    {_@IteratorVars} = if is_tuple(_@Vars), size(_@Vars) == _@IteratorCount@ -> _@Vars;",
          "                          _@___ifclauses -> _",
          "                       end,",
          "    {_@LoopBodyAst, erlydtl_runtime:increment_counter_stats(_@Counters)}",
          "  end,",
          "  _@LoopValueAst0, _@ParentLoop)",
          "of",
          "  empty -> _@EmptyContentsAst;",
          "  {L, _} -> L",
          "end"],
         [{ifclauses, if IteratorCount > 1 ->
                              ?Q(["() when is_list(_@Vars), length(_@Vars) == _@IteratorCount@ ->",
                                  "  list_to_tuple(_@Vars);",
                                  "() when true -> throw({for_loop, _@Iterators@, _@Vars})"]);
                         true ->
                              ?Q("() when true -> {_@Vars}")
                      end}]),
      merge_info(merge_info(Info, EmptyContentsInfo), LoopValueInfo)},
     TreeWalker2}.

ifchanged_values_ast(Values, {IfContentsAst, IfContentsInfo}, {ElseContentsAst, ElseContentsInfo}, TreeWalker) ->
    Info = merge_info(IfContentsInfo, ElseContentsInfo),
    ValueAstFun = fun (Expr, {LTreeWalker, LInfo, Acc}) ->
                          {{EAst, EInfo}, ETw} = value_ast(Expr, false, true, LTreeWalker),
                          {ETw, merge_info(LInfo, EInfo),
                           [?Q("{_@hash, _@EAst}",
                               [{hash, merl:term(erlang:phash2(Expr))}])
                            |Acc]}
                  end,
    {TreeWalker1, MergedInfo, Changed} = lists:foldl(ValueAstFun, {TreeWalker, Info, []}, Values),
    {{?Q(["case erlydtl_runtime:ifchanged([_@Changed]) of",
          "  true -> _@IfContentsAst;",
          "  _ -> _@ElseContentsAst",
          "end"]),
      MergedInfo},
     TreeWalker1}.

ifchanged_contents_ast(Contents, {IfContentsAst, IfContentsInfo}, {ElseContentsAst, ElseContentsInfo}, TreeWalker) ->
    {{?Q(["case erlydtl_runtime:ifchanged([{_@hash, _@IfContentsAst}]) of",
          "  true -> _@IfContentsAst;",
          "  _ -> _@ElseContentsAst",
          "end"],
         [{hash, merl:term(erlang:phash2(Contents))}]),
      merge_info(IfContentsInfo, ElseContentsInfo)},
     TreeWalker}.

cycle_ast(Names, #treewalker{ context=Context }=TreeWalker) ->
    {NamesTuple, VarNames}
        = lists:mapfoldl(
            fun ({string_literal, _, Str}, VarNamesAcc) ->
                    S = string_ast(unescape_string_literal(Str), Context),
                    {S, VarNamesAcc};
                ({variable, _}=Var, VarNamesAcc) ->
                    {{V, #ast_info{ var_names=[VarName] }}, _} = resolve_variable_ast(Var, true, TreeWalker),
                    {V, [VarName|VarNamesAcc]};
                ({number_literal, _, Num}, VarNamesAcc) ->
                    {format(erl_syntax:integer(Num), TreeWalker), VarNamesAcc};
                (_, VarNamesAcc) ->
                    {[], VarNamesAcc}
            end, [], Names),
    {{?Q("erlydtl_runtime:cycle({_@NamesTuple}, _@forloop)",
        [{forloop, resolve_variable('forloop', TreeWalker)}]),
      #ast_info{ var_names = VarNames }},
     TreeWalker}.

%% Older Django templates treat cycle with comma-delimited elements as strings
cycle_compat_ast(Names, #treewalker{ context=Context }=TreeWalker) ->
    NamesTuple = lists:map(
                   fun ({identifier, _, X}) ->
                           string_ast(X, Context)
                   end, Names),
    {{?Q("erlydtl_runtime:cycle({_@NamesTuple}, _@forloop)",
        [{forloop, resolve_variable('forloop', TreeWalker)}]),
      #ast_info{}},
     TreeWalker}.

now_ast(FormatString, TreeWalker) ->
    %% Note: we can't use unescape_string_literal here
    %% because we want to allow escaping in the format string.
    %% We only want to remove the surrounding escapes,
    %% i.e. \"foo\" becomes "foo"
    UnescapeOuter = string:strip(FormatString, both, 34),
    {{StringAst, Info}, TreeWalker1} = string_ast(UnescapeOuter, TreeWalker),
    {{?Q("erlydtl_dateformat:format(_@StringAst)"), Info}, TreeWalker1}.

spaceless_ast(Contents, TreeWalker) ->
    {{Ast, Info}, TreeWalker1} = body_ast(Contents, TreeWalker),
    {{?Q("erlydtl_runtime:spaceless(_@Ast)"), Info}, TreeWalker1}.

load_libs_ast(Libs, TreeWalker) ->
    TreeWalker1 = lists:foldl(
                    fun ({identifier, Pos, Lib}, TW) ->
                            load_library(Pos, Lib, TW)
                    end,
                    TreeWalker, Libs),
    empty_ast(TreeWalker1).

load_from_lib_ast(What, {identifier, Pos, Lib}, TreeWalker) ->
    Names = lists:foldl(
              fun ({identifier, _, Name}, Acc) -> [Name|Acc] end,
              [], What),
    empty_ast(load_library(Pos, Lib, Names, TreeWalker)).


%%-------------------------------------------------------------------
%% Custom tags
%%-------------------------------------------------------------------

interpret_value({trans, StringLiteral}, TreeWalker) ->
    translated_ast(StringLiteral, TreeWalker);
interpret_value(Value, TreeWalker) ->
    value_ast(Value, false, false, TreeWalker).

interpret_args(Args, TreeWalker) ->
    lists:foldr(
      fun ({{identifier, _, Key}, Value}, {{ArgsAcc, AstInfoAcc}, TreeWalkerAcc}) ->
              {{Ast0, AstInfo0}, TreeWalker0} = interpret_value(Value, TreeWalkerAcc),
              {{[?Q("{_@Key@, _@Ast0}")|ArgsAcc], merge_info(AstInfo0, AstInfoAcc)}, TreeWalker0};
          (Value, {{ArgsAcc, AstInfoAcc}, TreeWalkerAcc}) ->
              {{Ast0, AstInfo0}, TreeWalker0} = value_ast(Value, false, false, TreeWalkerAcc),
              {{[Ast0|ArgsAcc], merge_info(AstInfo0, AstInfoAcc)}, TreeWalker0}
      end, {{[], #ast_info{}}, TreeWalker}, Args).

tag_ast(Name, Args, TreeWalker) ->
    {{InterpretedArgs, AstInfo1}, TreeWalker1} = interpret_args(Args, TreeWalker),
    {{RenderAst, RenderInfo}, TreeWalker2} = custom_tags_modules_ast(Name, InterpretedArgs, TreeWalker1),
    {{RenderAst, merge_info(AstInfo1, RenderInfo)}, TreeWalker2}.

custom_tags_modules_ast({identifier, Pos, Name}, InterpretedArgs,
                        #treewalker{
                           context=#dtl_context{
                                      tags = Tags,
                                      module = Module,
                                      is_compiling_dir=IsCompilingDir
                                     }
                          }=TreeWalker) ->
    case proplists:get_value(Name, Tags) of
        {Mod, Fun}=Tag ->
            case lists:max([-1] ++ [I || {N,I} <- Mod:module_info(exports), N =:= Fun]) of
                2 ->
                    {{?Q("'@Mod@':'@Fun@'([_@InterpretedArgs], RenderOptions)"),
                      #ast_info{}}, TreeWalker};
                1 ->
                    {{?Q("'@Mod@':'@Fun@'([_@InterpretedArgs])"),
                      #ast_info{}}, TreeWalker};
                -1 ->
                    empty_ast(?WARN({Pos, {missing_tag, Name, Tag}}, TreeWalker));
                I ->
                    empty_ast(?WARN({Pos, {bad_tag, Name, Tag, I}}, TreeWalker))
            end;
        undefined ->
            if IsCompilingDir ->
                    {{?Q("'@Module@':'@Name@'([_@InterpretedArgs], RenderOptions)"),
                     #ast_info{ custom_tags = [Name] }}, TreeWalker};
            true ->
                    {{?Q("render_tag(_@Name@, [_@InterpretedArgs], RenderOptions)"),
                     #ast_info{ custom_tags = [Name] }}, TreeWalker}
            end
    end.

call_ast(Module, TreeWalker) ->
    call_ast(Module, merl:var("_Variables"), #ast_info{}, TreeWalker).

call_with_ast(Module, Variable, TreeWalker) ->
    {{VarAst, VarInfo}, TreeWalker2} = resolve_variable_ast(Variable, false, TreeWalker),
    call_ast(Module, VarAst, VarInfo, TreeWalker2).

call_ast(Module, Variable, AstInfo, TreeWalker) ->
    Ast = ?Q(["case '@Module@':render(_@Variable, RenderOptions) of",
              "  {ok, Rendered} -> Rendered;",
              "  {error, Reason} -> io_lib:format(\"error: ~p\", [Reason])",
              "end"]),
    with_dependencies(Module:dependencies(), {{Ast, AstInfo}, TreeWalker}).

create_scope(Vars, VarScope) ->
    {Scope, Values} =
        lists:foldl(
          fun ({Name, Value}, {VarAcc, ValueAcc}) ->
                  NameAst = merl:var(lists:concat(["_Var_", Name, VarScope])),
                  {[{Name, NameAst}|VarAcc],
                   [?Q("_@NameAst = _@Value")|ValueAcc]
                  }
          end,
          empty_scope(),
          Vars),
    {Scope, [Values]}.

create_scope(Vars, {Row, Col}, #treewalker{ context=Context }) ->
    Level = length(Context#dtl_context.local_scopes),
    create_scope(Vars, lists:concat(["/", Level, "_", Row, ":", Col])).
