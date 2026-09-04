(*
  SPDX-FileCopyrightText: 2016 - 2026 Leapsight
  SPDX-License-Identifier: Apache-2.0
*)

theory Seq_Seed
  imports Main Oplog_Model
begin

section \<open>Seeding the per-origin sequence counter across restarts\<close>

text \<open>
  @{text Oplog_Model} takes H1 (@{text origin_unique}: no two distinct
  events share a dot) as a hypothesis, and @{text "../README.md"} records it
  as an operator obligation --- distinct origin ids. That is only half of
  it. Within ONE origin, dot uniqueness is the minter's obligation across
  its own restarts: @{text "bondy_oplog_instance.erl"} keeps the counter in
  a volatile @{text "atomics"} cell and must re-derive it at @{text "init/1"}
  from what survived on disk. On 2026-09-03 a Jepsen run showed the shipped
  derivation regressing the counter to 0 after a restart, so post-restart
  writes minted dots already carried by acknowledged events.

  @{text "../tla/SeqSeed.tla"} models the persistence protocol with a crash
  action and refutes the shipped seeding rule and one candidate fix by
  model checking. This theory takes the rule TLC found clean and proves it
  for an unbounded number of writes:

  \<^item> @{text "init/1"} seeds the counter from the maximum of the checkpoint's
    frontier entry, the durable tree, and the retained WAL --- read at init,
    not awaited through the applier's replay;
  \<^item> compaction keeps its shipped order (truncated root flushed, then the
    checkpoint written);
  \<^item> WAL retention drops a segment only below the DURABLE checkpoint
    watermark --- the rule @{text "bondy_oplog_wal:compute_deletable/1"}
    states. This is the obligation that closes the crash window between a
    truncated root's flush and its checkpoint write: everything above the
    last durable checkpoint is still in the WAL.

  The state machine here over-approximates the TLA+ model: any WAL event
  may be applied at any time (no read cursor), a truncation may be
  interleaved with anything, and every crash point is reachable. Every
  behaviour of the TLA+ model is a behaviour here, so the invariant proved
  here covers it.

  What the theory does NOT establish: that @{text "init/1"} implements the
  rule. That is the falsifier's job (compact to empty, restart, write,
  assert the fresh seq is above the restored frontier).
\<close>

subsection \<open>The maximum of a finite set of naturals, with @{term 0} for empty\<close>

definition mx :: "nat set \<Rightarrow> nat" where
  "mx S = (if S = {} then 0 else Max S)"

lemma mx_empty [simp]: "mx {} = 0"
  by (simp add: mx_def)

lemma mx_le: "finite S \<Longrightarrow> x \<in> S \<Longrightarrow> x \<le> mx S"
  by (auto simp: mx_def)

lemma mx_in: "finite S \<Longrightarrow> S \<noteq> {} \<Longrightarrow> mx S \<in> S"
  by (simp add: mx_def)

lemma mx_leI: "finite S \<Longrightarrow> (\<And>x. x \<in> S \<Longrightarrow> x \<le> b) \<Longrightarrow> mx S \<le> b"
  by (auto simp: mx_def)

lemma mx_atLeastAtMost [simp]: "mx {Suc 0..n} = n"
proof (cases n)
  case 0 thus ?thesis by (simp add: mx_def)
next
  case (Suc k)
  hence "Max {Suc 0..n} = n" by (intro Max_eqI) auto
  thus ?thesis using Suc by (simp add: mx_def)
qed

lemma mx_mono: "finite T \<Longrightarrow> S \<subseteq> T \<Longrightarrow> mx S \<le> mx T"
  by (auto simp: mx_def intro: Max_mono finite_subset)


subsection \<open>The state\<close>

text \<open>
  One replica, one origin. Volatile: @{text up}, the counter, the reserved
  seqs, the registry frontier, the staged (unflushed) MST installs, and the
  truncation in flight. Durable: the WAL, the MST root, the checkpoint's
  frontier entry. @{text acked} and @{text log} are history variables ---
  the set, and the sequence, of seqs whose write was acknowledged.
\<close>

record st =
  up       :: bool
  seqRef   :: nat        \<comment> \<open>the @{text "atomics"} counter\<close>
  inflight :: "nat set"  \<comment> \<open>reserved, WAL append not yet acknowledged\<close>
  wal      :: "nat set"  \<comment> \<open>durable in the WAL\<close>
  fr       :: nat        \<comment> \<open>registry applied frontier, this origin\<close>
  mem      :: "nat set"  \<comment> \<open>installed in the MST, root not yet flushed\<close>
  tree     :: "nat set"  \<comment> \<open>in the durable MST root\<close>
  ckpt     :: nat        \<comment> \<open>checkpoint frontier entry, this origin\<close>
  wm       :: nat        \<comment> \<open>checkpoint watermark: the last truncation key made durable\<close>
  pend     :: nat        \<comment> \<open>truncated root flushed, checkpoint not yet written; 0 = none\<close>
  acked    :: "nat set"
  log      :: "nat list"

text \<open>The seed rule under proof: @{text "max(checkpoint, tree, WAL)"}.\<close>
definition seed :: "st \<Rightarrow> nat" where
  "seed s = mx (insert (ckpt s) (tree s \<union> wal s))"


subsection \<open>The protocol\<close>

text \<open>
  Each rule names the Erlang it stands for.

  \<^item> @{text reserve}: @{text "do_build_events/6"}, @{text "atomics:add_get"}.
  \<^item> @{text append}: the WAL append, fsync (@{text "per_write"}) and ack.
    The WAL gen_server serialises appends; taking the least reserved seq
    keeps the durable sequence gap-free, which is what
    @{text "release_seq_range/3"} exists to preserve.
  \<^item> @{text apply_ev}: the applier writes the projection and bumps the
    registry frontier (@{text "apply_cell_batch_mux"}), the instance
    installs and bumps the counter (@{text "install_fast_events"} $\to$
    @{text "maybe_bump_seq_atomic"}).
  \<^item> @{text flush}: @{text "drain_install_queue"} --- the staged root becomes
    the durable root.
  \<^item> @{text dropwal}: the retention sweep, @{text "compute_deletable/1"} ---
    only what is at or below the durable checkpoint watermark may go.
  \<^item> @{text persist}: @{text "maybe_persist_frontier/5"} --- the registry
    frontier is written into the checkpoint, watermark unchanged.
  \<^item> @{text truncate_flush}: @{text "finalize_catalogue_compaction/3"} ---
    the MST is truncated at or below a key it holds and the truncated root
    is flushed durably. The key is above the current watermark: it is a
    live key, and the live tree holds nothing at or below the watermark
    (@{text "compute_frontier_for/2"} picks from the live tree).
  \<^item> @{text truncate_checkpoint}: its tail --- the checkpoint is written
    with the new watermark and the registry frontier.
  \<^item> @{text stop}: @{text "terminate/2"} --- persist, then everything volatile
    is gone.
  \<^item> @{text crash}: @{text "kill -9"} --- everything volatile is gone; a
    flushed-but-uncheckpointed truncation stays that way on disk.
  \<^item> @{text restart}: @{text "init/1"} seeds the counter and restores the
    frontier (@{text "restore_frontier/2"}, @{text "frontier_from_mst/1"}).
\<close>

inductive step :: "st \<Rightarrow> st \<Rightarrow> bool" where
  reserve:
    "up s \<Longrightarrow>
     step s (s\<lparr>seqRef := Suc (seqRef s),
               inflight := insert (Suc (seqRef s)) (inflight s)\<rparr>)"
| append:
    "up s \<Longrightarrow> inflight s \<noteq> {} \<Longrightarrow> m = Min (inflight s) \<Longrightarrow>
     step s (s\<lparr>inflight := inflight s - {m},
               wal := insert m (wal s),
               acked := insert m (acked s),
               log := log s @ [m]\<rparr>)"
| apply_ev:
    "up s \<Longrightarrow> x \<in> wal s \<Longrightarrow>
     step s (s\<lparr>seqRef := max (seqRef s) x,
               fr := max (fr s) x,
               mem := insert x (mem s)\<rparr>)"
| flush:
    "up s \<Longrightarrow>
     step s (s\<lparr>mem := {}, tree := tree s \<union> mem s\<rparr>)"
| dropwal:
    "up s \<Longrightarrow>
     step s (s\<lparr>wal := {x \<in> wal s. wm s < x}\<rparr>)"
| persist:
    "up s \<Longrightarrow>
     step s (s\<lparr>ckpt := fr s\<rparr>)"
| truncate_flush:
    "up s \<Longrightarrow> pend s = 0 \<Longrightarrow> w \<in> tree s \<union> mem s \<Longrightarrow> wm s < w \<Longrightarrow>
     step s (s\<lparr>mem := {},
               tree := {x \<in> tree s \<union> mem s. w < x},
               pend := w\<rparr>)"
| truncate_checkpoint:
    "up s \<Longrightarrow> pend s \<noteq> 0 \<Longrightarrow>
     step s (s\<lparr>ckpt := fr s, wm := pend s, pend := 0\<rparr>)"
| stop:
    "up s \<Longrightarrow>
     step s (s\<lparr>up := False, inflight := {}, mem := {}, ckpt := fr s,
               pend := 0\<rparr>)"
| crash:
    "up s \<Longrightarrow>
     step s (s\<lparr>up := False, inflight := {}, mem := {}, pend := 0\<rparr>)"
| restart:
    "\<not> up s \<Longrightarrow>
     step s (s\<lparr>up := True, seqRef := seed s,
               fr := max (ckpt s) (mx (tree s))\<rparr>)"

definition init :: "st" where
  "init = \<lparr>up = True, seqRef = 0, inflight = {}, wal = {}, fr = 0, mem = {},
           tree = {}, ckpt = 0, wm = 0, pend = 0, acked = {}, log = []\<rparr>"

inductive reachable :: "st \<Rightarrow> bool" where
  reachable_init: "reachable init"
| reachable_step: "reachable s \<Longrightarrow> step s s' \<Longrightarrow> reachable s'"


subsection \<open>The inductive invariant\<close>

text \<open>
  The conjuncts, and why each is needed:

  \<^item> the acknowledged seqs are exactly @{text "1..a"} --- gap-free;
  \<^item> while up, the reservations are exactly @{text "a+1..seqRef"} --- the
    counter is the acknowledged maximum plus its reservations. This is
    @{text SeedExact} of the TLA+ module; @{text DotUnique} follows;
  \<^item> every durable or staged seq was acknowledged (the durable sources never
    over-claim), the frontier sits between the checkpoint and the
    acknowledged maximum, and dominates everything installed (apply
    precedes install);
  \<^item> RETAINED: everything installed is either still in the WAL or at or
    below the durable watermark. This is what watermark-keyed retention
    buys, and it is the conjunct commit-keyed retention breaks;
  \<^item> the durable watermark never exceeds the checkpoint's frontier entry,
    and a truncation in flight is at or below the frontier and above the
    watermark it will replace (the watermark is monotone);
  \<^item> COVER: the acknowledged maximum survives in some durable source. The
    shipped seeding rule does not break this conjunct --- the maximum is
    there, in the checkpoint --- it fails to read it;
  \<^item> down, nothing volatile is held.
\<close>

text \<open>@{term a} is the acknowledged maximum, kept as an explicit witness so
  that @{text "acked s = {1..a}"} is a usable rewrite.\<close>
definition inv_at :: "st \<Rightarrow> nat \<Rightarrow> bool" where
  "inv_at s a \<longleftrightarrow>
     acked s = {Suc 0..a}
   \<and> set (log s) = acked s \<and> distinct (log s)
   \<and> (up s \<longrightarrow> a \<le> seqRef s \<and> inflight s = {Suc a..seqRef s})
   \<and> (\<not> up s \<longrightarrow> inflight s = {} \<and> mem s = {} \<and> pend s = 0)
   \<and> wal s \<subseteq> acked s \<and> tree s \<subseteq> acked s \<and> mem s \<subseteq> acked s
   \<and> ckpt s \<le> fr s \<and> fr s \<le> a \<and> mx (tree s \<union> mem s) \<le> fr s
   \<and> (\<forall>x \<in> tree s \<union> mem s. x \<in> wal s \<or> x \<le> wm s)
   \<and> wm s \<le> ckpt s
   \<and> (pend s \<noteq> 0 \<longrightarrow> pend s \<le> fr s \<and> wm s < pend s)
   \<and> (a = 0 \<or> ckpt s = a \<or> a \<in> tree s \<or> a \<in> wal s)"

definition inv :: "st \<Rightarrow> bool" where
  "inv s \<longleftrightarrow> (\<exists>a. inv_at s a)"

lemma inv_init: "inv init"
  by (simp add: inv_def inv_at_def init_def)

lemma inv_at_finite: "inv_at s a \<Longrightarrow> finite (acked s)"
  by (simp add: inv_at_def)

lemma inv_at_finite_tree_mem: "inv_at s a \<Longrightarrow> finite (tree s \<union> mem s)"
  unfolding inv_at_def by (metis finite_Un finite_atLeastAtMost finite_subset)

lemma inv_at_finite_wal: "inv_at s a \<Longrightarrow> finite (wal s)"
  unfolding inv_at_def by (metis finite_atLeastAtMost finite_subset)

text \<open>The seed equals the acknowledged maximum --- from COVER and the
  no-over-claim conjuncts.\<close>
lemma seed_eq:
  assumes "inv_at s a"
  shows "seed s = a"
proof -
  have fin: "finite (insert (ckpt s) (tree s \<union> wal s))"
    using inv_at_finite_tree_mem[OF assms] inv_at_finite_wal[OF assms] by simp
  have le: "seed s \<le> a"
    unfolding seed_def
  proof (rule mx_leI[OF fin])
    fix x assume "x \<in> insert (ckpt s) (tree s \<union> wal s)"
    thus "x \<le> a" using assms unfolding inv_at_def by auto
  qed
  have ge: "a \<le> seed s"
  proof -
    from assms have "a = 0 \<or> ckpt s = a \<or> a \<in> tree s \<or> a \<in> wal s"
      unfolding inv_at_def by blast
    thus ?thesis unfolding seed_def using fin by (auto intro: mx_le)
  qed
  from le ge show ?thesis by simp
qed

lemma mx_tree_le:
  assumes "inv_at s a"
  shows "mx (tree s) \<le> fr s"
  using assms inv_at_finite_tree_mem[OF assms]
  unfolding inv_at_def by (auto intro: le_trans[OF mx_mono])

lemma inv_at_subs:
  assumes "inv_at s a"
  shows "wal s \<subseteq> {Suc 0..a}" "tree s \<subseteq> {Suc 0..a}" "mem s \<subseteq> {Suc 0..a}"
proof -
  note I = assms[unfolded inv_at_def]
  have A: "acked s = {Suc 0..a}" using I by (rule conjunct1)
  have W: "wal s \<subseteq> acked s" using I by (blast)
  have T: "tree s \<subseteq> acked s" using I by (blast)
  have M: "mem s \<subseteq> acked s" using I by (blast)
  show "wal s \<subseteq> {Suc 0..a}" using A W by simp
  show "tree s \<subseteq> {Suc 0..a}" using A T by simp
  show "mem s \<subseteq> {Suc 0..a}" using A M by simp
qed

lemma inv_at_installed_le:
  assumes "inv_at s a" and "y \<in> tree s \<union> mem s"
  shows "y \<le> fr s"
proof -
  have "y \<le> mx (tree s \<union> mem s)"
    using inv_at_finite_tree_mem[OF assms(1)] assms(2) by (rule mx_le)
  also have "... \<le> fr s" using assms(1) unfolding inv_at_def by blast
  finally show ?thesis .
qed

lemma inv_step:
  assumes "inv s" and "step s s'"
  shows "inv s'"
  using assms(2) assms(1)
proof (induction rule: step.induct)
  case (reserve s)
  then obtain a where i: "inv_at s a" by (auto simp: inv_def)
  hence "inv_at (s\<lparr>seqRef := Suc (seqRef s),
                   inflight := insert (Suc (seqRef s)) (inflight s)\<rparr>) a"
    using reserve.hyps unfolding inv_at_def by auto
  thus ?case by (auto simp: inv_def)
next
  case (append s m)
  then obtain a where i: "inv_at s a" by (auto simp: inv_def)
  from i append.hyps have infl: "inflight s = {Suc a..seqRef s}"
    and ale: "a \<le> seqRef s" by (auto simp: inv_at_def)
  have "Min {Suc a..seqRef s} = Suc a" if "{Suc a..seqRef s} \<noteq> {}"
    using that by (intro Min_eqI) auto
  with append.hyps infl have m: "m = Suc a" by simp
  have "inv_at (s\<lparr>inflight := inflight s - {m},
                  wal := insert m (wal s),
                  acked := insert m (acked s),
                  log := log s @ [m]\<rparr>) (Suc a)"
    using i append.hyps m unfolding inv_at_def by auto
  thus ?case by (auto simp: inv_def)
next
  case (apply_ev s x)
  then obtain a where i: "inv_at s a" by (auto simp: inv_def)
  have xle: "x \<le> a" using i apply_ev.hyps unfolding inv_at_def by auto
  have fin2: "finite (tree s \<union> mem s)" using i by (rule inv_at_finite_tree_mem)
  have mxi: "mx (tree s \<union> insert x (mem s)) \<le> max (fr s) x"
  proof (rule mx_leI)
    show "finite (tree s \<union> insert x (mem s))" using fin2 by simp
  next
    fix y assume "y \<in> tree s \<union> insert x (mem s)"
    hence "y = x \<or> y \<le> fr s"
      using inv_at_installed_le[OF i, of y] by auto
    thus "y \<le> max (fr s) x" by auto
  qed
  have "inv_at (s\<lparr>seqRef := max (seqRef s) x,
                  fr := max (fr s) x,
                  mem := insert x (mem s)\<rparr>) a"
    using i apply_ev.hyps xle mxi unfolding inv_at_def by auto
  thus ?case by (auto simp: inv_def)
next
  case (flush s)
  then obtain a where i: "inv_at s a" by (auto simp: inv_def)
  hence "inv_at (s\<lparr>mem := {}, tree := tree s \<union> mem s\<rparr>) a"
    unfolding inv_at_def by auto
  thus ?case by (auto simp: inv_def)
next
  case (dropwal s)
  then obtain a where i: "inv_at s a" by (auto simp: inv_def)
  hence "inv_at (s\<lparr>wal := {x \<in> wal s. wm s < x}\<rparr>) a"
    unfolding inv_at_def by auto
  thus ?case by (auto simp: inv_def)
next
  case (persist s)
  then obtain a where i: "inv_at s a" by (auto simp: inv_def)
  hence "inv_at (s\<lparr>ckpt := fr s\<rparr>) a"
    unfolding inv_at_def by auto
  thus ?case by (auto simp: inv_def)
next
  case (truncate_flush s w)
  then obtain a where i: "inv_at s a" by (auto simp: inv_def)
  have fin2: "finite (tree s \<union> mem s)" using i by (rule inv_at_finite_tree_mem)
  have wle: "w \<le> fr s" using inv_at_installed_le[OF i truncate_flush.hyps(3)] .
  have mx': "mx {x \<in> tree s \<union> mem s. w < x} \<le> fr s"
  proof (rule mx_leI)
    show "finite {x \<in> tree s \<union> mem s. w < x}" using fin2 by simp
  next
    fix y assume "y \<in> {x \<in> tree s \<union> mem s. w < x}"
    thus "y \<le> fr s" using inv_at_installed_le[OF i] by auto
  qed
  \<comment> \<open>COVER: if the maximum sat in the tree and is truncated, it is either
      still in the WAL (RETAINED) or at or below the durable watermark, and
      then @{text "a \<le> wm \<le> ckpt \<le> a"} makes the checkpoint carry it.\<close>
  have cover: "a = 0 \<or> ckpt s = a
             \<or> a \<in> {x \<in> tree s \<union> mem s. w < x} \<or> a \<in> wal s"
  proof -
    from i have ret: "\<forall>x \<in> tree s \<union> mem s. x \<in> wal s \<or> x \<le> wm s"
      and "wm s \<le> ckpt s" "ckpt s \<le> fr s" "fr s \<le> a"
      and c: "a = 0 \<or> ckpt s = a \<or> a \<in> tree s \<or> a \<in> wal s"
      unfolding inv_at_def by blast+
    with ret show ?thesis by (cases "w < a") auto
  qed
  have ret': "\<forall>x \<in> {x \<in> tree s \<union> mem s. w < x}. x \<in> wal s \<or> x \<le> wm s"
    using i unfolding inv_at_def by blast
  have sub1: "wal s \<subseteq> {Suc 0..a}" using inv_at_subs(1)[OF i] .
  have sub2: "{x \<in> tree s \<union> mem s. w < x} \<subseteq> {Suc 0..a}"
    using inv_at_subs(2,3)[OF i] by auto
  have "inv_at (s\<lparr>mem := {},
                  tree := {x \<in> tree s \<union> mem s. w < x},
                  pend := w\<rparr>) a"
    using i wle mx' cover ret' sub1 sub2 truncate_flush.hyps
    unfolding inv_at_def by simp
  thus ?case by (auto simp: inv_def)
next
  case (truncate_checkpoint s)
  then obtain a where i: "inv_at s a" by (auto simp: inv_def)
  from i truncate_checkpoint.hyps
  have "pend s \<le> fr s" "wm s < pend s" unfolding inv_at_def by blast+
  moreover have ret0: "\<forall>x \<in> tree s \<union> mem s. x \<in> wal s \<or> x \<le> wm s"
    using i unfolding inv_at_def by blast
  ultimately have ret': "\<forall>x \<in> tree s \<union> mem s. x \<in> wal s \<or> x \<le> pend s"
    by (metis less_imp_le le_trans)
  have "ckpt s \<le> fr s" "fr s \<le> a"
    and c0: "a = 0 \<or> ckpt s = a \<or> a \<in> tree s \<or> a \<in> wal s"
    using i unfolding inv_at_def by blast+
  hence cover: "a = 0 \<or> fr s = a \<or> a \<in> tree s \<or> a \<in> wal s"
    by (metis le_antisym)
  have "inv_at (s\<lparr>ckpt := fr s, wm := pend s, pend := 0\<rparr>) a"
    using i ret' cover \<open>pend s \<le> fr s\<close> inv_at_subs[OF i]
      truncate_checkpoint.hyps
    unfolding inv_at_def by simp
  thus ?case by (auto simp: inv_def)
next
  case (stop s)
  then obtain a where i: "inv_at s a" by (auto simp: inv_def)
  hence "inv_at (s\<lparr>up := False, inflight := {}, mem := {}, ckpt := fr s,
                   pend := 0\<rparr>) a"
    using mx_tree_le[OF i] unfolding inv_at_def by auto
  thus ?case by (auto simp: inv_def)
next
  case (crash s)
  then obtain a where i: "inv_at s a" by (auto simp: inv_def)
  hence "inv_at (s\<lparr>up := False, inflight := {}, mem := {}, pend := 0\<rparr>) a"
    using mx_tree_le[OF i] unfolding inv_at_def by auto
  thus ?case by (auto simp: inv_def)
next
  case (restart s)
  then obtain a where i: "inv_at s a" by (auto simp: inv_def)
  have sd: "seed s = a" using i by (rule seed_eq)
  have mt: "mx (tree s) \<le> fr s" using i by (rule mx_tree_le)
  have "inv_at (s\<lparr>up := True, seqRef := seed s,
                   fr := max (ckpt s) (mx (tree s))\<rparr>) a"
    using i restart.hyps sd mt unfolding inv_at_def by auto
  thus ?case by (auto simp: inv_def)
qed

theorem inv_reachable: "reachable s \<Longrightarrow> inv s"
  by (induction rule: reachable.induct) (auto intro: inv_init inv_step)


subsection \<open>The results\<close>

text \<open>@{text SeedExact}: whenever the instance is up, the counter is the
  acknowledged maximum plus its live reservations --- gap-free, and never
  behind. It holds in particular in the first state after @{text restart},
  before any replay: a mint that races the applier's boot drain is safe.\<close>
theorem seed_exact:
  assumes "reachable s" and "up s"
  shows "acked s \<union> inflight s = {Suc 0..seqRef s}"
proof -
  obtain a where "inv_at s a"
    using inv_reachable[OF assms(1)] by (auto simp: inv_def)
  with assms(2) show ?thesis unfolding inv_at_def by auto
qed

text \<open>@{text DotUnique}: a reserved seq never already carries an
  acknowledged event.\<close>
theorem dot_unique:
  assumes "reachable s"
  shows "inflight s \<inter> acked s = {}"
  using inv_reachable[OF assms] unfolding inv_def inv_at_def by auto

text \<open>The history form: the sequence of acknowledged writes never repeats a
  seq. Two distinct acknowledged writes under this origin carry distinct
  dots --- H1 for one origin, over the whole life of the instance, across
  any number of stops, crashes and restarts.\<close>
theorem log_distinct:
  assumes "reachable s"
  shows "distinct (log s)"
  using inv_reachable[OF assms] unfolding inv_def inv_at_def by blast

text \<open>In @{text Oplog_Model}'s terms: whatever payload (HLC, cell, context)
  each acknowledged write carried --- given here as arbitrary functions of
  its position in the history --- the resulting event set satisfies
  @{text origin_unique}. Without @{text log_distinct} two positions could
  share a seq with different payloads: two events, one dot.\<close>
definition events_of :: "st \<Rightarrow> origin \<Rightarrow> (nat \<Rightarrow> hlc) \<Rightarrow> (nat \<Rightarrow> cell) \<Rightarrow> (nat \<Rightarrow> vv) \<Rightarrow> event set" where
  "events_of s og h c x =
     {\<lparr>ev_origin = og, ev_seq = log s ! i, ev_hlc = h i, ev_cell = c i, ev_ctx = x i\<rparr>
      | i. i < length (log s)}"

corollary h1_for_origin:
  assumes "reachable s"
  shows "origin_unique (events_of s og h c x)"
proof -
  have d: "distinct (log s)" using assms by (rule log_distinct)
  have inj: "\<And>i j. i < length (log s) \<Longrightarrow> j < length (log s)
                \<Longrightarrow> log s ! i = log s ! j \<Longrightarrow> i = j"
    using d by (simp add: nth_eq_iff_index_eq)
  show ?thesis
    unfolding origin_unique_def events_of_def ev_dot_def
    by (auto dest: inj)
qed

end
