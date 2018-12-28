open Expr;;
open Parsing;;
open Lexing;;

exception SemErr of string 
exception ParseErr of string
exception LexErr of string

let spec_error msg start finish  = 
  Printf.sprintf "File \"%s\", line %d, characters %d-%d: '%s'" start.pos_fname start.pos_lnum 
    (start.pos_cnum  -start.pos_bol) (finish.pos_cnum  - finish.pos_bol) msg

let spec_parse_error msg nterm =
  raise ( ParseErr (spec_error msg (rhs_start_pos nterm) (rhs_end_pos nterm)))

let spec_lex_error lexbuf = 
  raise ( LexErr (spec_error (lexeme lexbuf) (lexeme_start_p lexbuf) (lexeme_end_p lexbuf)))

type symtkey = (string*int) (* string is predicate name, int is the arity of literal*)
type symtable = (symtkey, stt list) Hashtbl.t (* each row of a symtable is all the rules which has the same literal in head*)

let hash_max_size = ref 500;;

(** Prints a symtable
 *)
let print_symtable (st:symtable) =
    let print_el s = Printf.printf "%s" (string_of_stt s) in
    let print_lst _ lst = List.iter print_el lst in
    Hashtbl.iter print_lst st

(** string of a symtable
 *)
let string_of_symtable (st:symtable) =
    let p_el str s = str ^ (string_of_stt s) in
    let p_lst _ lst str = (List.fold_left p_el "" lst)^str in
    Hashtbl.fold p_lst st ""

(** Receives a rterm and generates its hash key for the
 *  symtable
 a rterm is identified by it predicate name and number of argument (arity)
 *)
let symtkey_of_rterm rt : symtkey = (get_rterm_predname rt, get_arity rt)

(** Receives a rule and generates its hash key for the
 *  symtable
 *)
let symtkey_of_rule rt : symtkey = match rt with
    | Rule (h, b) -> symtkey_of_rterm h
    | _ -> invalid_arg "function symtkey_of_rule called without a rule"

(** Inserts a rule in the symtable *)
let symt_insert (st:symtable) rule = match rule with
    | Rule (_,_) ->
        let key = symtkey_of_rule rule in
        if Hashtbl.mem st key then  
            Hashtbl.replace st key ((Hashtbl.find st key)@[rule]) (* add new rule into the list of rules of this key *)
        else
            Hashtbl.add st key [rule]
    | _ -> invalid_arg "function symt_insert called without a rule"

(** Compares two keys for ordering *)
let key_comp ((k1_n,k1_a):symtkey) ((k2_n,k2_a):symtkey) =
    let comp = String.compare k1_n k2_n in
    if comp != 0 then comp
    else k1_a - k2_a

(** Given a list of keys, remove repetitions *)
let remove_repeated_keys k_lst =
    let no_rep key = function
        | [] -> [key]
        | (hd::tl) ->
            if (key_comp key hd) == 0 then (hd::tl)
            else (key::hd::tl) in
    let sorted = List.sort key_comp k_lst in
    List.fold_right no_rep sorted []

(** Given a key, returns the predicate name that belongs to the key *)
let get_symtkey_predname ((n,_):symtkey) = n

(** Given a key, returns the predicate arity that belongs to the key *)
let get_symtkey_arity ((_,a):symtkey) = a

let string_of_symtkey ((n,a):symtkey) =
    n^"/"^(string_of_int a)

let alias_of_symtkey ((n,a):symtkey) =
    n^"_a"^(string_of_int a)

(**Takes a program and extracts all rules and places them in
* a symtable*)
let extract_idb = function
    | Prog stt_lst ->
        let idb:symtable = Hashtbl.create !hash_max_size in
        let in_stt t = match t with
            | Rule _ -> symt_insert idb t 
            | Query _ -> ()
            | Base _ -> () in            
        List.iter in_stt stt_lst;
        idb

let extract_edb = function
    | Prog stt_lst ->
        let edb:symtable = Hashtbl.create !hash_max_size in
        let in_stt t = match t with
            | Rule _ -> ()
            | Query rt -> ()
            | Base rt -> symt_insert edb (Rule (rt,[])) in            
        List.iter in_stt stt_lst;
        edb

(**This structure defines a set of symtable keys*)
module SymtkeySet = Set.Make( 
  struct
    let compare = key_comp
    type t = symtkey
  end
)
    
type kset = SymtkeySet.t

(** Compares two variables for ordering *)
let var_comp var1 var2 = String.compare (string_of_var var1) (string_of_var var2)

(** set for variable  *)
module VarSet = Set.Make(struct
    type t = var
    let compare = var_comp
  end)

type varset = VarSet.t

(** This type defines a colnamtab, which is a dictionnary that
 * contains for each predicate (edb & idb) a list with the name of
 * all of its columns in order. The information is stored in a
 * hash table using as a keys the keys from symtables.*)
type colnamtab = (symtkey, (string list)) Hashtbl.t

(*Extracts from the edb and idb their column names and
 * stores them in a colnamtab, places them in order*)
let build_colnamtab (edb:symtable) (idb:symtable) =
    let hs:colnamtab = Hashtbl.create !hash_max_size in
    let e_cols key rules =
        let rule = List.hd rules in
        let varlist = List.map string_of_var (get_rterm_varlist (rule_head rule)) in
        Hashtbl.add hs key varlist in
    Hashtbl.iter e_cols edb;
    let i_cols key rules =
        let rec cols ind n =
            if ind<n then ("col"^(string_of_int ind))::(cols (ind+1) n) 
            else [] in
        if not (Hashtbl.mem hs key) then
            Hashtbl.add hs key (cols 0 (get_symtkey_arity key))
        else
            ()
    in
    Hashtbl.iter i_cols idb;
    hs

(** This type defines a 'vartable', it belongs to a rule and
 * it is a dictionary with variable names as key, these variables
 * are those that appear in the body/head of the rule.
 * The value for each key is a list of variable-appearances:
 * references to predicates in the rule's body where the variable is
 * mentioned.
 * A variable appearence is simply a string denoting
 * a column of a relation in the way Table.column*)
type vartab = (string, string list) Hashtbl.t

(*Inserts in a vartab the provided var_app, initializing a list
 * in the hash if neccessary*)
let vt_insert (vt:vartab) vname va =
    if Hashtbl.mem vt vname then
        let ap_lst = Hashtbl.find vt vname in
        Hashtbl.replace vt vname (va::ap_lst)
    else
        Hashtbl.add vt vname [va]

(*Prints a vartab*)
let vt_print (vt:vartab) =
    let print_el vn alst =
        let ap_str = "["^(String.concat ", " alst)^"]" in
        Printf.printf "%s: %s\n" vn ap_str in
    Hashtbl.iter print_el vt

(*builds a vartab out of a list of rterms and with the colnamtab*)
let build_vartab (col_names:colnamtab) rterms =
    let vt:vartab = Hashtbl.create !hash_max_size in
    let in_rt n rterm =
        let pname = get_rterm_predname rterm in
        let vlst = get_rterm_varlist rterm in
        let arity = get_arity rterm in
        let key = symtkey_of_rterm rterm in
        let cols = Hashtbl.find col_names key in
        let in_v cn v =
            let comp_cn =
                pname^"_a"^(string_of_int arity)^
                "_"^(string_of_int n)^"."^cn
            in
            match v with
            NamedVar _ | NumberedVar _ ->
                vt_insert vt (string_of_var v) comp_cn
            | AggVar _ -> raise (SemErr (
                    "Goal "^(string_of_symtkey key)^
                    " contains an aggregate function as a variable, "^
                    "which is only allowed in rule heads"
                ))
            | _ -> ()
        in
        List.iter2 in_v cols vlst;
        n+1
    in
    let _ = List.fold_left in_rt 0 rterms in
    vt

(** This type defines a eqtab, it belongs to a rule and it is
 * a dictionary with variable names as
 * keys and constants as values. They represent equalities that
 * must be satisfied by the variables*) 
type eqtab = (string,const) Hashtbl.t

(** Given a list of equality ASTs, returns an eqtab with
 * the equality relations as var = value.
 * PRECONDITION: There should not be aggregate equalities
 * in the provided list.*)
let build_eqtab eqs =
    let tuples = List.map extract_eq_tuple eqs in
    let hs:eqtab = Hashtbl.create !hash_max_size in
    let add_rel (var,c) = match var with
        NamedVar _ | NumberedVar _ -> Hashtbl.add hs (string_of_var var) c
        | _ -> invalid_arg "Trying to build_eqtab with equalities not of the form var = const" in
    List.iter add_rel tuples;
    hs

(** Given a var name, returns the value and removes it from the eqtab*)
let eqt_extract eqt vname =
    let c = Hashtbl.find eqt vname in
    Hashtbl.remove eqt vname;
    c

let get_query e = match e with
    | Prog sttl -> 
        let is_q = function
            | Query _ -> true
            | _ -> false
        in
        let lq = List.filter is_q sttl in
        match lq with 
            | []     -> raise (SemErr "The program has no query")
            | h::[]    ->  h
            | h::_ -> raise (SemErr "The program has more than one query")
;;

let str_contains s1 s2 =
    let re = Str.regexp_string s2
    in
        try ignore (Str.search_forward re s1 0); true
        with Not_found -> false

let get_temp_rterm (rt:rterm) = match rt with
    | Pred (x, vl) -> Pred ("__temp__"^x, vl)
    | Deltainsert (x, vl) -> Deltainsert ("__temp__"^x, vl)
    | Deltadelete (x, vl) -> Deltadelete ("__temp__"^x, vl)
;;

(** set for rterm  *)
module RtermSet = Set.Make(struct
  type t = rterm
  let compare rt1 rt2 = key_comp (symtkey_of_rterm rt1) (symtkey_of_rterm rt2)
end)

(** print delta predicate list  *)
let print_deltas dlst = 
    let print_el s = Printf.printf "%s, " (string_of_rterm s) in
    List.iter print_el dlst

let rec gen_vars ind n =
            if ind<n then (NamedVar ("COL"^(string_of_int ind)))::(gen_vars (ind+1) n) 
            else []

let variableize_rterm(rt:rterm) = match rt with
    | Pred (x, vl) -> Pred (x, (gen_vars 0 (List.length vl)))
    | Deltainsert (x, vl) -> Deltainsert (x, (gen_vars 0 (List.length vl)))
    | Deltadelete (x, vl) -> Deltadelete (x, (gen_vars 0 (List.length vl)))
;;

let get_delta_rterms e = match e with
    | Prog sttl -> 
        let add_delta (rtset:RtermSet.t) = function
            | Rule (head, lst) -> (match head with Pred _ -> rtset | Deltainsert _ -> RtermSet.add (variableize_rterm head) rtset | Deltadelete _ -> RtermSet.add (variableize_rterm head) rtset)
            | _ -> rtset
        in
        let delta_lst: rterm list = RtermSet.elements (List.fold_left add_delta RtermSet.empty sttl) in
        (* print_endline "____delta____";
        print_deltas delta_lst; *)
        match delta_lst with 
            | []     -> raise (SemErr "The program has no update")
            | _::tail    -> delta_lst
;;

let rec gen_cols ind n =
            if ind<n then ( "col"^(string_of_int ind))::(gen_cols (ind+1) n) 
            else []

let deltapred_to_pred = function
    | Prog stt_lst -> 
        let rterm_to_pred rt = match rt with
        | Pred (x, vl) -> rt
        | Deltainsert (x, vl) -> Pred (get_rterm_predname rt, vl)
        | Deltadelete (x, vl) -> Pred (get_rterm_predname rt, vl) in
        let term_map_to_pred tt = match tt with
            | Rel rt -> Rel (rterm_to_pred rt)
            | Equal _ -> tt
            | Ineq _ -> tt
            | Not rt -> Not (rterm_to_pred rt) in
        let in_stt t = match t with
            | Rule(head,body) -> Rule(rterm_to_pred head, List.map term_map_to_pred body)
            | _ -> t in            
        Prog (List.map in_stt stt_lst)

let rec get_termlst_varset terms = 
    let lst = List.fold_right (@) (List.map get_term_varlist terms) [] in 
    VarSet.of_list lst
;;
