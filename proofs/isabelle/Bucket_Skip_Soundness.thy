(*
  SPDX-FileCopyrightText: 2016 - 2026 Leapsight
  SPDX-License-Identifier: Apache-2.0
*)

theory Bucket_Skip_Soundness
  imports Dot_Exactness_Gapped
begin

section \<open>The applied frontier when a bucket has no cell-apply context\<close>

text \<open>
  A shard instance in @{text bondy_db} multiplexes several tables onto one
  oplog. Each table is a BUCKET. The instance is founded by the first table
  opened on it and siblings register later
  (@{text "bondy_oplog_instance:register_table/4"}), so the set of buckets the
  instance can route GROWS while it is already serving anti-entropy.

  @{text "bondy_oplog_cell_apply:apply_cell_pairs_mux/5"} groups a replay batch
  by bucket and SKIPS any group whose bucket does not resolve, returning
  success. It then merges the applied frontier PER SURVIVING GROUP:
  @{text "merge_frontier(Id, batch_frontier(Pairs))"} runs inside
  @{text apply_cell_pairs} with @{term Pairs} bound to that one group.

  @{text "proofs/tla/MuxBucketSkip.tla"} model-checks the consequence and
  exhibits it in four steps at two replicas. This theory states the same result
  unbounded, and states what the fix that module selects actually guarantees.

  The seq sets here are per (origin, cell), as in @{theory_text Dot_Exactness}:
  @{term "obs"} is the set of seqs of one origin whose cells this replica
  MATERIALISED into its projection.
\<close>

subsection \<open>What a frontier entry must mean\<close>

text \<open>
  The oracle contract. @{text "bondy_oplog_responder:get_frontier"} calls the
  applied VV a convergence oracle and @{text bondy_prometheus_db} turns it into
  the @{text "Instances DIVERGED"} panel; both are sound only if a reported
  entry is backed by cells that are actually present. This is
  @{text NoOverClaim} from the TLA+ module, for one origin.
\<close>
definition sound_claim :: "seq \<Rightarrow> seq set \<Rightarrow> bool" where
  "sound_claim c obs \<longleftrightarrow> (\<forall>s. 0 < s \<and> s \<le> c \<longrightarrow> s \<in> obs)"

subsection \<open>The shipped representation is not sound under a bucket skip\<close>

text \<open>
  @{term ctx_of} --- the per-origin MAX, which is what @{text batch_frontier}
  computes over the pairs that folded --- claims a seq the projection does not
  hold, as soon as one seq of that origin rode in a skipped bucket group. The
  hypothesis @{theory_text Dot_Exactness} carries (downward closure of the
  observed set) is exactly what the skip destroys, and the skip destroys it
  WITHOUT any contiguity gap in delivery: both seqs were delivered, in order,
  in the same batch.
\<close>
lemma ctx_of_unsound_under_skip:
  "\<not> sound_claim (ctx_of {2::seq}) {2::seq}"
proof -
  have "ctx_of {2::seq} = 2" by (simp add: ctx_of_def)
  moreover have "(1::seq) \<notin> {2::seq}" by simp
  ultimately show ?thesis
    unfolding sound_claim_def by (metis less_numeral_extra(1) one_le_numeral)
qed

text \<open>
  Stated as the reachable situation rather than as a bare witness: origin
  @{text O} minted seq 1 into a bucket this replica has no table for and seq 2
  into one it does. Both arrive in one batch. The skipped group is dropped, the
  surviving group's max merges, and the frontier reports 2.
\<close>
lemma skip_produces_unsound_max:
  fixes folded :: "seq set"
  assumes "folded = {2}"
  shows "\<not> sound_claim (ctx_of folded) folded"
  using assms ctx_of_unsound_under_skip by simp

subsection \<open>The contiguous bound is sound for an ARBITRARY applied set\<close>

text \<open>
  The fix @{text "MuxBucketSkip.tla"} selects reports @{term "contig obs"}
  instead of @{term "ctx_of obs"}. No hypothesis on @{term obs}: holes from
  skipped buckets, holes from truncated peers, holes from anything at all.
  This is @{text NoOverClaim} discharged unbounded, where TLC could only check
  it to a fixed number of replicas, buckets and seqs.
\<close>
theorem contig_claim_sound:
  fixes obs :: "seq set"
  assumes fin: "finite obs"
  shows "sound_claim (contig obs) obs"
  unfolding sound_claim_def
  using contig_subset[OF fin] by blast

text \<open>
  And it is the LARGEST sound claim: nothing above the bound can be reported
  without breaking the contract, so the fix costs no reportable progress
  beyond what soundness itself forbids.
\<close>
theorem contig_claim_maximal:
  fixes obs :: "seq set"
  assumes fin: "finite obs" and gt: "contig obs < c"
  shows "\<not> sound_claim c obs"
proof -
  from first_gap_absent[OF fin] have pos: "0 < first_gap obs"
    and absent: "first_gap obs \<notin> obs" by simp_all
  have "first_gap obs \<le> c" using gt pos by (simp add: contig_def)
  thus ?thesis unfolding sound_claim_def using pos absent by blast
qed

subsection \<open>The bound never regresses as holes fill\<close>

text \<open>
  Monotone in the applied set. This is what makes the fix eventually complete
  rather than merely safe: when the sibling table registers and the parked
  cells fold, the bound rises on its own. No repair path, no rebootstrap, no
  peer-frontier adoption is needed to move it.
\<close>
theorem contig_mono:
  fixes obs obs' :: "seq set"
  assumes fin': "finite obs'" and sub: "obs \<subseteq> obs'"
  shows "contig obs \<le> contig obs'"
proof (rule ccontr)
  assume "\<not> contig obs \<le> contig obs'"
  hence gt: "contig obs' < contig obs" by simp
  from finite_subset[OF sub fin'] have fin: "finite obs" .
  from first_gap_absent[OF fin'] have pos': "0 < first_gap obs'"
    and absent': "first_gap obs' \<notin> obs'" by simp_all
  from pos' obtain n where n: "first_gap obs' = Suc n"
    by (cases "first_gap obs'") auto
  hence cn: "contig obs' = n" by (simp add: contig_def)
  have le: "first_gap obs' \<le> contig obs" using gt cn n by simp
  from contig_subset[OF fin pos' le] have "first_gap obs' \<in> obs" .
  with sub absent' show False by blast
qed

subsection \<open>The hold: an unroutable bucket stops the fold\<close>

text \<open>
  The other half of the fix, now in place. @{text "partition_contiguous/4"}
  draws the contiguous run from the ROUTABLE seqs, so a bucket with no
  registered table stops the fold exactly as a missing seq does and the
  caller keeps its replay cursor
  (@{text "bondy_oplog_applier:do_replay_cell_events_r/1"},
  @{text "bondy_oplog_instance:fused_replay_cell_events/1"}). Pinned by
  @{text "bondy_oplog_frontier_fold_gap_test"}'s
  @{text unroutable_bucket_keeps_the_replay_cursor}.

  @{term "run_from b S"} is what may then fold above bound @{term b}: the
  seqs whose whole interval down to @{term b} is routable and present.
\<close>
definition run_from :: "seq \<Rightarrow> seq set \<Rightarrow> seq set" where
  "run_from b S = {s. b < s \<and> (\<forall>i. b < i \<and> i \<le> s \<longrightarrow> i \<in> S)}"

text \<open>A run is drawn from the routable set, so it inherits its finiteness ---
  a replay batch is finite.\<close>
lemma run_from_subset: "run_from b S \<subseteq> S"
  unfolding run_from_def by blast

lemma finite_run_from: "finite S \<Longrightarrow> finite (run_from b S)"
  by (rule finite_subset[OF run_from_subset])

text \<open>The bound covers a prefix exactly when the prefix is present.\<close>
lemma first_gap_gt:
  fixes S :: "seq set" and n :: seq
  assumes fin: "finite S" and cov: "{i. 0 < i \<and> i \<le> n} \<subseteq> S"
  shows "n < first_gap S"
proof (rule ccontr)
  assume "\<not> n < first_gap S"
  hence le: "first_gap S \<le> n" by simp
  from first_gap_absent[OF fin] have pos: "0 < first_gap S"
    and absent: "first_gap S \<notin> S" by simp_all
  from pos le have "first_gap S \<in> {i. 0 < i \<and> i \<le> n}" by simp
  with cov absent show False by blast
qed

lemma contig_ge:
  fixes S :: "seq set" and n :: seq
  assumes fin: "finite S" and cov: "{i. 0 < i \<and> i \<le> n} \<subseteq> S"
  shows "n \<le> contig S"
proof -
  from first_gap_absent[OF fin] have "0 < first_gap S" by simp
  then obtain m where m: "first_gap S = Suc m" by (cases "first_gap S") auto
  hence cm: "contig S = m" by (simp add: contig_def)
  from first_gap_gt[OF fin cov] m have "n \<le> m" by simp
  thus ?thesis using cm by simp
qed

text \<open>An unroutable seq genuinely stops the bound: nothing at or above it
  can be claimed, however much of the batch above it was routable. This is the
  property the TLA+ model ASSUMED of @{text partition_contiguous}; here it is
  proved of the definition.\<close>
theorem unroutable_stops_bound:
  fixes obs routable :: "seq set" and b k :: seq
  assumes finO: "finite obs" and finR: "finite routable"
      and notR: "k \<notin> routable"
      and notObs: "k \<notin> obs"
      and above: "b < k"
  shows "contig (obs \<union> run_from b routable) < k"
proof -
  have "k \<notin> run_from b routable" using notR run_from_subset by blast
  with notObs have kabs: "k \<notin> obs \<union> run_from b routable" by blast
  have finU: "finite (obs \<union> run_from b routable)"
    using finO finite_run_from[OF finR] by simp
  show ?thesis
  proof (rule ccontr)
    assume "\<not> contig (obs \<union> run_from b routable) < k"
    hence le: "k \<le> contig (obs \<union> run_from b routable)" by simp
    have posk: "0 < k" using above by simp
    from contig_subset[OF finU posk le] kabs show False by blast
  qed
qed

text \<open>
  And the fold does make progress: when every seq from @{term "b+1"} to
  @{term n} is routable and present, the bound reaches at least @{term n}. So
  the hold parks only what it must.
\<close>
theorem run_advances_bound:
  fixes obs routable :: "seq set" and b n :: seq
  assumes finO: "finite obs" and finR: "finite routable"
      and covered: "{i. b < i \<and> i \<le> n} \<subseteq> routable"
      and below: "{i. 0 < i \<and> i \<le> b} \<subseteq> obs"
  shows "n \<le> contig (obs \<union> run_from b routable)"
proof (rule contig_ge)
  show "finite (obs \<union> run_from b routable)"
    using finO finite_run_from[OF finR] by simp
next
  show "{i. 0 < i \<and> i \<le> n} \<subseteq> obs \<union> run_from b routable"
  proof
    fix i :: seq assume "i \<in> {i. 0 < i \<and> i \<le> n}"
    hence posi: "0 < i" and lei: "i \<le> n" by simp_all
    show "i \<in> obs \<union> run_from b routable"
    proof (cases "i \<le> b")
      case True
      hence "i \<in> {j. 0 < j \<and> j \<le> b}" using posi by simp
      thus ?thesis using below by blast
    next
      case False
      hence gt: "b < i" by simp
      have "\<forall>j. b < j \<and> j \<le> i \<longrightarrow> j \<in> routable"
      proof (intro allI impI)
        fix j :: seq assume "b < j \<and> j \<le> i"
        hence "j \<in> {j. b < j \<and> j \<le> n}" using lei by simp
        thus "j \<in> routable" using covered by blast
      qed
      thus ?thesis using gt unfolding run_from_def by blast
    qed
  qed
qed

subsection \<open>The second channel: adopting a peer's frontier at bootstrap\<close>

text \<open>
  Everything above is the FOLD path. A replica has a second way to acquire a
  frontier entry: @{text "bondy_oplog_sync_session:do_bootstrap_snapshot/6"}
  installs a peer's projection snapshot and
  @{text "bondy_oplog_instance:finalize_catalogue_bootstrap/5"} max-merges the
  peer's whole version vector into the local one. Nothing proved above bounds
  that merge.

  The contiguous bound is NOT available on this path. A shipped cell is a
  @{text "(Bucket, Key, Frame)"} triple carrying no origin and no seq, so a
  claim derived from the installed cells is not a function of anything the
  install can observe. The only question the install can answer is whether
  anything it RECEIVED failed to route.

  Two sets matter and they differ. @{term "shipped preg bkt papp"} is what the
  peer's @{text "build_targets/2"} enumerates --- it scans the peer's OWN
  registry, so a peer still opening its tables ships a strict subset of what it
  holds while answering @{text get_frontier} in full.
  @{term "installed jreg bkt sh"} is the part the joiner could route. The
  joiner observes @{term "sh - ins"}; it cannot observe @{term "papp - sh"},
  because nothing on the wire names a cell the peer never sent.
\<close>

definition shipped :: "'b set \<Rightarrow> (seq \<Rightarrow> 'b) \<Rightarrow> seq set \<Rightarrow> seq set" where
  "shipped preg bkt papp = {s \<in> papp. bkt s \<in> preg}"

definition installed :: "'b set \<Rightarrow> (seq \<Rightarrow> 'b) \<Rightarrow> seq set \<Rightarrow> seq set" where
  "installed jreg bkt sh = {s \<in> sh. bkt s \<in> jreg}"

lemma installed_subset: "installed jreg bkt sh \<subseteq> sh"
  unfolding installed_def by blast

text \<open>
  The rule: adopt the peer's vector only when the install skipped nothing the
  joiner could see it skip; otherwise keep the local claim and complete the
  bootstrap anyway. @{term max} because @{text merge_frontier} is a max-merge.
  Refusing the bootstrap instead is a different rule, and a worse one: it never
  terminates when the unroutable bucket is one this build has no table for.
\<close>
definition adopted :: "seq \<Rightarrow> seq \<Rightarrow> seq set \<Rightarrow> seq set \<Rightarrow> seq" where
  "adopted jc pc sh ins = (if sh - ins = {} then max jc pc else jc)"

text \<open>
  Soundness needs BOTH halves, and the hypotheses say which is which.
  @{term serve_gate} is the responder refusing to serve a catalogue before its
  own directory is complete: without it @{term "sh"} is a strict subset of
  @{term papp} and the guard passes vacuously on cells that were never sent.
  The guard in @{term adopted} is the initiator half.
\<close>
theorem adopt_if_complete_sound:
  fixes bkt :: "seq \<Rightarrow> 'b" and papp jobs :: "seq set"
  assumes peer_sound:   "sound_claim pc papp"
      and serve_gate:   "papp \<subseteq> {s. bkt s \<in> preg}"
      and joiner_sound: "sound_claim jc jobs"
      and holds:        "installed jreg bkt (shipped preg bkt papp) \<subseteq> jobs"
  shows "sound_claim
           (adopted jc pc (shipped preg bkt papp)
                          (installed jreg bkt (shipped preg bkt papp)))
           jobs"
proof -
  let ?sh  = "shipped preg bkt papp"
  let ?ins = "installed jreg bkt ?sh"
  show ?thesis
  proof (cases "?sh - ?ins = {}")
    case True
    have "?ins \<subseteq> ?sh" by (rule installed_subset)
    with True have eq: "?ins = ?sh" by blast
    have "?sh = papp" using serve_gate unfolding shipped_def by blast
    with eq holds have papp_sub: "papp \<subseteq> jobs" by simp
    have "sound_claim (max jc pc) jobs"
      unfolding sound_claim_def
    proof (intro allI impI)
      fix s :: seq
      assume a: "0 < s \<and> s \<le> max jc pc"
      hence pos: "0 < s" by simp
      from a have "s \<le> jc \<or> s \<le> pc" by (metis max_def)
      thus "s \<in> jobs"
      proof
        assume "s \<le> jc"
        thus ?thesis using joiner_sound pos unfolding sound_claim_def by blast
      next
        assume "s \<le> pc"
        hence "s \<in> papp"
          using peer_sound pos unfolding sound_claim_def by blast
        thus ?thesis using papp_sub by blast
      qed
    qed
    thus ?thesis using True unfolding adopted_def by simp
  next
    case False
    thus ?thesis using joiner_sound unfolding adopted_def by simp
  qed
qed

text \<open>
  The guard is load-bearing. Origin @{text O} minted seq 1 into a bucket this
  joiner has no table for and seq 2 into one it does; the peer's directory is
  complete, so it ships both. Adopting unconditionally --- the shipped rule ---
  claims 2, and seq 1 is not in the projection. This is the TLC negative
  control @{text Minus_AdoptIfComplete}, unbounded.
\<close>
lemma unconditional_adoption_unsound:
  fixes bkt :: "seq \<Rightarrow> nat"
  assumes bkt: "bkt 1 = 0" "bkt 2 = 1"
  shows "shipped {0,1} bkt {1,2} = {1,2}"
    and "installed {1} bkt (shipped {0,1} bkt {1,2}) = {2}"
    and "sound_claim 2 {1,2}"
    and "\<not> sound_claim (max 0 2) (installed {1} bkt (shipped {0,1} bkt {1,2}))"
proof -
  show a: "shipped {0,1} bkt {1,2} = {1,2}"
    using bkt unfolding shipped_def by auto
  show b: "installed {1} bkt (shipped {0,1} bkt {1,2}) = {2}"
    using bkt a unfolding installed_def by auto
  show "sound_claim 2 {1,2}"
    unfolding sound_claim_def by auto
  show "\<not> sound_claim (max 0 2) (installed {1} bkt (shipped {0,1} bkt {1,2}))"
    using b unfolding sound_claim_def by auto
qed

text \<open>
  And the responder gate is load-bearing independently. Same two cells, but
  now the PEER is still opening its tables and registers only bucket 1, so it
  ships seq 2 alone while answering the frontier with 2. The joiner routes
  everything it received, the guard passes --- and the adopted claim covers
  seq 1, which neither replica sent nor holds here. This is the TLC negative
  control @{text Minus_ServeGate}, unbounded, and it is why
  @{thm [source] adopt_if_complete_sound} carries @{term serve_gate} as a
  hypothesis rather than deriving it.
\<close>
lemma adoption_unsound_without_serve_gate:
  fixes bkt :: "seq \<Rightarrow> nat"
  assumes bkt: "bkt 1 = 0" "bkt 2 = 1"
  shows "shipped {1} bkt {1,2} = {2}"
    and "shipped {1} bkt {1,2} - installed {1} bkt (shipped {1} bkt {1,2}) = {}"
    and "sound_claim 2 {1,2}"
    and "\<not> sound_claim (max 0 2) (installed {1} bkt (shipped {1} bkt {1,2}))"
proof -
  show a: "shipped {1} bkt {1,2} = {2}"
    using bkt unfolding shipped_def by auto
  show b: "shipped {1} bkt {1,2} - installed {1} bkt (shipped {1} bkt {1,2}) = {}"
    using bkt a unfolding installed_def by auto
  show "sound_claim 2 {1,2}"
    unfolding sound_claim_def by auto
  show "\<not> sound_claim (max 0 2) (installed {1} bkt (shipped {1} bkt {1,2}))"
    using bkt a unfolding installed_def sound_claim_def by auto
qed

subsection \<open>What is bought, and what is given up\<close>

text \<open>
  Bought on the FOLD path, and proved above: the reported frontier never
  claims a cell the projection does not hold
  (@{thm [source] contig_claim_sound}), for an arbitrary applied set and so
  for any number of shards, buckets and events; it is the largest such claim
  (@{thm [source] contig_claim_maximal}); it rises by itself as the parked
  cells fold (@{thm [source] contig_mono}); an unroutable bucket stops it
  (@{thm [source] unroutable_stops_bound}) and nothing else does
  (@{thm [source] run_advances_bound}).

  Bought on the BOOTSTRAP path: adopting a peer's vector only when the install
  skipped nothing observable is sound (@{thm [source] adopt_if_complete_sound})
  --- but only together with the responder gate, which appears there as the
  hypothesis @{term serve_gate} rather than as a conclusion. Both halves are
  necessary: @{thm [source] unconditional_adoption_unsound} refutes the guard's
  absence and @{thm [source] adoption_unsound_without_serve_gate} refutes the
  gate's, each by a concrete two-cell witness. The two paths are governed by
  DIFFERENT rules for a reason that is not a matter of taste: a shipped cell
  carries no origin and no seq, so the contiguous bound of the fold path is not
  a function of anything the install can observe.

  Given up: @{term "contig obs"} alone is NOT the exact context of
  @{theory_text Dot_Exactness_Gapped}, which is the PAIR
  @{term "(contig obs, exc obs)"}. Dropping the exception set costs
  COMPLETENESS, not soundness: a seq present above a hole tests as
  not-observed. By @{thm [source] gapped_test_exact} the pair is exact, so the
  bound alone can only under-report --- @{text "drop_observed/2"} may DEFER a
  remove whose add it already holds, and can never remove an add the writer
  never saw. Under @{thm [source] contig_mono} the deferral ends when the hole
  fills.

  NOT established here, and not by the TLA+ module either: that the deferred
  remove is harmless for datatype convergence. Two replicas with different
  holes compute different bounds and so apply different removes; they agree
  once the holes fill, but nothing above proves the intermediate states are
  reachable-equivalent, and @{theory_text Aw_Counterexample} is a reminder that
  observed-remove semantics do not always forgive. Datatype convergence is
  outside this session's scope (see @{text "proofs/README.md"}).

  Also NOT established: that the implementation matches any of this.
\<close>

end
