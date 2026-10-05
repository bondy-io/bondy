(* Victor B. F. Gomes, University of Cambridge
   Martin Kleppmann, University of Cambridge
   Dominic P. Mulligan, University of Cambridge
   Alastair R. Beresford, University of Cambridge
*)

section\<open>Increment-Decrement Counter\<close>
  
text\<open>The Increment-Decrement Counter is perhaps the simplest CRDT, and a paradigmatic example of a
    replicated data structure with commutative operations.\<close>

theory
  Counter
imports
  Network
begin

datatype operation = Increment | Decrement

fun counter_op :: "operation \<Rightarrow> int \<rightharpoonup> int" where
  "counter_op Increment x = Some (x + 1)" |
  "counter_op Decrement x = Some (x - 1)"

locale counter = network_with_ops _ counter_op 0

lemma (in counter) "counter_op x \<rhd> counter_op y = counter_op y \<rhd> counter_op x"
  by(case_tac x; case_tac y; auto simp add: kleisli_def)

lemma (in counter) concurrent_operations_commute:
  assumes "xs prefix of i"
  shows "hb.concurrent_ops_commute (node_deliver_messages xs)"
  using assms
  apply(clarsimp simp: hb.concurrent_ops_commute_def)
  apply(rename_tac a b x y)
  apply(case_tac b; case_tac y; force simp add: interp_msg_def kleisli_def)
  done
  
corollary (in counter) counter_convergence:
  assumes "set (node_deliver_messages xs) = set (node_deliver_messages ys)"
      and "xs prefix of i"
      and "ys prefix of j"
    shows "apply_operations xs = apply_operations ys"
  using assms by(auto simp add: apply_operations_def intro: hb.convergence_ext
      concurrent_operations_commute node_deliver_messages_distinct hb_consistent_prefix)

context counter begin

sublocale sec: strong_eventual_consistency weak_hb hb interp_msg
  "\<lambda>ops. \<exists>xs i. xs prefix of i \<and> node_deliver_messages xs = ops" 0
  apply(standard; clarsimp simp add: hb_consistent_prefix drop_last_message
      node_deliver_messages_distinct concurrent_operations_commute)
   apply(metis (full_types) interp_msg_def counter_op.elims)
  using drop_last_message apply blast
  done

end
end
