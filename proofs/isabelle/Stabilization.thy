(*
  SPDX-FileCopyrightText: 2016 - 2026 Leapsight
  SPDX-License-Identifier: Apache-2.0
*)

theory Stabilization
  imports Oplog_Model
begin

section \<open>Which reductions a scalar frontier licenses\<close>

text \<open>
  @{text "bondy_oplog_crdt:stabilize/2"} lets a CRDT reduce a cell's state
  once @{text StableHlc} is causally stable: @{text discard} drops the cell,
  @{text "{keep, State'}"} shrinks its representation.
  @{text "bondy_oplog_crdt_nested_core:stabilize_fold/2"} collapses an
  origin's stable run of sub-ops into one synthetic op.

  All three are reductions applied to a state that MUST remain
  indistinguishable to everything that can still arrive. This theory defines
  that obligation and identifies the exact class of interpretations for which
  a scalar HLC frontier discharges it.
\<close>

subsection \<open>Soundness of a reduction\<close>

text \<open>A reduction @{text red} is sound above @{text Fr} at @{text s} when no
  future event sequence --- every event strictly above the frontier --- can
  distinguish @{text "red s"} from @{text s} by value.\<close>
definition sound_above ::
    "(event \<Rightarrow> 's \<Rightarrow> 's) \<Rightarrow> ('s \<Rightarrow> 'v) \<Rightarrow> hlc \<Rightarrow> ('s \<Rightarrow> 's) \<Rightarrow> 's \<Rightarrow> bool" where
  "sound_above interp val Fr red s \<longleftrightarrow>
     (\<forall>es. (\<forall>e \<in> set es. Fr < ev_hlc e) \<longrightarrow>
           val (fold interp es (red s)) = val (fold interp es s))"


subsection \<open>The two reduction classes\<close>

text \<open>
  An interpretation is HLC-governed above @{text Fr} w.r.t. an observation
  @{text obs} when, for events above the frontier, the effect of interpreting
  an event factors through @{text obs}: states that agree on @{text obs} keep
  agreeing.

  This is the formal content of "its observable effect is governed purely by
  HLC comparison" in @{text "bondy_oplog_crdt.erl"}: @{text obs} is what an
  above-frontier event can actually see, and a tombstone whose only job is to
  lose an HLC comparison against every such event contributes nothing to it.
\<close>
definition governed_above ::
    "(event \<Rightarrow> 's \<Rightarrow> 's) \<Rightarrow> ('s \<Rightarrow> 'o) \<Rightarrow> hlc \<Rightarrow> bool" where
  "governed_above interp obs Fr \<longleftrightarrow>
     (\<forall>e s t. Fr < ev_hlc e \<longrightarrow> obs s = obs t \<longrightarrow> obs (interp e s) = obs (interp e t))"

lemma governed_above_fold:
  assumes g: "governed_above interp obs Fr"
      and above: "\<forall>e \<in> set es. Fr < ev_hlc e"
      and eq: "obs s = obs t"
    shows "obs (fold interp es s) = obs (fold interp es t)"
  using above eq
proof (induction es arbitrary: s t)
  case Nil
  thus ?case by simp
next
  case (Cons a es)
  have ha: "Fr < ev_hlc a"
    using Cons.prems(1) by simp
  have step: "obs (interp a s) = obs (interp a t)"
    using g[unfolded governed_above_def] ha Cons.prems(2) by blast
  have rest: "\<forall>e \<in> set es. Fr < ev_hlc e"
    using Cons.prems(1) by simp
  have "obs (fold interp es (interp a s)) = obs (fold interp es (interp a t))"
    using Cons.IH[OF rest step] .
  thus ?case by simp
qed

text \<open>
  Main positive result. A reduction that preserves the above-frontier
  observation is sound, for any HLC-governed interpretation. The frontier
  enters only through @{text governed_above} --- which is precisely why a
  SCALAR frontier suffices here.
\<close>
theorem hlc_governed_reduction_sound:
  assumes g:    "governed_above interp obs Fr"
      and vfac: "\<And>u v. obs u = obs v \<Longrightarrow> val u = val v"
      and pres: "obs (red s) = obs s"
    shows "sound_above interp val Fr red s"
  unfolding sound_above_def
proof (intro allI impI)
  fix es :: "event list"
  assume above: "\<forall>e \<in> set es. Fr < ev_hlc e"
  have "obs (fold interp es (red s)) = obs (fold interp es s)"
    using governed_above_fold[OF g above pres] .
  thus "val (fold interp es (red s)) = val (fold interp es s)"
    by (rule vfac)
qed


subsection \<open>Why the negative case is not a modelling artefact\<close>

text \<open>
  The counterexample in theory Aw_Counterexample refutes
  @{text governed_above} for the observed-remove interpretation. It is worth
  stating precisely why that is consistent with
  @{text stability_without_causal_broadcast}, which looks like it should rule
  it out.

  That theorem is conditioned on @{text "prepare_after_deliver r D e"} where
  @{text D} is the delivered map AT PREPARE TIME. An event may be:

  \<^item> prepared at a replica whose delivered set did not yet contain the
    stable run (so its context observes only a prefix of it), and

  \<^item> stamped with an HLC ABOVE the frontier --- legitimate, because the
    event is concurrent with the run's later members and
    @{text hlc_respects_hb} constrains ordered pairs only.

  Such an event is above the frontier but is NOT covered by the theorem. For
  an HLC-governed interpretation this is harmless: the only thing read off the
  event is that its HLC exceeds the frontier. For a context-governed one it is
  fatal: @{text drop_observed} reads the context, and the context is a
  pre-certification observation.

  Hence the precise grade of the frontier:

  \<^item> the frontier bounds the HLCs of events that can still arrive;
  \<^item> it does NOT bound their CONTEXTS, because a context is fixed at prepare
    time and prepare time is not ordered by certification.

  A reduction may therefore depend on the former and not on the latter.
\<close>

text \<open>
  What a context-governed reduction would need instead --- vector stability:
  a certified lower bound that every context still to arrive already observes.
  The substrate does not certify this, which is why
  @{text "bondy_oplog_crdt_nested_core:stabilize_fold/2"} is called for struct
  fields and not for collection keys.
\<close>
definition vector_stable ::
    "vv \<Rightarrow> event set \<Rightarrow> bool" where
  "vector_stable lb E \<longleftrightarrow> (\<forall>e\<in>E. \<forall>x. lb x \<le> ev_ctx e x)"

text \<open>Under vector stability the fold obligation is discharged directly: every
  dot the reduction folded away is observed by every future event, so
  @{term drop_observed} treats folded and unfolded stores alike.\<close>
lemma vector_stable_dots_observed:
  assumes "vector_stable lb E" and "e \<in> E" and "snd d \<le> lb (fst d)"
  shows "dot_observed d (ev_ctx e)"
proof -
  from assms(1,2) have "lb (fst d) \<le> ev_ctx e (fst d)"
    by (simp add: vector_stable_def)
  with assms(3) have "snd d \<le> ev_ctx e (fst d)"
    by (rule order_trans)
  thus ?thesis by (simp add: dot_observed_def)
qed

end
