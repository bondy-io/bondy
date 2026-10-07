(*
  SPDX-FileCopyrightText: 2016 - 2026 Leapsight
  SPDX-License-Identifier: Apache-2.0
*)

theory Confirmed_Compaction
  imports Main
begin

section \<open>Compaction by peer confirmation: nothing un-applied is ever unshippable\<close>

text \<open>
  A replica may truncate an event out of its MST only once every other
  member can be shown to hold it, or the event becomes unreachable for a
  member that has not applied it yet. A member is shown to hold an event
  by the durable frontier it last reported: the event's seq is at or below
  that frontier's entry for its origin
  (@{text "bondy_oplog_instance:compute_frontier_for/2"},
  @{text "bondy_oplog_event:covered/2"}). @{text "../tla/ConfirmedCompaction.tla"}
  models the same rule with keys in HLC order and TLC-checks it at two and
  three replicas. This theory proves it for any number of replicas and any
  number of events, over a state machine that over-approximates the TLA+
  model:

  \<^item> truncation removes ANY subset of the tree that is applied locally and
    confirmed by every other member --- no key order, so every frontier the
    code can pick is covered. Applied locally is what the replica's own
    durable frontier, also a witness, confirms;
  \<^item> the watermark door removes ANY applied subset after a merge;
  \<^item> a fold applies ANY prefix-closed set between what was applied and what
    the tree offers --- the inline fold of the fused instance and the
    applier's replay with the prefix hold are both instances;
  \<^item> a report writes, at any time and independently of any merge, the
    frontier of ANY prefix-closed subset of what the peer has applied. A
    reported durable frontier is one: it is the frontier of what the peer had
    applied when it was read (at its last checkpoint on a durable backend, the
    live applied frontier on ETS), and the applied set only grows. So a
    report recorded late, out of order, or not at all (an empty report keeps
    the previous row) is an instance.

  One fact about the rule carries the proof: a recorded frontier is the
  per-origin maximum of a prefix-closed set the peer applied, so everything
  at or below it was applied, and stays applied.

  What the theory does NOT establish: liveness (the TLA+ liveness configs),
  anything under @{text mst_retention} (it truncates past a member that has
  not confirmed), a retired origin's keys (every witness counts them as
  confirmed), membership change (the member set is fixed here; the code
  reads it on every cycle), the unservable-root rebuild
  (@{text "rebuild_frontier/2"} truncates the whole tree on a cover check,
  not this rule; the TLA+ lost-page configurations model it), crashes (a member that restarts with
  less applied than it reported keeps its old row until it reports a
  non-empty frontier), and that the code implements the rule.
\<close>

subsection \<open>Events, prefix closure, the per-origin maximum\<close>

type_synonym event = "nat \<times> nat"   \<comment> \<open>(origin, seq)\<close>

definition prefix_closed :: "event set \<Rightarrow> bool" where
  "prefix_closed S \<longleftrightarrow> (\<forall>og s. (og, s) \<in> S \<longrightarrow> (\<forall>i. 1 \<le> i \<longrightarrow> i \<le> s \<longrightarrow> (og, i) \<in> S))"

definition mx :: "nat set \<Rightarrow> nat" where
  "mx S = (if S = {} then 0 else Max S)"

lemma mx_in: "finite S \<Longrightarrow> S \<noteq> {} \<Longrightarrow> mx S \<in> S"
  by (simp add: mx_def)

text \<open>A frontier's entry for origin @{term og}: the largest seq of that
  origin in the set.\<close>
definition vv_of :: "event set \<Rightarrow> nat \<Rightarrow> nat" where
  "vv_of S og = mx {s. (og, s) \<in> S}"

text \<open>Under prefix closure the maximum is a contiguous bound: everything at
  or below it is present. This is the one property of the frontier the rule
  relies on, and the reason the prefix hold is a precondition.\<close>
lemma vv_of_witness:
  assumes "finite S" and "prefix_closed S" and "1 \<le> s" and "s \<le> vv_of S og"
  shows "(og, s) \<in> S"
proof -
  let ?T = "{s. (og, s) \<in> S}"
  have fin: "finite ?T"
  proof -
    have "?T \<subseteq> snd ` S" by force
    thus ?thesis using assms(1) by (rule finite_subset[OF _ finite_imageI])
  qed
  have "?T \<noteq> {}"
  proof
    assume "?T = {}"
    hence "vv_of S og = 0" by (simp add: vv_of_def mx_def)
    with assms(3,4) show False by simp
  qed
  hence "mx ?T \<in> ?T" by (rule mx_in[OF fin])
  hence "(og, vv_of S og) \<in> S" by (simp add: vv_of_def)
  with assms(2,3,4) show ?thesis unfolding prefix_closed_def by blast
qed


subsection \<open>The state\<close>

text \<open>
  Replicas and origins share the naturals; the member set @{term R} is a
  parameter. Per replica: the tree (items under the MST root), the applied
  set (the projection), per peer the recorded frontier, and @{term cw}, a
  history variable: everything the replica has ever truncated.
  @{term minted} is the per-origin count.
\<close>

record cst =
  minted  :: "nat \<Rightarrow> nat"
  tree    :: "nat \<Rightarrow> event set"
  applied :: "nat \<Rightarrow> event set"
  vv      :: "nat \<Rightarrow> nat \<Rightarrow> nat \<Rightarrow> nat"
  cw      :: "nat \<Rightarrow> event set"   \<comment> \<open>history: what this replica has truncated\<close>

definition events :: "nat set \<Rightarrow> cst \<Rightarrow> event set" where
  "events R s = {(og, i). og \<in> R \<and> 1 \<le> i \<and> i \<le> minted s og}"

definition holds :: "cst \<Rightarrow> nat \<Rightarrow> event \<Rightarrow> bool" where
  "holds s q e \<longleftrightarrow> e \<in> tree s q \<or> e \<in> applied s q"

text \<open>The rule.\<close>
definition confirmed :: "cst \<Rightarrow> nat \<Rightarrow> nat \<Rightarrow> event \<Rightarrow> bool" where
  "confirmed s r p e \<longleftrightarrow> snd e \<le> vv s r p (fst e)"


subsection \<open>The protocol\<close>

locale members =
  fixes R :: "nat set"
  assumes fin_R: "finite R"
begin

text \<open>
  Each rule names the Erlang it stands for.

  \<^item> @{text mint}: a local append --- in the tree and applied (the applier
    writes the projection before the MST install).
  \<^item> @{text sync}: a pull round of @{term r} from @{term p}. The merged tree is the union; the fold applies a
    prefix-closed set @{term A} (@{text "apply_cell_pairs_mux"} with the
    hold; @{term "A = applied s r"} is the applier-backed instance whose
    replay comes later); the door drops @{term D}, a subset of what is
    applied after the fold (@{text "watermark_door/2"}) --- and, for the
    replica's OWN events, only what it truncated before: the door acts at
    or below the watermark, and an own event is minted above every
    watermark then in force (@{text "bondy_connect_hlc"}), so an own event
    at or below it was in the tree when the watermark was set and went
    with that truncation. This is the one place key order enters this
    theory, as a hypothesis the TLA+ model discharges.
  \<^item> @{text report}: @{term r} records a frontier for @{term p}
    (@{text "bondy_oplog_peer_state:record_sync_complete/3"}): the one the
    initiator read from @{term p} before a round, or the one @{term p}
    reported after a round it initiated (@{text confirm_frontier}). Both
    writes are casts, so neither is ordered with the merge.
  \<^item> @{text replay}: the applier folds a prefix-closed set from the tree.
  \<^item> @{text compact}: truncation of a subset that is applied here and
    confirmed by every other member.
\<close>

inductive step :: "cst \<Rightarrow> cst \<Rightarrow> bool" where
  mint:
    "r \<in> R \<Longrightarrow> e = (r, Suc (minted s r)) \<Longrightarrow>
     step s (s\<lparr>minted := (minted s)(r := Suc (minted s r)),
               tree := (tree s)(r := insert e (tree s r)),
               applied := (applied s)(r := insert e (applied s r))\<rparr>)"
| sync:
    "r \<in> R \<Longrightarrow> p \<in> R \<Longrightarrow> r \<noteq> p \<Longrightarrow>
     U = tree s r \<union> tree s p \<Longrightarrow>
     applied s r \<subseteq> A \<Longrightarrow> A \<subseteq> applied s r \<union> U \<Longrightarrow> prefix_closed A \<Longrightarrow>
     D \<subseteq> A \<Longrightarrow> (\<And>x. x \<in> D \<Longrightarrow> fst x = r \<Longrightarrow> x \<in> cw s r) \<Longrightarrow>
     step s (s\<lparr>tree := (tree s)(r := U - D),
               applied := (applied s)(r := A)\<rparr>)"
| report:
    "r \<in> R \<Longrightarrow> p \<in> R \<Longrightarrow> r \<noteq> p \<Longrightarrow>
     B \<subseteq> applied s p \<Longrightarrow> prefix_closed B \<Longrightarrow>
     step s (s\<lparr>vv := (vv s)(r := (vv s r)(p := vv_of B))\<rparr>)"
| replay:
    "r \<in> R \<Longrightarrow>
     applied s r \<subseteq> A \<Longrightarrow> A \<subseteq> applied s r \<union> tree s r \<Longrightarrow> prefix_closed A \<Longrightarrow>
     step s (s\<lparr>applied := (applied s)(r := A)\<rparr>)"
| compact:
    "r \<in> R \<Longrightarrow> C \<subseteq> tree s r \<Longrightarrow> C \<subseteq> applied s r \<Longrightarrow>
     (\<And>e p. e \<in> C \<Longrightarrow> p \<in> R \<Longrightarrow> p \<noteq> r \<Longrightarrow> confirmed s r p e) \<Longrightarrow>
     step s (s\<lparr>tree := (tree s)(r := tree s r - C),
               cw := (cw s)(r := cw s r \<union> C)\<rparr>)"

definition init :: cst where
  "init = \<lparr>minted = (\<lambda>_. 0), tree = (\<lambda>_. {}), applied = (\<lambda>_. {}),
           vv = (\<lambda>_ _ _. 0), cw = (\<lambda>_. {})\<rparr>"

inductive reachable :: "cst \<Rightarrow> bool" where
  reachable_init: "reachable init"
| reachable_step: "reachable s \<Longrightarrow> step s s' \<Longrightarrow> reachable s'"


subsection \<open>The inductive invariant\<close>

text \<open>
  \<^item> WF: trees and applied sets hold minted events only;
  \<^item> OWN: a replica has applied every event it minted --- own origins are
    contiguous by minting;
  \<^item> PC: every applied set is prefix-closed --- the hold;
  \<^item> VV: a recorded frontier entry bounds a prefix the peer has applied;
  \<^item> TRUNC: what a replica truncated, every other member holds;
  \<^item> SHIP: a minted event is in its minter's tree, was truncated by its
    minter (and so, by TRUNC, is held by everyone else), or is held by the
    member in question. This is what makes NoLoss a consequence: a member
    that has not applied the event holds it in its tree, or the minter
    still ships it.
\<close>

definition WF :: "cst \<Rightarrow> bool" where
  "WF s \<longleftrightarrow> (\<forall>r \<in> R. tree s r \<subseteq> events R s \<and> applied s r \<subseteq> events R s)"

definition OWN :: "cst \<Rightarrow> bool" where
  "OWN s \<longleftrightarrow> (\<forall>r \<in> R. \<forall>i. 1 \<le> i \<longrightarrow> i \<le> minted s r \<longrightarrow> (r, i) \<in> applied s r)"

definition PC :: "cst \<Rightarrow> bool" where
  "PC s \<longleftrightarrow> (\<forall>r \<in> R. prefix_closed (applied s r))"

definition VVI :: "cst \<Rightarrow> bool" where
  "VVI s \<longleftrightarrow> (\<forall>r \<in> R. \<forall>p \<in> R. \<forall>og i. 1 \<le> i \<longrightarrow> i \<le> vv s r p og \<longrightarrow> (og, i) \<in> applied s p)"

definition TRUNC :: "cst \<Rightarrow> bool" where
  "TRUNC s \<longleftrightarrow> (\<forall>r \<in> R. \<forall>e \<in> cw s r. \<forall>q \<in> R. q \<noteq> r \<longrightarrow> holds s q e)"

definition SHIP :: "cst \<Rightarrow> bool" where
  "SHIP s \<longleftrightarrow> (\<forall>e \<in> events R s. \<forall>q \<in> R. q \<noteq> fst e \<longrightarrow>
                 e \<in> cw s (fst e) \<or> e \<in> tree s (fst e) \<or> holds s q e)"

definition inv :: "cst \<Rightarrow> bool" where
  "inv s \<longleftrightarrow> WF s \<and> OWN s \<and> PC s \<and> VVI s \<and> TRUNC s \<and> SHIP s"

lemma events_finite: "finite (events R s)"
proof -
  let ?M = "Max (minted s ` R)"
  have "events R s \<subseteq> R \<times> {0..?M}"
  proof
    fix x assume x: "x \<in> events R s"
    obtain og i where xi: "x = (og, i)" by (cases x)
    with x have og: "og \<in> R" "i \<le> minted s og" by (simp_all add: events_def)
    have "minted s og \<le> ?M" using fin_R og(1) by (intro Max_ge) auto
    with xi og show "x \<in> R \<times> {0..?M}" by simp
  qed
  moreover have "finite (R \<times> {0..?M})" using fin_R by simp
  ultimately show ?thesis by (rule finite_subset)
qed

lemma applied_finite:
  assumes "WF s" and "p \<in> R"
  shows "finite (applied s p)"
proof -
  have "applied s p \<subseteq> events R s" using assms unfolding WF_def by blast
  thus ?thesis using events_finite by (rule finite_subset)
qed

lemma inv_init: "inv init"
  by (simp add: inv_def WF_def OWN_def PC_def VVI_def TRUNC_def SHIP_def
                init_def events_def holds_def prefix_closed_def)

text \<open>A confirmed event is held by the confirming peer --- from VV.\<close>
lemma confirmed_holds:
  assumes "VVI s" and "r \<in> R" and "p \<in> R" and "confirmed s r p e"
    and "e \<in> events R s"
  shows "holds s p e"
proof -
  obtain og i where e: "e = (og, i)" by (cases e)
  with assms(5) have "1 \<le> i" unfolding events_def by auto
  with assms(1-4) e have "(og, i) \<in> applied s p" unfolding VVI_def confirmed_def by auto
  thus ?thesis using e unfolding holds_def by simp
qed

text \<open>A recorded frontier is a witness: the per-origin maximum of a
  prefix-closed set the peer applied.\<close>
lemma vv_record_witness:
  assumes "WF s" and "p \<in> R" and "B \<subseteq> applied s p" and "prefix_closed B"
    and "1 \<le> i" and "i \<le> vv_of B og"
  shows "(og, i) \<in> applied s p"
proof -
  have "finite B" using assms(3) applied_finite[OF assms(1,2)] by (rule finite_subset)
  hence "(og, i) \<in> B" using assms(4-6) by (rule vv_of_witness)
  thus ?thesis using assms(3) by blast
qed

lemma prefix_closed_insert_own:
  assumes "prefix_closed S" and "\<forall>i. 1 \<le> i \<longrightarrow> i \<le> n \<longrightarrow> (r, i) \<in> S"
  shows "prefix_closed (insert (r, Suc n) S)"
  using assms unfolding prefix_closed_def by (auto simp: le_Suc_eq)

text \<open>A record keeps VV, given that the recorded set is prefix-closed and
  applied by the peer.\<close>
lemma VVI_record:
  assumes "VVI s" and "WF s" and "p \<in> R"
    and B: "B \<subseteq> applied s p" "prefix_closed B"
  shows "VVI (s\<lparr>vv := (vv s)(r := (vv s r)(p := vv_of B))\<rparr>)"
  unfolding VVI_def
proof (intro ballI allI impI)
  fix q q' og i assume q: "q \<in> R" "q' \<in> R" and i: "1 \<le> i"
    and le: "i \<le> vv (s\<lparr>vv := (vv s)(r := (vv s r)(p := vv_of B))\<rparr>) q q' og"
  show "(og, i) \<in> applied (s\<lparr>vv := (vv s)(r := (vv s r)(p := vv_of B))\<rparr>) q'"
  proof (cases "q = r \<and> q' = p")
    case True
    with le have "i \<le> vv_of B og" by simp
    with True assms(2,3) B i show ?thesis by (auto intro: vv_record_witness)
  next
    case False
    with le have "i \<le> vv s q q' og" by (auto split: if_splits)
    with assms(1) q i show ?thesis unfolding VVI_def by simp
  qed
qed

text \<open>The generic preservation argument: a step that keeps the minted
  counts, grows every applied and truncated set, moves a tree item only
  into the applied set, and re-establishes WF, PC and VV, preserves the
  invariant once TRUNC and SHIP are shown for what changed.\<close>
lemma inv_stable:
  assumes "inv s"
    and minted: "minted s' = minted s"
    and app: "\<And>r. applied s r \<subseteq> applied s' r"
    and wf: "WF s'" and pc: "PC s'" and vvi: "VVI s'"
    and hm: "\<And>q x. holds s q x \<Longrightarrow> holds s' q x"
    and cwm: "\<And>r. cw s r \<subseteq> cw s' r"
    and cwn: "\<And>r e q. r \<in> R \<Longrightarrow> e \<in> cw s' r \<Longrightarrow> e \<notin> cw s r \<Longrightarrow> q \<in> R \<Longrightarrow> q \<noteq> r \<Longrightarrow> holds s' q e"
    and ship: "\<And>e q. e \<in> events R s \<Longrightarrow> q \<in> R \<Longrightarrow> q \<noteq> fst e \<Longrightarrow> e \<in> tree s (fst e) \<Longrightarrow>
                 e \<in> cw s' (fst e) \<or> e \<in> tree s' (fst e) \<or> holds s' q e"
  shows "inv s'"
proof -
  note I = assms(1)[unfolded inv_def]
  have ev: "events R s' = events R s" unfolding events_def minted by simp
  have "OWN s" using I by blast
  hence "OWN s'" unfolding OWN_def minted using app by blast
  moreover have "TRUNC s'" unfolding TRUNC_def
  proof (intro ballI impI)
    fix r e q assume "r \<in> R" "e \<in> cw s' r" "q \<in> R" "q \<noteq> r"
    thus "holds s' q e" using I cwn hm unfolding TRUNC_def by (cases "e \<in> cw s r") blast+
  qed
  moreover have "SHIP s'" unfolding SHIP_def
  proof (intro ballI impI)
    fix e q assume e: "e \<in> events R s'" and q: "q \<in> R" "q \<noteq> fst e"
    from e ev have es: "e \<in> events R s" by simp
    with I q have "e \<in> cw s (fst e) \<or> e \<in> tree s (fst e) \<or> holds s q e"
      unfolding SHIP_def by blast
    thus "e \<in> cw s' (fst e) \<or> e \<in> tree s' (fst e) \<or> holds s' q e"
      using cwm hm ship[OF es q] by blast
  qed
  ultimately show ?thesis unfolding inv_def using wf pc vvi by blast
qed

text \<open>VV is untouched by a step that leaves the records alone and only grows
  what is applied.\<close>
lemma VVI_keep:
  assumes "VVI s" and "vv s' = vv s" and "\<And>r. applied s r \<subseteq> applied s' r"
  shows "VVI s'"
  using assms(1,3) unfolding VVI_def assms(2) by blast

lemma inv_step:
  assumes "inv s" and "step s s'"
  shows "inv s'"
  using assms(2) assms(1)
proof (induction rule: step.induct)
  case (mint r e s)
  note I = mint.prems[unfolded inv_def]
  let ?s' = "s\<lparr>minted := (minted s)(r := Suc (minted s r)),
               tree := (tree s)(r := insert e (tree s r)),
               applied := (applied s)(r := insert e (applied s r))\<rparr>"
  have ev: "events R s \<subseteq> events R ?s'" and ev_e: "e \<in> events R ?s'"
    using mint.hyps unfolding events_def by auto
  have hm: "\<And>q x. holds s q x \<Longrightarrow> holds ?s' q x" unfolding holds_def by auto
  have "WF ?s'" using I ev ev_e unfolding WF_def by auto
  moreover have "OWN ?s'" using I mint.hyps unfolding OWN_def by (auto simp: le_Suc_eq)
  moreover have "PC ?s'" using I mint.hyps unfolding PC_def OWN_def
    by (auto intro: prefix_closed_insert_own)
  moreover have "VVI ?s'" using I unfolding VVI_def by (simp; blast)
  moreover have "TRUNC ?s'" using I hm unfolding TRUNC_def by (simp; blast)
  moreover have "SHIP ?s'" unfolding SHIP_def
  proof (intro ballI impI)
    fix x q assume x: "x \<in> events R ?s'" and q: "q \<in> R" "q \<noteq> fst x"
    show "x \<in> cw ?s' (fst x) \<or> x \<in> tree ?s' (fst x) \<or> holds ?s' q x"
    proof (cases "x = e")
      case True thus ?thesis using mint.hyps by simp
    next
      case False
      with x mint.hyps have "x \<in> events R s"
        unfolding events_def by (auto simp: le_Suc_eq split: if_splits)
      with I q have "x \<in> cw s (fst x) \<or> x \<in> tree s (fst x) \<or> holds s q x"
        unfolding SHIP_def by blast
      thus ?thesis
      proof (elim disjE)
        assume "x \<in> cw s (fst x)" thus ?thesis by simp
      next
        assume "x \<in> tree s (fst x)" thus ?thesis by auto
      next
        assume "holds s q x" thus ?thesis using hm[of q x] by blast
      qed
    qed
  qed
  ultimately show ?case unfolding inv_def by blast
next
  case (sync r p U s A D)
  note I = sync.prems[unfolded inv_def]
  let ?s' = "s\<lparr>tree := (tree s)(r := U - D),
               applied := (applied s)(r := A)\<rparr>"
  have hm: "\<And>q x. holds s q x \<Longrightarrow> holds ?s' q x"
    using sync.hyps unfolding holds_def by auto
  have app: "\<And>q. applied s q \<subseteq> applied ?s' q" using sync.hyps by simp
  have ev: "events R ?s' = events R s" unfolding events_def by simp
  have wf: "WF ?s'"
  proof -
    have "U \<subseteq> events R s" and "A \<subseteq> events R s"
      using I sync.hyps unfolding WF_def by blast+
    thus ?thesis using I ev unfolding WF_def by auto
  qed
  have pc: "PC ?s'" using I sync.hyps unfolding PC_def by simp
  have "VVI s" using I by blast
  have vvi: "VVI ?s'" by (rule VVI_keep[OF \<open>VVI s\<close> _ app]) simp
  show ?case
  proof (rule inv_stable[OF sync.prems _ app wf pc vvi hm])
    show "minted ?s' = minted s" by simp
  next
    fix q show "cw s q \<subseteq> cw ?s' q" by simp
  next
    fix q x q' assume "x \<in> cw ?s' q" "x \<notin> cw s q"
    thus "holds ?s' q' x" by simp
  next
    fix x q assume x: "x \<in> events R s" and q: "q \<in> R" "q \<noteq> fst x" and t: "x \<in> tree s (fst x)"
    show "x \<in> cw ?s' (fst x) \<or> x \<in> tree ?s' (fst x) \<or> holds ?s' q x"
    proof (cases "fst x = r")
      case True
      with t sync.hyps have "x \<in> U" by simp
      show ?thesis
      proof (cases "x \<in> D")
        case True
        with \<open>fst x = r\<close> sync.hyps have "x \<in> cw s r" by blast
        with \<open>fst x = r\<close> show ?thesis by simp
      next
        case False
        with \<open>x \<in> U\<close> True show ?thesis by simp
      qed
    next
      case False
      with t show ?thesis by simp
    qed
  qed
next
  case (report r p B s)
  note I = report.prems[unfolded inv_def]
  let ?s' = "s\<lparr>vv := (vv s)(r := (vv s r)(p := vv_of B))\<rparr>"
  have hm: "\<And>q x. holds s q x \<Longrightarrow> holds ?s' q x" unfolding holds_def by simp
  have app: "\<And>q. applied s q \<subseteq> applied ?s' q" by simp
  have wf: "WF ?s'" using I unfolding WF_def events_def by simp
  have pc: "PC ?s'" using I unfolding PC_def by simp
  have "VVI s" and "WF s" using I by blast+
  have vvi: "VVI ?s'"
    by (rule VVI_record[OF \<open>VVI s\<close> \<open>WF s\<close>]) (use report.hyps in simp_all)
  show ?case
  proof (rule inv_stable[OF report.prems _ app wf pc vvi hm])
    show "minted ?s' = minted s" by simp
  next
    fix q show "cw s q \<subseteq> cw ?s' q" by simp
  next
    fix q x q' assume "x \<in> cw ?s' q" "x \<notin> cw s q"
    thus "holds ?s' q' x" by simp
  next
    fix x q assume "x \<in> tree s (fst x)"
    thus "x \<in> cw ?s' (fst x) \<or> x \<in> tree ?s' (fst x) \<or> holds ?s' q x" by simp
  qed
next
  case (replay r s A)
  note I = replay.prems[unfolded inv_def]
  let ?s' = "s\<lparr>applied := (applied s)(r := A)\<rparr>"
  have hm: "\<And>q x. holds s q x \<Longrightarrow> holds ?s' q x"
    using replay.hyps unfolding holds_def by auto
  have app: "\<And>q. applied s q \<subseteq> applied ?s' q" using replay.hyps by simp
  have wf: "WF ?s'"
  proof -
    have "A \<subseteq> events R s" using I replay.hyps unfolding WF_def by blast
    thus ?thesis using I unfolding WF_def events_def by auto
  qed
  have pc: "PC ?s'" using I replay.hyps unfolding PC_def by simp
  have "VVI s" using I by blast
  have vvi: "VVI ?s'" by (rule VVI_keep[OF \<open>VVI s\<close> _ app]) simp
  show ?case
  proof (rule inv_stable[OF replay.prems _ app wf pc vvi hm])
    show "minted ?s' = minted s" by simp
  next
    fix q show "cw s q \<subseteq> cw ?s' q" by simp
  next
    fix q x q' assume "x \<in> cw ?s' q" "x \<notin> cw s q"
    thus "holds ?s' q' x" by simp
  next
    fix x q assume "x \<in> tree s (fst x)"
    thus "x \<in> cw ?s' (fst x) \<or> x \<in> tree ?s' (fst x) \<or> holds ?s' q x" by simp
  qed
next
  case (compact r C s)
  note I = compact.prems[unfolded inv_def]
  let ?s' = "s\<lparr>tree := (tree s)(r := tree s r - C),
               cw := (cw s)(r := cw s r \<union> C)\<rparr>"
  have hm: "\<And>q x. holds s q x \<Longrightarrow> holds ?s' q x"
    using compact.hyps unfolding holds_def by auto
  have "VVI s" using I by blast
  have conf: "\<And>x q. x \<in> C \<Longrightarrow> q \<in> R \<Longrightarrow> q \<noteq> r \<Longrightarrow> holds ?s' q x"
  proof -
    fix x q assume x: "x \<in> C" and q: "q \<in> R" "q \<noteq> r"
    from x compact.hyps I have xe: "x \<in> events R s" unfolding WF_def by blast
    from confirmed_holds[OF \<open>VVI s\<close> compact.hyps(1) q(1) compact.hyps(4)[OF x q] xe]
    show "holds ?s' q x" by (rule hm)
  qed
  have wf: "WF ?s'" using I unfolding WF_def events_def by auto
  have pc: "PC ?s'" using I unfolding PC_def by simp
  have vvi: "VVI ?s'" by (rule VVI_keep[OF \<open>VVI s\<close>]) simp_all
  show ?case
  proof (rule inv_stable[OF compact.prems _ _ wf pc vvi hm])
    show "minted ?s' = minted s" by simp
  next
    fix q show "applied s q \<subseteq> applied ?s' q" by simp
  next
    fix q show "cw s q \<subseteq> cw ?s' q" by simp
  next
    fix q x q' assume "q \<in> R" "x \<in> cw ?s' q" "x \<notin> cw s q" "q' \<in> R" "q' \<noteq> q"
    thus "holds ?s' q' x" using conf by (cases "q = r") auto
  next
    fix x q assume t: "x \<in> tree s (fst x)"
    show "x \<in> cw ?s' (fst x) \<or> x \<in> tree ?s' (fst x) \<or> holds ?s' q x"
      using t by (cases "fst x = r") auto
  qed
qed

lemma inv_reachable: "reachable s \<Longrightarrow> inv s"
  by (induction rule: reachable.induct) (auto intro: inv_init inv_step)


subsection \<open>The theorems\<close>

text \<open>NoLoss: an event a member has not applied is in some member's tree.\<close>
theorem no_loss:
  assumes "reachable s" and "e \<in> events R s" and "q \<in> R" and "e \<notin> applied s q"
  shows "\<exists>r \<in> R. e \<in> tree s r"
proof -
  note I = inv_reachable[OF assms(1), unfolded inv_def]
  obtain og i where e: "e = (og, i)" by (cases e)
  with assms(2) have og: "og \<in> R" "1 \<le> i" "i \<le> minted s og" unfolding events_def by auto
  show ?thesis
  proof (cases "q = og")
    case True
    with I og e assms(4) show ?thesis unfolding OWN_def by blast
  next
    case False
    from I have S: "SHIP s" by blast
    have "q \<noteq> fst e" using e False by simp
    with S assms(2,3) have "e \<in> cw s (fst e) \<or> e \<in> tree s (fst e) \<or> holds s q e"
      unfolding SHIP_def by blast
    hence "e \<in> cw s og \<or> e \<in> tree s og \<or> holds s q e" using e by simp
    thus ?thesis
    proof (elim disjE)
      assume "e \<in> cw s og"
      with I og(1) assms(3) False have "holds s q e" unfolding TRUNC_def by blast
      with assms(3,4) show ?thesis unfolding holds_def by auto
    next
      assume "e \<in> tree s og" with og(1) show ?thesis by blast
    next
      assume "holds s q e" with assms(3,4) show ?thesis unfolding holds_def by auto
    qed
  qed
qed

text \<open>NoDrop: no step removes an event from a tree without it being applied
  there --- the compact rule's own condition plus the door's.\<close>
theorem no_drop:
  assumes "step s s'" and "r \<in> R" and "e \<in> tree s r" and "e \<notin> tree s' r"
  shows "e \<in> applied s' r"
  using assms by (cases rule: step.cases) (auto split: if_splits)

end

end
