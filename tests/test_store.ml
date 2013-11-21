(*
 * Copyright (c) 2013 Thomas Gazagnaire <thomas@gazagnaire.org>
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

open OUnit
open Test_common
open Lwt

let debug fmt =
  IrminLog.debug "TEST-STORE" fmt

type t = {
  name : string;
  init : unit -> unit Lwt.t;
  clean: unit -> unit Lwt.t;
  store: (module Irmin.S);
}

let unit () =
  return_unit

module Make (S: Irmin.S) = struct

  module Common = Make(S)
  open Common
  open S

  let v1 = Value.of_bytes "foo"
  let v2 = Value.of_bytes ""
  let k1 = key v1
  let k2 = key v2
  let t1 = Tag.of_string "foo"
  let t2 = Tag.of_string "bar"

  let run x test =
    try Lwt_unix.run (x.init () >>= test >>= x.clean)
    with e ->
      Lwt_unix.run (x.clean ());
      raise e

  let test_values x () =
    let test () =
      create ()             >>= fun t    ->
      Value.add t.value v1  >>= fun k1'  ->
      assert_key_equal "k1" k1 k1';
      Value.add t.value v1  >>= fun k1'' ->
      assert_key_equal "k1" k1 k1'';
      Value.add t.value v2  >>= fun k2'  ->
      assert_key_equal "k2" k2 k2';
      Value.add t.value v2  >>= fun k2'' ->
      assert_key_equal "k2" k2 k2'';
      Value.read t.value k1 >>= fun v1'  ->
      assert_value_opt_equal "v1" (Some v1) v1';
      Value.read t.value k2 >>= fun v2'  ->
      assert_value_opt_equal "v2" (Some v2) v2';
      return_unit
    in
    run x test

  let test_trees x () =
    let test () =
      create () >>= fun t  ->

      (* Create a node containing t1(v1) *)
      Tree.tree t.tree ~value:v1 [] >>= fun k1  ->
      Tree.tree t.tree ~value:v1 [] >>= fun k1' ->
      assert_key_equal "k1.1" k1 k1';
      Tree.read_exn t.tree k1       >>= fun t1  ->
      Tree.add t.tree t1            >>= fun k1''->
      assert_key_equal "k1.2" k1 k1'';

      (* Create the tree  t2 -b-> t1(v1) *)
      Tree.tree t.tree ["b", t1]    >>= fun k2  ->
      Tree.tree t.tree ["b", t1]    >>= fun k2' ->
      assert_key_equal "k2.1" k2 k2';
      Tree.read_exn t.tree k2       >>= fun t2  ->
      Tree.add t.tree t2            >>= fun k2''->
      assert_key_equal "k2.2" k2 k2'';
      Tree.sub_exn t.tree t2 ["b"]  >>= fun t1' ->
      assert_tree_equal "t1.1" t1 t1';
      Tree.add t.tree t1'           >>= fun k1''->
      assert_key_equal "k1.3" k1 k1'';

      (* Create the tree t3 -a-> t2 -b-> t1(v1) *)
      Tree.tree t.tree ["a", t2]    >>= fun k3  ->
      Tree.tree t.tree ["a", t2]    >>= fun k3' ->
      assert_key_equal "k3.1" k3 k3';
      Tree.read_exn t.tree k3       >>= fun t3  ->
      Tree.add t.tree t3            >>= fun k3''->
      assert_key_equal "k3.2" k3 k3'';
      Tree.sub_exn t.tree t3 ["a"]  >>= fun t2' ->
      assert_tree_equal "t2.1" t2 t2';
      Tree.add t.tree t2'           >>= fun k2''->
      assert_key_equal "k2.3" k2 k2'';
      Tree.sub_exn t.tree t2' ["b"]     >>= fun t1' ->
      assert_tree_equal "t1.2" t1 t1';
      Tree.sub t.tree t3 ["a";"b"]  >>= fun t1' ->
      assert_tree_opt_equal "t1.3" (Some t1) t1';

      Tree.find t.tree t1 []        >>= fun v11 ->
      assert_value_opt_equal "v1.1" (Some v1) v11;
      Tree.find t.tree t2 ["b"]     >>= fun v12 ->
      assert_value_opt_equal "v1.2" (Some v1) v12;
      Tree.find t.tree t3 ["a";"b"] >>= fun v13 ->
      assert_value_opt_equal "v1" (Some v1) v13;

      (* Create the tree t6 -a-> t5 -b-> t1(v1)
                                   \-c-> t4(v2) *)
      Tree.tree t.tree ~value:v2 []         >>= fun k4  ->
      Tree.read_exn t.tree k4               >>= fun t4  ->
      Tree.tree t.tree [("b",t1); ("c",t4)] >>= fun k5  ->
      Tree.read_exn t.tree k5               >>= fun t5  ->
      Tree.tree t.tree ["a",t5]             >>= fun k6  ->
      Tree.read_exn t.tree k6               >>= fun t6  ->
      Tree.update t.tree t3 ["a";"c"] v2    >>= fun t6' ->
      assert_tree_equal "tree" t6 t6';

      return_unit
    in
    run x test

  let test_revisions x () =
    let test () =
      create () >>= fun t   ->

      (* t3 -a-> t2 -b-> t1(v1) *)
      Tree.tree t.tree ~value:v1 [] >>= fun k1  ->
      Tree.read_exn t.tree k1       >>= fun t1  ->
      Tree.tree t.tree ["a", t1]    >>= fun k2  ->
      Tree.read_exn t.tree k2       >>= fun t2  ->
      Tree.tree t.tree ["b", t2]    >>= fun k3  ->
      Tree.read_exn t.tree k3       >>= fun t3  ->

      (* r1 : t2 *)
      Revision.revision t.revision ~tree:t2 [] >>= fun kr1 ->
      Revision.revision t.revision ~tree:t2 [] >>= fun kr1'->
      assert_key_equal "kr1" kr1 kr1';
      Revision.read_exn t.revision kr1         >>= fun r1  ->

      (* r1 -> r2 : t3 *)
      Revision.revision t.revision ~tree:t3 [r1] >>= fun kr2  ->
      Revision.revision t.revision ~tree:t3 [r1] >>= fun kr2' ->
      assert_key_equal "kr2" kr2 kr2';
      Revision.read_exn t.revision kr2           >>= fun r2   ->

      Revision.list t.revision kr1 >>= fun kr1s ->
      assert_keys_equal "g1" [kr1] kr1s;

      Revision.list t.revision kr2 >>= fun kr2s ->
      assert_keys_equal "g2" [kr1; kr2] kr2s;

     return_unit
    in
    run x test

  let test_tags x () =
    let test () =
      create ()              >>= fun t   ->
      Tag.update t.tag t1 k1 >>= fun ()  ->
      Tag.read   t.tag t1    >>= fun k1' ->
      assert_key_opt_equal "t1" (Some k1) k1';
      Tag.update t.tag t2 k2 >>= fun ()  ->
      Tag.read   t.tag t2    >>= fun k2' ->
      assert_key_opt_equal "t2" (Some k2) k2';
      Tag.update t.tag t1 k2 >>= fun ()   ->
      Tag.read   t.tag t1    >>= fun k2'' ->
      assert_key_opt_equal "t1-after-update" (Some k2) k2'';
      Tag.list   t.tag t1    >>= fun ts ->
      assert_tags_equal "list" [t1; t2] ts;
      Tag.remove t.tag t1    >>= fun () ->
      Tag.read   t.tag t1    >>= fun empty ->
      assert_key_opt_equal "empty" None empty;
      Tag.list   t.tag t1    >>= fun t2' ->
      assert_tags_equal "all-after-remove" [t2] t2';
      return_unit
    in
    run x test

  let test_stores x () =
    let test () =
      create ()             >>= fun t   ->
      update t ["a";"b"] v1 >>= fun ()  ->

      mem t ["a";"b"]       >>= fun b1  ->
      assert_bool_equal "mem1" true b1;
      mem t ["a"]           >>= fun b2  ->
      assert_bool_equal "mem2" false b2;
      read_exn t ["a";"b"]  >>= fun v1' ->
      assert_value_equal "v1.1" v1 v1';
      snapshot t            >>= fun r1  ->

      dump t "before" >>= fun () ->
      update t ["a";"c"] v2 >>= fun ()  ->
      dump t "after" >>= fun () ->
      mem t ["a";"b"]       >>= fun b1  ->
      assert_bool_equal "mem3" true b1;
      mem t ["a"]           >>= fun b2  ->
      assert_bool_equal "mem4" false b2;
      read_exn t ["a";"b"]  >>= fun v1' ->
      assert_value_equal "v1.1" v1 v1';
      mem t ["a";"c"]       >>= fun b1  ->
      assert_bool_equal "mem5" true b1;
      read_exn t ["a";"c"]  >>= fun v2' ->
      assert_value_equal "v1.1" v2 v2';

      remove t ["a";"b"]    >>= fun ()  ->
      read t ["a";"b"]      >>= fun v1''->
      assert_value_opt_equal "v1.2" None v1'';
      revert t r1           >>= fun ()  ->
      read t ["a";"b"]      >>= fun v1''->
      assert_value_opt_equal "v1.3" (Some v1) v1'';
      list t ["a"]          >>= fun ks  ->
      assert_paths_equal "path" [["a";"b"]] ks;
      return_unit
    in
    run x test

  let test_sync x () =
    let test () =
      create ()              >>= fun t1 ->
      update t1 ["a";"b"] v1 >>= fun () ->
      snapshot t1            >>= fun r1 ->
      update t1 ["a";"c"] v2 >>= fun () ->
      snapshot t1            >>= fun r2 ->
      update t1 ["a";"d"] v1 >>= fun () ->
      snapshot t1            >>= fun r3 ->
      Raw.export t1          >>= fun xx ->

      (* Restart a fresh store and import everything in there. *)
      x.clean ()             >>= fun () ->
      x.init ()              >>= fun () ->
      create ()              >>= fun t2 ->

      Raw.import t2 xx       >>= fun () ->
      revert t2 r3           >>= fun () ->

      mem t2 ["a";"b"]       >>= fun b1 ->
      assert_bool_equal "mem-ab" true b1;

      mem t2 ["a";"c"]       >>= fun b2 ->
      assert_bool_equal "mem-ac" true b2;

      mem t2 ["a";"d"]       >>= fun b3  ->
      assert_bool_equal "mem-ad" true b3;
      read_exn t2 ["a";"d"]  >>= fun v1' ->
      assert_value_equal "v1" v1' v1;

      revert t2 r2           >>= fun () ->
      mem t2 ["a";"d"]       >>= fun b4 ->
      assert_bool_equal "mem-ab" false b4;

      return_unit in
    run x test

end

let suite (speed, x) =
  let (module S) = x.store in
  let module T = Make(S) in
  x.name,
  [
    "Basic operations on values"      , speed, T.test_values    x;
    "Basic operations on trees"       , speed, T.test_trees     x;
    "Basic operations on revisions"   , speed, T.test_revisions x;
    "Basic operations on tags"        , speed, T.test_tags      x;
    "High-level store operations"     , speed, T.test_stores    x;
    "High-level store synchronisation", speed, T.test_sync      x;
  ]

let run name tl =
  let tl = List.map suite tl in
  Alcotest.run name tl