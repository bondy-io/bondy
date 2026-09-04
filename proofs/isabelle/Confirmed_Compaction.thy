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
  member that has not applied it yet. @{text "../tla/ConfirmedCompaction.tla"}
  models the shipped confirmation --- a peer's recorded ROOT --- and the
  rule under proof --- root OR the peer's recorded applied VV --- with keys
  in HLC order and TLC-checked at two and three replicas. This theory proves
  the rule under proof for any number of replicas and any number of events,
  over a state machine that over-approximates the TLA+ model:

  \<^item> truncation removes ANY subset of the tree that is applied locally and
    confirmed by every peer --- no key order, so every frontier the code
    can pick (and every retention policy that respects the two conditions)
    is covered;
  \<^item> the watermark door removes ANY applied subset after a merge;
  \<^item> a fold applies ANY prefix-closed set between what was applied and what
    the tree offers --- the inline fold of the fused instance and the
    applier's replay with the prefix hold are both instances;
  \<^item> a recorded root may be forgotten at any time (the ETS page GC) --- a
    pure weakening of what a replica can certify.

  Two facts about the rule carry the proof:

  \<^item> a recorded root is a set of events its peer HELD at record time, and
    holding (in the tree or applied) is stable: the tree loses an event only
    into the applied set, and the applied set only grows;
  \<^item> a recorded VV entry is the per-origin maximum of a prefix-closed applied
    set, so everything at or below it was applied, and stays applied.

  The confirm half of a round --- the initiator tells the peer it holds the
  peer's root --- is sound for the same reason: the initiator's merged tree
  contains that root minus what its door dropped, and the door drops only
  applied events.

  What the theory does NOT establish: liveness (the TLA+ liveness configs),
  anything under the recency filter or @{text mst_retention} (both let a
  replica truncate past a member that has not confirmed --- out of scope
  by design, repaired by catalogue rebootstrap), and that the code
  implements the rule.
\<close>

subsection \<open>Events, prefix closure, the per-origin maximum\<close>

type_synonym event = "nat \<times> nat"   \<comment> \<open>(origin, seq)\<close>

definition prefix_closed :: "event set \<Rightarrow> bool" where
  "prefix_closed S \<longleftrightarrow> (\<forall>og s. (og, s) \<in> S \<longrightarrow> (\<forall>i. 1 \<le> i \<longrightarrow> i \<le> s \<longrightarrow> (og, i) \<in> S))"

definition mx :: "nat set \<Rightarrow> nat" where
  "mx S = (if S = {} then 0 else Max S)"

lemma mx_in: "finite S \<Longrightarrow> S \<noteq> {} \<Longrightarrow> mx S \<in> S"
  by (simp add: mx_def)

text \<open>What @{text get_frontier} reports for origin @{term og}: the largest
  applied seq of that origin.\<close>
definition vv_of :: "event set \<Rightarrow> nat \<Rightarrow> nat" where
  "vv_of S og = mx {s. (og, s) \<in> S}"

text \<open>Under prefix closure the maximum is a contiguous bound: everything at
  or below it is present. This is the one property of the VV the rule
  relies on, and the reason the shipped prefix hold is a precondition.\<close>
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
  set (the projection), per peer the recorded root (@{term None} once
  forgotten or never recorded) and the recorded VV, and @{term cw}, a
  history variable: everything the replica has ever truncated. @{term minted}
  is the per-origin count.
\<close>

record cst =
  minted  :: "nat \<Rightarrow> nat"
  tree    :: "nat \<Rightarrow> event set"
  applied :: "nat \<Rightarrow> event set"
  root    :: "nat \<Rightarrow> nat \<Rightarrow> event set option"
  vv      :: "nat \<Rightarrow> nat \<Rightarrow> nat \<Rightarrow> nat"
  cw      :: "nat \<Rightarrow> event set"   \<comment> \<open>history: what this replica has truncated\<close>

definition events :: "nat set \<Rightarrow> cst \<Rightarrow> event set" where
  "events R s = {(og, i). og \<in> R \<and> 1 \<le> i \<and> i \<le> minted s og}"

definition holds :: "cst \<Rightarrow> nat \<Rightarrow> event \<Rightarrow> bool" where
  "holds s q e \<longleftrightarrow> e \<in> tree s q \<or> e \<in> applied s q"

text \<open>The rule under proof.\<close>
definition confirmed :: "cst \<Rightarrow> nat \<Rightarrow> nat \<Rightarrow> event \<Rightarrow> bool" where
  "confirmed s r p e \<longleftrightarrow>
     (\<exists>T. root s r p = Some T \<and> e \<in> T) \<or> snd e \<le> vv s r p (fst e)"


subsection \<open>The protocol\<close>

locale members =
  fixes R :: "nat set"
  assumes fin_R: "finite R"
begin

text \<open>
  Each rule names the Erlang it stands for.

  \<^item> @{text mint}: a local append --- in the tree and applied (the applier
    writes the projection before the MST install).
  \<^item> @{text sync}: a complete pull round of @{term r} from @{term p} with a
    non-empty peer tree. The merged tree is the union; the fold applies a
    prefix-closed set @{term A} (@{text "apply_cell_pairs_mux"} with the
    hold; @{term "A = applied s r"} is the applier-backed instance whose
    replay comes later); the door drops @{term D}, a subset of what is
    applied after the fold (@{text "watermark_door/3"}) --- and, for the
    replica's OWN events, only what it truncated before: the door acts at
    or below the watermark, and an own event is minted above every
    watermark then in force (@{text "bondy_oplog_hlc"}), so an own event
    at or below it was in the tree when the watermark was set and went
    with that truncation. This is the one place key order enters this
    theory, as a hypothesis the TLA+ model discharges; the round records
    the peer's root and VV (@{text "maybe_record/6"}) and confirms the root
    to the peer (@{text "maybe_confirm_root/7"}).
  \<^item> @{text sync_empty}: a round against an empty peer tree --- nothing
    pulled, the VV recorded, a previous root preserved
    (@{text "record_sync_complete/5"}).
  \<^item> @{text replay}: the applier folds a prefix-closed set from the tree.
  \<^item> @{text compact}: truncation of a subset that is applied here and
    confirmed by every other member. The first condition is the cap the
    door already enforces, applied at the compaction sites; the second is
    the rule.
  \<^item> @{text forget}: the page GC makes a recorded root unreadable.
\<close>

inductive step :: "cst \<Rightarrow> cst \<Rightarrow> bool" where
  mint:
    "r \<in> R \<Longrightarrow> e = (r, Suc (minted s r)) \<Longrightarrow>
     step s (s\<lparr>minted := (minted s)(r := Suc (minted s r)),
               tree := (tree s)(r := insert e (tree s r)),
               applied := (applied s)(r := insert e (applied s r))\<rparr>)"
| sync:
    "r \<in> R \<Longrightarrow> p \<in> R \<Longrightarrow> r \<noteq> p \<Longrightarrow> tree s p \<noteq> {} \<Longrightarrow>
     U = tree s r \<union> tree s p \<Longrightarrow>
     applied s r \<subseteq> A \<Longrightarrow> A \<subseteq> applied s r \<union> U \<Longrightarrow> prefix_closed A \<Longrightarrow>
     D \<subseteq> A \<Longrightarrow> (\<And>x. x \<in> D \<Longrightarrow> fst x = r \<Longrightarrow> x \<in> cw s r) \<Longrightarrow>
     step s (s\<lparr>tree := (tree s)(r := U - D),
               applied := (applied s)(r := A),
               root := (root s)(r := (root s r)(p := Some (tree s p)),
                                p := (root s p)(r := Some (tree s p))),
               vv := (vv s)(r := (vv s r)(p := vv_of (applied s p)))\<rparr>)"
| sync_empty:
    "r \<in> R \<Longrightarrow> p \<in> R \<Longrightarrow> r \<noteq> p \<Longrightarrow> tree s p = {} \<Longrightarrow>
     step s (s\<lparr>vv := (vv s)(r := (vv s r)(p := vv_of (applied s p)))\<rparr>)"
| replay:
    "r \<in> R \<Longrightarrow>
     applied s r \<subseteq> A \<Longrightarrow> A \<subseteq> applied s r \<union> tree s r \<Longrightarrow> prefix_closed A \<Longrightarrow>
     step s (s\<lparr>applied := (applied s)(r := A)\<rparr>)"
| compact:
    "r \<in> R \<Longrightarrow> C \<subseteq> tree s r \<Longrightarrow> C \<subseteq> applied s r \<Longrightarrow>
     (\<And>e p. e \<in> C \<Longrightarrow> p \<in> R \<Longrightarrow> p \<noteq> r \<Longrightarrow> confirmed s r p e) \<Longrightarrow>
     step s (s\<lparr>tree := (tree s)(r := tree s r - C),
               cw := (cw s)(r := cw s r \<union> C)\<rparr>)"
| forget:
    "r \<in> R \<Longrightarrow> p \<in> R \<Longrightarrow>
     step s (s\<lparr>root := (root s)(r := (root s r)(p := None))\<rparr>)"

definition init :: cst where
  "init = \<lparr>minted = (\<lambda>_. 0), tree = (\<lambda>_. {}), applied = (\<lambda>_. {}),
           root = (\<lambda>_ _. None), vv = (\<lambda>_ _ _. 0), cw = (\<lambda>_. {})\<rparr>"

inductive reachable :: "cst \<Rightarrow> bool" where
  reachable_init: "reachable init"
| reachable_step: "reachable s \<Longrightarrow> step s s' \<Longrightarrow> reachable s'"


subsection \<open>The inductive invariant\<close>

text \<open>
  \<^item> WF: trees and applied sets hold minted events only;
  \<^item> OWN: a replica has applied every event it minted --- own origins are
    contiguous by minting;
  \<^item> PC: every applied set is prefix-closed --- the hold;
  \<^item> ROOT: a recorded root is held by the peer it was recorded for;
  \<^item> VV: a recorded VV entry bounds a prefix the peer has applied;
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

definition ROOT :: "cst \<Rightarrow> bool" where
  "ROOT s \<longleftrightarrow> (\<forall>r \<in> R. \<forall>p \<in> R. \<forall>T. root s r p = Some T \<longrightarrow> (\<forall>e \<in> T. holds s p e))"

definition VVI :: "cst \<Rightarrow> bool" where
  "VVI s \<longleftrightarrow> (\<forall>r \<in> R. \<forall>p \<in> R. \<forall>og i. 1 \<le> i \<longrightarrow> i \<le> vv s r p og \<longrightarrow> (og, i) \<in> applied s p)"

definition TRUNC :: "cst \<Rightarrow> bool" where
  "TRUNC s \<longleftrightarrow> (\<forall>r \<in> R. \<forall>e \<in> cw s r. \<forall>q \<in> R. q \<noteq> r \<longrightarrow> holds s q e)"

definition SHIP :: "cst \<Rightarrow> bool" where
  "SHIP s \<longleftrightarrow> (\<forall>e \<in> events R s. \<forall>q \<in> R. q \<noteq> fst e \<longrightarrow>
                 e \<in> cw s (fst e) \<or> e \<in> tree s (fst e) \<or> holds s q e)"

definition inv :: "cst \<Rightarrow> bool" where
  "inv s \<longleftrightarrow> WF s \<and> OWN s \<and> PC s \<and> ROOT s \<and> VVI s \<and> TRUNC s \<and> SHIP s"

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
  by (simp add: inv_def WF_def OWN_def PC_def ROOT_def VVI_def TRUNC_def SHIP_def
                init_def events_def holds_def prefix_closed_def)

text \<open>A confirmed event is held by the confirming peer --- from ROOT and VV.\<close>
lemma confirmed_holds:
  assumes "ROOT s" and "VVI s" and "r \<in> R" and "p \<in> R" and "confirmed s r p e"
    and "e \<in> events R s"
  shows "holds s p e"
proof -
  from assms(5) show ?thesis unfolding confirmed_def
  proof
    assume "\<exists>T. root s r p = Some T \<and> e \<in> T"
    with assms(1,3,4) show ?thesis unfolding ROOT_def by blast
  next
    assume le: "snd e \<le> vv s r p (fst e)"
    obtain og i where e: "e = (og, i)" by (cases e)
    with assms(6) have "1 \<le> i" unfolding events_def by auto
    with le e assms(2,3,4) have "(og, i) \<in> applied s p" unfolding VVI_def by auto
    thus ?thesis using e unfolding holds_def by simp
  qed
qed

text \<open>The recorded VV entry is a witness: the per-origin maximum of a
  finite prefix-closed set.\<close>
lemma vv_record_witness:
  assumes "WF s" and "PC s" and "p \<in> R" and "1 \<le> i" and "i \<le> vv_of (applied s p) og"
  shows "(og, i) \<in> applied s p"
  using applied_finite[OF assms(1,3)] assms(2,4,5)
  unfolding PC_def by (auto intro: vv_of_witness simp: assms(3))

lemma prefix_closed_insert_own:
  assumes "prefix_closed S" and "\<forall>i. 1 \<le> i \<longrightarrow> i \<le> n \<longrightarrow> (r, i) \<in> S"
  shows "prefix_closed (insert (r, Suc n) S)"
  using assms unfolding prefix_closed_def by (auto simp: le_Suc_eq)

text \<open>The generic preservation argument: a step that keeps the minted
  counts, grows every applied and truncated set, moves a tree item only
  into the applied set, and re-establishes WF, PC, ROOT and VV, preserves
  the invariant once TRUNC and SHIP are shown for what changed.\<close>
lemma inv_stable:
  assumes "inv s"
    and minted: "minted s' = minted s"
    and app: "\<And>r. applied s r \<subseteq> applied s' r"
    and wf: "WF s'" and pc: "PC s'" and rt: "ROOT s'" and vvi: "VVI s'"
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
  ultimately show ?thesis unfolding inv_def using wf pc rt vvi by blast
qed

text \<open>ROOT and VV are untouched by a step that leaves the records alone and
  only grows what is held.\<close>
lemma ROOT_keep:
  assumes "ROOT s" and "root s' = root s" and "\<And>q x. holds s q x \<Longrightarrow> holds s' q x"
  shows "ROOT s'"
  using assms(1,3) unfolding ROOT_def assms(2) by blast

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
  moreover have "ROOT ?s'" using I hm unfolding ROOT_def by (simp; blast)
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
  case (sync r p s U A D)
  note I = sync.prems[unfolded inv_def]
  let ?s' = "s\<lparr>tree := (tree s)(r := U - D),
               applied := (applied s)(r := A),
               root := (root s)(r := (root s r)(p := Some (tree s p)),
                                p := (root s p)(r := Some (tree s p))),
               vv := (vv s)(r := (vv s r)(p := vv_of (applied s p)))\<rparr>"
  have hm: "\<And>q x. holds s q x \<Longrightarrow> holds ?s' q x"
    using sync.hyps unfolding holds_def by auto
  have r_holds_peer: "\<And>x. x \<in> tree s p \<Longrightarrow> holds ?s' r x"
    using sync.hyps unfolding holds_def by auto
  have ev: "events R ?s' = events R s" unfolding events_def by simp
  have wf: "WF ?s'"
  proof -
    have "U \<subseteq> events R s" and "A \<subseteq> events R s"
      using I sync.hyps unfolding WF_def by blast+
    thus ?thesis using I ev unfolding WF_def by auto
  qed
  have pc: "PC ?s'" using I sync.hyps unfolding PC_def by simp
  have rt: "ROOT ?s'" unfolding ROOT_def
  proof (intro ballI allI impI)
    fix q q' T x assume q: "q \<in> R" "q' \<in> R" and T: "root ?s' q q' = Some T"
      and x: "x \<in> T"
    show "holds ?s' q' x"
    proof (cases "q = r \<and> q' = p")
      case True
      with T sync.hyps have "T = tree s p" by simp
      with x have "holds s p x" unfolding holds_def by simp
      thus ?thesis using True by (simp add: hm)
    next
      case False
      show ?thesis
      proof (cases "q = p \<and> q' = r")
        case True
        with T sync.hyps have "T = tree s p" by simp
        thus ?thesis using True x r_holds_peer by simp
      next
        case False
        with \<open>\<not> (q = r \<and> q' = p)\<close> T have "root s q q' = Some T"
          by (auto split: if_splits)
        with I q x have "holds s q' x" unfolding ROOT_def by blast
        thus ?thesis by (rule hm)
      qed
    qed
  qed
  have vvi: "VVI ?s'" unfolding VVI_def
  proof (intro ballI allI impI)
    fix q q' og i assume q: "q \<in> R" "q' \<in> R" and i: "1 \<le> i" "i \<le> vv ?s' q q' og"
    show "(og, i) \<in> applied ?s' q'"
    proof (cases "q = r \<and> q' = p")
      case True
      with i sync.hyps have "i \<le> vv_of (applied s p) og" by simp
      with I i(1) sync.hyps have "(og, i) \<in> applied s p"
        unfolding inv_def by (intro vv_record_witness) auto
      with True sync.hyps show ?thesis by simp
    next
      case False
      with i have "i \<le> vv s q q' og" by (auto split: if_splits)
      with I q i(1) have "(og, i) \<in> applied s q'" unfolding VVI_def by blast
      thus ?thesis using sync.hyps by auto
    qed
  qed
  show ?case
  proof (rule inv_stable[OF sync.prems _ _ wf pc rt vvi hm])
    show "minted ?s' = minted s" by simp
  next
    fix q show "applied s q \<subseteq> applied ?s' q" using sync.hyps by simp
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
  case (sync_empty r p s)
  note I = sync_empty.prems[unfolded inv_def]
  let ?s' = "s\<lparr>vv := (vv s)(r := (vv s r)(p := vv_of (applied s p)))\<rparr>"
  have hm: "\<And>q x. holds s q x \<Longrightarrow> holds ?s' q x" unfolding holds_def by simp
  have wf: "WF ?s'" using I unfolding WF_def events_def by simp
  have pc: "PC ?s'" using I unfolding PC_def by simp
  have rt: "ROOT ?s'" using I unfolding ROOT_def holds_def by simp
  have vvi: "VVI ?s'" unfolding VVI_def
  proof (intro ballI allI impI)
    fix q q' og i assume q: "q \<in> R" "q' \<in> R" and i: "1 \<le> i" "i \<le> vv ?s' q q' og"
    show "(og, i) \<in> applied ?s' q'"
    proof (cases "q = r \<and> q' = p")
      case True
      with i have "i \<le> vv_of (applied s p) og" by simp
      with I i(1) sync_empty.hyps have "(og, i) \<in> applied s p"
        unfolding inv_def by (intro vv_record_witness) auto
      with True show ?thesis by simp
    next
      case False
      with i have "i \<le> vv s q q' og" by (auto split: if_splits)
      with I q i(1) show ?thesis unfolding VVI_def by (simp; blast)
    qed
  qed
  show ?case
  proof (rule inv_stable[OF sync_empty.prems _ _ wf pc rt vvi hm])
    show "minted ?s' = minted s" by simp
  next
    fix q show "applied s q \<subseteq> applied ?s' q" by simp
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
  have "ROOT s" and "VVI s" using I by blast+
  have rt: "ROOT ?s'" by (rule ROOT_keep[OF \<open>ROOT s\<close> _ hm]) simp
  have vvi: "VVI ?s'" by (rule VVI_keep[OF \<open>VVI s\<close> _ app]) simp
  show ?case
  proof (rule inv_stable[OF replay.prems _ app wf pc rt vvi hm])
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
  have conf: "\<And>x q. x \<in> C \<Longrightarrow> q \<in> R \<Longrightarrow> q \<noteq> r \<Longrightarrow> holds ?s' q x"
  proof -
    fix x q assume x: "x \<in> C" and q: "q \<in> R" "q \<noteq> r"
    from x compact.hyps I have xe: "x \<in> events R s" unfolding WF_def by blast
    have "ROOT s" and "VVI s" using I by blast+
    from confirmed_holds[OF this compact.hyps(1) q(1) compact.hyps(4)[OF x q] xe]
    show "holds ?s' q x" by (rule hm)
  qed
  have wf: "WF ?s'" using I unfolding WF_def events_def by auto
  have pc: "PC ?s'" using I unfolding PC_def by simp
  have "ROOT s" and "VVI s" using I by blast+
  have rt: "ROOT ?s'" by (rule ROOT_keep[OF \<open>ROOT s\<close> _ hm]) simp
  have vvi: "VVI ?s'" by (rule VVI_keep[OF \<open>VVI s\<close>]) simp_all
  show ?case
  proof (rule inv_stable[OF compact.prems _ _ wf pc rt vvi hm])
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
next
  case (forget r p s)
  note I = forget.prems[unfolded inv_def]
  let ?s' = "s\<lparr>root := (root s)(r := (root s r)(p := None))\<rparr>"
  have hm: "\<And>q x. holds s q x \<Longrightarrow> holds ?s' q x" unfolding holds_def by simp
  have wf: "WF ?s'" using I unfolding WF_def events_def by simp
  have pc: "PC ?s'" using I unfolding PC_def by simp
  have rt: "ROOT ?s'" unfolding ROOT_def
  proof (intro ballI allI impI)
    fix q q' T x assume "q \<in> R" "q' \<in> R" "root ?s' q q' = Some T" "x \<in> T"
    thus "holds ?s' q' x" using I unfolding ROOT_def holds_def
      by (cases "q = r \<and> q' = p") (auto split: if_splits)
  qed
  have "VVI s" using I by blast
  have vvi: "VVI ?s'" by (rule VVI_keep[OF \<open>VVI s\<close>]) simp_all
  show ?case
  proof (rule inv_stable[OF forget.prems _ _ wf pc rt vvi hm])
    show "minted ?s' = minted s" by simp
  next
    fix q show "applied s q \<subseteq> applied ?s' q" by simp
  next
    fix q show "cw s q \<subseteq> cw ?s' q" by simp
  next
    fix q x q' assume "x \<in> cw ?s' q" "x \<notin> cw s q"
    thus "holds ?s' q' x" by simp
  next
    fix x q assume "x \<in> tree s (fst x)"
    thus "x \<in> cw ?s' (fst x) \<or> x \<in> tree ?s' (fst x) \<or> holds ?s' q x" by simp
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
  there --- the cap at the compaction sites plus the door's own rule.\<close>
theorem no_drop:
  assumes "step s s'" and "r \<in> R" and "e \<in> tree s r" and "e \<notin> tree s' r"
  shows "e \<in> applied s' r"
  using assms by (cases rule: step.cases) (auto split: if_splits)

end

end
