(*
  SPDX-FileCopyrightText: 2016 - 2026 Leapsight
  SPDX-License-Identifier: Apache-2.0
*)

theory Dot_Exactness
  imports Oplog_Model
begin

section \<open>Exactness of the compact version-vector test\<close>

text \<open>
  @{text "bondy_oplog_crdt_aw_core:dot_observed/2"} decides "did the writer
  observe this dot?" with a single comparison, @{text "Ctx[O] >= S"}. The
  moduledoc of @{text "bondy_oplog_crdt_aw_map.erl"} flags why that is not
  obviously exact and then argues it is harmless:

  \<^item> the substrate @{text Seq} is a per-origin GLOBAL sequence, so an
    origin's dots on any ONE cell are sparse (it writes other cells in
    between);
  \<^item> hence @{text "Ctx[O]"}, the max seq of @{text O}'s ops on this cell,
    can be numerically @{text "\<ge> S"} for an @{text "{O, S}"} that never
    touched this cell;
  \<^item> "but that is harmless: it is only ever evaluated against dots actually
    in the cell's dot-store, and for those, FIFO makes it exact".

  This theory turns that argument into a theorem. The sparseness is modelled
  head-on: @{term cell} is an ARBITRARY set of seqs (the ones this origin
  used on this cell), with no contiguity assumed. What per-origin FIFO buys
  is that the observed subset is downward closed WITHIN that set.
\<close>

text \<open>The context entry an origin contributes: the max observed seq, or 0
  when nothing from that origin was observed (the meaning of a missing entry
  in the sparse list --- @{text "lists:keyfind"} returning @{text false}).\<close>
definition ctx_of :: "seq set \<Rightarrow> seq" where
  "ctx_of S = (if S = {} then 0 else Max S)"

text \<open>
  Exactness. Note the hypotheses:

  \<^item> @{term prefix_closed} is per-origin FIFO delivery, stated exactly as
    it is needed: an observed seq drags in every EARLIER seq OF THIS CELL.
    Nothing is assumed about seqs the origin spent on other cells.
  \<^item> @{term pos} is discharged by the substrate: seqs start at 1.
    @{text "bondy_oplog_instance:build_events_fast/6"} computes
    @{text "StartSeq = EndSeq - N + 1"} from @{text "atomics:add_get"} over a
    counter starting at 0, so the first minted seq is 1. Without it the
    encoding of "observed nothing" as 0 would collide with a real dot.
\<close>
theorem compact_test_exact:
  assumes fin:    "finite obs"
      and sub:    "obs \<subseteq> cell"
      and prefix: "\<And>a b. b \<in> obs \<Longrightarrow> a \<in> cell \<Longrightarrow> a \<le> b \<Longrightarrow> a \<in> obs"
      and pos:    "\<And>t. t \<in> cell \<Longrightarrow> 0 < t"
      and s_cell: "s \<in> cell"
    shows "s \<le> ctx_of obs \<longleftrightarrow> s \<in> obs"
proof
  assume le: "s \<le> ctx_of obs"
  show "s \<in> obs"
  proof (cases "obs = {}")
    case True
    hence "ctx_of obs = 0" by (simp add: ctx_of_def)
    with le have "s = 0" by simp
    with pos[OF s_cell] show ?thesis by simp
  next
    case False
    have mem: "Max obs \<in> obs" using fin False by simp
    have "s \<le> Max obs" using le False by (simp add: ctx_of_def)
    thus ?thesis using prefix[OF mem s_cell] by simp
  qed
next
  assume "s \<in> obs"
  thus "s \<le> ctx_of obs" using fin by (auto simp: ctx_of_def)
qed

text \<open>The same statement in the form the code evaluates it.\<close>
corollary dot_observed_exact:
  assumes "finite obs" and "obs \<subseteq> cell"
      and "\<And>a b. b \<in> obs \<Longrightarrow> a \<in> cell \<Longrightarrow> a \<le> b \<Longrightarrow> a \<in> obs"
      and "\<And>t. t \<in> cell \<Longrightarrow> 0 < t"
      and "s \<in> cell"
    shows "dot_observed (x, s) (\<lambda>y. if y = x then ctx_of obs else 0) \<longleftrightarrow> s \<in> obs"
  using compact_test_exact[OF assms]
  by (simp add: dot_observed_def)

text \<open>
  Where the hypotheses bite. @{term prefix_closed} is the ONLY place
  per-origin FIFO is used, and it is used per cell --- which is why the
  sparseness of an origin's seqs across cells costs nothing. Conversely, if
  delivery could skip a seq that this origin spent ON THIS CELL, the
  right-to-left direction still holds but the left-to-right one fails: the
  compact test would report a skipped dot as observed. That is the precise
  obligation the anti-entropy layer owes @{text dot_observed}.
\<close>

end
