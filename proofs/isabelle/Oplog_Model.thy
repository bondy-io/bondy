(*
  SPDX-FileCopyrightText: 2016 - 2026 Leapsight
  SPDX-License-Identifier: Apache-2.0
*)

theory Oplog_Model
  imports Main
begin

section \<open>A model of the bondy_db oplog substrate\<close>

text \<open>
  This theory models just enough of the substrate to state and prove the
  claim made informally in @{text "bondy_oplog_applier.erl"} (THE PREPARE
  FENCE): that invariants I1 and I2 together recover causal stability in an
  anti-entropy architecture with no causal broadcast layer.

  Deliberately NOT modelled: the Merkle search tree itself, compaction,
  WAL durability, the projection/overlay, network failure. The MST enters
  only through the containment predicate it is used to decide.
\<close>

subsection \<open>Basic types\<close>

type_synonym origin  = nat
type_synonym seq     = nat
type_synonym hlc     = nat
type_synonym cell    = nat
type_synonym replica = nat

text \<open>A dot is the unique identity of an operation, taken from its event
  key --- @{text "bondy_oplog_crdt_aw_core:dot_of/1"}.\<close>
type_synonym dot = "origin \<times> seq"

text \<open>A causal context is a version vector. Modelled as a total function
  with default 0, which is the meaning of a missing entry in the sparse
  list representation @{text "bondy_dvvset:vector()"}.\<close>
type_synonym vv = "origin \<Rightarrow> seq"

text \<open>An event carries its dot, its HLC, the cell it targets, and the
  causal context stamped at its origin at PREPARE time.\<close>
record event =
  ev_origin :: origin
  ev_seq    :: seq
  ev_hlc    :: hlc
  ev_cell   :: cell
  ev_ctx    :: vv

definition ev_dot :: "event \<Rightarrow> dot" where
  "ev_dot e = (ev_origin e, ev_seq e)"


subsection \<open>Observed-remove primitives\<close>

text \<open>@{text "bondy_oplog_crdt_aw_core:dot_observed/2"} --- exact under
  per-origin FIFO delivery.\<close>
definition dot_observed :: "dot \<Rightarrow> vv \<Rightarrow> bool" where
  "dot_observed d ctx \<longleftrightarrow> snd d \<le> ctx (fst d)"

text \<open>@{text "bondy_oplog_crdt_aw_core:drop_observed/2"}.\<close>
definition drop_observed :: "(dot \<rightharpoonup> 'v) \<Rightarrow> vv \<Rightarrow> (dot \<rightharpoonup> 'v)" where
  "drop_observed ds ctx = (\<lambda>d. if dot_observed d ctx then None else ds d)"

lemma drop_observed_dom:
  "dom (drop_observed ds ctx) = {d \<in> dom ds. \<not> dot_observed d ctx}"
  by (auto simp: drop_observed_def dom_def split: if_splits)

text \<open>@{text "bondy_oplog_crdt_aw_core:vv_merge/2"} --- pointwise max.\<close>
definition vv_merge :: "vv \<Rightarrow> vv \<Rightarrow> vv" where
  "vv_merge a b = (\<lambda>x. max (a x) (b x))"

lemma vv_merge_mono: "a x \<le> vv_merge a b x"
  by (simp add: vv_merge_def)


subsection \<open>Happens-before, and the substrate invariants it rests on\<close>

text \<open>@{text "hb f e"}: e's stamped context observed f's dot, i.e. f is in
  e's causal past.\<close>
definition hb :: "event \<Rightarrow> event \<Rightarrow> bool" where
  "hb f e \<longleftrightarrow> dot_observed (ev_dot f) (ev_ctx e)"

text \<open>H1 --- origin uniqueness. No two replicas mint dots under the same
  origin (@{text "bondy_oplog_crdt_aw_map.erl"}, convergence precondition 1).\<close>
definition origin_unique :: "event set \<Rightarrow> bool" where
  "origin_unique E \<longleftrightarrow> (\<forall>e\<in>E. \<forall>f\<in>E. ev_dot e = ev_dot f \<longrightarrow> e = f)"

text \<open>H2 --- causal delivery (precondition 2). Substrate-provided, not
  enforced by the CRDT modules.\<close>
definition causal_delivery :: "event set \<Rightarrow> (replica \<Rightarrow> event set) \<Rightarrow> bool" where
  "causal_delivery E D \<longleftrightarrow> (\<forall>r. \<forall>e \<in> D r. \<forall>f \<in> E. hb f e \<longrightarrow> f \<in> D r)"

text \<open>H3 --- the HLC is a logical clock: it respects happens-before. This
  is what @{text "bondy_oplog_hlc:update/2"} buys on receipt of a peer
  event. Note it constrains ORDERED pairs only: concurrent events have
  unordered HLCs, which is the hinge of the counterexample in
  theory Aw_Counterexample.\<close>
definition hlc_respects_hb :: "event set \<Rightarrow> bool" where
  "hlc_respects_hb E \<longleftrightarrow> (\<forall>e\<in>E. \<forall>f\<in>E. hb f e \<longrightarrow> ev_hlc f < ev_hlc e)"


subsection \<open>I2 --- the containment frontier\<close>

definition contains_below :: "hlc \<Rightarrow> event set \<Rightarrow> event set \<Rightarrow> bool" where
  "contains_below Fr A B \<longleftrightarrow> (\<forall>e\<in>A. ev_hlc e \<le> Fr \<longrightarrow> e \<in> B)"

text \<open>I2 (containment stability): every replica in the confirmed set holds
  every event, held anywhere in that set, whose HLC is at or below the
  frontier.\<close>
definition certified_frontier ::
    "hlc \<Rightarrow> replica set \<Rightarrow> (replica \<Rightarrow> event set) \<Rightarrow> bool" where
  "certified_frontier Fr R D \<longleftrightarrow> (\<forall>r\<in>R. \<forall>r'\<in>R. contains_below Fr (D r) (D r'))"

text \<open>
  How the code establishes I2, in two halves that meet in the middle:

  \<^item> @{text "bondy_oplog_instance:compute_frontier_for/2"} --- the frontier
    is the largest local key K such that every local key @{text "=< K"} is
    present in EVERY peer's confirmed root. That is one containment
    direction: everything I hold below the frontier, my peers hold.

  \<^item> @{text "bondy_oplog_sync_session:pull_if_compatible/7"} --- a peer root
    is checkpointed as confirmed only when the round COMPLETED against it
    (held-in-full); a benign-incomplete round "must checkpoint nothing".
    That is the other direction: everything a confirmed peer holds, I hold.

  The second half alone is already enough for the model, so we record it as
  the sufficient condition.
\<close>
definition held_in_full :: "replica \<Rightarrow> replica set \<Rightarrow> (replica \<Rightarrow> event set) \<Rightarrow> bool" where
  "held_in_full r R D \<longleftrightarrow> (\<forall>r'\<in>R. D r' \<subseteq> D r)"

lemma held_in_full_certifies:
  assumes "\<forall>r\<in>R. held_in_full r R D"
  shows "certified_frontier Fr R D"
  using assms
  by (auto simp: certified_frontier_def contains_below_def held_in_full_def)


subsection \<open>I1 --- prepare-after-deliver\<close>

text \<open>Every operation on a cell is prepared against a state reflecting every
  event on that cell delivered at this replica before the prepare. Enforced
  by @{text "bondy_oplog_applier:ensure_remote_caught_up/1"}.

  Note the argument @{term D} is the delivered map AT PREPARE TIME. The
  whole subtlety of this development is that prepare time is not ordered by
  the frontier.\<close>
definition prepare_after_deliver ::
    "replica \<Rightarrow> (replica \<Rightarrow> event set) \<Rightarrow> event \<Rightarrow> bool" where
  "prepare_after_deliver r D e \<longleftrightarrow>
     (\<forall>f \<in> D r. ev_cell f = ev_cell e \<longrightarrow> dot_observed (ev_dot f) (ev_ctx e))"


subsection \<open>The stability theorem\<close>

text \<open>
  Theorem (causal stability without causal broadcast). Given I1 and I2, an
  event prepared at a replica in the confirmed set, AFTER certification,
  carries a context dominating every dot on its cell at or below the
  frontier.

  This is the mechanized form of the proof sketch in
  @{text "bondy_oplog_applier.erl"}. Note what it does NOT say: nothing
  about events prepared BEFORE certification. See @{text sound_above} in
  theory Stabilization.
\<close>
theorem stability_without_causal_broadcast:
  assumes cert:   "certified_frontier Fr R D"
      and r_mem:  "r \<in> R"
      and r'_mem: "r' \<in> R"
      and i1:     "prepare_after_deliver r D e"
      and f_del:  "f \<in> D r'"
      and f_cell: "ev_cell f = ev_cell e"
      and f_stab: "ev_hlc f \<le> Fr"
    shows "dot_observed (ev_dot f) (ev_ctx e)"
proof -
  from cert r'_mem r_mem f_del f_stab have "f \<in> D r"
    unfolding certified_frontier_def contains_below_def by blast
  with i1 f_cell show ?thesis
    unfolding prepare_after_deliver_def by blast
qed

text \<open>The same statement in the form the reclamation code consumes it: no
  event at or below the frontier is invisible to a post-certification
  prepare on its cell.\<close>
corollary stable_dots_are_observed:
  assumes "certified_frontier Fr R D" and "r \<in> R"
      and "prepare_after_deliver r D e"
    shows "\<forall>f \<in> (\<Union>r'\<in>R. D r'). ev_cell f = ev_cell e \<longrightarrow> ev_hlc f \<le> Fr \<longrightarrow>
             dot_observed (ev_dot f) (ev_ctx e)"
  using assms stability_without_causal_broadcast by blast

end
