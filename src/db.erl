-module(db).
-compile(export_all).

-define(WARNING(QueryText,Msg), error_logger:info_msg("QUERY WARNING: ~p~n~nQuery:~n~p~n~n",[Msg,QueryText])).

-define(TYPE, application:get_env(sigma_sql, type, mysql)).
-define(HOST, application:get_env(sigma_sql, host, "127.0.0.1")).
-define(PORT, application:get_env(sigma_sql, port, 3306)).
-define(USER, application:get_env(sigma_sql, user, "root")).
-define(PASS, application:get_env(sigma_sql, pass, "")).
-define(LOOKUP, application:get_env(sigma_sql, lookup, fun() -> throw({sigma_sql,undefined_lookup_method}) end )).
-define(CPP, application:get_env(sigma_sql, connections_per_pool, 10)).

%% does not currently do anything
-define(AUTOGROW, application:get_env(sigma_sql, autogrow_pool, false)).

-define(DB, sigma_sql_cached_db).

-type db()			:: atom().
-type table()		:: string() | atom().
-type field()		:: string() | atom().
-type value()		:: string() | binary() | atom() | integer() | float().
-type insert_id()	:: term().
-type update_id()	:: term().
-type proplist()	:: {atom() | value()}.

-spec lookup() -> db().
% @doc Checks the configuration for how we determine the database we're using
% and returns the database.
lookup() ->
	case ?LOOKUP of
		A when is_atom(A) -> A;
		F when is_function(F, 0) -> F();
		{M, F} when is_atom(M), is_atom(F) -> M:F()
	end.

-spec db() -> db().
% @doc Checks the process dictionary for an active database connection
% associated with this process. If none, then look it up from configuration and
% store it in the process dictionary. Note, this function does not actually
% establish a connection, only returns the name of the database that either is
% associated with the process or that *should* be associated with the process
% based on some criteria (for example, checking host headers)
db() ->
	case erlang:get(?DB) of
		undefined ->
			DB = lookup(),
			db(DB);
		DB ->
			DB
	end.

-spec db(db()) -> db().
% @doc Stores the database name in the process dictionary
db(DB) ->
	erlang:put(?DB,DB),
	DB.

-spec start() -> ok.
% @doc starts the actual database driver, if necessary
start() ->
	case ?TYPE of
		mysql -> 
				application:start(crypto),
				application:start(emysql);
		Other -> throw({unknown_db_type, Other})
	end,
	ok.

-spec connect() -> db().
% @doc establishes a connection to the appropriate database.
connect() ->
	connect(db()).

-spec connect(db()) -> db().
% @doc establishes a connection to the named database.
connect(DB) when is_atom(DB) ->
	emysql:add_pool(DB, ?CPP, ?USER, ?PASS, ?HOST, ?PORT, DB, utf8),
	DB.

-spec pl(Table :: table(), Proplist :: proplist()) -> insert_id() | update_id().
% @doc Shortcut for pl(Table, Table ++ "id", PropList)
pl(Table,PropList) when is_atom(Table) ->
	pl(atom_to_list(Table),PropList);
pl(Table,PropList) when is_list(Table) ->
	KeyField = Table ++ "id",
	pl(Table,KeyField,PropList).

-spec pl(Table :: table(), KeyField :: field(), PropList :: proplist()) -> insert_id() | update_id().
% @doc Inserts into or updates a table based on the value of the KeyField i1n
% PropList. If get_value(KeyField, PropList) is "0", 0, or undefined, then
% insert, otherwise update
pl(Table,KeyField,PropList) when is_atom(Table) ->
	pl(atom_to_list(Table),KeyField,PropList);
pl(Table,KeyField,PropList) when is_list(KeyField) ->
	pl(Table,list_to_atom(KeyField),PropList);
pl(Table,KeyField,PropList) when is_list(Table) ->
	KeyValue = proplists:get_value(KeyField,PropList,0),
	case KeyValue of
		Zero when Zero==0;Zero=="0";Zero==undefined -> 
			pli(Table,pl:delete(PropList,KeyField));
		_ -> 
			plu(Table,KeyField,PropList)
	end.

-spec atomize(list() | binary() | atom()) -> atom().
% @doc converts X to an atom.
atomize(X) when is_list(X) ->
	list_to_atom(X);
atomize(X) when is_atom(X) ->
	X;
atomize(X) when is_binary(X) ->
	list_to_atom(binary_to_list(X)).

-spec filter_fields(Table :: table(), PropList :: proplist()) -> proplist().
% @doc removes from Proplist any fields that aren't found in the table "Table"
filter_fields(Table,PropList) ->
	TableFields = table_fields(Table),
	[{K,V} || {K,V} <- PropList,lists:member(atomize(K),TableFields)].

%% Inserts a proplist into the table
-spec pli(Table :: table(), PropList :: proplist()) -> insert_id().
pli(Table,PropList) when is_atom(Table) ->
	pli(atom_to_list(Table),PropList);
pli(Table,InitPropList) ->
	PropList = filter_fields(Table,InitPropList),
	Sets = [atom_to_list(F) ++ "=" ++ encode(V) || {F,V} <- PropList],
	Set = string:join(Sets,","),
	SQL = "insert into " ++ Table ++ " set " ++ Set,
	qi(SQL).

%% Updates a row from the proplist based on the key `Table ++ "id"` in the Table
plu(Table,PropList) when is_atom(Table) ->
	plu(atom_to_list(Table),PropList);
plu(Table,PropList) ->
	KeyField = list_to_atom(Table ++ "id"),
	plu(Table,KeyField,PropList).

plu(Table,KeyField,InitPropList) when is_atom(Table) ->
	plu(atom_to_list(Table),KeyField,InitPropList);
plu(Table,KeyField,InitPropList) ->
	PropList = filter_fields(Table,InitPropList),
	KeyValue = proplists:get_value(KeyField,PropList),
	Sets = [atom_to_list(F) ++ "=" ++ encode(V) || {F,V} <- PropList,F /= KeyField],
	Set = string:join(Sets,","),
	SQL = "update " ++ Table ++ " set " ++ Set ++ " where " ++ atom_to_list(KeyField) ++ "=" ++ encode(KeyValue),
	q(SQL),
	KeyValue.

%% proplist query
plq(Q) ->
	Db = db(),
	db_q(proplist,Db,Q).

plq(Q,ParamList) ->
	Db = db(),
	db_q(proplist,Db,Q,ParamList).

%% dict query
dq(Q) ->
	Db = db(),
	db_q(dict,Db,Q).

dq(Q,ParamList) ->
	Db = db(),
	db_q(dict,Db,Q,ParamList).

%% tuple query
tq(Q) ->
	Db = db(),
	db_q(tuple,Db,Q).

tq(Q,ParamList) ->
	Db = db(),
	db_q(tuple,Db,Q,ParamList).


format_result(Type,Res) ->
	Res1 = sigma:deep_unbinary(mysql:get_result_rows(Res)),
	case Type of
		list ->
			Res1;
		tuple ->
			[list_to_tuple(R) || R<-Res1];
		Other when Other==proplist;Other==dict -> 
			Fields = mysql:get_result_field_info(Res),
			Proplists = [format_proplist_result(R,Fields) || R<-Res1],
			case Other of
				proplist -> Proplists;
				dict -> [dict:from_list(PL) || PL <- Proplists]
			end	
	end.

format_proplist_result(Row,Fields) ->
	FieldNames = [list_to_atom(binary_to_list(F)) || {_,F,_,_} <- Fields],
	lists:zip(FieldNames,Row).

%% Query from the specified Database pool (Db)
%% This will connect to the specified Database Pool
%% Type must be atoms: proplist, dict, list, or tuple
%% Type can also be atom 'insert' in which case, it'll return the insert value

db_q(Type,Db,Q) ->
	case mysql:fetch(Db,Q) of
		{data, Res} ->
			format_result(Type,Res);
		{updated, Res} ->
			case Type of
				insert -> mysql:get_result_insert_id(Res);
				_ -> mysql:get_result_affected_rows(Res)
			end;
		{error, {no_connection_in_pool,_}} ->
			NewDB = connect(),
			db_q(Type,NewDB,Q);
		{error, Res} ->
			{error, mysql:get_result_reason(Res)}
	end.

db_q(Type,Db,Q,ParamList) ->
	NewQ = q_prep(Q,ParamList),
	db_q(Type,Db,NewQ).

%%  A special Query function just for inserting.
%%  Inserts the record(s) and returns the insert_id
qi(Q) ->
	Db = db(),
	db_q(insert,Db,Q).

qi(Q,ParamList) ->
	Db = db(),
	db_q(insert,Db,Q,ParamList).

%% Query the database and return the relevant information
%% If a select query, it returns all the rows
%% If an update or Insert query, it returns the number of rows affected
q(Q) ->
	Db = db(),
	db_q(list,Db,Q).

q(Q,ParamList) ->
	Db = db(),
	db_q(list,Db,Q,ParamList).


%% fr = First Record
plfr(Q,ParamList) ->
	case plq(Q,ParamList) of
		[] -> not_found;
		[[undefined]] -> not_found;
		[First|_] -> First
	end.

plfr(Q) ->
	plfr(Q,[]).

tfr(Q) ->
	tfr(Q,[]).

tfr(Q,ParamList) ->
	case tq(Q,ParamList) of
		[] -> not_found;
		[[undefined]] -> not_found;
		[First|_] -> First
	end.

%% fr = First Record
fr(Q,ParamList) ->
	case q(Q,ParamList) of
		[] -> not_found;
		[[undefined]] -> not_found;
		[First|_] -> First
	end.

fr(Q) ->
	fr(Q,[]).

%% fffr = First Field of First record
fffr(Q,ParamList) ->
	case fr(Q,ParamList) of
		not_found -> not_found;
		[First|_] -> First
	end.

fffr(Q) ->
	fffr(Q,[]).

%% First Field List
ffl(Q,ParamList) ->
	[First || [First | _ ] <- db:q(Q,ParamList)].

ffl(Q) ->
	ffl(Q,[]).

table_fields(Table) when is_atom(Table) ->
	table_fields(atom_to_list(Table));
table_fields(Table) ->
	[list_to_atom(F) || F <- db:ffl("describe " ++ Table)].

%% Existance query, just returns true if the query returns anything other than an empty set
%% QE = "Q Exists"
%% TODO: Check for "limit" clause and add? Or rely on user.
qexists(Q) ->
	qexists(Q,[]).

qexists(Q,ParamList) ->
	case q(Q,ParamList) of
		[] -> false;
		[_] -> true;
		[_|_] -> 
			?WARNING({Q,ParamList},"qexists returned more than one record. Recommend returning one record for performance."),
			true
	end.
			
	
%% retrieves a field value from a table
%% ie: Select 'Field' from 'Table' where 'IDField'='IDValue'
%% This should only be called from the db_ modules.  Never in the page.
%% It's not a security thing, just a convention thing
field(Table,Field,IDField,IDValue) when is_atom(Table) ->
	field(atom_to_list(Table),Field,IDField,IDValue);
field(Table,Field,IDField,IDValue) when is_atom(Field) ->
	field(Table,atom_to_list(Field),IDField,IDValue);
field(Table,Field,IDField,IDValue) when is_atom(IDField) ->
	field(Table,Field,atom_to_list(IDField),IDValue);
field(Table,Field,IDField,IDValue) ->
	db:fffr("select " ++ Field ++ " from " ++ Table ++ " where " ++ IDField ++ "= ?",[IDValue]).

%% This does the same as above, but uses Table ++ "id" for the idfield
field(Table,Field,IDValue) when is_atom(Table) ->
	field(atom_to_list(Table),Field,IDValue);
field(Table,Field,IDValue) ->
	field(Table,Field,Table ++ "id",IDValue).

delete(Table,ID) when is_atom(Table) ->
	delete(atom_to_list(Table),ID);
delete(Table,ID) when is_list(Table) ->
	KeyField = Table ++ "id",
	delete(Table,KeyField,ID).

delete(Table,KeyField,ID) when is_atom(Table) ->
	delete(atom_to_list(Table),KeyField,ID);
delete(Table,KeyField,ID) when is_atom(KeyField) ->
	delete(Table,atom_to_list(KeyField),ID);
delete(Table,KeyField,ID) ->
	db:q("delete from " ++ Table ++ " where " ++ KeyField ++ "=?",[ID]).

%%% Prepares a query with Parameters %%%%%%%%%%
q_prep(Q,[]) ->
	Q;
q_prep(Q,ParamList) ->
	QParts = re:split(Q,"\\?",[{return,list}]),
	NumParts = length(QParts)-1,
	NumParams = length(ParamList),
	if
		 NumParts == NumParams -> q_join(QParts,ParamList);
		 true -> 
			 throw({error, "Parameter Count in query is not consistent: ?'s = " ++ integer_to_list(NumParts) ++ ", Params = " ++ integer_to_list(NumParams),[{sql,Q},{params,ParamList}]})
	end.

q_join([QFirstPart|[QSecondPart|QRest]],[FirstParam|OtherParam]) when is_list(QFirstPart);is_list(QSecondPart) ->
	NewFirst = QFirstPart ++ encode(FirstParam) ++ QSecondPart,
	q_join([NewFirst|QRest],OtherParam);
q_join([QFirstPart | [QRest]],[FirstParam | [] ]) when is_list(QFirstPart);is_list(QRest) ->
	QFirstPart ++ FirstParam ++ QRest;
q_join([QFirstPart], []) ->
	QFirstPart.

%% Prelim Encoding, then does mysql encoding %%%
%% primarily for the atoms true and false
encode(true) -> "1";
encode(false) -> "0";
encode(Other) -> mysql:encode(Other).

remove_wrapping_quotes(Str) ->
	lists:reverse(tl(lists:reverse(tl(Str)))).


encode64("") -> "";
encode64(undefined) -> "";
encode64(Data) ->
	base64:encode_to_string(term_to_binary(Data)).

decode64("") -> "";
decode64(undefined) -> "";
decode64(Data) ->
	binary_to_term(base64:decode(Data)).

%%%%%%%%%% Takes a list of items and encodes them for SQL then returns a comma-separated list of them
encode_list(List) ->
	NewList = [encode(X) || X<-List],
	string:join(NewList,",").


dict_to_proplist(SrcDict,AcceptableFields) ->
	DictFilterFoldFun = fun(F,Dict) ->
		case dict:is_key(F,Dict) of
			true -> Dict;
			false -> dict:erase(F,Dict)
		end
	end,
	FilteredDict = lists:foldl(DictFilterFoldFun,SrcDict,AcceptableFields),
	dict:to_list(FilteredDict).


to_bool(false) -> 	false;
to_bool(0) -> 		false;
to_bool(undefined) -> 	false;
to_bool(_) -> 		true.

offset(PerPage, Page) when Page =< 0 ->
	offset(PerPage, 1);
offset(PerPage, Page) when PerPage < 1 ->
	offset(1, Page);
offset(PerPage, Page) when Page > 0 ->
	(Page-1) * PerPage.

limit_clause(PerPage, Page) ->
	Offset = offset(PerPage, Page),
	" limit " ++ wf:to_list(Offset) ++ ", " ++ wf:to_list(PerPage).
