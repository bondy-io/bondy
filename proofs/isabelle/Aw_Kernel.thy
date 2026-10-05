(*
  SPDX-FileCopyrightText: 2016 - 2026 Leapsight
  SPDX-License-Identifier: Apache-2.0
*)

theory Aw_Kernel
  imports Oplog_Model "CRDT.ORSet"
begin

section \<open>Dotted kernels under re-delivery\<close>

text \<open>
  A cell kernel whose state carries a causal context that grows by exactly the
  context and the dot of each operation it applies: the kernels that declare
  @{text "dotted_context/0"}, each built on
  @{text "bondy_oplog_crdt_aw_core:cc_absorb/3"}. The substrate folds a cell's
  events causally and, as the AFP network model assumes, at most once; a fold
  that sees an event again breaks the second hypothesis.

  @{text "guarded"} is @{text "bondy_oplog_cell_kernel:apply/6"}'s
  guard: an operation whose dot the context already covers is skipped. Under
  any delivery it makes re-delivery a no-op
  (@{text "dotted_kernel.guarded_redelivery_noop"}); on causal, at-most-once,
  per-origin FIFO delivery it never fires
  (@{text "dotted_kernel.guarded_eq_step"}); and it needs causal delivery
  (@{text "guard_needs_causal_delivery"}), which a hold provides when it folds
  nothing ahead of what it observed (@{text "causal_hold_delivers_causally"}).

  The instance is one @{text "aw_set"} / @{text "aw_map"} cell: per key a
  dot-store and the cell context, with @{text "nested_core:put/5"},
  @{text "put_nested/7"} and @{text "rmv/3"}. Without the guard a re-delivered
  add restores a removed key (@{text "shipped_redelivery_resurrects"}); per key
  each step is the AFP @{text "ORSet"} interpretation (@{text "put_is_orset"}).
\<close>

subsection \<open>Contexts\<close>

text \<open>The version vector of one dot, as @{text "cc_absorb/3"} merges it.\<close>
definition single :: "dot \<Rightarrow> vv" where
  "single d = (\<lambda>p. if p = fst d then snd d else 0)"

text \<open>@{text "bondy_oplog_crdt_aw_core:cc_absorb/3"}.\<close>
definition absorb :: "vv \<Rightarrow> vv \<Rightarrow> dot \<Rightarrow> vv" where
  "absorb cc c d = vv_merge (vv_merge cc c) (single d)"

lemma dot_observed_vv_merge [simp]:
  "dot_observed d (vv_merge a b) \<longleftrightarrow> dot_observed d a \<or> dot_observed d b"
  by (auto simp: dot_observed_def vv_merge_def)

lemma dot_observed_single [simp]:
  "dot_observed x (single d) \<longleftrightarrow> fst x = fst d \<and> snd x \<le> snd d \<or> snd x = 0"
  by (auto simp: dot_observed_def single_def)

lemma dot_observed_absorb:
  "dot_observed x (absorb cc c d) \<longleftrightarrow>
   dot_observed x cc \<or> dot_observed x c \<or> dot_observed x (single d)"
  by (simp add: absorb_def)


subsection \<open>Causal, at-most-once delivery\<close>

text \<open>An operation @{text "x"} observes @{text "y"} when its context or its own
  dot covers @{text "y"}'s dot; @{const single} covers every lower seq of the
  same origin.\<close>
definition obs :: "('o \<Rightarrow> dot) \<Rightarrow> ('o \<Rightarrow> vv) \<Rightarrow> 'o \<Rightarrow> 'o \<Rightarrow> bool" where
  "obs odot octx x y \<longleftrightarrow>
     dot_observed (odot y) (octx x) \<or> dot_observed (odot y) (single (odot x))"

text \<open>The substrate's hypotheses for one cell's delivery order: no operation
  is delivered after one that observed it. Its context observing it is causal
  delivery (H2 of @{theory Bondy_Stabilization.Oplog_Model}); its own dot
  observing it is per-origin FIFO with no re-delivery. Seqs start at 1; seq 0
  is covered by every context.\<close>
definition causal_fresh :: "('o \<Rightarrow> dot) \<Rightarrow> ('o \<Rightarrow> vv) \<Rightarrow> 'o list \<Rightarrow> bool" where
  "causal_fresh odot octx xs \<longleftrightarrow>
     (\<forall>y \<in> set xs. 0 < snd (odot y)) \<and>
     (\<forall>i j. i < j \<and> j < length xs \<longrightarrow> \<not> obs odot octx (xs ! i) (xs ! j))"

lemma causal_fresh_butlast:
  assumes "causal_fresh odot octx (xs @ [x])"
  shows "causal_fresh odot octx xs"
  unfolding causal_fresh_def
proof (intro conjI allI impI)
  show "\<forall>y \<in> set xs. 0 < snd (odot y)"
    using assms by (simp add: causal_fresh_def)
next
  fix i j assume ij: "i < j \<and> j < length xs"
  then have "i < j \<and> j < length (xs @ [x])" by simp
  then have "\<not> obs odot octx ((xs @ [x]) ! i) ((xs @ [x]) ! j)"
    using assms unfolding causal_fresh_def by blast
  then show "\<not> obs odot octx (xs ! i) (xs ! j)"
    using ij by (simp add: nth_append)
qed

lemma causal_fresh_last:
  assumes "causal_fresh odot octx (xs @ [x])" "y \<in> set xs"
  shows "\<not> obs odot octx y x"
proof -
  obtain i where i: "i < length xs" "xs ! i = y"
    using assms(2) by (meson in_set_conv_nth)
  have "(xs @ [x]) ! i = y" "(xs @ [x]) ! length xs = x"
    using i by (simp_all add: nth_append)
  then show ?thesis
    using assms(1) i unfolding causal_fresh_def
    by (metis length_append_singleton lessI)
qed

lemma causal_fresh_append:
  assumes "causal_fresh odot octx xs" "causal_fresh odot octx ys"
    and "\<forall>x \<in> set xs. \<forall>y \<in> set ys. \<not> obs odot octx x y"
  shows "causal_fresh odot octx (xs @ ys)"
  unfolding causal_fresh_def
proof (intro conjI allI impI)
  show "\<forall>y \<in> set (xs @ ys). 0 < snd (odot y)"
    using assms(1,2) by (auto simp: causal_fresh_def)
next
  fix i j assume ij: "i < j \<and> j < length (xs @ ys)"
  show "\<not> obs odot octx ((xs @ ys) ! i) ((xs @ ys) ! j)"
  proof (cases "j < length xs")
    case True
    then show ?thesis
      using ij assms(1) by (auto simp: causal_fresh_def nth_append)
  next
    case jy: False
    show ?thesis
    proof (cases "i < length xs")
      case True
      then show ?thesis
        using ij jy assms(3) by (auto simp: nth_append)
    next
      case False
      have "i - length xs < j - length xs" "j - length xs < length ys"
        using False ij jy by auto
      then have "\<not> obs odot octx (ys ! (i - length xs)) (ys ! (j - length xs))"
        using assms(2) by (auto simp: causal_fresh_def)
      then show ?thesis
        using False jy by (simp add: nth_append)
    qed
  qed
qed


subsection \<open>The guard\<close>

locale dotted_kernel =
  fixes step :: "'o \<Rightarrow> 's \<Rightarrow> 's"
    and cc :: "'s \<Rightarrow> vv"
    and odot :: "'o \<Rightarrow> dot"
    and octx :: "'o \<Rightarrow> vv"
  assumes cc_step:
    "dot_observed d (cc (step x s)) \<longleftrightarrow>
     dot_observed d (cc s) \<or> dot_observed d (octx x) \<or> dot_observed d (single (odot x))"
begin

definition guarded :: "'o \<Rightarrow> 's \<Rightarrow> 's" where
  "guarded x s = (if dot_observed (odot x) (cc s) then s else step x s)"

definition run :: "('o \<Rightarrow> 's \<Rightarrow> 's) \<Rightarrow> 'o list \<Rightarrow> 's \<Rightarrow> 's" where
  "run f xs s = foldl (\<lambda>s x. f x s) s xs"

lemma run_simps [simp]:
  "run f [] s = s"
  "run f (x # xs) s = run f xs (f x s)"
  "run f (xs @ ys) s = run f ys (run f xs s)"
  by (simp_all add: run_def)

lemma guarded_mono:
  "dot_observed d (cc s) \<Longrightarrow> dot_observed d (cc (guarded x s))"
  by (simp add: guarded_def cc_step)

lemma guarded_covers: "dot_observed (odot x) (cc (guarded x s))"
  unfolding guarded_def by (simp add: cc_step)

lemma run_guarded_mono:
  "dot_observed d (cc s) \<Longrightarrow> dot_observed d (cc (run guarded xs s))"
  by (induction xs arbitrary: s) (auto intro: guarded_mono)

theorem guarded_redelivery_noop:
  assumes "x \<in> set xs"
  shows "guarded x (run guarded xs s) = run guarded xs s"
proof -
  obtain ys zs where "xs = ys @ x # zs"
    using assms by (meson split_list)
  moreover have "dot_observed (odot x) (cc (run guarded zs (guarded x (run guarded ys s))))"
    using run_guarded_mono guarded_covers by blast
  ultimately show ?thesis
    by (simp add: guarded_def)
qed

lemma cc_run_step:
  "dot_observed d (cc (run step xs s)) \<longleftrightarrow>
   dot_observed d (cc s) \<or> (\<exists>y \<in> set xs. dot_observed d (octx y) \<or> dot_observed d (single (odot y)))"
  by (induction xs arbitrary: s) (auto simp: cc_step)

theorem guarded_eq_step:
  assumes "causal_fresh odot octx xs" "cc s = (\<lambda>_. 0)"
  shows "run guarded xs s = run step xs s"
  using assms
proof (induction xs rule: rev_induct)
  case Nil then show ?case by simp
next
  case (snoc x xs)
  have ih: "run guarded xs s = run step xs s"
    using snoc.IH[OF causal_fresh_butlast[OF snoc.prems(1)] snoc.prems(2)] .
  have "0 < snd (odot x)"
    using snoc.prems(1) by (simp add: causal_fresh_def)
  then have "\<not> dot_observed (odot x) (cc s)"
    using snoc.prems(2) by (simp add: dot_observed_def)
  then have unseen: "\<not> dot_observed (odot x) (cc (run step xs s))"
    using cc_run_step causal_fresh_last[OF snoc.prems(1)] by (auto simp: obs_def)
  have "run guarded (xs @ [x]) s = guarded x (run step xs s)"
    using ih by (simp only: run_simps)
  also have "\<dots> = step x (run step xs s)"
    using unseen by (simp add: guarded_def)
  finally show ?case by (simp only: run_simps)
qed

end


subsection \<open>A causal hold delivers causally\<close>

text \<open>The replay folds a batch at a time, in key order, holding what it
  cannot fold yet. The hold delivers causally when each batch folds only
  events whose context observes nothing beyond what is applied or folding in
  that batch. With per-origin tops @{text "tp"}: every context entry of a
  folded event is at most the top, and every event folded in a later batch is
  above its origin's top. Key order respects happens-before (H3 of
  @{theory Bondy_Stabilization.Oplog_Model}, discharged by
  @{text "Hlc.thy"}), which orders a batch.\<close>

lemma sorted_batch_causal:
  fixes key :: "'o \<Rightarrow> 'a :: linorder"
  assumes "sorted (map key b)" "distinct (map odot b)"
    and "\<forall>y \<in> set b. 0 < snd (odot y)"
    and h3: "\<forall>x \<in> set b. \<forall>y \<in> set b.
               odot x \<noteq> odot y \<and> obs odot octx x y \<longrightarrow> key y < key x"
  shows "causal_fresh odot octx b"
  unfolding causal_fresh_def
proof (intro conjI allI impI)
  show "\<forall>y \<in> set b. 0 < snd (odot y)" using assms(3) .
next
  fix i j assume ij: "i < j \<and> j < length b"
  have le: "key (b ! i) \<le> key (b ! j)"
    using assms(1) ij by (simp add: sorted_iff_nth_mono)
  have ne: "odot (b ! i) \<noteq> odot (b ! j)"
    using assms(2) ij by (auto simp: distinct_conv_nth)
  show "\<not> obs odot octx (b ! i) (b ! j)"
    using h3 le ne ij by (meson leD nth_mem order.strict_trans)
qed

text \<open>The hold's rule, per batch: what a folded event observes is within
  the tops, and what folds later is above them.\<close>
lemma tops_separate:
  assumes ctx: "\<forall>x \<in> set xs. \<forall>p. octx x p \<le> tp p"
    and own: "\<forall>x \<in> set xs. snd (odot x) \<le> tp (fst (odot x))"
    and later: "\<forall>y \<in> set ys. tp (fst (odot y)) < snd (odot y)"
  shows "\<forall>x \<in> set xs. \<forall>y \<in> set ys. \<not> obs odot octx x y"
proof (intro ballI)
  fix x y assume x: "x \<in> set xs" and y: "y \<in> set ys"
  have lt: "tp (fst (odot y)) < snd (odot y)" using later y by blast
  have "\<not> dot_observed (odot y) (octx x)"
    using ctx x lt by (simp add: dot_observed_def) (meson leD order.strict_trans1)
  moreover have "\<not> dot_observed (odot y) (single (odot x))"
  proof
    assume o: "dot_observed (odot y) (single (odot x))"
    have le: "snd (odot x) \<le> tp (fst (odot x))" using own x by blast
    show False
      using o lt le by (auto simp: dot_observed_single)
  qed
  ultimately show "\<not> obs odot octx x y" by (simp add: obs_def)
qed

text \<open>A schedule of batches, each folded in key order and separated from
  every later batch by its tops, is causal, so the guard never fires on it
  (@{text "dotted_kernel.guarded_eq_step"}).\<close>
theorem causal_hold_delivers_causally:
  fixes key :: "'o \<Rightarrow> 'a :: linorder"
  assumes "distinct (map odot (concat bs))"
    and "\<forall>y \<in> set (concat bs). 0 < snd (odot y)"
    and "\<forall>x \<in> set (concat bs). \<forall>y \<in> set (concat bs).
           odot x \<noteq> odot y \<and> obs odot octx x y \<longrightarrow> key y < key x"
    and "\<forall>b \<in> set bs. sorted (map key b)"
    and "\<forall>k < length bs. \<exists>tp.
           (\<forall>x \<in> set (bs ! k). (\<forall>p. octx x p \<le> tp p) \<and>
                               snd (odot x) \<le> tp (fst (odot x))) \<and>
           (\<forall>y \<in> set (concat (drop (Suc k) bs)). tp (fst (odot y)) < snd (odot y))"
  shows "causal_fresh odot octx (concat bs)"
  using assms
proof (induction bs)
  case Nil then show ?case by (simp add: causal_fresh_def)
next
  case (Cons b bs)
  have tail: "causal_fresh odot octx (concat bs)"
  proof (rule Cons.IH)
    show "\<forall>k < length bs. \<exists>tp.
           (\<forall>x \<in> set (bs ! k). (\<forall>p. octx x p \<le> tp p) \<and>
                               snd (odot x) \<le> tp (fst (odot x))) \<and>
           (\<forall>y \<in> set (concat (drop (Suc k) bs)). tp (fst (odot y)) < snd (odot y))"
    proof (intro allI impI)
      fix k assume "k < length bs"
      then show "\<exists>tp.
           (\<forall>x \<in> set (bs ! k). (\<forall>p. octx x p \<le> tp p) \<and>
                               snd (odot x) \<le> tp (fst (odot x))) \<and>
           (\<forall>y \<in> set (concat (drop (Suc k) bs)). tp (fst (odot y)) < snd (odot y))"
        using Cons.prems(5)[rule_format, of "Suc k"] by simp
    qed
  qed (use Cons.prems in auto)
  have head: "causal_fresh odot octx b"
    using Cons.prems(1-4)
    by (intro sorted_batch_causal[where key = key]) auto
  obtain tp where
    t: "\<forall>x \<in> set b. (\<forall>p. octx x p \<le> tp p) \<and> snd (odot x) \<le> tp (fst (odot x))"
       "\<forall>y \<in> set (concat bs). tp (fst (odot y)) < snd (odot y)"
    using Cons.prems(5)[rule_format, of 0] by auto
  have "\<forall>x \<in> set b. \<forall>y \<in> set (concat bs). \<not> obs odot octx x y"
    using t by (intro tops_separate) auto
  then show ?case
    using causal_fresh_append[OF head tail] by simp
qed


section \<open>The observed-remove cell\<close>

datatype ('k, 'v) kop = Put dot vv 'k 'v | PutN dot vv 'k 'v | Rmv dot vv 'k

type_synonym ('k, 'v) cstate = "('k \<Rightarrow> (dot \<rightharpoonup> 'v)) \<times> vv"

fun kop_dot :: "('k, 'v) kop \<Rightarrow> dot" where
  "kop_dot (Put d c k v) = d"
| "kop_dot (PutN d c k v) = d"
| "kop_dot (Rmv d c k) = d"

fun kop_ctx :: "('k, 'v) kop \<Rightarrow> vv" where
  "kop_ctx (Put d c k v) = c"
| "kop_ctx (PutN d c k v) = c"
| "kop_ctx (Rmv d c k) = c"

text \<open>@{text "nested_core:put/5"}, @{text "put_nested/7"} (its dot added
  without the observed drop) and @{text "rmv/3"}, each with
  @{text "cc_absorb/3"}.\<close>
fun step_shipped :: "('k, 'v) kop \<Rightarrow> ('k, 'v) cstate \<Rightarrow> ('k, 'v) cstate" where
  "step_shipped (Put d c k v) (E, cc) =
     (E(k := (drop_observed (E k) c)(d \<mapsto> v)), absorb cc c d)"
| "step_shipped (PutN d c k v) (E, cc) = (E(k := (E k)(d \<mapsto> v)), absorb cc c d)"
| "step_shipped (Rmv d c k) (E, cc) = (E(k := drop_observed (E k) c), absorb cc c d)"

interpretation aw: dotted_kernel step_shipped snd kop_dot kop_ctx
proof
  fix d x and s :: "('k, 'v) cstate"
  show "dot_observed d (snd (step_shipped x s)) \<longleftrightarrow>
        dot_observed d (snd s) \<or> dot_observed d (kop_ctx x) \<or>
        dot_observed d (single (kop_dot x))"
    by (cases s; cases x) (simp_all add: dot_observed_absorb)
qed

definition empty_cell :: "('k, 'v) cstate" where
  "empty_cell = (\<lambda>_. Map.empty, \<lambda>_. 0)"

subsection \<open>Without the guard a re-delivered add restores a removed key\<close>

abbreviation ex_add :: "(nat, nat) kop" where
  "ex_add \<equiv> Put (1, 1) (\<lambda>_. 0) 0 0"

abbreviation ex_rmv :: "(nat, nat) kop" where
  "ex_rmv \<equiv> Rmv (2, 1) (single (1, 1)) 0"

theorem shipped_redelivery_resurrects:
  "fst (aw.run step_shipped [ex_add, ex_rmv] empty_cell) 0 = Map.empty"
  "fst (aw.run step_shipped [ex_add, ex_rmv, ex_add] empty_cell) 0 (1, 1) = Some 0"
  "fst (aw.run aw.guarded [ex_add, ex_rmv, ex_add] empty_cell) 0 = Map.empty"
  by (auto simp: empty_cell_def drop_observed_def dot_observed_def absorb_def
                 single_def vv_merge_def aw.guarded_def fun_eq_iff)

subsection \<open>The guard needs causal delivery\<close>

text \<open>Origin 2 adds key 1 having seen origin 1's add of key 0, and a hold
  folds it first. The guard then skips the add of key 0 as already seen; the
  unguarded kernel keeps it.\<close>

abbreviation ex_dep :: "(nat, nat) kop" where
  "ex_dep \<equiv> Put (2, 1) (single (1, 1)) 1 1"

theorem guard_needs_causal_delivery:
  "\<not> causal_fresh kop_dot kop_ctx [ex_dep, ex_add]"
  "fst (aw.run aw.guarded [ex_dep, ex_add] empty_cell) 0 = Map.empty"
  "fst (aw.run step_shipped [ex_dep, ex_add] empty_cell) 0 (1, 1) = Some 0"
  by (auto simp: causal_fresh_def obs_def empty_cell_def drop_observed_def
                 dot_observed_def absorb_def single_def vv_merge_def
                 aw.guarded_def nth_Cons')

subsection \<open>Per key, a step is the AFP ORSet's interpretation\<close>

text \<open>Viewed through the dots it holds per key, a put is the
  @{theory CRDT.ORSet} removal of the dots its context observed followed by the
  add of its own dot, a nested put is the add alone, and a remove is that
  removal alone.\<close>

definition observed_dots :: "(dot \<rightharpoonup> 'v) \<Rightarrow> vv \<Rightarrow> dot set" where
  "observed_dots ds c = {x \<in> dom ds. dot_observed x c}"

definition dots :: "('k, 'v) cstate \<Rightarrow> 'k \<Rightarrow> dot set" where
  "dots s k = dom (fst s k)"

theorem put_is_orset:
  "Some (dots (step_shipped (Put d c k v) s)) =
     (ORSet.interpret_op (Rem (observed_dots (fst s k) c) k) \<rhd>
      ORSet.interpret_op (Add d k)) (dots s)"
  by (cases s)
     (auto simp: dots_def observed_dots_def interpret_op_def op_elem_def
                 kleisli_def drop_observed_dom fun_eq_iff)

theorem putn_is_orset:
  "Some (dots (step_shipped (PutN d c k v) s)) =
     ORSet.interpret_op (Add d k) (dots s)"
  by (cases s)
     (auto simp: dots_def interpret_op_def op_elem_def fun_eq_iff)

theorem rmv_is_orset:
  "Some (dots (step_shipped (Rmv d c k) s)) =
     ORSet.interpret_op (Rem (observed_dots (fst s k) c) k) (dots s)"
  by (cases s)
     (auto simp: dots_def observed_dots_def interpret_op_def op_elem_def
                 drop_observed_dom fun_eq_iff)

end
