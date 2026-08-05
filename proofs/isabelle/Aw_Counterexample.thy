(*
  SPDX-FileCopyrightText: 2016 - 2026 Leapsight
  SPDX-License-Identifier: Apache-2.0
*)

theory Aw_Counterexample
  imports Stabilization
begin

section \<open>The scalar frontier does not license folding an observed-remove store\<close>

text \<open>
  This theory mechanizes the license boundary asserted informally in
  @{text "bondy_oplog_crdt_nested_core.erl"} (section
  "@{text "stabilize_fold/2"} --- License boundary --- callers beware"):

  \<^item> a struct field, whose only operation is @{text "put_nested/7"} so that
    no context ever selects among its dots, MAY be folded under HLC
    stability;
  \<^item> an @{text aw_map} / @{text aw_set} key MAY NOT, because a remove
    prepared before certification can carry an HLC above the frontier while
    observing only a prefix of an origin's stable run.

  Both halves are proved below, against the same store representation and
  the same value function --- so the difference is entirely in the
  interpretation, not in the encoding.
\<close>

subsection \<open>Representation\<close>

text \<open>A nested PO-Log at one key: one entry per sub-op, value = the sum of
  the deltas. An association list keeps the counterexample computable.\<close>
type_synonym aw_store = "(dot \<times> int) list"

definition aw_val :: "aw_store \<Rightarrow> int" where
  "aw_val ds = sum_list (map snd ds)"

text \<open>Interpreting a remove --- @{text "drop_observed/2"} in list form: keep
  exactly the dots the writer did NOT observe.\<close>
definition aw_interp :: "event \<Rightarrow> aw_store \<Rightarrow> aw_store" where
  "aw_interp e ds = filter (\<lambda>p. \<not> dot_observed (fst p) (ev_ctx e)) ds"

text \<open>A struct field's only operation appends a sub-op; no context ever
  selects among its dots.\<close>
definition struct_interp :: "event \<Rightarrow> aw_store \<Rightarrow> aw_store" where
  "struct_interp e ds = ds @ [(ev_dot e, 1)]"


subsection \<open>The witness\<close>

definition stable_fr :: hlc where "stable_fr = 30"

definition dot_a :: dot where "dot_a = (1, 1)"
definition dot_b :: dot where "dot_b = (1, 2)"

text \<open>Origin 1's causally stable run at one key: sub-ops at HLC 10 and 20,
  both at or below the frontier 30.\<close>
definition store_unfolded :: aw_store where
  "store_unfolded = [(dot_a, 1), (dot_b, 1)]"

text \<open>What @{text "stabilize_fold/2"} produces: the run collapsed into ONE
  synthetic op, kept at the run's max dot, carrying the folded state.\<close>
definition store_folded :: aw_store where
  "store_folded = [(dot_b, 2)]"

text \<open>A remove PREPARED BEFORE CERTIFICATION. Its context observed only the
  prefix @{text "{(1,1)}"} of the run, yet its HLC is above the frontier ---
  legitimate, because it is concurrent with @{text "(1,2)"} and
  @{text hlc_respects_hb} constrains ordered pairs only.\<close>
definition ctx_prefix :: vv where
  "ctx_prefix = (\<lambda>x. if x = 1 then 1 else 0)"

definition e_rmv :: event where
  "e_rmv = \<lparr> ev_origin = 2, ev_seq = 1, ev_hlc = 40, ev_cell = 0,
             ev_ctx = ctx_prefix \<rparr>"

lemma e_rmv_above_frontier: "stable_fr < ev_hlc e_rmv"
  by (simp add: stable_fr_def e_rmv_def)

text \<open>The fold is value-preserving at the moment it is applied --- it passes
  the check @{text "bondy_oplog_crdt.erl"} states for a @{text "{keep, S'}"}
  reduction, namely that @{text "to_value(State') = to_value(State)"}.\<close>
lemma fold_preserves_value: "aw_val store_folded = aw_val store_unfolded"
  by (simp add: aw_val_def store_folded_def store_unfolded_def)

text \<open>And yet the future remove distinguishes them: unfolded, it drops the
  observed prefix's contribution; folded, that contribution now sits under an
  UNobserved dot and survives.\<close>
lemma rmv_distinguishes:
  "aw_val (aw_interp e_rmv store_folded) \<noteq> aw_val (aw_interp e_rmv store_unfolded)"
  by (simp add: aw_val_def aw_interp_def dot_observed_def e_rmv_def
                ctx_prefix_def store_folded_def store_unfolded_def
                dot_a_def dot_b_def)


subsection \<open>Negative result\<close>

theorem aw_fold_not_sound_above:
  "\<not> sound_above aw_interp aw_val stable_fr (\<lambda>_. store_folded) store_unfolded"
proof
  assume "sound_above aw_interp aw_val stable_fr (\<lambda>_. store_folded) store_unfolded"
  hence "(\<forall>e \<in> set [e_rmv]. stable_fr < ev_hlc e) \<longrightarrow>
         aw_val (fold aw_interp [e_rmv] store_folded)
           = aw_val (fold aw_interp [e_rmv] store_unfolded)"
    unfolding sound_above_def by blast
  hence "aw_val (aw_interp e_rmv store_folded)
           = aw_val (aw_interp e_rmv store_unfolded)"
    using e_rmv_above_frontier by simp
  thus False using rmv_distinguishes by simp
qed

corollary aw_not_governed_above:
  "\<not> governed_above aw_interp aw_val stable_fr"
proof
  assume g: "governed_above aw_interp aw_val stable_fr"
  have "aw_val (aw_interp e_rmv store_folded)
          = aw_val (aw_interp e_rmv store_unfolded)"
    using g e_rmv_above_frontier fold_preserves_value
    unfolding governed_above_def by blast
  thus False using rmv_distinguishes by simp
qed


subsection \<open>Positive result --- the struct field\<close>

lemma struct_governed_above: "governed_above struct_interp aw_val Fr"
  by (auto simp: governed_above_def struct_interp_def aw_val_def)

text \<open>Any value-preserving reduction of a struct field is sound above any
  frontier --- indeed the frontier plays no role, which is the sharpest way
  to state the asymmetry: append-only interpretations never read the context,
  so nothing about future events needs bounding beyond what
  @{text "state_to_op/1"} already preserves.\<close>
theorem struct_fold_sound:
  assumes pres: "aw_val (red s) = aw_val s"
  shows "sound_above struct_interp aw_val Fr red s"
proof (rule hlc_governed_reduction_sound[where obs = aw_val])
  show "governed_above struct_interp aw_val Fr"
    by (rule struct_governed_above)
  show "\<And>u v. aw_val u = aw_val v \<Longrightarrow> aw_val u = aw_val v"
    by simp
  show "aw_val (red s) = aw_val s"
    by (rule pres)
qed

end
