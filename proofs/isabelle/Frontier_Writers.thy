(*
  SPDX-FileCopyrightText: 2016 - 2026 Leapsight
  SPDX-License-Identifier: Apache-2.0
*)

theory Frontier_Writers
  imports Bucket_Skip_Soundness
begin

section \<open>Why the applied frontier needs one writer, not four\<close>

text \<open>
  @{theory_text Bucket_Skip_Soundness} shows that a per-batch MAX over the
  cells that folded is an unsound claim once a bucket group is skipped, and
  that the contiguous prefix bound is the sound alternative. That result is
  about ONE writer's arithmetic.

  This theory is about WHICH SET the claim is a claim about.

  Two sets must be kept apart, and the implementation keeps them apart
  everywhere except in the frontier:

  \<^item> the OPLOG --- @{text bondy_mst}. @{text
    "bondy_oplog_instance:install_event/5"} is the shared insert path for both
    @{text install_local_batch} (local origin) and @{text do_append_remote}
    (peer-received), so tree membership means RECEIVED. That is by design: the
    tree is the anti-entropy structure and the equivocation witness
    (@{text "append_remote_install/3"} compares @{text "bondy_mst:get"} three
    ways before installing).

  \<^item> the PROJECTION --- leveled or ETS. @{text
    "bondy_oplog_instance:deliver_remote/1"} runs strictly AFTER the tree
    advance and then asks the applier to re-fold; the fold is best-effort and
    idempotent.

  The applied frontier is a claim about the SECOND set. @{text
  "bondy_oplog_instance:frontier_from_mst/1"} computes it from the FIRST.

  That is worse than an over-claim: the watermark door judges "never applied"
  against this same frontier and HOLDS un-folded events from truncation so the
  applier can replay them (@{text "watermark_door/3"},
  @{text "capped_truncation_point/2"}). A frontier that claims an unfolded
  event also DISARMS the mechanism that would have folded it.

  @{term sound_claim} and @{term ctx_of} are inherited. Throughout, @{term app}
  is the set of seqs of one origin whose cells this replica has FOLDED INTO ITS
  PROJECTION, and @{term rcv} the set it has received into its oplog.
\<close>

subsection \<open>A join cannot be capped from below\<close>

lemma sound_claim_downward:
  assumes "sound_claim c obs" and "c' \<le> c"
  shows "sound_claim c' obs"
  using assms unfolding sound_claim_def by auto

text \<open>
  UNsoundness is upward closed. This is the argument against the cap that was
  shipped and has since been reverted: whatever a conservative writer
  contributes, a larger contribution from any other writer subsumes it, and
  @{text merge_frontier} offers no operation that lowers the entry.
\<close>
theorem join_absorbs_unsound:
  assumes "\<not> sound_claim v obs" and "v \<le> c"
  shows "\<not> sound_claim c obs"
  using assms sound_claim_downward by blast

definition joined :: "seq set \<Rightarrow> seq" where
  "joined C = (if C = {} then 0 else Max C)"

text \<open>
  Only the maximum matters, which is why the COUNT of writers is not the
  interesting quantity --- their PREDICATES are.
\<close>
theorem one_unsound_writer_defeats_all:
  assumes "finite C" and "v \<in> C" and "\<not> sound_claim v obs"
  shows "\<not> sound_claim (joined C) obs"
proof -
  from assms have "C \<noteq> {}" by auto
  hence "joined C = Max C" unfolding joined_def by simp
  moreover from \<open>finite C\<close> \<open>v \<in> C\<close> have "v \<le> Max C" by simp
  ultimately show ?thesis using assms(3) join_absorbs_unsound by simp
qed

corollary cap_cannot_repair:
  assumes "finite C" and "bad \<in> C" and "\<not> sound_claim bad obs"
  shows "\<not> sound_claim (joined (insert good C)) obs"
proof -
  have "finite (insert good C)" using assms(1) by simp
  moreover have "bad \<in> insert good C" using assms(2) by simp
  ultimately show ?thesis
    using assms(3) one_unsound_writer_defeats_all by blast
qed

subsection \<open>Claiming the oplog is claiming the wrong set\<close>

text \<open>
  The oplog holds what was received; the frontier asserts what was folded. Any
  received-but-unfolded seq makes a claim derived from the oplog unsound with
  respect to the projection.

  This is NOT an argument for withholding events from the oplog. The tree must
  record everything received --- it is the durable log, the AAE structure and
  the equivocation witness. It is an argument that the frontier may not be
  DERIVED from it.
\<close>
theorem receipt_log_overclaims:
  assumes "finite rcv" and "s \<in> rcv" and "s \<notin> app" and "0 < s"
  shows "\<not> sound_claim (ctx_of rcv) app"
proof -
  from assms(1,2) have "s \<le> Max rcv" by simp
  moreover from assms(2) have "rcv \<noteq> {}" by auto
  hence "ctx_of rcv = Max rcv" unfolding ctx_of_def by simp
  ultimately have "s \<le> ctx_of rcv" by simp
  with assms(3,4) show ?thesis unfolding sound_claim_def by blast
qed

subsection \<open>The max is sound exactly when the folded set is prefix-closed\<close>

definition prefix_closed_set :: "seq set \<Rightarrow> bool" where
  "prefix_closed_set S \<longleftrightarrow> (\<forall>s\<in>S. \<forall>t. 0 < t \<and> t \<le> s \<longrightarrow> t \<in> S)"

theorem max_sound_iff_prefix:
  assumes "finite S"
  shows "sound_claim (ctx_of S) S \<longleftrightarrow> prefix_closed_set S"
proof
  assume *: "sound_claim (ctx_of S) S"
  show "prefix_closed_set S"
  proof (unfold prefix_closed_set_def, intro ballI allI impI)
    fix s t assume "s \<in> S" and t: "0 < t \<and> t \<le> s"
    from \<open>s \<in> S\<close> assms have "s \<le> Max S" by simp
    moreover from \<open>s \<in> S\<close> have "S \<noteq> {}" by auto
    hence "ctx_of S = Max S" unfolding ctx_of_def by simp
    ultimately have "t \<le> ctx_of S" using t by simp
    with * t show "t \<in> S" unfolding sound_claim_def by blast
  qed
next
  assume pc: "prefix_closed_set S"
  show "sound_claim (ctx_of S) S"
  proof (cases "S = {}")
    case True
    thus ?thesis by (auto simp: sound_claim_def ctx_of_def)
  next
    case False
    hence "ctx_of S = Max S" unfolding ctx_of_def by simp
    moreover from False assms have "Max S \<in> S" by simp
    ultimately show ?thesis
      using pc unfolding sound_claim_def prefix_closed_set_def by auto
  qed
qed

subsection \<open>Folding behind an admission test preserves prefix-closure\<close>

text \<open>
  The reachable situation from the repro: origin @{text O} minted seq 1 into a
  bucket this replica has no table for and seq 2 into one it does. BOTH are in
  the oplog --- correctly. The FOLDED set is @{term "{2}"}, and it is not
  prefix-closed.
\<close>
lemma unfolded_seq_breaks_prefix:
  "\<not> prefix_closed_set {2::seq}"
  unfolding prefix_closed_set_def by force

text \<open>
  The admission test. A seq joins the folded set iff its cell MATERIALISED in
  this pass and every positive seq below it is already folded or materialises
  in the same pass. Nothing here is withheld from the oplog: @{term app} is the
  projection's reach, not the tree's.
\<close>
definition fold_step :: "seq set \<Rightarrow> seq set \<Rightarrow> seq set" where
  "fold_step app mat =
     app \<union> {s. s \<in> mat \<and> (\<forall>t. 0 < t \<and> t \<le> s \<longrightarrow> t \<in> app \<union> mat)}"

lemma fold_step_subset: "fold_step app mat \<subseteq> app \<union> mat"
  unfolding fold_step_def by auto

lemma fold_step_mono: "app \<subseteq> fold_step app mat"
  unfolding fold_step_def by auto

lemma finite_fold_step:
  assumes "finite app" and "finite mat"
  shows "finite (fold_step app mat)"
  using assms fold_step_subset finite_subset by fastforce

theorem fold_preserves_prefix_closed:
  assumes "prefix_closed_set app"
  shows "prefix_closed_set (fold_step app mat)"
proof (unfold prefix_closed_set_def, intro ballI allI impI)
  fix s t
  assume s: "s \<in> fold_step app mat" and t: "0 < t \<and> t \<le> s"
  show "t \<in> fold_step app mat"
  proof (cases "s \<in> app")
    case True
    with assms t have "t \<in> app" unfolding prefix_closed_set_def by blast
    thus ?thesis using fold_step_mono by blast
  next
    case False
    with s have adm: "s \<in> mat \<and> (\<forall>u. 0 < u \<and> u \<le> s \<longrightarrow> u \<in> app \<union> mat)"
      unfolding fold_step_def by blast
    from adm t have "t \<in> app \<union> mat" by blast
    thus ?thesis
    proof
      assume "t \<in> app" thus ?thesis using fold_step_mono by blast
    next
      assume "t \<in> mat"
      moreover have "\<forall>u. 0 < u \<and> u \<le> t \<longrightarrow> u \<in> app \<union> mat"
        using adm t by auto
      ultimately show ?thesis unfolding fold_step_def by blast
    qed
  qed
qed

corollary fold_step_claim_sound:
  assumes "prefix_closed_set app" and "finite app" and "finite mat"
  shows "sound_claim (ctx_of (fold_step app mat)) (fold_step app mat)"
  using assms fold_preserves_prefix_closed finite_fold_step max_sound_iff_prefix
  by blast

subsection \<open>Reconstruction must re-fold, not declare\<close>

fun folded_after :: "seq set \<Rightarrow> seq set list \<Rightarrow> seq set" where
  "folded_after app [] = app"
| "folded_after app (m # ms) = folded_after (fold_step app m) ms"

fun incremental :: "seq set \<Rightarrow> seq set list \<Rightarrow> seq" where
  "incremental app [] = ctx_of app"
| "incremental app (m # ms) = max (ctx_of app) (incremental (fold_step app m) ms)"

lemma ctx_of_mono:
  assumes "finite B" and "A \<subseteq> B"
  shows "ctx_of A \<le> ctx_of B"
proof (cases "A = {}")
  case True thus ?thesis unfolding ctx_of_def by simp
next
  case False
  with assms have "B \<noteq> {}" by auto
  hence "ctx_of B = Max B" unfolding ctx_of_def by simp
  moreover from False have "ctx_of A = Max A" unfolding ctx_of_def by simp
  moreover from assms False have "Max A \<le> Max B"
    by (simp add: Max.subset_imp)
  ultimately show ?thesis by simp
qed

lemma folded_after_mono: "app \<subseteq> folded_after app ms"
proof (induction ms arbitrary: app)
  case Nil thus ?case by simp
next
  case (Cons m ms)
  have "app \<subseteq> fold_step app m" by (rule fold_step_mono)
  also have "\<dots> \<subseteq> folded_after (fold_step app m) ms" using Cons.IH by blast
  finally show ?case by simp
qed

lemma finite_folded_after:
  assumes "finite app" and "\<forall>m \<in> set ms. finite m"
  shows "finite (folded_after app ms)"
  using assms
proof (induction ms arbitrary: app)
  case Nil thus ?case by simp
next
  case (Cons m ms)
  have "finite (fold_step app m)"
    using Cons.prems by (simp add: finite_fold_step)
  thus ?case using Cons.IH Cons.prems by simp
qed

text \<open>
  A frontier maintained incrementally by the fold path equals one reconstructed
  by folding the accumulated FOLDED set. Both quantify over @{term fold_step},
  never over the oplog. Declaring a range applied without folding it satisfies
  no hypothesis here.
\<close>
theorem reconstruction_agrees:
  assumes "finite app" and "\<forall>m \<in> set ms. finite m"
  shows "incremental app ms = ctx_of (folded_after app ms)"
  using assms
proof (induction ms arbitrary: app)
  case Nil thus ?case by simp
next
  case (Cons m ms)
  have fin: "finite (fold_step app m)"
    using Cons.prems by (simp add: finite_fold_step)
  have IH: "incremental (fold_step app m) ms
              = ctx_of (folded_after (fold_step app m) ms)"
    using Cons.IH fin Cons.prems by simp
  have sub: "app \<subseteq> folded_after (fold_step app m) ms"
    using fold_step_mono folded_after_mono by blast
  have finall: "finite (folded_after (fold_step app m) ms)"
    using fin Cons.prems by (simp add: finite_folded_after)
  from sub finall have "ctx_of app \<le> ctx_of (folded_after (fold_step app m) ms)"
    by (rule ctx_of_mono[rotated])
  thus ?case using IH by simp
qed

subsection \<open>Restart: the writer that erases the others\<close>

text \<open>
  Everything above is about one boot. The defect is a RESTART defect, so a
  theory without a restart cannot express it --- the same gap
  @{text "proofs/tla/README.md"} records for @{text MuxBucketSkip.tla}, which
  had to be given a @{text Restart} action before it could reproduce anything.

  Four sets per origin, and the point is that the third is NOT the second:

  \<^item> @{term rc} --- the OPLOG: what this replica received. Grows on delivery.
  \<^item> @{term fl} --- what actually reached the PROJECTION.
  \<^item> @{term cl} --- what the frontier CLAIMS. The convergence oracle reports
    @{term "ctx_of cl"}.
  \<^item> @{term ck} --- the durable copy of @{term cl} written at compaction
    (@{text "maybe_persist_frontier/5"}).

  Soundness is @{term "cl \<subseteq> fl"}: never claim what was not folded.
  Every reader in the design note breaks when it fails --- and
  @{text "watermark_door/3"} breaks by TRUNCATING the very event that is
  missing.
\<close>

definition wf_frontier ::
  "seq set \<Rightarrow> seq set \<Rightarrow> seq set \<Rightarrow> seq set \<Rightarrow> bool" where
  "wf_frontier ck cl fl rc \<longleftrightarrow>
     fl \<subseteq> rc \<and> cl \<subseteq> fl \<and> ck \<subseteq> cl \<and>
     prefix_closed_set cl \<and> prefix_closed_set ck"

text \<open>
  Weakening the observed set keeps a claim sound; used for the own-origin
  result below.
\<close>
lemma sound_claim_mono_obs:
  assumes "sound_claim c A" and "A \<subseteq> B"
  shows "sound_claim c B"
  using assms unfolding sound_claim_def by blast

subsubsection \<open>The shipped restart\<close>

text \<open>
  @{text "bondy_oplog_instance:frontier_from_mst/1"} sets the claim to the
  OPLOG. Modelled as @{text "cl := rc"}.

  The witness is the measured probe: seq 1 rode a bucket with no context and
  seq 2 folded, so @{term "rc = {1,2}"} while @{term "fl = {2}"}. The state
  before the restart is well-formed --- nothing has gone wrong yet, the
  frontier honestly claims nothing.
\<close>
lemma pre_restart_wellformed:
  "wf_frontier {} {} {2::seq} {1,2::seq}"
  unfolding wf_frontier_def prefix_closed_set_def by simp

text \<open>Declaring the oplog folded breaks soundness outright.\<close>
theorem shipped_restart_breaks_soundness:
  "\<not> wf_frontier {} {1,2::seq} {2::seq} {1,2::seq}"
proof -
  have "\<not> {1,2::seq} \<subseteq> {2::seq}" by simp
  thus ?thesis by (simp add: wf_frontier_def)
qed

text \<open>
  And the resulting entry is an unsound claim in the sense of
  @{theory_text sound_claim}: it reports 2, asserting the prefix that contains
  1, which is not in the projection.
\<close>
theorem shipped_restart_overclaims:
  "\<not> sound_claim (ctx_of {1,2::seq}) {2::seq}"
proof -
  have "ctx_of {1,2::seq} = ctx_of {2::seq}" unfolding ctx_of_def by simp
  thus ?thesis using ctx_of_unsound_under_skip by simp
qed

subsubsection \<open>The re-folding restart\<close>

text \<open>
  The design note's §5. Recovery restores the CHECKPOINT and re-presents the
  oplog to the fold; @{term mat} is what materialises on that pass, which need
  not be all of @{term rc} (an unroutable bucket still does not resolve). The
  claim is then whatever the admission test admits --- never a declaration.

  Re-presenting an already-folded seq is harmless here because @{term fold_step}
  unions into @{term cl}; in the implementation that is discharged by the
  per-origin @{text MaxSeq} guard in
  @{text "bondy_oplog_crdt_g_counter:apply_op/3"} and
  @{text "bondy_oplog_crdt_pn_counter:apply_op/3"}.
\<close>
theorem refold_restart_preserves_soundness:
  assumes "wf_frontier ck cl fl rc"
  shows "wf_frontier ck (fold_step ck (mat \<inter> rc)) (fl \<union> (mat \<inter> rc)) rc"
proof -
  from assms have base: "fl \<subseteq> rc" "cl \<subseteq> fl" "ck \<subseteq> cl"
    and pc: "prefix_closed_set ck"
    unfolding wf_frontier_def by auto
  have "fold_step ck (mat \<inter> rc) \<subseteq> ck \<union> (mat \<inter> rc)"
    by (rule fold_step_subset)
  moreover have "ck \<subseteq> fl" using base by auto
  ultimately have sub: "fold_step ck (mat \<inter> rc) \<subseteq> fl \<union> (mat \<inter> rc)"
    by blast
  show ?thesis
    unfolding wf_frontier_def
  proof (intro conjI)
    show "fl \<union> (mat \<inter> rc) \<subseteq> rc" using base by blast
    show "fold_step ck (mat \<inter> rc) \<subseteq> fl \<union> (mat \<inter> rc)"
      using sub .
    show "ck \<subseteq> fold_step ck (mat \<inter> rc)" by (rule fold_step_mono)
    show "prefix_closed_set (fold_step ck (mat \<inter> rc))"
      using pc by (rule fold_preserves_prefix_closed)
    show "prefix_closed_set ck" using pc .
  qed
qed

text \<open>
  Recovery never loses durable progress: the re-folded claim is at least the
  checkpoint's. So the honest frontier is not a regression --- it is only ever
  BEHIND the dishonest one, which is the direction that costs a re-fetch rather
  than a user.
\<close>
theorem refold_no_regression:
  assumes "finite ck" and "finite mat"
  shows "ctx_of ck \<le> ctx_of (fold_step ck (mat \<inter> rc))"
proof -
  have fi: "finite (mat \<inter> rc)" using assms(2) by simp
  have f: "finite (fold_step ck (mat \<inter> rc))"
    using assms(1) fi by (rule finite_fold_step)
  have sb: "ck \<subseteq> fold_step ck (mat \<inter> rc)" by (rule fold_step_mono)
  from sb f show ?thesis by (rule ctx_of_mono[rotated])
qed

subsubsection \<open>Why the split is not optional\<close>

text \<open>
  @{theory_text shipped_restart_breaks_soundness} is about a REMOTE origin. For
  the replica's OWN origin the same oplog-derived claim is SOUND, because a
  local write folds before the event is minted, giving
  @{term "own_rc \<subseteq> own_fl"}; and local minting is contiguous
  (@{theory_text Seq_Seed}), giving prefix-closure.

  This is why @{text frontier_from_mst} may not simply be deleted or filtered:
  it is the only durable record of the own-origin maximum once compaction has
  truncated those events from both the MST
  (@{text "truncate_below_or_equal/4"}) and the WAL
  (@{text "advance_wal_snapshot_watermark/2"}). It must be SPLIT --- kept for
  the own origin, removed for remote ones.
\<close>
theorem own_origin_oplog_claim_is_sound:
  assumes "finite own_rc"
      and "prefix_closed_set own_rc"
      and "own_rc \<subseteq> own_fl"
  shows "sound_claim (ctx_of own_rc) own_fl"
proof -
  from assms(1,2) have "sound_claim (ctx_of own_rc) own_rc"
    using max_sound_iff_prefix by blast
  thus ?thesis using assms(3) by (rule sound_claim_mono_obs)
qed

text \<open>
  Together with @{theory_text shipped_restart_overclaims}: the SAME derivation
  is sound on one origin and unsound on the others. A single map cannot carry
  both, which is the split the design note calls @{term minted_vv} and
  @{term applied_vv}.
\<close>

subsection \<open>What this licenses\<close>

text \<open>
  \<^item> @{theory_text join_absorbs_unsound} and @{theory_text cap_cannot_repair}
    rule OUT capping one merge site while another merges a looser predicate.

  \<^item> @{theory_text receipt_log_overclaims} identifies the looser predicate as
    a claim about the OPLOG. The remedy is to stop deriving the frontier from
    the tree --- NOT to keep events out of the tree.

  \<^item> @{theory_text max_sound_iff_prefix} says the representation is right and
    the hypothesis it needs is prefix-closure OF THE FOLDED SET.

  \<^item> @{theory_text fold_preserves_prefix_closed} and
    @{theory_text fold_step_claim_sound} say an admission test evaluated after
    bucket resolution delivers that hypothesis structurally.

  \<^item> @{theory_text reconstruction_agrees} says boot and steady state agree
    when boot RE-FOLDS.

  NOT proved here:

  \<^item> That the Erlang refines @{term fold_step}. Discharged by the property
    test named I5 in @{text "_design/applied_frontier.md"}, which does not yet
    exist.

  \<^item> Anything about LIVENESS. @{term fold_step} may admit nothing
    (@{term "mat = {}"} is a fixpoint), which is the permanently unroutable
    bucket.
\<close>

end
