(*
  SPDX-FileCopyrightText: 2016 - 2026 Leapsight
  SPDX-License-Identifier: Apache-2.0
*)

theory Frontier_Pending
  imports Frontier_Writers
begin

section \<open>The applied frontier as a prefix plus a pending set\<close>

text \<open>
  @{theory_text Frontier_Writers} settles WHICH SET the applied frontier is a
  claim about, and @{theory_text Bucket_Skip_Soundness} settles WHAT ARITHMETIC
  is sound over a given applied set. Both reason about one value against one
  set. Neither can express the defect this theory is about, because that defect
  needs a SCHEDULE: the applied set is built by a sequence of batches, and the
  frontier is maintained incrementally across them.

  The shipped writer is @{text "bondy_oplog_cell_apply:claim/2"}: per origin,
  the highest seq that materialised in this batch, capped strictly below the
  lowest seq this batch is known to have FAILED to materialise; the result is
  max-merged into the registry by @{text "bondy_oplog_registry:merge_frontier/2"}.
  Its own docstring records the limit --- ``a failure in a LATER batch, below a
  claim already made, is out of this function's reach'' --- and
  @{text "_design/applied_frontier.md"} \<open>\<section>\<close>10.2 records that splitting the
  reproduction across two batches defeats it.

  This theory establishes three things about that limit.

  \<^item> The shipped rule is sound EXACTLY under batch visibility
    (@{text shipped_sound_when_visible}, @{text shipped_split_batch_overclaims}).
    So the limit is real, and its boundary is not a matter of degree.

  \<^item> The limit is NOT a defect of that rule's arithmetic, and no better
    arithmetic exists. Any writer whose state is a single integer per origin ---
    however it computes its contribution, with whatever failure information ---
    is either unsound on some schedule or permanently incomplete on a schedule
    that ends perfectly healthy (@{text no_scalar_writer_sound_and_complete}).
    Deterministic; the counterexample schedules carry NO failures at all, so
    reporting failures better cannot close it.

  \<^item> The two-component state --- a contiguous prefix plus the applied seqs
    above it --- is sound on every schedule, exact on every schedule, and
    complete whenever delivery ends prefix-closed
    (@{text pending_exact}, @{text pending_sound}, @{text pending_complete}).
    It costs nothing in the healthy case and one interval per hole otherwise.

  The representation is not new here: @{theory_text Dot_Exactness_Gapped} built
  it for the observed-remove context, with @{term contig}, @{term exc},
  @{term denote} and @{thm [source] repr_faithful}. What is new is carrying it
  across a schedule, and the impossibility result that says the carry is
  necessary rather than merely convenient.

  Throughout, one origin. The frontier is a sparse map over origins and every
  operation on it is pointwise, so nothing below quantifies over origins.
\<close>

subsection \<open>Batches, schedules, and the ground truth\<close>

text \<open>
  A batch is what one call of @{text "apply_cell_batch_mux/3"} sees: the seqs
  that MATERIALISED into the projection, and the seqs it observed FAILING to
  materialise (an unresolved bucket, a failed @{text "put_batch/2"}). A seq that
  is in neither is a seq the batch never saw --- the case that matters, since a
  batch sees only the events the applier drained into it.
\<close>

type_synonym batch = "seq set \<times> seq set"

text \<open>The projection's reach after a schedule. This is ground truth: the fold
  applies what it can, and the frontier is a claim about the result. The
  failure component plays no part --- it is information for the writer, never
  a change to what was folded.\<close>
fun applied_after :: "seq set \<Rightarrow> batch list \<Rightarrow> seq set" where
  "applied_after app [] = app"
| "applied_after app ((m, f) # bs) = applied_after (app \<union> m) bs"

lemma applied_after_mono: "app \<subseteq> applied_after app bs"
proof (induction bs arbitrary: app)
  case Nil thus ?case by simp
next
  case (Cons b bs)
  obtain m f where b: "b = (m, f)" by (cases b)
  have "app \<subseteq> app \<union> m" by auto
  also have "app \<union> m \<subseteq> applied_after (app \<union> m) bs" using Cons.IH by blast
  finally show ?case using b by simp
qed

lemma applied_after_pos:
  assumes "\<forall>s \<in> app. 0 < s" and "\<forall>(m, f) \<in> set bs. \<forall>s \<in> m. 0 < s"
  shows "\<forall>s \<in> applied_after app bs. 0 < s"
  using assms
proof (induction bs arbitrary: app)
  case Nil thus ?case by simp
next
  case (Cons b bs)
  obtain m f where b: "b = (m, f)" by (cases b)
  have "\<forall>s \<in> m. 0 < s" using Cons.prems(2) b by auto
  hence "\<forall>s \<in> app \<union> m. 0 < s" using Cons.prems(1) by auto
  moreover have "\<forall>(m, f) \<in> set bs. \<forall>s \<in> m. 0 < s" using Cons.prems(2) by auto
  ultimately show ?case using Cons.IH b by simp
qed

lemma finite_applied_after:
  assumes "finite app" and "\<forall>(m, f) \<in> set bs. finite m"
  shows "finite (applied_after app bs)"
  using assms by (induction bs arbitrary: app) auto

subsection \<open>The shipped writer, and the exact boundary of its soundness\<close>

text \<open>
  @{text "claim/2"}, for one origin: the highest materialised seq strictly
  below the lowest failure. @{term ctx_of} supplies the @{text 0} for the empty
  case, which is the Erlang omitting the origin from the partial map.
\<close>
definition cap :: "seq set \<Rightarrow> seq set \<Rightarrow> seq" where
  "cap m f = ctx_of {s \<in> m. \<forall>t \<in> f. s < t}"

lemma cap_clean: "finite m \<Longrightarrow> cap m {} = ctx_of m"
  unfolding cap_def by simp

text \<open>
  A writer with one integer of state. It reads the current entry and the batch
  and returns a contribution; @{text "merge_frontier/2"} joins it with
  @{term max}. This shape covers @{text "claim/2"} and every arithmetic
  variation on it, including ones that consult the current frontier (which
  @{text "claim/2"} does not).
\<close>
type_synonym scalar_writer = "seq \<Rightarrow> seq set \<Rightarrow> seq set \<Rightarrow> seq"

fun scalar_after :: "scalar_writer \<Rightarrow> seq \<Rightarrow> batch list \<Rightarrow> seq" where
  "scalar_after w c [] = c"
| "scalar_after w c ((m, f) # bs) = scalar_after w (max c (w c m f)) bs"

definition shipped :: scalar_writer where
  "shipped c m f = cap m f"

text \<open>
  The hypothesis under which the shipped rule is sound: every absent seq below
  what this batch would claim is VISIBLE to the batch as a failure. A batch
  that contains the whole of an origin's outstanding work satisfies it; a batch
  boundary drawn between the hole and the claim does not.
\<close>
definition batch_visible :: "seq set \<Rightarrow> seq set \<Rightarrow> seq set \<Rightarrow> bool" where
  "batch_visible app m f \<longleftrightarrow>
     (\<forall>s. 0 < s \<and> s \<le> ctx_of m \<and> s \<notin> app \<union> m \<longrightarrow> s \<in> f)"

lemma cap_mem:
  assumes "finite m" and "0 < cap m f"
  shows "cap m f \<in> {s \<in> m. \<forall>t \<in> f. s < t}"
proof -
  let ?S = "{s \<in> m. \<forall>t \<in> f. s < t}"
  have "?S \<noteq> {}"
  proof (rule ccontr)
    assume "\<not> ?S \<noteq> {}"
    hence "cap m f = 0" unfolding cap_def ctx_of_def by simp
    with assms(2) show False by simp
  qed
  have finS: "finite ?S" using assms(1) by simp
  have eq: "cap m f = Max ?S"
    unfolding cap_def ctx_of_def by (rule if_not_P[OF \<open>?S \<noteq> {}\<close>])
  show ?thesis unfolding eq by (rule Max_in[OF finS \<open>?S \<noteq> {}\<close>])
qed

lemma cap_le_ctx_of:
  assumes "finite m"
  shows "cap m f \<le> ctx_of m"
proof (cases "cap m f = 0")
  case True thus ?thesis by simp
next
  case False
  hence "0 < cap m f" by simp
  from cap_mem[OF assms this] have mem: "cap m f \<in> m" by simp
  hence "ctx_of m = Max m" unfolding ctx_of_def by auto
  thus ?thesis using assms mem by (simp add: Max_ge)
qed

text \<open>
  Under batch visibility the shipped rule is sound: it is a correct writer for
  the batches it can see whole. This is the positive half, and it is why the
  rule holds in the reproduction that gated the drain
  (@{text "bondy_oplog_frontier_fold_gap_test:live_path/0"}).
\<close>
theorem shipped_sound_when_visible:
  assumes fin: "finite m"
      and prev: "sound_claim c app"
      and vis: "batch_visible app m f"
  shows "sound_claim (max c (shipped c m f)) (app \<union> m)"
proof (unfold sound_claim_def, intro allI impI)
  fix s assume s: "0 < s \<and> s \<le> max c (shipped c m f)"
  show "s \<in> app \<union> m"
  proof (cases "s \<le> c")
    case True
    with s prev show ?thesis unfolding sound_claim_def by blast
  next
    case False
    with s have le: "s \<le> cap m f" unfolding shipped_def by simp
    show ?thesis
    proof (rule ccontr)
      assume out: "s \<notin> app \<union> m"
      have "s \<le> ctx_of m" using le cap_le_ctx_of[OF fin] order_trans by blast
      with s out vis have inf: "s \<in> f" unfolding batch_visible_def by blast
      from le s have "0 < cap m f" by simp
      from cap_mem[OF fin this] inf have "cap m f < s" by blast
      with le show False by simp
    qed
  qed
qed

text \<open>
  And the negative half, which is the reproduction split across two batches.
  Batch one fails seq 1 and materialises nothing; batch two materialises seq 2
  and sees no failure at all. The projection holds @{term "{2::seq}"}; the
  frontier claims @{term "2::seq"}; seq 1 is claimed and was never folded.

  Note what the second batch would have had to know: that a DIFFERENT call, on
  a batch it never saw, failed. No cap computed from its own arguments can
  reach that.
\<close>
definition split_sched :: "batch list" where
  "split_sched = [({}, {1}), ({2}, {})]"

lemma split_applied: "applied_after {} split_sched = {2}"
  unfolding split_sched_def by simp

lemma split_shipped: "scalar_after shipped 0 split_sched = 2"
  unfolding split_sched_def shipped_def cap_def ctx_of_def by simp

lemma sound_claim_two_forces_zero:
  assumes "sound_claim c {2::seq}"
  shows "c = 0"
proof (rule ccontr)
  assume "c \<noteq> 0"
  hence "0 < (1::seq) \<and> (1::seq) \<le> c" by simp
  hence "(1::seq) \<in> {2::seq}" using assms unfolding sound_claim_def by blast
  thus False by simp
qed

theorem shipped_split_batch_overclaims:
  "\<not> sound_claim (scalar_after shipped 0 split_sched)
                  (applied_after {} split_sched)"
proof -
  have "\<not> sound_claim 2 {2::seq}" using sound_claim_two_forces_zero by force
  thus ?thesis using split_shipped split_applied by simp
qed

text \<open>
  The two results together say the limit is a boundary, not a slope: the rule
  is sound for exactly the batches whose failures it can see, and unsound as
  soon as one is drawn elsewhere. Batch boundaries are set by drain timing, so
  nothing in the code chooses which side of that boundary a run lands on.
\<close>

subsection \<open>No single-integer state is both sound and complete\<close>

text \<open>
  The obvious next move is a better rule. This subsection closes that route.

  Completeness is the second requirement, and it is not optional: an entry that
  under-claims makes @{text "bondy_oplog_sync_session:frontier_deficit/2"}
  re-request an origin forever, holds the event in the tree against
  @{text "capped_truncation_point/2"} forever, and keeps the
  @{text "Instances DIVERGED"} panel red forever. Soundness alone is met by the
  writer that claims nothing.

  The argument is a diagonal, and it needs only that the writer is a FUNCTION
  of its state and its batch. Consider two schedules that share a prefix state:

  \<^item> @{text "[({2}, {})]"} --- seq 2 folds, seq 1 has not arrived. Ground truth
    @{term "{2::seq}"}. Soundness forces the entry to @{term "0::seq"}, because
    any entry \<open>\<ge>\<close> 1 claims seq 1.

  \<^item> @{text "[({2}, {}), ({1}, {})]"} --- seq 1 arrives next. Ground truth
    @{term "{1::seq, 2}"}, prefix-closed, no failure anywhere in the schedule.
    But the second batch is fed the state @{term "0::seq"}, which is exactly the
    state the one-batch schedule @{text "[({1}, {})]"} feeds it --- and on THAT
    schedule soundness caps the result at @{term "1::seq"}. Same function, same
    arguments, same result: the entry ends at 1 while the projection holds 2.

  Seq 2 was folded and can never be claimed again, because the only record that
  it was folded was an integer that could not hold it. That is the whole case
  for a second component.
\<close>

lemma sound_claim_one_bounds:
  assumes "sound_claim c {1::seq}"
  shows "c \<le> 1"
proof (rule ccontr)
  assume "\<not> c \<le> 1"
  hence "0 < (2::seq) \<and> (2::seq) \<le> c" by simp
  hence "(2::seq) \<in> {1::seq}" using assms unfolding sound_claim_def by blast
  thus False by simp
qed

definition diag_sched :: "batch list" where
  "diag_sched = [({2}, {}), ({1}, {})]"

lemma diag_applied: "applied_after {} diag_sched = {1, 2}"
  unfolding diag_sched_def by auto

lemma diag_applied_prefix_closed: "prefix_closed_set (applied_after {} diag_sched)"
  unfolding diag_applied prefix_closed_set_def by auto

lemma diag_no_failures: "\<forall>(m, f) \<in> set diag_sched. f = {}"
  unfolding diag_sched_def by auto

lemma ctx_of_diag: "ctx_of (applied_after {} diag_sched) = 2"
  unfolding diag_applied ctx_of_def by simp

theorem no_scalar_writer_sound_and_complete:
  fixes w :: scalar_writer
  assumes sound: "\<And>bs. sound_claim (scalar_after w 0 bs) (applied_after {} bs)"
  shows "scalar_after w 0 diag_sched < ctx_of (applied_after {} diag_sched)"
proof -
  have a1: "applied_after {} [({2::seq}, {})] = {2}" by simp
  have "sound_claim (scalar_after w 0 [({2::seq}, {})]) {2}"
    using sound[of "[({2::seq}, {})]"] a1 by simp
  moreover have "scalar_after w 0 [({2::seq}, {})] = max 0 (w 0 {2} {})" by simp
  ultimately have z: "max 0 (w 0 {2} {}) = 0"
    using sound_claim_two_forces_zero by simp
  have a2: "applied_after {} [({1::seq}, {})] = {1}" by simp
  have "sound_claim (scalar_after w 0 [({1::seq}, {})]) {1}"
    using sound[of "[({1::seq}, {})]"] a2 by simp
  moreover have "scalar_after w 0 [({1::seq}, {})] = max 0 (w 0 {1} {})" by simp
  ultimately have b: "max 0 (w 0 {1} {}) \<le> 1"
    using sound_claim_one_bounds by simp
  have "scalar_after w 0 diag_sched
          = max (max 0 (w 0 {2} {})) (w (max 0 (w 0 {2} {})) {1} {})"
    unfolding diag_sched_def by simp
  also have "\<dots> = max 0 (w 0 {1} {})" using z by simp
  finally have "scalar_after w 0 diag_sched \<le> 1" using b by simp
  thus ?thesis using ctx_of_diag by simp
qed

text \<open>
  The shipped writer is one instance, and it fails the other way on this
  schedule: it is complete here and unsound on @{term split_sched}. Neither
  outcome is reachable by changing the arithmetic.
\<close>

subsection \<open>The pending representation, carried across a schedule\<close>

text \<open>
  The state is the pair @{theory_text Dot_Exactness_Gapped} already justifies:
  a contiguous prefix bound and the applied seqs above it. In the Erlang this
  is the existing @{text "#{Origin => Seq}"} frontier column plus a second
  column @{text "#{Origin => [{From, To}]}"} of intervals; \<open>\<section>\<close>8 below bounds
  the second.
\<close>

type_synonym pstate = "seq \<times> seq set"

definition pstate_of :: "seq set \<Rightarrow> pstate" where
  "pstate_of S = (contig S, exc S)"

text \<open>
  One batch. The materialised seqs join the pending set; the prefix bound then
  absorbs whatever contiguous run now starts at @{term "fst P + 1"}, and the
  absorbed seqs leave the pending set. The failure set is ABSENT from this
  definition: the writer never needs to know what failed, only what folded.
  That is the mechanism this design removes rather than guards ---
  @{text "apply_cell_batch_mux/3"}'s @{text Failed} accumulator,
  @{text "subtract_seqs/2"} and @{text "first_failure/2"} all become dead.
\<close>
definition pstep :: "pstate \<Rightarrow> seq set \<Rightarrow> pstate" where
  "pstep P m = pstate_of (denote (fst P) (snd P \<union> m))"

fun prun :: "pstate \<Rightarrow> batch list \<Rightarrow> pstate" where
  "prun P [] = P"
| "prun P ((m, f) # bs) = prun (pstep P m) bs"

text \<open>What the entry asserts to a reader that can see both components.\<close>
abbreviation pdenote :: "pstate \<Rightarrow> seq set" where
  "pdenote P \<equiv> denote (fst P) (snd P)"

lemma denote_union: "denote b (e \<union> m) = denote b e \<union> {s \<in> m. 0 < s}"
  unfolding denote_def observed_gapped_def by auto

lemma denote_pos: "t \<in> denote b e \<Longrightarrow> 0 < t"
  unfolding denote_def by simp

lemma finite_denote:
  assumes "finite e"
  shows "finite (denote b e)"
proof -
  have "denote b e \<subseteq> {s. 0 < s \<and> s \<le> b} \<union> e"
    unfolding denote_def observed_gapped_def by auto
  moreover have "finite {s::seq. 0 < s \<and> s \<le> b}"
    by (rule finite_subset[of _ "{..b}"]) auto
  ultimately show ?thesis using assms finite_subset by fastforce
qed

lemma finite_exc: "finite S \<Longrightarrow> finite (exc S)"
  unfolding exc_def by simp

text \<open>The state is canonical when it is the representation of what it
  denotes --- no seq recorded twice, nothing pending that the prefix already
  covers. @{term pstep} restores it unconditionally.\<close>
definition canonical :: "pstate \<Rightarrow> bool" where
  "canonical P \<longleftrightarrow> P = pstate_of (pdenote P)"

lemma canonical_init: "canonical (0, {})"
proof -
  have "denote 0 {} = ({} :: seq set)"
    unfolding denote_def observed_gapped_def by auto
  moreover have "first_gap ({} :: seq set) = 1"
    unfolding first_gap_def by (intro Least_equality) auto
  ultimately show ?thesis
    unfolding canonical_def pstate_of_def contig_def exc_def by simp
qed

lemma pstep_props:
  assumes "finite (snd P)" and "finite m"
  shows "pdenote (pstep P m) = pdenote P \<union> {s \<in> m. 0 < s}"
    and "finite (snd (pstep P m))"
    and "canonical (pstep P m)"
proof -
  let ?U = "denote (fst P) (snd P \<union> m)"
  have finU: "finite ?U" using assms finite_denote by simp
  have posU: "\<And>t. t \<in> ?U \<Longrightarrow> 0 < t" using denote_pos by blast
  have rep: "denote (contig ?U) (exc ?U) = ?U" using denote_repr[OF finU posU] .
  have eq: "pdenote (pstep P m) = ?U"
    unfolding pstep_def pstate_of_def using rep by simp
  show "pdenote (pstep P m) = pdenote P \<union> {s \<in> m. 0 < s}"
    using eq denote_union by simp
  show "finite (snd (pstep P m))"
    unfolding pstep_def pstate_of_def using finite_exc[OF finU] by simp
  show "canonical (pstep P m)"
    unfolding canonical_def using eq by (simp add: pstep_def)
qed

lemma canonical_fst: "canonical P \<Longrightarrow> fst P = contig (pdenote P)"
  unfolding canonical_def pstate_of_def by (metis fst_conv)

text \<open>
  The carry. Three facts by one induction: the state stays canonical, stays
  finite, and denotes exactly the projection's reach. The third is EXACTNESS
  --- not a bound, an equality --- and it holds for every schedule, with no
  hypothesis on batch boundaries, contiguity, or failure visibility.
\<close>
lemma prun_props:
  assumes "canonical P" and "finite (snd P)"
      and "\<forall>(m, f) \<in> set bs. finite m \<and> (\<forall>s \<in> m. 0 < s)"
  shows "canonical (prun P bs) \<and> finite (snd (prun P bs)) \<and>
         pdenote (prun P bs) = applied_after (pdenote P) bs"
  using assms
proof (induction bs arbitrary: P)
  case Nil thus ?case by simp
next
  case (Cons b bs)
  obtain m f where b: "b = (m, f)" by (cases b)
  have finm: "finite m" and posm: "\<forall>s \<in> m. 0 < s"
    using Cons.prems(3) b by auto
  have d: "pdenote (pstep P m) = pdenote P \<union> {s \<in> m. 0 < s}"
    using pstep_props(1)[OF Cons.prems(2) finm] .
  have "{s \<in> m. 0 < s} = m" using posm by auto
  hence d': "pdenote (pstep P m) = pdenote P \<union> m" using d by simp
  have IH: "canonical (prun (pstep P m) bs) \<and> finite (snd (prun (pstep P m) bs)) \<and>
            pdenote (prun (pstep P m) bs) = applied_after (pdenote (pstep P m)) bs"
    using Cons.IH[OF pstep_props(3)[OF Cons.prems(2) finm]
                     pstep_props(2)[OF Cons.prems(2) finm]] Cons.prems(3) by auto
  show ?case using IH d' b by simp
qed

theorem pending_exact:
  assumes "\<forall>(m, f) \<in> set bs. finite m \<and> (\<forall>s \<in> m. 0 < s)"
  shows "pdenote (prun (0, {}) bs) = applied_after {} bs"
proof -
  have "pdenote ((0, {}) :: pstate) = {}"
    unfolding denote_def observed_gapped_def by auto
  thus ?thesis
    using prun_props[OF canonical_init _ assms] by simp
qed

text \<open>The integer the entry reports --- the one that goes on the wire and into
  the checkpoint --- is the contiguous prefix bound of what was actually
  folded, at every point of every schedule.\<close>
theorem pending_report:
  assumes "\<forall>(m, f) \<in> set bs. finite m \<and> (\<forall>s \<in> m. 0 < s)"
  shows "fst (prun (0, {}) bs) = contig (applied_after {} bs)"
proof -
  have "pdenote ((0, {}) :: pstate) = {}"
    unfolding denote_def observed_gapped_def by auto
  hence can: "canonical (prun (0, {}) bs)"
    using prun_props[OF canonical_init _ assms] by simp
  show ?thesis
    using canonical_fst[OF can] pending_exact[OF assms] by simp
qed

subsection \<open>Sound on every schedule, maximal, monotone, and complete\<close>

theorem pending_sound:
  assumes "\<forall>(m, f) \<in> set bs. finite m \<and> (\<forall>s \<in> m. 0 < s)"
  shows "sound_claim (fst (prun (0, {}) bs)) (applied_after {} bs)"
proof -
  have fin: "finite (applied_after {} bs)"
    using finite_applied_after[of "{}" bs] assms by auto
  show ?thesis
    using contig_claim_sound[OF fin] pending_report[OF assms] by simp
qed

text \<open>And it is the largest sound report, so soundness costs nothing that
  soundness does not itself forbid (@{thm [source] contig_claim_maximal}).\<close>
theorem pending_maximal:
  assumes "\<forall>(m, f) \<in> set bs. finite m \<and> (\<forall>s \<in> m. 0 < s)"
      and "fst (prun (0, {}) bs) < c"
  shows "\<not> sound_claim c (applied_after {} bs)"
proof -
  have fin: "finite (applied_after {} bs)"
    using finite_applied_after[of "{}" bs] assms(1) by auto
  show ?thesis
    using contig_claim_maximal[OF fin] assms(2) pending_report[OF assms(1)] by simp
qed

text \<open>The report never regresses as the schedule extends: the applied set only
  grows and @{thm [source] contig_mono} is monotone in it. A reader that saw an
  entry can never see a lower one, which is what
  @{text "bondy_oplog_registry:merge_frontier/2"}'s join gave for free and what
  a two-component state must not lose.\<close>
theorem pending_no_regression:
  assumes "\<forall>(m, f) \<in> set (bs @ cs). finite m \<and> (\<forall>s \<in> m. 0 < s)"
  shows "fst (prun (0, {}) bs) \<le> fst (prun (0, {}) (bs @ cs))"
proof -
  have hbs: "\<forall>(m, f) \<in> set bs. finite m \<and> (\<forall>s \<in> m. 0 < s)" using assms by auto
  have sub: "applied_after {} bs \<subseteq> applied_after {} (bs @ cs)"
  proof -
    have "applied_after app (bs @ cs) = applied_after (applied_after app bs) cs"
      for app :: "seq set"
      by (induction bs arbitrary: app) (auto split: prod.splits)
    thus ?thesis using applied_after_mono by metis
  qed
  have fin: "finite (applied_after {} (bs @ cs))"
    using finite_applied_after[of "{}" "bs @ cs"] assms by auto
  show ?thesis
    using contig_mono[OF fin sub] pending_report[OF hbs] pending_report[OF assms]
    by simp
qed

text \<open>
  COMPLETENESS. When the schedule ends with the origin's delivery prefix-closed
  --- every hole eventually filled, which is what anti-entropy and the boot
  re-fold both drive toward --- the report is the maximum, exactly as the
  integer frontier reports today. The pending set is therefore a transient, not
  a permanent second quantity.
\<close>
theorem pending_complete:
  assumes fins: "\<forall>(m, f) \<in> set bs. finite m \<and> (\<forall>s \<in> m. 0 < s)"
      and pc: "prefix_closed_set (applied_after {} bs)"
  shows "fst (prun (0, {}) bs) = ctx_of (applied_after {} bs)"
proof -
  let ?A = "applied_after {} bs"
  have fin: "finite ?A" using finite_applied_after[of "{}" bs] fins by auto
  have pos: "\<And>t. t \<in> ?A \<Longrightarrow> 0 < t"
    using applied_after_pos[of "{}" bs] fins by auto
  have dc: "\<And>a b. b \<in> ?A \<Longrightarrow> 0 < a \<Longrightarrow> a \<le> b \<Longrightarrow> a \<in> ?A"
    using pc unfolding prefix_closed_set_def by blast
  show ?thesis
    using gapped_degenerates[OF fin pos dc] pending_report[OF fins] by simp
qed

text \<open>
  The contrast, on the schedule of @{thm [source] no_scalar_writer_sound_and_complete}.
  Every scalar writer that is sound ends this schedule at @{term "1::seq"} or
  below; the pending writer ends it at @{term "2::seq"}, which is both sound and
  the maximum. Nothing was re-delivered and no restart occurred --- the second
  batch simply completed a run whose upper part the state had kept.
\<close>
theorem pending_closes_the_diagonal:
  "fst (prun (0, {}) diag_sched) = 2"
proof -
  have fins: "\<forall>(m, f) \<in> set diag_sched. finite m \<and> (\<forall>s \<in> m. 0 < s)"
    unfolding diag_sched_def by auto
  show ?thesis
    using pending_complete[OF fins diag_applied_prefix_closed] ctx_of_diag by simp
qed

text \<open>And on the schedule that defeats the shipped rule, it reports
  @{term "0::seq"} --- an honest under-claim while seq 1 is missing, which the
  first batch that carries seq 1 will convert into a report of 2.\<close>
theorem pending_holds_at_the_hole:
  "fst (prun (0, {}) split_sched) = 0"
proof -
  have fins: "\<forall>(m, f) \<in> set split_sched. finite m \<and> (\<forall>s \<in> m. 0 < s)"
    unfolding split_sched_def by auto
  have "contig ({2} :: seq set) = 0"
  proof -
    have "first_gap ({2} :: seq set) = 1"
      unfolding first_gap_def by (intro Least_equality) auto
    thus ?thesis unfolding contig_def by simp
  qed
  thus ?thesis using pending_report[OF fins] split_applied by simp
qed

subsection \<open>Cost\<close>

text \<open>
  Nothing is paid when delivery is well behaved: the pending component is empty
  exactly when the applied set is prefix-closed, so the entry is the integer it
  is today (@{thm [source] gapped_degenerates}).
\<close>
theorem pending_zero_cost_when_healthy:
  assumes fins: "\<forall>(m, f) \<in> set bs. finite m \<and> (\<forall>s \<in> m. 0 < s)"
      and pc: "prefix_closed_set (applied_after {} bs)"
  shows "snd (prun (0, {}) bs) = {}"
proof -
  let ?A = "applied_after {} bs"
  have fin: "finite ?A" using finite_applied_after[of "{}" bs] fins by auto
  have dc: "\<And>a b. b \<in> ?A \<Longrightarrow> 0 < a \<Longrightarrow> a \<le> b \<Longrightarrow> a \<in> ?A"
    using pc unfolding prefix_closed_set_def by blast
  have e: "exc ?A = {}" using exc_empty_if_downward_closed[OF fin dc] .
  have can: "canonical (prun (0, {}) bs)"
    using prun_props[OF canonical_init _ fins]
    by (simp add: denote_def observed_gapped_def)
  have "pdenote (prun (0, {}) bs) = ?A" using pending_exact[OF fins] .
  hence "prun (0, {}) bs = pstate_of ?A" using can unfolding canonical_def by simp
  thus ?thesis using e unfolding pstate_of_def by simp
qed

text \<open>
  When a hole does exist the entry is stored as INTERVALS, and the count of
  intervals is bounded by the count of holes --- not by the count of seqs above
  the hole. This is the bound that makes a permanently unroutable bucket
  survivable: one unfillable seq costs one interval no matter how many later
  seqs of that origin fold behind it. Without it, the pending set of
  @{text "risk 2"} in @{text "_design/applied_frontier.md"} would grow without
  bound.
\<close>

definition holes :: "seq set \<Rightarrow> seq set" where
  "holes S = {h. 0 < h \<and> h \<notin> S \<and> h < ctx_of S}"

definition run_starts :: "seq set \<Rightarrow> seq set" where
  "run_starts S = {s \<in> S. s - 1 \<notin> S}"

lemma finite_holes: "finite (holes S)"
proof -
  have "holes S \<subseteq> {..ctx_of S}" unfolding holes_def by auto
  thus ?thesis using finite_subset by blast
qed

lemma exc_run_start_predecessor:
  assumes fin: "finite S" and s: "s \<in> run_starts (exc S)"
  shows "s - 1 \<in> holes S"
proof -
  from s have inx: "s \<in> exc S" and nb: "s - 1 \<notin> exc S"
    unfolding run_starts_def by auto
  from inx have inS: "s \<in> S" and gt: "contig S < s" unfolding exc_def by auto
  have s2: "2 \<le> s"
  proof (rule ccontr)
    assume "\<not> 2 \<le> s"
    with gt have "s = 1" and "contig S = 0" by auto
    hence "first_gap S = 1" unfolding contig_def
      using first_gap_absent[OF fin] by (cases "first_gap S") auto
    hence "(1::seq) \<notin> S" using first_gap_absent[OF fin] by simp
    with inS \<open>s = 1\<close> show False by simp
  qed
  have "s - 1 \<notin> S"
  proof (rule ccontr)
    assume "\<not> s - 1 \<notin> S"
    hence pS: "s - 1 \<in> S" by simp
    with nb have "\<not> contig S < s - 1" unfolding exc_def by auto
    hence "s - 1 \<le> contig S" by simp
    with gt s2 have "s = contig S + 1" by simp
    hence "s = first_gap S" unfolding contig_def
      using first_gap_absent[OF fin] by (cases "first_gap S") auto
    with inS first_gap_absent[OF fin] show False by simp
  qed
  moreover have "0 < s - 1" using s2 by simp
  moreover have "s - 1 < ctx_of S"
  proof -
    from inS fin have "s \<le> Max S" by simp
    moreover from inS have "S \<noteq> {}" by auto
    ultimately show ?thesis unfolding ctx_of_def using s2 by simp
  qed
  ultimately show ?thesis unfolding holes_def by simp
qed

theorem pending_intervals_bounded_by_holes:
  assumes fin: "finite S"
  shows "card (run_starts (exc S)) \<le> card (holes S)"
proof (rule card_inj_on_le)
  show "inj_on (\<lambda>s. s - 1) (run_starts (exc S))"
  proof (rule inj_onI)
    fix x y
    assume x: "x \<in> run_starts (exc S)" and y: "y \<in> run_starts (exc S)"
       and eq: "x - 1 = y - 1"
    have "2 \<le> x" and "2 \<le> y"
      using exc_run_start_predecessor[OF fin x] exc_run_start_predecessor[OF fin y]
      unfolding holes_def by auto
    thus "x = y" using eq by simp
  qed
next
  show "(\<lambda>s. s - 1) ` run_starts (exc S) \<subseteq> holes S"
    using exc_run_start_predecessor[OF fin] by auto
next
  show "finite (holes S)" by (rule finite_holes)
qed

subsection \<open>What does not change, and what the wire carries\<close>

text \<open>
  ONE WRITER STILL. The join is now union rather than @{term max}, and the
  absorption argument of @{thm [source] join_absorbs_unsound} survives the
  change: a writer that contributes a seq the projection does not hold poisons
  the entry permanently, because union only grows. Changing the representation
  buys exactness, not the freedom to add writers.
\<close>
theorem union_absorbs_unsound:
  assumes "\<not> C \<subseteq> app" and "C \<subseteq> D"
  shows "\<not> D \<subseteq> app"
  using assms by blast

text \<open>
  THE WIRE IS UNCHANGED. @{text "bondy_oplog_transport"}'s @{text get_frontier}
  answers @{text "#{origin() => seq()}"}, and a peer uses it to compute a
  deficit and to certify compaction (@{theory_text Confirmed_Compaction}). The
  peer is sent the PREFIX alone: the pending component stays local. That is a
  lowering of an exact claim, and lowering preserves soundness
  (@{thm [source] sound_claim_downward}), so no peer-side result is disturbed
  and no version negotiation is needed. What a peer loses is only the chance to
  certify the seqs above a local hole --- of which there are none in the healthy
  case, by @{thm [source] pending_zero_cost_when_healthy}.
\<close>
theorem shipping_the_prefix_is_sound:
  assumes "\<forall>(m, f) \<in> set bs. finite m \<and> (\<forall>s \<in> m. 0 < s)"
  shows "sound_claim (fst (prun (0, {}) bs)) (applied_after {} bs)"
  by (rule pending_sound[OF assms])

text \<open>
  TWO COLUMNS NEED NO ATOMIC WRITE. The prefix and the pending set are read
  separately by @{text "bondy_oplog_instance:applied_witness/1"} and written
  under separate compare-and-swaps, so a reader can pair a new prefix with an
  old pending set or the reverse. Both components are individually sound claims
  about a set that only grows, and soundness of each half is all a reader needs:
  no torn pair can denote a seq that was never folded.
\<close>
theorem torn_read_is_sound:
  assumes "sound_claim p app" and "pend \<subseteq> app" and "app \<subseteq> app'"
  shows "denote p pend \<subseteq> app'"
proof
  fix s assume "s \<in> denote p pend"
  hence "0 < s" and "s \<le> p \<or> s \<in> pend"
    unfolding denote_def observed_gapped_def by auto
  thus "s \<in> app'"
    using assms unfolding sound_claim_def by blast
qed

text \<open>
  THE PENDING SET NEED NOT BE DURABLE. The compaction checkpoint carries the
  prefix (@{text "bondy_oplog_instance:maybe_persist_frontier/6"}); dropping the
  pending component at a restart yields a state that denotes LESS, which is the
  safe direction, and the boot re-fold of
  @{text "bondy_oplog_instance:replay_anchor/1"} rebuilds it by re-presenting
  the live oplog --- the fold being idempotent. So the on-disk format is
  unchanged too.
\<close>
theorem dropping_pending_is_sound:
  assumes "sound_claim (fst P) app"
  shows "denote (fst P) {} \<subseteq> pdenote P \<and> denote (fst P) {} \<subseteq> app"
  using assms unfolding denote_def observed_gapped_def sound_claim_def by auto

text \<open>
  And the re-fold restores exactness in one batch: re-presenting the applied set
  to a state whose pending half was dropped returns the exact representation.
\<close>
theorem refold_restores_exactness:
  assumes fin: "finite app" and pos: "\<And>t. t \<in> app \<Longrightarrow> 0 < t"
      and sound: "sound_claim p app"
  shows "pdenote (pstep (p, {}) app) = app"
proof -
  have "pdenote (pstep (p, {}) app) = pdenote (p, {}) \<union> {s \<in> app. 0 < s}"
    using pstep_props(1)[of "(p, {})" app] fin by simp
  moreover have "{s \<in> app. 0 < s} = app" using pos by auto
  moreover have "pdenote ((p, {}) :: pstate) \<subseteq> app"
    using sound unfolding denote_def observed_gapped_def sound_claim_def by auto
  ultimately show ?thesis by auto
qed

subsection \<open>What this theory does not cover\<close>

text \<open>
  \<^item> One origin. The frontier is a map and every operation on it is pointwise,
    so this is a genuine reduction, but it is a reduction --- a defect that
    correlated two origins would not be visible here.

  \<^item> Concurrency. A schedule is a list; two appliers writing the same origin's
    entry concurrently are not modelled. @{text "proofs/tla/FrontierPending.tla"}
    covers the interleavings, including the torn read above.

  \<^item> The projection. @{term applied_after} says a materialised seq is folded and
    stays folded; the idempotence that justifies it is
    @{text "bondy_oplog_crdt_g_counter:apply_op/3"}'s per-origin @{text MaxSeq}
    guard, established by reading the code, not proved here.

  \<^item> Retirement and reaping. @{text "bondy_oplog_registry:reap_frontier/2"}
    LOWERS an entry, which every monotonicity result above excludes by
    hypothesis. A reap must remove an origin from both components together;
    @{theory_text OriginRetirementSet} governs when it is licensed.
\<close>

end
