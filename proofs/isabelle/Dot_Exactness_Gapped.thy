(*
  SPDX-FileCopyrightText: 2016 - 2026 Leapsight
  SPDX-License-Identifier: Apache-2.0
*)

theory Dot_Exactness_Gapped
  imports Dot_Exactness
begin

section \<open>An observed-test that is exact without per-origin FIFO\<close>

text \<open>
  @{thm [source] compact_test_exact} is exact only under its @{text prefix}
  hypothesis: the observed set must be downward closed within the cell. That
  hypothesis is an obligation on the anti-entropy layer, and
  @{text "proofs/tla/"} exhibits a reachable state in which the layer does not
  meet it --- a replica integrates a peer's truncated tree and ends up holding
  a seq without an earlier one, while both report the same per-origin maximum.

  This theory takes the other route. Rather than asking the substrate to keep
  the hypothesis true, it changes the context representation so exactness holds
  for an ARBITRARY observed set. A hole then cannot be misread as observed,
  because a hole is representable.

  The representation is the standard compact-but-exact causal context: a
  contiguous prefix bound, plus the observed seqs above it. It is not a
  materialised set --- under the hypothesis the compact test needs, the
  exception set is empty and the bound is the maximum, so the entry degenerates
  to the single integer stored today.
\<close>

subsection \<open>Representation\<close>

text \<open>The first positive seq that is absent. Total on finite sets: some
  positive seq above the maximum is always absent.\<close>
definition first_gap :: "seq set \<Rightarrow> seq" where
  "first_gap S = (LEAST n. 0 < n \<and> n \<notin> S)"

text \<open>The contiguous prefix bound: every positive seq at or below it is
  present. This is the single integer the wire already carries.\<close>
definition contig :: "seq set \<Rightarrow> seq" where
  "contig S = first_gap S - 1"

text \<open>The observed seqs the prefix bound does not cover. Empty exactly when
  delivery was prefix closed.\<close>
definition exc :: "seq set \<Rightarrow> seq set" where
  "exc S = {s \<in> S. contig S < s}"

text \<open>The test itself, on the pair the representation stores.\<close>
definition observed_gapped :: "seq \<Rightarrow> seq set \<Rightarrow> seq \<Rightarrow> bool" where
  "observed_gapped b e s \<longleftrightarrow> s \<le> b \<or> s \<in> e"

subsection \<open>The gap exists\<close>

lemma ex_positive_absent:
  fixes S :: "seq set"
  assumes "finite S"
  shows "\<exists>n. 0 < n \<and> n \<notin> S"
proof -
  let ?n = "Suc (Max (insert 0 S))"
  have fin: "finite (insert 0 S)" using assms by simp
  have "?n \<notin> S"
  proof
    assume "?n \<in> S"
    hence "?n \<in> insert 0 S" by simp
    from Max_ge[OF fin this] have "?n \<le> Max (insert 0 S)" .
    thus False by simp
  qed
  moreover have "0 < ?n" by simp
  ultimately show ?thesis by blast
qed

lemma first_gap_absent:
  fixes S :: "seq set"
  assumes "finite S"
  shows "0 < first_gap S \<and> first_gap S \<notin> S"
  unfolding first_gap_def
  using LeastI_ex[OF ex_positive_absent[OF assms]] by blast

text \<open>Everything strictly below the first gap, and positive, is present ---
  which is what makes the prefix bound sound.\<close>
lemma below_first_gap:
  fixes S :: "seq set"
  assumes "0 < k" and "k < first_gap S"
  shows "k \<in> S"
proof (rule ccontr)
  assume "k \<notin> S"
  with \<open>0 < k\<close> have "0 < k \<and> k \<notin> S" by simp
  hence "first_gap S \<le> k" unfolding first_gap_def by (rule Least_le)
  with \<open>k < first_gap S\<close> show False by simp
qed

lemma contig_subset:
  fixes S :: "seq set"
  assumes fin: "finite S" and pos: "0 < k" and le: "k \<le> contig S"
  shows "k \<in> S"
proof -
  from first_gap_absent[OF fin] have "0 < first_gap S" by simp
  then obtain n where n: "first_gap S = Suc n" by (cases "first_gap S") auto
  hence "contig S = n" by (simp add: contig_def)
  with le have "k \<le> n" by simp
  hence "k < first_gap S" using n by simp
  thus ?thesis using below_first_gap[OF pos] by simp
qed

subsection \<open>Exactness, with no FIFO hypothesis\<close>

text \<open>
  The theorem the compact test cannot have. No @{text prefix} assumption:
  @{term obs} is an arbitrary finite set of positive seqs, holes and all.
\<close>
theorem gapped_test_exact:
  fixes obs :: "seq set"
  assumes fin: "finite obs" and pos: "0 < s"
  shows "observed_gapped (contig obs) (exc obs) s \<longleftrightarrow> s \<in> obs"
proof
  assume "observed_gapped (contig obs) (exc obs) s"
  thus "s \<in> obs"
    unfolding observed_gapped_def
    using contig_subset[OF fin pos] by (auto simp: exc_def)
next
  assume mem: "s \<in> obs"
  show "observed_gapped (contig obs) (exc obs) s"
    unfolding observed_gapped_def
  proof (cases "s \<le> contig obs")
    case True
    thus "s \<le> contig obs \<or> s \<in> exc obs" by simp
  next
    case False
    hence "s \<in> exc obs" using mem by (simp add: exc_def)
    thus "s \<le> contig obs \<or> s \<in> exc obs" by simp
  qed
qed

subsection \<open>No cost when delivery is well behaved\<close>

lemma exc_empty_if_downward_closed:
  fixes obs :: "seq set"
  assumes fin: "finite obs"
      and dc: "\<And>a b. b \<in> obs \<Longrightarrow> 0 < a \<Longrightarrow> a \<le> b \<Longrightarrow> a \<in> obs"
  shows "exc obs = {}"
proof (rule ccontr)
  assume "exc obs \<noteq> {}"
  then obtain s where s: "s \<in> obs" and gt: "contig obs < s"
    by (auto simp: exc_def)
  from first_gap_absent[OF fin]
  have gap: "first_gap obs \<notin> obs" and gpos: "0 < first_gap obs" by simp_all
  from gpos obtain n where n: "first_gap obs = Suc n" by (cases "first_gap obs") auto
  hence "contig obs = n" by (simp add: contig_def)
  with gt have "n < s" by simp
  hence "first_gap obs \<le> s" using n by simp
  hence "first_gap obs \<in> obs" using dc[OF s gpos] by simp
  with gap show False by simp
qed

text \<open>
  Under the hypothesis the compact test needs, the exception set is empty and
  the prefix bound IS the maximum --- so the representation degenerates to the
  single integer stored today, and the test degenerates to @{text "s \<le> Ctx[O]"}.
  Exactness for arbitrary delivery therefore costs nothing in the healthy case;
  it is paid for only where a hole actually exists.
\<close>
theorem gapped_degenerates:
  fixes obs :: "seq set"
  assumes fin: "finite obs"
      and pos: "\<And>t. t \<in> obs \<Longrightarrow> 0 < t"
      and dc:  "\<And>a b. b \<in> obs \<Longrightarrow> 0 < a \<Longrightarrow> a \<le> b \<Longrightarrow> a \<in> obs"
  shows "exc obs = {} \<and> contig obs = ctx_of obs"
proof
  show exc0: "exc obs = {}" using exc_empty_if_downward_closed[OF fin dc] .
next
  show "contig obs = ctx_of obs"
  proof (cases "obs = {}")
    case True
    have "first_gap obs = 1"
      unfolding first_gap_def using True by (intro Least_equality) auto
    thus ?thesis using True by (simp add: contig_def ctx_of_def)
  next
    case False
    have exc0: "exc obs = {}" using exc_empty_if_downward_closed[OF fin dc] .
    have le_all: "\<And>t. t \<in> obs \<Longrightarrow> t \<le> contig obs"
      using exc0 by (auto simp: exc_def)
    have mx: "Max obs \<in> obs" using fin False by simp
    have up: "Max obs \<le> contig obs" using le_all[OF mx] .
    have dn: "contig obs \<le> Max obs"
    proof (cases "contig obs = 0")
      case True
      then show ?thesis by simp
    next
      case False
      then have "0 < contig obs" by simp
      then have "contig obs \<in> obs"
        using contig_subset[OF fin, of "contig obs"] by simp
      then show ?thesis using fin by simp
    qed
    from up dn have "contig obs = Max obs" by simp
    thus ?thesis using False by (simp add: ctx_of_def)
  qed
qed

subsection \<open>The representation is faithful\<close>

text \<open>What the pair denotes: the seqs the test accepts.\<close>
definition denote :: "seq \<Rightarrow> seq set \<Rightarrow> seq set" where
  "denote b e = {s. 0 < s \<and> observed_gapped b e s}"

lemma denote_repr:
  fixes S :: "seq set"
  assumes fin: "finite S" and pos: "\<And>t. t \<in> S \<Longrightarrow> 0 < t"
  shows "denote (contig S) (exc S) = S"
proof (rule set_eqI)
  fix s
  show "s \<in> denote (contig S) (exc S) \<longleftrightarrow> s \<in> S"
  proof
    assume "s \<in> denote (contig S) (exc S)"
    hence p: "0 < s" and t: "observed_gapped (contig S) (exc S) s"
      by (simp_all add: denote_def)
    show "s \<in> S" using gapped_test_exact[OF fin p] t by blast
  next
    assume m: "s \<in> S"
    hence p: "0 < s" using pos by simp
    have "observed_gapped (contig S) (exc S) s"
      using gapped_test_exact[OF fin p] m by blast
    thus "s \<in> denote (contig S) (exc S)"
      using p by (simp add: denote_def)
  qed
qed

text \<open>
  Distinct observed sets have distinct representations. This is what makes a
  join defined ON the pairs well defined: the pair carries the whole set, so
  transporting union through it cannot lose or invent a seq.
\<close>
theorem repr_faithful:
  fixes A B :: "seq set"
  assumes finA: "finite A" and posA: "\<And>t. t \<in> A \<Longrightarrow> 0 < t"
      and finB: "finite B" and posB: "\<And>t. t \<in> B \<Longrightarrow> 0 < t"
      and eqb: "contig A = contig B"
      and eqe: "exc A = exc B"
  shows "A = B"
proof -
  have "A = denote (contig A) (exc A)" using denote_repr[OF finA posA] by simp
  also have "\<dots> = denote (contig B) (exc B)" using eqb eqe by simp
  also have "\<dots> = B" using denote_repr[OF finB posB] by simp
  finally show ?thesis .
qed

subsection \<open>Join\<close>

text \<open>A prefix bound is justified by the seqs below it: if everything
  positive up to @{term b} is present, the bound is at least @{term b}.\<close>
lemma contig_ge_bound:
  fixes S :: "seq set"
  assumes fin: "finite S"
      and all: "\<And>k. 0 < k \<Longrightarrow> k \<le> b \<Longrightarrow> k \<in> S"
  shows "b \<le> contig S"
proof -
  have "b < first_gap S"
  proof (rule ccontr)
    assume "\<not> b < first_gap S"
    hence le: "first_gap S \<le> b" by simp
    from first_gap_absent[OF fin]
    have gpos: "0 < first_gap S" and gabs: "first_gap S \<notin> S" by simp_all
    from all[OF gpos le] gabs show False by simp
  qed
  thus ?thesis by (simp add: contig_def)
qed

text \<open>
  THE MERGE SAFETY PROPERTY. The joined bound never regresses below either
  input's bound, so a replica that merges a peer's context cannot lose ground
  it had already established. This is the property @{text "merge_frontier/2"}
  relies on today from @{text max} being monotone; it survives the change of
  representation.
\<close>
theorem join_bound_no_regression:
  fixes A B :: "seq set"
  assumes finA: "finite A" and finB: "finite B"
  shows "max (contig A) (contig B) \<le> contig (A \<union> B)"
proof -
  have fin: "finite (A \<union> B)" using finA finB by simp
  have a: "contig A \<le> contig (A \<union> B)"
  proof (rule contig_ge_bound[OF fin])
    fix k assume "0 < k" and "k \<le> contig A"
    thus "k \<in> A \<union> B" using contig_subset[OF finA] by simp
  qed
  have b: "contig B \<le> contig (A \<union> B)"
  proof (rule contig_ge_bound[OF fin])
    fix k assume "0 < k" and "k \<le> contig B"
    thus "k \<in> A \<union> B" using contig_subset[OF finB] by simp
  qed
  from a b show ?thesis by simp
qed

text \<open>
  The join on representations denotes exactly the union of what the operands
  denote. With @{thm [source] repr_faithful} this is what lets the join be
  computed on pairs rather than on materialised sets.
\<close>
theorem join_denotes_union:
  fixes A B :: "seq set"
  assumes finA: "finite A" and posA: "\<And>t. t \<in> A \<Longrightarrow> 0 < t"
      and finB: "finite B" and posB: "\<And>t. t \<in> B \<Longrightarrow> 0 < t"
  shows "denote (contig (A \<union> B)) (exc (A \<union> B))
           = denote (contig A) (exc A) \<union> denote (contig B) (exc B)"
proof -
  have fin: "finite (A \<union> B)" using finA finB by simp
  have pos: "\<And>t. t \<in> A \<union> B \<Longrightarrow> 0 < t" using posA posB by blast
  show ?thesis
    using denote_repr[OF fin pos] denote_repr[OF finA posA]
          denote_repr[OF finB posB]
    by simp
qed

text \<open>The semilattice laws, inherited from union through the faithful
  encoding --- the obligation on any value merged by a CRDT.\<close>

lemma join_commutative: "A \<union> B = B \<union> A"
  by blast

lemma join_associative: "(A \<union> B) \<union> C = A \<union> (B \<union> C)"
  by blast

lemma join_idempotent: "A \<union> A = A"
  by blast

subsection \<open>The join degenerates to the integer max\<close>

lemma ctx_of_Un:
  fixes A B :: "seq set"
  assumes finA: "finite A" and finB: "finite B"
  shows "ctx_of (A \<union> B) = max (ctx_of A) (ctx_of B)"
proof (cases "A = {}")
  case True
  thus ?thesis by (simp add: ctx_of_def)
next
  case Ane: False
  show ?thesis
  proof (cases "B = {}")
    case True
    thus ?thesis using Ane by (simp add: ctx_of_def)
  next
    case Bne: False
    have "Max (A \<union> B) = max (Max A) (Max B)"
      using Max_Un[OF finA Ane finB Bne] .
    thus ?thesis using Ane Bne by (simp add: ctx_of_def)
  qed
qed

text \<open>
  THE COMPATIBILITY THEOREM. When both operands were delivered prefix closed,
  the joined exception set is empty and the joined bound is exactly the
  per-origin @{text max} the wire and the registry carry today. So an exact
  context costs nothing in the healthy case and needs no flag day: a bare
  integer is the correct encoding precisely when the exception set is empty,
  which is precisely when a peer that only understands integers would have
  been right anyway.
\<close>
theorem join_degenerates_to_max:
  fixes A B :: "seq set"
  assumes finA: "finite A" and posA: "\<And>t. t \<in> A \<Longrightarrow> 0 < t"
      and dcA: "\<And>a b. b \<in> A \<Longrightarrow> 0 < a \<Longrightarrow> a \<le> b \<Longrightarrow> a \<in> A"
      and finB: "finite B" and posB: "\<And>t. t \<in> B \<Longrightarrow> 0 < t"
      and dcB: "\<And>a b. b \<in> B \<Longrightarrow> 0 < a \<Longrightarrow> a \<le> b \<Longrightarrow> a \<in> B"
  shows "exc (A \<union> B) = {} \<and> contig (A \<union> B) = max (contig A) (contig B)"
proof -
  have fin: "finite (A \<union> B)" using finA finB by simp
  have pos: "\<And>t. t \<in> A \<union> B \<Longrightarrow> 0 < t" using posA posB by blast
  have dc: "\<And>a b. b \<in> A \<union> B \<Longrightarrow> 0 < a \<Longrightarrow> a \<le> b \<Longrightarrow> a \<in> A \<union> B"
    using dcA dcB by blast
  from gapped_degenerates[OF fin pos dc]
  have e0: "exc (A \<union> B) = {}" and cu: "contig (A \<union> B) = ctx_of (A \<union> B)"
    by simp_all
  from gapped_degenerates[OF finA posA dcA] have ca: "contig A = ctx_of A"
    by simp
  from gapped_degenerates[OF finB posB dcB] have cb: "contig B = ctx_of B"
    by simp
  have "contig (A \<union> B) = max (ctx_of A) (ctx_of B)"
    using cu ctx_of_Un[OF finA finB] by simp
  thus ?thesis using e0 ca cb by simp
qed

subsection \<open>What this buys\<close>

text \<open>
  @{thm [source] gapped_test_exact} has no @{text prefix} hypothesis, so the
  obligation @{text Dot_Exactness} places on the anti-entropy layer --- "if
  delivery could skip a seq that this origin spent ON THIS CELL ... the compact
  test would report a skipped dot as observed" --- is discharged by the
  representation rather than owed by the protocol.

  Concretely: with an exact context, @{text "drop_observed/2"} can no longer
  remove an add the writer never saw, because a seq strictly inside a hole
  tests as NOT observed. Prefix closure remains desirable for the convergence
  oracle and for compactness, but it stops being a correctness precondition of
  the observed-remove primitives.
\<close>

end
