(*
  SPDX-FileCopyrightText: 2016 - 2026 Leapsight
  SPDX-License-Identifier: Apache-2.0
*)

theory Hlc
  imports Main
begin

section \<open>The hybrid logical clock\<close>

text \<open>
  A faithful model of @{text "bondy_oplog_hlc.erl"}: a 64-bit value packed as
  48 bits physical (ms) and 16 bits logical, with @{text "local_next"} for a
  local tick and @{text "peer_next"} for the merge on receipt of a peer event.

  What this buys the rest of the development: @{text Oplog_Model} ASSUMES H3
  (@{text hlc_respects_hb} --- the HLC respects happens-before). Here that
  assumption is discharged operationally: @{text run_dominates_received}
  proves that a replica's clock, after receiving a peer value, strictly
  exceeds it forever after, so every event it later mints sorts above every
  event it has received.

  Modelling note: physical is unbounded @{typ nat} here, where the Erlang
  encoding gives it 48 bits. The overflow path
  (@{text "bump_logical(Phys, _) -> encode(Phys + 1, 0)"}) can therefore
  advance physical past a millisecond boundary, which the model allows and
  the encoding tolerates until year 10889. The logical field's 16-bit bound
  IS modelled, because the clamp is what the monotonicity argument turns on.
\<close>

subsection \<open>Encoding\<close>

definition enc :: "nat \<Rightarrow> nat \<Rightarrow> nat" where
  "enc p l = p * 65536 + l"

definition dec_phys :: "nat \<Rightarrow> nat" where
  "dec_phys h = h div 65536"

definition dec_log :: "nat \<Rightarrow> nat" where
  "dec_log h = h mod 65536"

lemma enc_dec: "enc (dec_phys h) (dec_log h) = h"
  unfolding enc_def dec_phys_def dec_log_def by simp

lemma dec_log_lt: "dec_log h < 65536"
  unfolding dec_log_def by simp

lemma enc_less_phys:
  assumes "l < 65536" and "p < p'"
  shows "enc p l < enc p' l'"
proof -
  have "enc p l < (p + 1) * 65536"
    using assms(1) by (simp add: enc_def)
  also have "... \<le> p' * 65536"
    using assms(2) by simp
  also have "... \<le> enc p' l'"
    by (simp add: enc_def)
  finally show ?thesis .
qed

lemma enc_less_log: "l < l' \<Longrightarrow> enc p l < enc p l'"
  by (simp add: enc_def)

lemma enc_le_log: "l \<le> l' \<Longrightarrow> enc p l \<le> enc p l'"
  by (simp add: enc_def)


subsection \<open>The two clock steps\<close>

text \<open>@{text "bump_logical/2"}: increment logical, advancing physical on
  overflow so the result still strictly dominates.\<close>
definition bump :: "nat \<Rightarrow> nat \<Rightarrow> nat" where
  "bump p l = (if l < 65535 then enc p (l + 1) else enc (p + 1) 0)"

lemma bump_gt:
  assumes "l < 65536"
  shows "enc p l < bump p l"
proof (cases "l < 65535")
  case True
  thus ?thesis by (simp add: bump_def enc_less_log)
next
  case False
  have "enc p l < enc (p + 1) 0"
    using enc_less_phys[OF assms] by simp
  thus ?thesis using False by (simp add: bump_def)
qed

lemma enc_le_bump: "l < 65536 \<Longrightarrow> enc p l \<le> bump p l"
  using bump_gt by (simp add: less_imp_le)

text \<open>@{text "local_next/2"}: take the larger of the stored physical and the
  wall clock; bump logical when physical did not advance.\<close>
definition local_next :: "nat \<Rightarrow> nat \<Rightarrow> nat" where
  "local_next old wall =
     (if dec_phys old < wall then enc wall 0
      else bump (dec_phys old) (dec_log old))"

text \<open>@{text "peer_next/3"}: dominate both the stored value and the peer's.\<close>
definition peer_next :: "nat \<Rightarrow> nat \<Rightarrow> nat \<Rightarrow> nat" where
  "peer_next old wall peer =
     (let ph = max (dec_phys old) (max wall (dec_phys peer)) in
        if ph = dec_phys old \<and> ph = dec_phys peer
          then bump ph (max (dec_log old) (dec_log peer))
        else if ph = dec_phys old then bump ph (dec_log old)
        else if ph = dec_phys peer then bump ph (dec_log peer)
        else enc ph 0)"


subsection \<open>Strict monotonicity\<close>

theorem local_next_gt: "old < local_next old wall"
proof (cases "dec_phys old < wall")
  case True
  have "old = enc (dec_phys old) (dec_log old)" by (simp add: enc_dec)
  also have "... < enc wall 0" using enc_less_phys[OF dec_log_lt True] .
  finally show ?thesis using True by (simp add: local_next_def)
next
  case False
  have "old = enc (dec_phys old) (dec_log old)" by (simp add: enc_dec)
  also have "... < bump (dec_phys old) (dec_log old)"
    using bump_gt[OF dec_log_lt] .
  finally show ?thesis using False by (simp add: local_next_def)
qed

text \<open>The shared domination argument: a bumped value at physical
  @{term ph} strictly exceeds @{term h}, provided @{term ph} is at least
  @{term h}'s physical and, when equal, the logical does not go backwards.\<close>
lemma bump_dominates:
  assumes ph_ge:  "dec_phys h \<le> ph"
      and log_le: "dec_phys h = ph \<longrightarrow> dec_log h \<le> l"
      and l_lt:   "l < 65536"
    shows "h < bump ph l"
proof (cases "dec_phys h = ph")
  case True
  have "h = enc ph (dec_log h)" using enc_dec[of h] True by simp
  also have "... \<le> enc ph l" using log_le True by (simp add: enc_le_log)
  also have "... < bump ph l" using bump_gt[OF l_lt] .
  finally show ?thesis .
next
  case False
  hence lt: "dec_phys h < ph" using ph_ge by simp
  have "h = enc (dec_phys h) (dec_log h)" using enc_dec by simp
  also have "... < enc ph l" using enc_less_phys[OF dec_log_lt lt] .
  also have "... \<le> bump ph l" using enc_le_bump[OF l_lt] .
  finally show ?thesis .
qed

lemma enc0_dominates:
  assumes "dec_phys h < ph"
  shows "h < enc ph 0"
proof -
  have "h = enc (dec_phys h) (dec_log h)" using enc_dec by simp
  also have "... < enc ph 0" using enc_less_phys[OF dec_log_lt assms] .
  finally show ?thesis .
qed

lemma max_dec_log_lt: "max (dec_log a) (dec_log b) < 65536"
  using dec_log_lt[of a] dec_log_lt[of b] by simp

text \<open>The merge strictly dominates the stored value ...\<close>
theorem peer_next_gt_old: "old < peer_next old wall peer"
proof -
  define ph where "ph = max (dec_phys old) (max wall (dec_phys peer))"
  have ge: "dec_phys old \<le> ph" by (simp add: ph_def)
  have A: "old < bump ph (max (dec_log old) (dec_log peer))"
  proof (rule bump_dominates[OF ge _ max_dec_log_lt])
    show "dec_phys old = ph \<longrightarrow> dec_log old \<le> max (dec_log old) (dec_log peer)"
      by simp
  qed
  have B: "old < bump ph (dec_log old)"
    by (rule bump_dominates[OF ge _ dec_log_lt]) simp
  have C: "old < bump ph (dec_log peer)" if "ph \<noteq> dec_phys old"
  proof (rule bump_dominates[OF ge _ dec_log_lt])
    show "dec_phys old = ph \<longrightarrow> dec_log old \<le> dec_log peer" using that by simp
  qed
  have D: "old < enc ph 0" if "ph \<noteq> dec_phys old"
  proof -
    have "dec_phys old < ph" using ge that by simp
    thus ?thesis by (rule enc0_dominates)
  qed
  show ?thesis
    unfolding peer_next_def Let_def ph_def[symmetric]
    using A B C D by auto
qed

text \<open>... and the peer value.\<close>
theorem peer_next_gt_peer: "peer < peer_next old wall peer"
proof -
  define ph where "ph = max (dec_phys old) (max wall (dec_phys peer))"
  have ge: "dec_phys peer \<le> ph" by (simp add: ph_def)
  have A: "peer < bump ph (max (dec_log old) (dec_log peer))"
  proof (rule bump_dominates[OF ge _ max_dec_log_lt])
    show "dec_phys peer = ph \<longrightarrow> dec_log peer \<le> max (dec_log old) (dec_log peer)"
      by simp
  qed
  have B: "peer < bump ph (dec_log peer)"
    by (rule bump_dominates[OF ge _ dec_log_lt]) simp
  have C: "peer < bump ph (dec_log old)" if "ph \<noteq> dec_phys peer"
  proof (rule bump_dominates[OF ge _ dec_log_lt])
    show "dec_phys peer = ph \<longrightarrow> dec_log peer \<le> dec_log old" using that by simp
  qed
  have D: "peer < enc ph 0" if "ph \<noteq> dec_phys peer"
  proof -
    have "dec_phys peer < ph" using ge that by simp
    thus ?thesis by (rule enc0_dominates)
  qed
  show ?thesis
    unfolding peer_next_def Let_def ph_def[symmetric]
    using A B C D by auto
qed


subsection \<open>H3, discharged over a run\<close>

text \<open>A replica's clock evolves by local ticks and peer receipts.\<close>
datatype step = Tick nat | Recv nat nat

fun run :: "nat \<Rightarrow> step list \<Rightarrow> nat" where
  "run c [] = c"
| "run c (Tick w # ss) = run (local_next c w) ss"
| "run c (Recv w p # ss) = run (peer_next c w p) ss"

lemma run_mono: "c \<le> run c ss"
proof (induction ss arbitrary: c)
  case Nil
  thus ?case by simp
next
  case (Cons a ss)
  show ?case
  proof (cases a)
    case (Tick w)
    have "c \<le> local_next c w" using local_next_gt by (simp add: less_imp_le)
    also have "... \<le> run (local_next c w) ss" using Cons.IH .
    finally show ?thesis using Tick by simp
  next
    case (Recv w p)
    have "c \<le> peer_next c w p" using peer_next_gt_old by (simp add: less_imp_le)
    also have "... \<le> run (peer_next c w p) ss" using Cons.IH .
    finally show ?thesis using Recv by simp
  qed
qed

text \<open>
  H3, operationally. Once a replica has received a peer HLC, its clock
  strictly exceeds that value for the rest of the run --- so every event it
  subsequently mints sorts strictly after every event it has received. This
  is what @{text "bondy_oplog_hlc:update/2"} is for, and it is the property
  @{text Oplog_Model} takes as the hypothesis @{text hlc_respects_hb}.
\<close>
theorem run_dominates_received:
  assumes "Recv w p \<in> set ss"
  shows "p < run c ss"
  using assms
proof (induction ss arbitrary: c)
  case Nil
  thus ?case by simp
next
  case (Cons a ss)
  show ?case
  proof (cases "a = Recv w p")
    case True
    have "p < peer_next c w p" using peer_next_gt_peer .
    also have "... \<le> run (peer_next c w p) ss" using run_mono .
    finally show ?thesis using True by simp
  next
    case False
    hence "Recv w p \<in> set ss" using Cons.prems by simp
    thus ?thesis using Cons.IH by (cases a) auto
  qed
qed

end
