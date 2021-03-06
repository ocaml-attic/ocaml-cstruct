(*
 * Copyright (c) 2012-2013 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Printf

open Camlp4.PreCast
open Syntax
open Ast

type mode = Big_endian | Little_endian | Host_endian

type prim =
  | UInt8
  | UInt16
  | UInt32
  | UInt64

type ty =
  | Prim of prim
  | Buffer of prim * int

type field = {
  field: string;
  ty: ty;
  off: int;
}

type t = {
  name: string;
  fields: field list;
  len: int;
  endian: mode;
}

let ty_of_string =
  function
  |"uint8_t" |"uint8" |"int8" |"int8_t"  -> Some UInt8
  |"uint16_t"|"uint16"|"int16"|"int16_t" -> Some UInt16
  |"uint32_t"|"uint32"|"int32"|"int32_t" -> Some UInt32
  |"uint64_t"|"uint64"|"int64"|"int64_t" -> Some UInt64
  |_ -> None

let width_of_field f =
  let rec width = function
    |Prim UInt8 -> 1
    |Prim UInt16 -> 2
    |Prim UInt32 -> 4
    |Prim UInt64 -> 8
    |Buffer (prim, len) -> (width (Prim prim)) * len
  in
  width f.ty

let field_to_string f =
  let rec string = function
    |Prim UInt8 -> "uint8_t"
    |Prim UInt16 -> "uint16_t"
    |Prim UInt32 -> "uint32_t"
    |Prim UInt64 -> "uint64_t"
    |Buffer (prim, len) -> sprintf "%s[%d]" (string (Prim prim)) len
  in
  sprintf "%s %s" (string f.ty) f.field

let to_string t =
  sprintf "cstruct[%d] %s { %s }" t.len t.name
    (String.concat "; " (List.map field_to_string t.fields))

let loc_err _loc err = Loc.raise _loc (Failure err)

let parse_field _loc field field_type sz =
  match ty_of_string field_type with
  |None -> loc_err _loc (sprintf "Unknown type %s" field_type)
  |Some ty -> begin
    let ty = match ty,sz with
      |_,None -> Prim ty
      |prim,Some sz -> Buffer (prim, int_of_string sz)
    in
    let off = -1 in
    { field; ty; off }
  end

let create_struct _loc endian name fields =
  let endian = match endian with
    |"little_endian" -> Little_endian
    |"big_endian" -> Big_endian
    |"host_endian" -> Host_endian
    |_ -> Loc.raise _loc (Failure (sprintf "unknown endian %s, should be little_endian, big_endian or host_endian" endian))
  in
  let len, fields =
    List.fold_left (fun (off,acc) field ->
      let field = {field with off=off} in
      let off = width_of_field field + off in
      let acc = acc @ [field] in
      (off, acc)
    ) (0,[]) fields
  in
  { fields; name; len; endian }

let mode_mod _loc =
  function
  |Big_endian -> <:expr< Cstruct.BE >>
  |Little_endian -> <:expr< Cstruct.LE >>
  |Host_endian -> <:expr< Cstruct.HE >>

let getter_name s f = sprintf "get_%s_%s" s.name f.field
let setter_name s f = sprintf "set_%s_%s" s.name f.field
let op_name op s f = sprintf "%s_%s_%s" op s.name f.field

let output_get _loc s f =
  let m = mode_mod _loc s.endian in
  let num x = <:expr< $int:string_of_int x$ >> in
  match f.ty with
  |Buffer (_, _) ->
    let len = width_of_field f in
    <:str_item<
      value $lid:op_name "get" s f$ src = Cstruct.sub src $num f.off$ $num len$ ;
      value $lid:op_name "copy" s f$ src = Cstruct.copy src $num f.off$ $num len$
    >>
  |Prim prim ->
    <:str_item<
      value $lid:getter_name s f$ v =
      $match prim with
       |UInt8 -> <:expr< Cstruct.get_uint8 v $num f.off$ >>
       |UInt16 -> <:expr< $m$.get_uint16 v $num f.off$ >>
       |UInt32 -> <:expr< $m$.get_uint32 v $num f.off$ >>
       |UInt64 -> <:expr< $m$.get_uint64 v $num f.off$ >>
      $
    >>

let type_of_int_field _loc = function
  |UInt8 -> <:ctyp<Cstruct.uint8>>
  |UInt16 -> <:ctyp<Cstruct.uint16>>
  |UInt32 -> <:ctyp<Cstruct.uint32>>
  |UInt64 -> <:ctyp<Cstruct.uint64>>

let output_get_sig _loc s f =
  match f.ty with
  |Buffer (_,_) ->
    <:sig_item<
      value $lid:op_name "get" s f$ : Cstruct.t -> Cstruct.t ;
      value $lid:op_name "copy" s f$ : Cstruct.t -> string >>
  |Prim prim ->
    let retf = type_of_int_field _loc prim in
    <:sig_item< value $lid:getter_name s f$ : Cstruct.t -> $retf$ ; >>

let output_set _loc s f =
  let m = mode_mod _loc s.endian in
  let num x = <:expr< $int:string_of_int x$ >> in
  match f.ty with
  |Buffer (_,_) ->
    let len = width_of_field f in
    <:str_item<
      value $lid:setter_name s f$ src srcoff dst = Cstruct.blit_from_string src srcoff dst $num f.off$ $num len$ ;
      value $lid:op_name "blit" s f$ src srcoff dst = Cstruct.blit src srcoff dst $num f.off$ $num len$
    >>
  |Prim prim ->
    <:str_item<
      value $lid:setter_name s f$ v x = $match prim with
       |UInt8 -> <:expr< Cstruct.set_uint8 v $num f.off$ x >>
       |UInt16 -> <:expr< $m$.set_uint16 v $num f.off$ x >>
       |UInt32 -> <:expr< $m$.set_uint32 v $num f.off$ x >>
       |UInt64 -> <:expr< $m$.set_uint64 v $num f.off$ x >>
      $
    >>

let output_set_sig _loc s f =
  match f.ty with
  |Buffer (_,_) ->
    <:sig_item<
      value $lid:setter_name s f$ : string -> int -> Cstruct.t -> unit ;
      value $lid:op_name "blit" s f$ : Cstruct.t -> int -> Cstruct.t -> unit >>
  |Prim prim ->
    let retf = type_of_int_field _loc prim in
    <:sig_item< value $lid:setter_name s f$ : Cstruct.t -> $retf$ -> unit >>

let output_sizeof _loc s =
  <:str_item<
    value $lid:"sizeof_"^s.name$ = $int:string_of_int s.len$
  >>

let output_sizeof_sig _loc s =
  <:sig_item<
    value $lid:"sizeof_"^s.name$ : int
  >>

let output_hexdump _loc s =
  let hexdump =
    List.fold_left (fun a f ->
      <:expr<
        $a$; Buffer.add_string _buf $str:"  "^f.field^" = "$;
        $match f.ty with
         |Prim (UInt8|UInt16) ->
           <:expr< Printf.bprintf _buf "0x%x\n" ($lid:getter_name s f$ v) >>
         |Prim UInt32 ->
           <:expr< Printf.bprintf _buf "0x%lx\n" ($lid:getter_name s f$ v) >>
         |Prim UInt64 ->
           <:expr< Printf.bprintf _buf "0x%Lx\n" ($lid:getter_name s f$ v) >>
         |Buffer (_,_) ->
           <:expr< Printf.bprintf _buf "<buffer %s>"
                     $str: field_to_string f$;
                     Cstruct.hexdump_to_buffer _buf ($lid:getter_name s f$ v) >>
        $ >>
    ) <:expr< >> s.fields
  in
  <:str_item<
    value $lid:"hexdump_"^s.name^"_to_buffer"$ _buf v = do { $hexdump$ };
    value $lid:"hexdump_"^s.name$ v =
      let _buf = Buffer.create 128 in
      do {
        Buffer.add_string _buf $str:s.name ^ " = {\n"$;
        $lid:"hexdump_"^s.name^"_to_buffer"$ _buf v;
        print_endline (Buffer.contents _buf);
        print_endline "}"
      } >>

let output_hexdump_sig _loc s =
  <:sig_item<
    value $lid:"hexdump_"^s.name^"_to_buffer"$ : Buffer.t -> Cstruct.t -> unit;
    value $lid:"hexdump_"^s.name$ : Cstruct.t -> unit;
  >>

let output_struct _loc s =
  (* Generate functions of the form {get/set}_<struct>_<field> *)
  let expr = List.fold_left (fun a f ->
    <:str_item<
      $a$ ;
      $output_get _loc s f$ ;
      $output_set _loc s f$
    >>
  ) <:str_item< $output_sizeof _loc s$ >> s.fields
  in <:str_item< $expr$; $output_hexdump _loc s$ >>

let output_struct_sig _loc s =
  (* Generate signaturs of the form {get/set}_<struct>_<field> *)
  let expr = List.fold_left (fun a f ->
    <:sig_item<
      $a$ ;
      $output_get_sig _loc s f$ ;
      $output_set_sig _loc s f$ ;
    >>
  ) <:sig_item< $output_sizeof_sig _loc s$ >> s.fields
  in <:sig_item< $expr$; $output_hexdump_sig _loc s$ >>

let output_enum _loc name fields width =
  let intfn,pattfn = match ty_of_string width with
    |None -> loc_err _loc ("enum: unknown width specifier " ^ width)
    |Some (UInt8 | UInt16) ->
      (fun i -> <:expr< $int:Int64.to_string i$ >>),
      (fun i -> <:patt< $int:Int64.to_string i$ >>)
    |Some UInt32 ->
      (fun i -> <:expr< $int32:Printf.sprintf "0x%Lx" i$ >>),
      (fun i -> <:patt< $int32:Printf.sprintf "0x%Lx" i$ >>)
    |Some UInt64 ->
      (fun i -> <:expr< $int64:Printf.sprintf "0x%Lx" i$ >>),
      (fun i -> <:patt< $int64:Printf.sprintf "0x%Lx" i$ >>)
  in
  let decls = tyOr_of_list (List.map (fun (f,_) ->
    <:ctyp< $uid:f$ >>) fields) in
  let getters = mcOr_of_list ((List.map (fun (f,i) ->
    <:match_case< $pattfn i$ -> Some $uid:f$ >>
  ) fields) @ [ <:match_case< _ -> None >> ]) in
  let setters = mcOr_of_list (List.map (fun (f,i) ->
    <:match_case< $uid:f$ -> $intfn i$ >>
  ) fields) in
  let printers = mcOr_of_list (List.map (fun (f,_) ->
    <:match_case< $uid:f$ -> $str:f$ >>) fields) in
  let parsers = mcOr_of_list (List.map (fun (f,_) ->
    <:match_case< $str:f$ -> Some $uid:f$ >>) fields) in
  let getter x = sprintf "int_to_%s" x in
  let setter x = sprintf "%s_to_int" x in
  let printer x = sprintf "%s_to_string" x in
  let parse x = sprintf "string_to_%s" x in
  <:str_item<
    type $lid:name$ = [ $decls$ ] ;
    value $lid:getter name$ x = match x with [ $getters$ ] ;
    value $lid:setter name$ x = match x with [ $setters$ ] ;
    value $lid:printer name$ x = match x with [ $printers$ ] ;
    value $lid:parse name$ x = match x with [ $parsers$ | _ -> None ] ;
  >>

let output_enum_sig _loc name fields width =
  let oty = match ty_of_string width with
    |None -> loc_err _loc ("enum: unknown width specifier " ^ width)
    |Some (UInt8|UInt16) -> <:ctyp<int>>
    |Some UInt32 -> <:ctyp<int32>>
    |Some UInt64 -> <:ctyp<int64>>
  in
  let decls = tyOr_of_list (List.map (fun (f,_) ->
    <:ctyp< $uid:f$ >>) fields) in
  let getter x = sprintf "int_to_%s" x in
  let setter x = sprintf "%s_to_int" x in
  let printer x = sprintf "%s_to_string" x in
  let parse x = sprintf "string_to_%s" x in
  let ctyo = <:ctyp< option $lid:name$ >> in
  let cty = <:ctyp< $lid:name$ >> in
  <:sig_item<
    type $lid:name$ = [ $decls$ ] ;
    value $lid:getter name$ : $oty$ -> $ctyo$ ;
    value $lid:setter name$ : $cty$ -> $oty$ ;
    value $lid:printer name$ : $cty$ -> string ;
    value $lid:parse name$ : string -> option $cty$ ;
  >>

EXTEND Gram
  GLOBAL: str_item sig_item;

  constr_field: [
    [ fty = LIDENT; fname = LIDENT; sz = OPT [ "["; sz = INT; "]" -> sz ] ->
        parse_field _loc fname fty sz
    ]
  ];

  constr_field_decl: [
    [ field = constr_field -> [field]
    | field = constr_field; ";"; rest = constr_field_decl -> field::rest
    | field = constr_field; ";" -> [field] ]
  ];

  constr_fields: [
    [ "{"; fields = constr_field_decl; "}" -> fields ]
  ];

  constr_enum: [
    [ f = UIDENT -> (f, None)
    | f = UIDENT; "="; i = INT64     -> (f, Some (Int64.of_string i)) 
    | f = UIDENT; "="; i = INT32     -> (f, Some (Int64.of_string i))
    | f = UIDENT; "="; i = NATIVEINT -> (f, Some (Int64.of_string i))
    | f = UIDENT; "="; i = INT       -> (f, Some (Int64.of_string i)) ]
  ];

  constr_enum_decl: [
    [ enum = constr_enum -> [enum]
    | enum = constr_enum; ";"; rest = constr_enum_decl -> enum::rest
    | enum = constr_enum; ";" -> [enum] ]
  ];

  constr_enums: [
    [ "{"; enums = constr_enum_decl; "}" -> enums ]
  ];

  sig_item: [
    [ "cstruct"; name = LIDENT; fields = constr_fields;
      "as"; endian = LIDENT ->
        output_struct_sig _loc (create_struct _loc endian name fields)
    ] |
    [ "cenum"; name = LIDENT; fields = constr_enums;
      "as"; width = LIDENT ->
        let n = ref Int64.minus_one in
        let incr_n () = n := Int64.succ !n in
        let fields =
          List.map (function
            | (f, None)   -> incr_n (); (f, !n)
            | (f, Some i) -> n := i; (f, i)
          ) fields in
        output_enum_sig _loc name fields width
    ]
  ];

  str_item: [
    [ "cstruct"; name = LIDENT; fields = constr_fields;
      "as"; endian = LIDENT ->
	output_struct _loc (create_struct _loc endian name fields)
    ] |
    [ "cenum"; name = LIDENT; fields = constr_enums;
      "as"; width = LIDENT ->
        let n = ref Int64.minus_one in
        let incr_n () = n := Int64.succ !n in
        let fields =
          List.map (function
            | (f, None)   -> incr_n (); (f, !n)
            | (f, Some i) -> n := i; (f, i)
          ) fields in
        output_enum _loc name fields width
    ]
  ];

END
