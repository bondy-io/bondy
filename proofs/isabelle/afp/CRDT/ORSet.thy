(* Victor B. F. Gomes, University of Cambridge
   Martin Kleppmann, University of Cambridge
   Dominic P. Mulligan, University of Cambridge
   Alastair R. Beresford, University of Cambridge
*)

section\<open>Observed-Remove Set\<close>
 
text\<open>The ORSet is a well-known CRDT for implementing replicated sets, supporting two operations:
     the \emph{insertion} and \emph{deletion} of an arbitrary element in the shared set.\<close>

theory
  ORSet
imports
  Network
begin

datatype ('id, 'a) operation = Add "'id" "'a" | Rem "'id set" "'a"

type_synonym ('id, 'a) state = "'a \<Rightarrow> 'id set"

definition op_elem :: "('id, 'a) operation \<Rightarrow> 'a" where
  "op_elem oper \<equiv> case oper of Add i e \<Rightarrow> e | Rem is e \<Rightarrow> e"

definition interpret_op :: "('id, 'a) operation \<Rightarrow> ('id, 'a) state \<rightharpoonup> ('id, 'a) state" (\<open>\<langle>_\<rangle>\<close> [0] 1000) where
  "interpret_op oper state \<equiv>
     let before = state (op_elem oper);
         after  = case oper of Add i e \<Rightarrow> before \<union> {i} | Rem is e \<Rightarrow> before - is
     in  Some (state ((op_elem oper) := after))"
  
definition valid_behaviours :: "('id, 'a) state \<Rightarrow> 'id \<times> ('id, 'a) operation \<Rightarrow> bool" where
  "valid_behaviours state msg \<equiv>
     case msg of
       (i, Add j  e) \<Rightarrow> i = j |
       (i, Rem is e) \<Rightarrow> is = state e"

locale orset = network_with_constrained_ops _ interpret_op "\<lambda>x. {}" valid_behaviours

lemma (in orset) add_add_commute:
  shows "\<langle>Add i1 e1\<rangle> \<rhd> \<langle>Add i2 e2\<rangle> = \<langle>Add i2 e2\<rangle> \<rhd> \<langle>Add i1 e1\<rangle>"
  by(auto simp add: interpret_op_def op_elem_def kleisli_def, fastforce)

lemma (in orset) add_rem_commute:
  assumes "i \<notin> is"
  shows "\<langle>Add i e1\<rangle> \<rhd> \<langle>Rem is e2\<rangle> = \<langle>Rem is e2\<rangle> \<rhd> \<langle>Add i e1\<rangle>"
  using assms by(auto simp add: interpret_op_def kleisli_def op_elem_def, fastforce)

lemma (in orset) apply_operations_never_fails:
  assumes "xs prefix of i"
  shows "apply_operations xs \<noteq> None"
using assms proof(induction xs rule: rev_induct, clarsimp)
  case (snoc x xs) thus ?case
  proof (cases x)
    case (Broadcast e) thus ?thesis
      using snoc by force
  next
    case (Deliver e) thus ?thesis
      using snoc by (clarsimp, metis interpret_op_def interp_msg_def bind.bind_lunit prefix_of_appendD)
  qed
qed

lemma (in orset) add_id_valid:
  assumes "xs prefix of j"
    and "Deliver (i1, Add i2 e) \<in> set xs"
  shows "i1 = i2"
proof -
  have "\<exists>s. valid_behaviours s (i1, Add i2 e)"
    using assms deliver_in_prefix_is_valid by blast
  thus ?thesis
    by(simp add: valid_behaviours_def)
qed

definition (in orset) added_ids :: "('id \<times> ('id, 'b) operation) event list \<Rightarrow> 'b \<Rightarrow> 'id list" where
  "added_ids es p \<equiv> List.map_filter (\<lambda>x. case x of Deliver (i, Add j e) \<Rightarrow> if e = p then Some j else None | _ \<Rightarrow> None) es"

lemma (in orset) [simp]:
  shows "added_ids [] e = []"
  by (auto simp: added_ids_def map_filter_def)
    
lemma (in orset) [simp]:
  shows "added_ids (xs @ ys) e = added_ids xs e @ added_ids ys e"
    by (auto simp: added_ids_def map_filter_append)

lemma (in orset) added_ids_Broadcast_collapse [simp]:
  shows "added_ids ([Broadcast e]) e' = []"
  by (auto simp: added_ids_def map_filter_append map_filter_def)
    
lemma (in orset) added_ids_Deliver_Rem_collapse [simp]:
  shows "added_ids ([Deliver (i, Rem is e)]) e' = []"
  by (auto simp: added_ids_def map_filter_append map_filter_def)
    
lemma (in orset) added_ids_Deliver_Add_diff_collapse [simp]:
  shows "e \<noteq> e' \<Longrightarrow> added_ids ([Deliver (i, Add j e)]) e' = []"
  by (auto simp: added_ids_def map_filter_append map_filter_def)
    
lemma (in orset) added_ids_Deliver_Add_same_collapse [simp]:
  shows "added_ids ([Deliver (i, Add j e)]) e = [j]"
  by (auto simp: added_ids_def map_filter_append map_filter_def)

lemma (in orset) added_id_not_in_set:
  assumes "i1 \<notin> set (added_ids [Deliver (i, Add i2 e)] e)"
  shows "i1 \<noteq> i2"
  using assms by simp

lemma (in orset) apply_operations_added_ids:
  assumes "es prefix of j"
    and "apply_operations es = Some f"
  shows "f x \<subseteq> set (added_ids es x)"
using assms proof (induct es arbitrary: f rule: rev_induct, force)
  case (snoc x xs) thus ?case
  proof (cases x, force)
    case (Deliver e)
    moreover obtain a b where "e = (a, b)" by force
    ultimately show ?thesis
      using snoc by(case_tac b; clarsimp simp: interp_msg_def split: bind_splits,
                    force split: if_split_asm simp add: op_elem_def interpret_op_def)
  qed
qed
    
lemma (in orset) Deliver_added_ids:
  assumes "xs prefix of j"
    and "i \<in> set (added_ids xs e)"
  shows "Deliver (i, Add i e) \<in> set xs"
using assms proof (induct xs rule: rev_induct, clarsimp)
  case (snoc x xs) thus ?case
  proof (cases x, force)
    case (Deliver e')
    moreover obtain a b where "e' = (a, b)" by force
    ultimately show ?thesis
      using snoc apply (case_tac b; clarsimp)
       apply (metis added_ids_Deliver_Add_diff_collapse added_ids_Deliver_Add_same_collapse
              empty_iff list.set(1) set_ConsD add_id_valid in_set_conv_decomp prefix_of_appendD)
      apply force
      done  
  qed
qed

lemma (in orset) Broadcast_Deliver_prefix_closed:
  assumes "xs @ [Broadcast (r, Rem ix e)] prefix of j"
    and "i \<in> ix"
  shows "Deliver (i, Add i e) \<in> set xs"
proof -  
  obtain y where "apply_operations xs = Some y"
    using assms broadcast_only_valid_msgs by blast
  moreover hence "ix = y e"
    by (metis (mono_tags, lifting) assms(1) broadcast_only_valid_msgs operation.case(2) option.simps(1)
     valid_behaviours_def case_prodD)
  ultimately show ?thesis
    using assms Deliver_added_ids apply_operations_added_ids by blast
qed

lemma (in orset) Broadcast_Deliver_prefix_closed2:
  assumes "xs prefix of j"
    and "Broadcast (r, Rem ix e) \<in> set xs"
    and "i \<in> ix"
  shows "Deliver (i, Add i e) \<in> set xs"
using assms Broadcast_Deliver_prefix_closed by (induction xs rule: rev_induct; force)

lemma (in orset) concurrent_add_remove_independent_technical:
  assumes "i \<in> is"
    and "xs prefix of j"
    and "(i, Add i e) \<in> set (node_deliver_messages xs)" and "(ir, Rem is e) \<in> set (node_deliver_messages xs)"
  shows "hb (i, Add i e) (ir, Rem is e)"
proof -
  obtain pre k where "pre@[Broadcast (ir, Rem is e)] prefix of k"
    using assms delivery_has_a_cause events_before_exist prefix_msg_in_history by blast
  moreover hence "Deliver (i, Add i e) \<in> set pre"
    using Broadcast_Deliver_prefix_closed assms(1) by auto
  ultimately show ?thesis
    using hb.intros(2) events_in_local_order by blast
qed

lemma (in orset) Deliver_Add_same_id_same_message:
  assumes "Deliver (i, Add i e1) \<in> set (history j)" and "Deliver (i, Add i e2) \<in> set (history j)"
  shows "e1 = e2"
proof -
  obtain pre1 pre2 k1 k2 where *: "pre1@[Broadcast (i, Add i e1)] prefix of k1" "pre2@[Broadcast (i, Add i e2)] prefix of k2"
    using assms delivery_has_a_cause events_before_exist by meson
  moreover hence "Broadcast (i, Add i e1) \<in> set (history k1)" "Broadcast (i, Add i e2) \<in> set (history k2)"
    using node_histories.prefix_to_carriers node_histories_axioms by force+
  ultimately show ?thesis
    using msg_id_unique by fastforce
qed

lemma (in orset) ids_imply_messages_same:
  assumes "i \<in> is"
    and "xs prefix of j"
    and "(i, Add i e1) \<in> set (node_deliver_messages xs)" and "(ir, Rem is e2) \<in> set (node_deliver_messages xs)"
  shows "e1 = e2"
proof -
  obtain pre k where "pre@[Broadcast (ir, Rem is e2)] prefix of k"
    using assms delivery_has_a_cause events_before_exist prefix_msg_in_history by blast
  moreover hence "Deliver (i, Add i e2) \<in> set pre"
    using Broadcast_Deliver_prefix_closed assms(1) by blast
  moreover have "Deliver (i, Add i e1) \<in> set (history j)"
    using assms(2) assms(3) prefix_msg_in_history by blast
  ultimately show ?thesis
    by (metis fst_conv msg_id_unique network.delivery_has_a_cause network_axioms operation.inject(1)
        prefix_elem_to_carriers prefix_of_appendD prod.inject)
qed

corollary (in orset) concurrent_add_remove_independent:
  assumes "\<not> hb (i, Add i e1) (ir, Rem is e2)" and "\<not> hb (ir, Rem is e2) (i, Add i e1)"
    and "xs prefix of j"
    and "(i, Add i e1) \<in> set (node_deliver_messages xs)" and "(ir, Rem is e2) \<in> set (node_deliver_messages xs)"
  shows "i \<notin> is"
  using assms ids_imply_messages_same concurrent_add_remove_independent_technical by fastforce

lemma (in orset) rem_rem_commute:
  shows "\<langle>Rem i1 e1\<rangle> \<rhd> \<langle>Rem i2 e2\<rangle> = \<langle>Rem i2 e2\<rangle> \<rhd> \<langle>Rem i1 e1\<rangle>"
  by(unfold interpret_op_def op_elem_def kleisli_def, fastforce)

lemma (in orset) concurrent_operations_commute:
  assumes "xs prefix of i"
  shows "hb.concurrent_ops_commute (node_deliver_messages xs)"                     
proof -
  { fix a b x y
    assume "(a, b) \<in> set (node_deliver_messages xs)"
           "(x, y) \<in> set (node_deliver_messages xs)"
           "hb.concurrent (a, b) (x, y)"
    hence "interp_msg (a, b) \<rhd> interp_msg (x, y) = interp_msg (x, y) \<rhd> interp_msg (a, b)"
      apply(unfold interp_msg_def, case_tac "b"; case_tac "y"; simp add: add_add_commute rem_rem_commute hb.concurrent_def)
       apply (metis add_id_valid add_rem_commute assms concurrent_add_remove_independent hb.concurrentD1 hb.concurrentD2 prefix_contains_msg)+
      done
  } thus ?thesis
    by(fastforce simp: hb.concurrent_ops_commute_def)
qed

theorem (in orset) convergence:
  assumes "set (node_deliver_messages xs) = set (node_deliver_messages ys)"
      and "xs prefix of i" and "ys prefix of j"
    shows "apply_operations xs = apply_operations ys"
using assms by(auto simp add: apply_operations_def intro: hb.convergence_ext concurrent_operations_commute
                node_deliver_messages_distinct hb_consistent_prefix)
              
context orset begin

sublocale sec: strong_eventual_consistency weak_hb hb interp_msg
  "\<lambda>ops.\<exists>xs i. xs prefix of i \<and> node_deliver_messages xs = ops" "\<lambda>x.{}"
  apply(standard; clarsimp simp add: hb_consistent_prefix node_deliver_messages_distinct
        concurrent_operations_commute)
   apply(metis (no_types, lifting) apply_operations_def bind.bind_lunit not_None_eq
     hb.apply_operations_Snoc kleisli_def apply_operations_never_fails interp_msg_def)
  using drop_last_message apply blast
done

end
end
