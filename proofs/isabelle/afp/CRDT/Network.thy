(* Victor B. F. Gomes, University of Cambridge
   Martin Kleppmann, University of Cambridge
   Dominic P. Mulligan, University of Cambridge
   Alastair R. Beresford, University of Cambridge
*)

section\<open>Axiomatic network models\<close>

text\<open>In this section we develop a formal definition of an \emph{asynchronous unreliable causal broadcast network}.
     We choose this model because it satisfies the causal delivery requirements of many operation-based
     CRDTs~\<^cite>\<open>"Almeida:2015fc" and "Baquero:2014ed"\<close>. Moreover, it is suitable for use in decentralised settings,
     as motivated in the introduction, since it does not require waiting for communication with
     a central server or a quorum of nodes.\<close>

theory
  Network
imports
  Convergence
begin

subsection\<open>Node histories\<close>
  
text\<open>We model a distributed system as an unbounded number of communicating nodes.
     We assume nothing about the communication pattern of nodes---we assume only that each node is
     uniquely identified by a natural number, and that the flow of execution at each node consists
     of a finite, totally ordered sequence of execution steps (events).
     We call that sequence of events at node $i$ the \emph{history} of that node.
     For convenience, we assume that every event or execution step is unique within a node's history.\<close>

locale node_histories = 
  fixes history :: "nat \<Rightarrow> 'evt list"
  assumes histories_distinct [intro!, simp]: "distinct (history i)"

lemma (in node_histories) history_finite:
  shows "finite (set (history i))"
by auto
    
definition (in node_histories) history_order :: "'evt \<Rightarrow> nat \<Rightarrow> 'evt \<Rightarrow> bool" (\<open>_/ \<sqsubset>\<^sup>_/ _\<close> [50,1000,50]50) where
  "x \<sqsubset>\<^sup>i z \<equiv> \<exists>xs ys zs. xs@x#ys@z#zs = history i"

lemma (in node_histories) node_total_order_trans:
  assumes "e1 \<sqsubset>\<^sup>i e2"
      and "e2 \<sqsubset>\<^sup>i e3"
    shows "e1 \<sqsubset>\<^sup>i e3"
proof - 
  obtain xs1 xs2 ys1 ys2 zs1 zs2 where *: "xs1 @ e1 # ys1 @ e2 # zs1 = history i"
      "xs2 @ e2 # ys2 @ e3 # zs2 = history i"
    using history_order_def assms by auto
  hence "xs1 @ e1 # ys1 = xs2 \<and> zs1 = ys2 @ e3 # zs2"
    by(rule_tac xs="history i" and ys="[e2]" in pre_suf_eq_distinct_list) auto
  thus ?thesis
    by(clarsimp simp: history_order_def) (metis "*"(2) append.assoc append_Cons)
qed

lemma (in node_histories) local_order_carrier_closed:
  assumes "e1 \<sqsubset>\<^sup>i e2"
    shows "{e1,e2} \<subseteq> set (history i)"
  using assms by (clarsimp simp add: history_order_def)
    (metis in_set_conv_decomp Un_iff Un_subset_iff insert_subset list.simps(15)
        set_append set_subset_Cons)+

lemma (in node_histories) node_total_order_irrefl:
  shows "\<not> (e \<sqsubset>\<^sup>i e)"
  by(clarsimp simp add: history_order_def)
    (metis Un_iff histories_distinct distinct_append distinct_set_notin
        list.set_intros(1) set_append)

lemma (in node_histories) node_total_order_antisym:
  assumes "e1 \<sqsubset>\<^sup>i e2"
      and "e2 \<sqsubset>\<^sup>i e1"
    shows "False"
  using assms node_total_order_irrefl node_total_order_trans by blast

lemma (in node_histories) node_order_is_total:
  assumes "e1 \<in> set (history i)"
      and "e2 \<in> set (history i)"
      and "e1 \<noteq> e2"
    shows "e1 \<sqsubset>\<^sup>i e2 \<or> e2 \<sqsubset>\<^sup>i e1"
  using assms unfolding history_order_def by(metis list_split_two_elems histories_distinct)

definition (in node_histories) prefix_of_node_history :: "'evt list \<Rightarrow> nat \<Rightarrow> bool" (infix \<open>prefix of\<close> 50) where
  "xs prefix of i \<equiv> \<exists>ys. xs@ys = history i"

lemma (in node_histories) carriers_head_lt:
  assumes "y#ys = history i"
  shows   "\<not>(x \<sqsubset>\<^sup>i y)"
using assms
  apply(clarsimp simp add: history_order_def)
  apply(rename_tac xs1 ys1 zs1)
   apply (subgoal_tac "xs1 @ x # ys1 = [] \<and> zs1 = ys")
  apply clarsimp
  apply (rule_tac xs="history i" and ys="[y]" in pre_suf_eq_distinct_list)
   apply auto
  done

lemma (in node_histories) prefix_of_ConsD [dest]:
  assumes "x # xs prefix of i"
    shows "[x] prefix of i"
  using assms by(auto simp: prefix_of_node_history_def)

lemma (in node_histories) prefix_of_appendD [dest]:
  assumes "xs @ ys prefix of i"
    shows "xs prefix of i"
  using assms by(auto simp: prefix_of_node_history_def)

lemma (in node_histories) prefix_distinct:
  assumes "xs prefix of i"
    shows "distinct xs"
  using assms by(clarsimp simp: prefix_of_node_history_def) (metis histories_distinct distinct_append)

lemma (in node_histories) prefix_to_carriers [intro]:
  assumes "xs prefix of i"
    shows "set xs \<subseteq> set (history i)"
  using assms by(clarsimp simp: prefix_of_node_history_def) (metis Un_iff set_append)

lemma (in node_histories) prefix_elem_to_carriers:
  assumes "xs prefix of i"
      and "x \<in> set xs"
    shows "x \<in> set (history i)"
  using assms by(clarsimp simp: prefix_of_node_history_def) (metis Un_iff set_append)

lemma (in node_histories) local_order_prefix_closed:
  assumes "x \<sqsubset>\<^sup>i y"
      and "xs prefix of i"
      and "y \<in> set xs"
    shows "x \<in> set xs"
proof -
  obtain ys where "xs @ ys = history i"
    using assms prefix_of_node_history_def by blast
  moreover obtain as bs cs where "as @ x # bs @ y # cs = history i"
    using assms history_order_def by blast
  moreover obtain pre suf where *: "xs = pre @ y # suf"
    using assms split_list by fastforce
  ultimately have "pre = as @ x # bs \<and> suf @ ys = cs"
    by (rule_tac xs="history i" and ys="[y]" in pre_suf_eq_distinct_list) auto
  thus ?thesis
    using assms * by clarsimp
qed

lemma (in node_histories) local_order_prefix_closed_last:
  assumes "x \<sqsubset>\<^sup>i y"
      and "xs@[y] prefix of i"
    shows "x \<in> set xs"
proof -
  have "x \<in> set (xs @ [y])"
    using assms by (force dest: local_order_prefix_closed)
  thus ?thesis
    using assms by(force simp add: node_total_order_irrefl prefix_to_carriers)
qed

lemma (in node_histories) events_before_exist:
  assumes "x \<in> set (history i)"
  shows "\<exists>pre. pre @ [x] prefix of i"
proof -
  have "\<exists>idx. idx < length (history i) \<and> (history i) ! idx = x"
    using assms by(simp add: set_elem_nth)
  thus ?thesis
    by(metis append_take_drop_id take_Suc_conv_app_nth prefix_of_node_history_def)
qed

lemma (in node_histories) events_in_local_order:
  assumes "pre @ [e2] prefix of i"
  and "e1 \<in> set pre"
  shows "e1 \<sqsubset>\<^sup>i e2"
  using assms split_list unfolding history_order_def prefix_of_node_history_def by fastforce

subsection\<open>Asynchronous broadcast networks\<close>
  
text\<open>We define a new locale $\isa{network}$ containing three axioms that define how broadcast
     and deliver events may interact, with these axioms defining the properties of our network model.\<close>

datatype 'msg event
  = Broadcast 'msg
  | Deliver 'msg

locale network = node_histories history for history :: "nat \<Rightarrow> 'msg event list" +
  fixes msg_id :: "'msg \<Rightarrow> 'msgid"
  (* Broadcast/Deliver interaction *)
  assumes delivery_has_a_cause: "\<lbrakk> Deliver m \<in> set (history i) \<rbrakk> \<Longrightarrow>
                                    \<exists>j. Broadcast m \<in> set (history j)"
      and deliver_locally: "\<lbrakk> Broadcast m \<in> set (history i) \<rbrakk> \<Longrightarrow>
                                    Broadcast m \<sqsubset>\<^sup>i Deliver m"
      and msg_id_unique: "\<lbrakk> Broadcast m1 \<in> set (history i);
                            Broadcast m2 \<in> set (history j);
                            msg_id m1 = msg_id m2 \<rbrakk> \<Longrightarrow> i = j \<and> m1 = m2"

text\<open>
The axioms can be understood as follows:
\begin{description}
    \item[delivery-has-a-cause:] If some message $\isa{m}$ was delivered at some node, then there exists some node on which $\isa{m}$ was broadcast.
        With this axiom, we assert that messages are not created ``out of thin air'' by the network itself, and that the only source of messages are the nodes.
    \item[deliver-locally:] If a node broadcasts some message $\isa{m}$, then the same node must subsequently also deliver $\isa{m}$ to itself.
        Since $\isa{m}$ does not actually travel over the network, this local delivery is always possible, even if the network is interrupted.
        Local delivery may seem redundant, since the effect of the delivery could also be implemented by the broadcast event itself; however, it is standard practice in the description of broadcast protocols that the sender of a message also sends it to itself, since this property simplifies the definition of algorithms built on top of the broadcast abstraction \<^cite>\<open>"Cachin:2011wt"\<close>.
    \item[msg-id-unique:] We do not assume that the message type $\isacharprime\isa{msg}$ has any particular structure; we only assume the existence of a function $\isa{msg-id} \mathbin{\isacharcolon\isacharcolon} \isacharprime\isa{msg} \mathbin{\isasymRightarrow} \isacharprime\isa{msgid}$ that maps every message to some globally unique identifier of type $\isacharprime\isa{msgid}$.
        We assert this uniqueness by stating that if $\isa{m1}$ and $\isa{m2}$ are any two messages broadcast by any two nodes, and their $\isa{msg-id}$s are the same, then they were in fact broadcast by the same node and the two messages are identical. 
        In practice, these globally unique IDs can by implemented using unique node identifiers, sequence numbers or timestamps.
\end{description}
\<close>
  
lemma (in network) broadcast_before_delivery:
  assumes "Deliver m \<in> set (history i)"
  shows "\<exists>j. Broadcast m \<sqsubset>\<^sup>j Deliver m"
  using assms deliver_locally delivery_has_a_cause by blast

lemma (in network) broadcasts_unique:
  assumes "i \<noteq> j"
    and "Broadcast m \<in> set (history i)"
  shows "Broadcast m \<notin> set (history j)"
  using assms msg_id_unique by blast
    
text\<open>Based on the well-known definition by \<^cite>\<open>"Lamport:1978jq"\<close>, we say that
    $\isa{m1}\prec\isa{m2}$ if any of the following is true:
    \begin{enumerate}
      \item $\isa{m1}$ and $\isa{m2}$ were broadcast by the same node, and $\isa{m1}$ was broadcast before $\isa{m2}$.
      \item The node that broadcast $\isa{m2}$ had delivered $\isa{m1}$ before it broadcast $\isa{m2}$.
      \item There exists some operation $\isa{m3}$ such that $\isa{m1} \prec \isa{m3}$ and $\isa{m3} \prec \isa{m2}$.
    \end{enumerate}\<close>

inductive (in network) hb :: "'msg \<Rightarrow> 'msg \<Rightarrow> bool" where
  hb_broadcast: "\<lbrakk> Broadcast m1 \<sqsubset>\<^sup>i Broadcast m2 \<rbrakk> \<Longrightarrow> hb m1 m2" |
  hb_deliver:   "\<lbrakk> Deliver m1 \<sqsubset>\<^sup>i Broadcast m2 \<rbrakk> \<Longrightarrow> hb m1 m2" |
  hb_trans:     "\<lbrakk> hb m1 m2; hb m2 m3 \<rbrakk> \<Longrightarrow> hb m1 m3"
  
inductive_cases (in network) hb_elim: "hb x y"
        
definition (in network) weak_hb :: "'msg \<Rightarrow> 'msg \<Rightarrow> bool" where
  "weak_hb m1 m2 \<equiv> hb m1 m2 \<or> m1 = m2"

locale causal_network = network +
  assumes causal_delivery: "Deliver m2 \<in> set (history j) \<Longrightarrow> hb m1 m2 \<Longrightarrow> Deliver m1 \<sqsubset>\<^sup>j Deliver m2"

lemma (in causal_network) causal_broadcast:
  assumes "Deliver m2 \<in> set (history j)"
      and "Deliver m1 \<sqsubset>\<^sup>i Broadcast m2"
    shows "Deliver m1 \<sqsubset>\<^sup>j Deliver m2"
  using assms causal_delivery hb.intros(2) by blast

lemma (in network) hb_broadcast_exists1:
  assumes "hb m1 m2"
  shows "\<exists>i. Broadcast m1 \<in> set (history i)"
  using assms
  apply(induction rule: hb.induct)
    apply(meson insert_subset node_histories.local_order_carrier_closed node_histories_axioms)
   apply(meson delivery_has_a_cause insert_subset local_order_carrier_closed)
  apply simp
  done
    
lemma (in network) hb_broadcast_exists2:
  assumes "hb m1 m2"
  shows "\<exists>i. Broadcast m2 \<in> set (history i)"
  using assms
  apply(induction rule: hb.induct)
    apply(meson insert_subset node_histories.local_order_carrier_closed node_histories_axioms)
   apply(meson delivery_has_a_cause insert_subset local_order_carrier_closed)
  apply simp
  done
    
subsection\<open>Causal networks\<close>

lemma (in causal_network) hb_has_a_reason:
  assumes "hb m1 m2"
    and "Broadcast m2 \<in> set (history i)"
  shows "Deliver m1 \<in> set (history i) \<or> Broadcast m1 \<in> set (history i)"
  using assms apply (induction rule: hb.induct)
    apply(metis insert_subset local_order_carrier_closed network.broadcasts_unique network_axioms)
   apply(metis insert_subset local_order_carrier_closed network.broadcasts_unique network_axioms)
  using hb_trans causal_delivery local_order_carrier_closed apply blast
  done

lemma (in causal_network) hb_cross_node_delivery:
  assumes "hb m1 m2"
    and "Broadcast m1 \<in> set (history i)"
    and "Broadcast m2 \<in> set (history j)"
    and "i \<noteq> j"
  shows "Deliver m1 \<in> set (history j)"
  using assms
  apply(induction rule: hb.induct)
    apply(metis broadcasts_unique insert_subset local_order_carrier_closed)
   apply(metis insert_subset local_order_carrier_closed network.broadcasts_unique network_axioms)
  using broadcasts_unique hb.intros(3) hb_has_a_reason apply blast
  done
    
lemma (in causal_network) hb_irrefl:
  assumes "hb m1 m2"
  shows "m1 \<noteq> m2"
using assms proof(induction rule: hb.induct)
  case (hb_broadcast m1 i m2) thus ?case
    using node_total_order_antisym by blast
next
  case (hb_deliver m1 i m2) thus ?case
    by(meson causal_broadcast insert_subset local_order_carrier_closed node_total_order_irrefl)
next
  case (hb_trans m1 m2 m3)
  then obtain i j where "Broadcast m3 \<in> set (history i)" "Broadcast m2 \<in> set (history j)"
    using hb_broadcast_exists2 by blast
  then show ?case
    using assms hb_trans by (meson causal_network.causal_delivery causal_network_axioms
        deliver_locally insert_subset network.hb.intros(3) network_axioms 
        node_histories.local_order_carrier_closed assms hb_trans
        node_histories_axioms node_total_order_irrefl)
qed

lemma (in causal_network) hb_broadcast_broadcast_order:
  assumes "hb m1 m2"
    and "Broadcast m1 \<in> set (history i)"
    and "Broadcast m2 \<in> set (history i)"
  shows "Broadcast m1 \<sqsubset>\<^sup>i Broadcast m2"
using assms proof(induction rule: hb.induct)
  case (hb_broadcast m1 i m2) thus ?case
    by(metis insertI1 local_order_carrier_closed network.broadcasts_unique network_axioms subsetCE)
next
  case (hb_deliver m1 i m2) thus ?case
    by(metis broadcasts_unique insert_subset local_order_carrier_closed
          network.broadcast_before_delivery network_axioms node_total_order_trans)
next
  case (hb_trans m1 m2 m3)
  then show ?case
  proof (cases "Broadcast m2 \<in> set (history i)")
    case True thus ?thesis
      using hb_trans node_total_order_trans by blast
  next
    case False hence "Deliver m2 \<in> set (history i)" "m1 \<noteq> m2" "m2 \<noteq> m3"
      using hb_has_a_reason hb_trans by auto
    thus ?thesis
      by(metis hb_trans event.inject(1) hb.intros(1) hb_irrefl network.hb.intros(3) network_axioms node_order_is_total hb_irrefl)
  qed
qed
  
lemma (in causal_network) hb_antisym:
  assumes "hb x y"
      and "hb y x"
  shows   "False"
using assms proof(induction rule: hb.induct)
  fix m1 i m2  
  assume "hb m2 m1" and "Broadcast m1 \<sqsubset>\<^sup>i Broadcast m2"
  thus False
    apply - proof(erule hb_elim)
    show "\<And>ia. Broadcast m1 \<sqsubset>\<^sup>i Broadcast m2 \<Longrightarrow> Broadcast m2 \<sqsubset>\<^sup>ia Broadcast m1 \<Longrightarrow> False"
      by(metis broadcasts_unique insert_subset local_order_carrier_closed node_total_order_irrefl node_total_order_trans)
  next
    show "\<And>ia. Broadcast m1 \<sqsubset>\<^sup>i Broadcast m2 \<Longrightarrow> Deliver m2 \<sqsubset>\<^sup>ia Broadcast m1 \<Longrightarrow> False"
      by(metis broadcast_before_delivery broadcasts_unique insert_subset local_order_carrier_closed node_total_order_irrefl node_total_order_trans)
  next
    show "\<And>m2a. Broadcast m1 \<sqsubset>\<^sup>i Broadcast m2 \<Longrightarrow> hb m2 m2a \<Longrightarrow> hb m2a m1 \<Longrightarrow> False"
      using assms(1) assms(2) hb.intros(3) hb_irrefl by blast
  qed
next
  fix m1 i m2
  assume "hb m2 m1"
     and "Deliver m1 \<sqsubset>\<^sup>i Broadcast m2"
  thus "False"
    apply - proof(erule hb_elim)
    show "\<And>ia. Deliver m1 \<sqsubset>\<^sup>i Broadcast m2 \<Longrightarrow> Broadcast m2 \<sqsubset>\<^sup>ia Broadcast m1 \<Longrightarrow> False"
      by (metis broadcast_before_delivery broadcasts_unique insert_subset local_order_carrier_closed node_total_order_irrefl node_total_order_trans)
  next
    show "\<And>ia. Deliver m1 \<sqsubset>\<^sup>i Broadcast m2 \<Longrightarrow> Deliver m2 \<sqsubset>\<^sup>ia Broadcast m1 \<Longrightarrow> False"
      by (meson causal_network.causal_delivery causal_network_axioms hb.intros(2) hb.intros(3) insert_subset local_order_carrier_closed node_total_order_irrefl)
  next
    show "\<And>m2a. Deliver m1 \<sqsubset>\<^sup>i Broadcast m2 \<Longrightarrow> hb m2 m2a \<Longrightarrow> hb m2a m1 \<Longrightarrow> False"
      by (meson causal_delivery hb.intros(2) insert_subset local_order_carrier_closed network.hb.intros(3) network_axioms node_total_order_irrefl)
  qed
next
  fix m1 m2 m3
  assume "hb m1 m2" "hb m2 m3" "hb m3 m1"
     and "(hb m2 m1 \<Longrightarrow> False)" "(hb m3 m2 \<Longrightarrow> False)"
  thus "False"
    using hb.intros(3) by blast
qed

definition (in network) node_deliver_messages :: "'msg event list \<Rightarrow> 'msg list" where
  "node_deliver_messages cs \<equiv> List.map_filter (\<lambda>e. case e of Deliver m \<Rightarrow> Some m | _ \<Rightarrow> None) cs"

lemma (in network) node_deliver_messages_empty [simp]:
  shows "node_deliver_messages [] = []"
  by(simp add: node_deliver_messages_def map_filter_def)

lemma (in network) node_deliver_messages_Broadcast [simp]:
  shows "node_deliver_messages [Broadcast m] = []"
  by(simp add: node_deliver_messages_def map_filter_def)

lemma (in network) node_deliver_messages_Deliver [simp]:
  shows "node_deliver_messages [Deliver m] = [m]"
  by(simp add: node_deliver_messages_def map_filter_def)

lemma (in network) node_deliver_messages_Cons:
  shows "node_deliver_messages (x#xs) = (node_deliver_messages [x])@(node_deliver_messages xs)"
  by(simp add: node_deliver_messages_def map_filter_def)
    
lemma (in network) node_deliver_messages_append:
  shows "node_deliver_messages (xs@ys) = (node_deliver_messages xs)@(node_deliver_messages ys)"
  by(simp add: node_deliver_messages_def map_filter_def)

lemma (in network) prefix_msg_in_history:
  assumes "es prefix of i"
      and "m \<in> set (node_deliver_messages es)"
    shows "Deliver m \<in> set (history i)"
using assms prefix_to_carriers by(fastforce simp: node_deliver_messages_def map_filter_def split: event.split_asm)

lemma (in network) prefix_contains_msg:
  assumes "es prefix of i"
      and "m \<in> set (node_deliver_messages es)"
    shows "Deliver m \<in> set es"
  using assms by(auto simp: node_deliver_messages_def map_filter_def split: event.split_asm)
    
lemma (in network) node_deliver_messages_distinct:
  assumes "xs prefix of i"
  shows "distinct (node_deliver_messages xs)"
using assms proof(induction xs rule: rev_induct)
  case Nil thus ?case by simp
next
  case (snoc x xs)
  { fix y assume *: "y \<in> set (node_deliver_messages xs)" "y \<in> set (node_deliver_messages [x])"
    moreover have "distinct (xs @ [x])"
      using assms snoc prefix_distinct by blast
    ultimately have "False"
      using assms apply(case_tac x; clarsimp simp add: map_filter_def node_deliver_messages_def)
      using * prefix_contains_msg snoc.prems by blast
  } thus ?case
    using snoc by(fastforce simp add: node_deliver_messages_append node_deliver_messages_def map_filter_def)
qed
  
lemma (in network) drop_last_message:
  assumes "evts prefix of i"
  and "node_deliver_messages evts = msgs @ [last_msg]"
  shows "\<exists>pre. pre prefix of i \<and> node_deliver_messages pre = msgs"
proof -
  have "Deliver last_msg \<in> set evts"
    using assms network.prefix_contains_msg network_axioms by force
  then obtain idx where *: "idx < length evts" "evts ! idx = Deliver last_msg"
    by (meson set_elem_nth)
  then obtain pre suf where "evts = pre @ (evts ! idx) # suf"
    using id_take_nth_drop by blast
  hence **: "evts = pre @ (Deliver last_msg) # suf"
    using assms * by auto
  moreover hence "distinct (node_deliver_messages ([Deliver last_msg] @ suf))"
    by (metis assms(1) assms(2) distinct_singleton node_deliver_messages_Cons node_deliver_messages_Deliver
        node_deliver_messages_append node_deliver_messages_distinct not_Cons_self2 pre_suf_eq_distinct_list)
  ultimately have "node_deliver_messages ([Deliver last_msg] @ suf) = [last_msg] @ []"
    by (metis append_self_conv assms(1) assms(2) node_deliver_messages_Cons node_deliver_messages_Deliver
        node_deliver_messages_append node_deliver_messages_distinct not_Cons_self2 pre_suf_eq_distinct_list)
  thus ?thesis
    using assms * ** by (metis append1_eq_conv append_Cons append_Nil node_deliver_messages_append prefix_of_appendD)
qed

locale network_with_ops = causal_network history fst
  for history :: "nat \<Rightarrow> ('msgid \<times> 'op) event list" +
  fixes interp :: "'op \<Rightarrow> 'state \<rightharpoonup> 'state"
  and initial_state :: "'state"

context network_with_ops begin

definition interp_msg :: "'msgid \<times> 'op \<Rightarrow> 'state \<rightharpoonup> 'state" where
  "interp_msg msg state \<equiv> interp (snd msg) state"

sublocale hb: happens_before weak_hb hb interp_msg
proof
  fix x y :: "'msgid \<times> 'op"
  show "hb x y = (weak_hb x y \<and> \<not> weak_hb y x)"
    unfolding weak_hb_def using hb_antisym by blast
next
  fix x
  show "weak_hb x x"
    using weak_hb_def by blast
next
  fix x y z
  assume "weak_hb x y" "weak_hb y z"
  thus "weak_hb x z"
    using weak_hb_def by (metis network.hb.intros(3) network_axioms)
qed

end

definition (in network_with_ops) apply_operations :: "('msgid \<times> 'op) event list \<rightharpoonup> 'state" where
  "apply_operations es \<equiv> hb.apply_operations (node_deliver_messages es) initial_state"

definition (in network_with_ops) node_deliver_ops :: "('msgid \<times> 'op) event list \<Rightarrow> 'op list" where
  "node_deliver_ops cs \<equiv> map snd (node_deliver_messages cs)"

lemma (in network_with_ops) apply_operations_empty [simp]:
  shows "apply_operations [] = Some initial_state"
  by(auto simp add: apply_operations_def)

lemma (in network_with_ops) apply_operations_Broadcast [simp]:
  shows "apply_operations (xs @ [Broadcast m]) = apply_operations xs"
  by(auto simp add: apply_operations_def node_deliver_messages_def map_filter_def)

lemma (in network_with_ops) apply_operations_Deliver [simp]:
  shows "apply_operations (xs @ [Deliver m]) = (apply_operations xs \<bind> interp_msg m)"
  by(auto simp add: apply_operations_def node_deliver_messages_def map_filter_def kleisli_def)

lemma (in network_with_ops) hb_consistent_technical:
  assumes "\<And>m n. m < length cs \<Longrightarrow> n < m \<Longrightarrow> cs ! n \<sqsubset>\<^sup>i cs ! m"
  shows   "hb.hb_consistent (node_deliver_messages cs)"
using assms proof (induction cs rule: rev_induct)
  case Nil thus ?case
    by (simp add: node_deliver_messages_def hb.hb_consistent.intros List.map_filter_def)
next
  case (snoc x xs)
  hence *: "(\<And>m n. m < length xs \<Longrightarrow> n < m \<Longrightarrow> xs ! n \<sqsubset>\<^sup>i xs ! m)"
    by(-, erule_tac x=m in meta_allE, erule_tac x=n in meta_allE, clarsimp simp add: nth_append)
  then show ?case
  proof (cases x)
    case (Broadcast x1) thus ?thesis
      using snoc * by (simp add: node_deliver_messages_append)
  next
    case (Deliver x2) thus ?thesis
      using snoc * [[simproc del: defined_all]]
      apply (clarsimp simp add: node_deliver_messages_def map_filter_def map_filter_append)
      apply (rename_tac m m1 m2)
      apply (case_tac m; clarsimp)
      apply (drule set_elem_nth, erule exE, erule conjE)
      apply (erule_tac x="length xs" in meta_allE)
      apply (clarsimp simp add: nth_append)
      apply (metis causal_delivery insert_subset local_order_carrier_closed
        node_total_order_antisym)
      done
 qed
qed
    
corollary (in network_with_ops)
  shows "hb.hb_consistent (node_deliver_messages (history i))"
  by (metis hb_consistent_technical history_order_def less_one linorder_neqE_nat list_nth_split zero_order(3))

lemma (in network_with_ops) hb_consistent_prefix:
  assumes "xs prefix of i"
  shows "hb.hb_consistent (node_deliver_messages xs)"
using assms proof (clarsimp simp: prefix_of_node_history_def, rule_tac i=i in hb_consistent_technical)
  fix m n ys assume *: "xs @ ys = history i" "m < length xs" "n < m"
  consider (a) "xs = []" | (b) "\<exists>c. xs = [c]" | (c) "Suc 0 < length (xs)"
    by (metis Suc_pred length_Suc_conv length_greater_0_conv zero_less_diff)
  thus "xs ! n \<sqsubset>\<^sup>i xs ! m"
  proof (cases)
    case a thus ?thesis
      using * by clarsimp
  next
    case b thus ?thesis
      using assms * by clarsimp
  next
    case c thus ?thesis
      using assms * apply clarsimp
      apply(drule list_nth_split, assumption, clarsimp simp: c)
      apply (metis append.assoc append.simps(2) history_order_def)
      done
  qed
qed

locale network_with_constrained_ops = network_with_ops +
  fixes valid_msg :: "'c \<Rightarrow> ('a \<times> 'b) \<Rightarrow> bool"
  assumes broadcast_only_valid_msgs: "pre @ [Broadcast m] prefix of i \<Longrightarrow>
             \<exists>state. apply_operations pre = Some state \<and> valid_msg state m"

lemma (in network_with_constrained_ops) broadcast_is_valid:
  assumes "Broadcast m \<in> set (history i)"
  shows "\<exists>state. valid_msg state m"
  using assms broadcast_only_valid_msgs events_before_exist by blast

lemma (in network_with_constrained_ops) deliver_is_valid:
  assumes "Deliver m \<in> set (history i)"
  shows "\<exists>j pre state. pre @ [Broadcast m] prefix of j \<and> apply_operations pre = Some state \<and> valid_msg state m"
  using assms apply (clarsimp dest!: delivery_has_a_cause)
  using broadcast_only_valid_msgs events_before_exist apply blast
  done

lemma (in network_with_constrained_ops) deliver_in_prefix_is_valid:
  assumes "xs prefix of i"
      and "Deliver m \<in> set xs"
    shows "\<exists>state. valid_msg state m"
  by (meson assms network_with_constrained_ops.deliver_is_valid network_with_constrained_ops_axioms prefix_elem_to_carriers)

subsection\<open>Dummy network models\<close>

interpretation trivial_node_histories: node_histories "\<lambda>m. []"
  by standard auto

interpretation trivial_network: network "\<lambda>m. []" id
  by standard auto
    
interpretation trivial_causal_network: causal_network "\<lambda>m. []" id
  by standard auto

interpretation trivial_network_with_ops: network_with_ops "\<lambda>m. []" "(\<lambda>x y. Some y)" 0
  by standard auto
    
interpretation trivial_network_with_constrained_ops: network_with_constrained_ops "\<lambda>m. []" "(\<lambda>x y. Some y)" 0 "\<lambda>x y. True"
  by standard (simp add: trivial_node_histories.prefix_of_node_history_def)

end
