(* Victor B. F. Gomes, University of Cambridge
   Martin Kleppmann, University of Cambridge
   Dominic P. Mulligan, University of Cambridge
   Alastair R. Beresford, University of Cambridge
*)

section\<open>Strong Eventual Consistency\<close>

text\<open>In this section we formalise the notion of strong eventual consistency.
     We do not make any assumptions about networks or data structures; instead,
     we use an abstract model of operations that may be reordered, and we reason about
    the properties that those operations must satisfy.
    We then provide concrete implementations of that abstract model in later sections.\<close>
  
theory
  Convergence
imports
  Util
begin
  
text\<open>The \emph{happens-before} relation, as introduced by \<^cite>\<open>"Lamport:1978jq"\<close>, captures 
     causal dependencies between operations. It can be defined in terms of sending and receiving
     messages on a network.
     However, for now, we keep it abstract, our only restriction on the happens-before relation is
     that it must be a \emph{strict partial order},
     that is, it must be irreflexive and transitive, which implies that it is also antisymmetric.
     We describe the state of a node using an abstract type variable.
     To model state changes, we assume the existence of an \emph{interpretation} function \isa{interp}
     which lifts an operation into a \emph{state transformer}---a function that either maps
     an old state to a new state, or fails.\<close>

locale happens_before = preorder hb_weak hb
  for hb_weak :: "'a \<Rightarrow> 'a \<Rightarrow> bool"  (infix \<open>\<preceq>\<close> 50)
  and hb :: "'a \<Rightarrow> 'a \<Rightarrow> bool"       (infix \<open>\<prec>\<close> 50) +
  fixes interp :: "'a \<Rightarrow> 'b \<rightharpoonup> 'b" (\<open>\<langle>_\<rangle>\<close> [0] 1000)
begin

(*************************************************************************)
subsection\<open>Concurrent operations\<close>
(*************************************************************************)
  
text\<open>We say that two operations $x$ and $y$ are \emph{concurrent}, written
    $\isa{x} \mathbin{\isasymparallel} \isa{y}$, whenever one does not happen before the other:
    $\neg (\isa{x} \prec \isa{y})$ and $\neg (\isa{y} \prec \isa{x})$.\<close>

definition concurrent :: "'a \<Rightarrow> 'a \<Rightarrow> bool" (infix \<open>\<parallel>\<close> 50) where
  "s1 \<parallel> s2 \<equiv> \<not> (s1 \<prec> s2) \<and> \<not> (s2 \<prec> s1)"

lemma concurrentI [intro!]: "\<not> (s1 \<prec> s2) \<Longrightarrow> \<not> (s2 \<prec> s1) \<Longrightarrow> s1 \<parallel> s2"
  by (auto simp: concurrent_def)

lemma concurrentD1 [dest]: "s1 \<parallel> s2 \<Longrightarrow> \<not> (s1 \<prec> s2)"
  by (auto simp: concurrent_def)

lemma concurrentD2 [dest]: "s1 \<parallel> s2 \<Longrightarrow> \<not> (s2 \<prec> s1)"
  by (auto simp: concurrent_def)

lemma concurrent_refl [intro!, simp]: "s \<parallel> s"
  by (auto simp: concurrent_def)

lemma concurrent_comm: "s1 \<parallel> s2 \<longleftrightarrow> s2 \<parallel> s1"
  by (auto simp: concurrent_def)

definition concurrent_set :: "'a \<Rightarrow> 'a list \<Rightarrow> bool" where
  "concurrent_set x xs \<equiv> \<forall>y \<in> set xs. x \<parallel> y"

lemma concurrent_set_empty [simp, intro!]:
  "concurrent_set x []"
  by (auto simp: concurrent_set_def)

lemma concurrent_set_ConsE [elim!]:
  assumes "concurrent_set a (x#xs)"
      and "concurrent_set a xs \<Longrightarrow> concurrent x a \<Longrightarrow> G"
    shows "G"
  using assms by (auto simp: concurrent_set_def)

lemma concurrent_set_ConsI [intro!]:
  "concurrent_set a xs \<Longrightarrow> concurrent a x \<Longrightarrow> concurrent_set a (x#xs)"
  by (auto simp: concurrent_set_def)

lemma concurrent_set_appendI [intro!]:
  "concurrent_set a xs \<Longrightarrow> concurrent_set a ys \<Longrightarrow> concurrent_set a (xs@ys)"
  by (auto simp: concurrent_set_def)

lemma concurrent_set_Cons_Snoc [simp]:
  "concurrent_set a (xs@[x]) = concurrent_set a (x#xs)"
  by (auto simp: concurrent_set_def)

(*************************************************************************)
subsection\<open>Happens-before consistency\<close>
(*************************************************************************)

text\<open>The purpose of the happens-before relation is to require that some operations must be applied
     in a particular order, while allowing concurrent operations to be reordered with respect to each other.
     We assume that each node applies operations in some sequential order (a standard assumption
     for distributed algorithms), and so we can model the execution history of a node as a list of operations.\<close>
  
inductive hb_consistent :: "'a list \<Rightarrow> bool" where
  [intro!]: "hb_consistent []" |
  [intro!]: "\<lbrakk> hb_consistent xs; \<forall>x \<in> set xs. \<not> y \<prec> x \<rbrakk> \<Longrightarrow> hb_consistent (xs @ [y])"
  
text\<open>As a result, whenever two operations $\isa{x}$ and $\isa{y}$ appear in a hb-consistent list,
     and $\isa{x}\prec\isa{y}$, then $\isa{x}$ must appear before $\isa{y}$ in the list.
     However, if $\isa{x}\mathbin{\isasymparallel}\isa{y}$, the operations can appear in the list
     in either order.\<close>

lemma "(x \<prec> y \<or> concurrent x y) = (\<not> y \<prec> x)"
  using less_asym by blast

lemma consistentI [intro!]:
  assumes "hb_consistent (xs @ ys)"
  and     "\<forall>x \<in> set (xs @ ys). \<not> z \<prec> x"
  shows   "hb_consistent (xs @ ys @ [z])"
  using assms hb_consistent.intros append_assoc by metis

inductive_cases  hb_consistent_elim [elim]:
  "hb_consistent []"
  "hb_consistent (xs@[y])"
  "hb_consistent (xs@ys)"
  "hb_consistent (xs@ys@[z])"

inductive_cases  hb_consistent_elim_gen:
  "hb_consistent zs"

lemma hb_consistent_append_D1 [dest]:
  assumes "hb_consistent (xs @ ys)"
  shows   "hb_consistent xs"
  using assms by(induction ys arbitrary: xs rule: List.rev_induct) auto

lemma hb_consistent_append_D2 [dest]:
  assumes "hb_consistent (xs @ ys)"
  shows   "hb_consistent ys"
  using assms by(induction ys arbitrary: xs rule: List.rev_induct) fastforce+

lemma hb_consistent_append_elim_ConsD [elim]:
  assumes "hb_consistent (y#ys)"
  shows   "hb_consistent ys"
  using assms hb_consistent_append_D2 by(metis append_Cons append_Nil)

lemma hb_consistent_remove1 [intro]:
  assumes "hb_consistent xs"
  shows   "hb_consistent (remove1 x xs)"
  using assms by (induction rule: hb_consistent.induct) (auto simp: remove1_append)

lemma hb_consistent_singleton [intro!]:
  shows "hb_consistent [x]"
  using hb_consistent.intros by fastforce

lemma hb_consistent_prefix_suffix_exists:
  assumes "hb_consistent ys"
          "hb_consistent (xs @ [x])"
          "{x} \<union> set xs = set ys"
          "distinct (x#xs)"
          "distinct ys"
  shows "\<exists>prefix suffix. ys = prefix @ x # suffix \<and> concurrent_set x suffix"
using assms proof (induction arbitrary: xs rule: hb_consistent.induct, simp)
  fix xs y ys
  assume IH: "(\<And>xs. hb_consistent (xs @ [x]) \<Longrightarrow>
               {x} \<union> set xs = set ys \<Longrightarrow>
               distinct (x # xs) \<Longrightarrow> distinct ys \<Longrightarrow>
             \<exists>prefix suffix. ys = prefix @ x # suffix \<and> concurrent_set x suffix) "
  assume assms: "hb_consistent ys" "\<forall>x\<in>set ys. \<not> hb y x"
                "hb_consistent (xs @ [x])"
                "{x} \<union> set xs = set (ys @ [y])"
                "distinct (x # xs)" "distinct (ys @ [y])"
  hence "x = y \<or> y \<in> set xs"
    using assms by auto
  moreover {
    assume "x = y"
    hence "\<exists>prefix suffix. ys @ [y] = prefix @ x # suffix \<and> concurrent_set x suffix"
      by force
  }
  moreover {
    assume y_in_xs: "y \<in> set xs"
    hence "{x} \<union> (set xs - {y}) = set ys"
      using assms by (auto intro: set_equality_technical)
    hence remove_y_in_xs: "{x} \<union> set (remove1 y xs) = set ys"
      using assms by auto
    moreover have "hb_consistent ((remove1 y xs) @ [x])"
      using assms hb_consistent_remove1 by force        
    moreover have "distinct (x # (remove1 y xs))"
      using assms by simp
    moreover have "distinct ys"
      using assms by simp
    ultimately obtain prefix suffix where ys_split: "ys = prefix @ x # suffix \<and> concurrent_set x suffix"
      using IH by force
    moreover {
      have "concurrent x y"
        using assms y_in_xs remove_y_in_xs concurrent_def by blast
      hence "concurrent_set x (suffix@[y])"
        using ys_split by clarsimp
    }
    ultimately have "\<exists>prefix suffix. ys @ [y] = prefix @ x # suffix \<and> concurrent_set x suffix"
      by force
  }
  ultimately show "\<exists>prefix suffix. ys @ [y] = prefix @ x # suffix \<and> concurrent_set x suffix"
    by auto
qed

lemma hb_consistent_append [intro!]:
  assumes "hb_consistent suffix"
          "hb_consistent prefix"
          "\<And>s p. s \<in> set suffix \<Longrightarrow> p \<in> set prefix \<Longrightarrow> \<not> s \<prec> p"
  shows "hb_consistent (prefix @ suffix)"
using assms by (induction rule: hb_consistent.induct) force+

lemma hb_consistent_append_porder:
  assumes "hb_consistent (xs @ ys)"
          "x \<in> set xs"
          "y \<in> set ys"
  shows   "\<not> y \<prec> x"
using assms by (induction ys arbitrary: xs rule: rev_induct) force+

(*************************************************************************)
subsection\<open>Apply operations\<close>
(*************************************************************************)

text\<open>We can now define a function \isa{apply-operations} that composes an arbitrary list of operations
     into a state transformer. We first map \isa{interp} across the list to obtain a state transformer
     for each operation, and then collectively compose them using the Kleisli arrow composition combinator.\<close>
  
definition apply_operations :: "'a list \<Rightarrow> 'b \<rightharpoonup> 'b" where
  "apply_operations es \<equiv> foldl (\<rhd>) Some (map interp es)"

lemma apply_operations_empty [simp]: "apply_operations [] s = Some s"
  by(auto simp: apply_operations_def)

lemma apply_operations_Snoc [simp]:
  "apply_operations (xs@[x]) = (apply_operations xs) \<rhd> \<langle>x\<rangle>"
  by(auto simp add: apply_operations_def kleisli_def)

(*************************************************************************)
subsection\<open>Concurrent operations commute\<close>
(*************************************************************************)

text\<open>We say that two operations $\isa{x}$ and $\isa{y}$ \emph{commute} whenever
     $\langle\isa{x}\rangle \mathbin{\isasymrhd} \langle\isa{y}\rangle = \langle\isa{y}\rangle \mathbin{\isasymrhd} \langle\isa{x}\rangle$,
     i.e. when we can swap the order of the composition of their interpretations without changing
     the resulting state transformer. For our purposes, requiring that this property holds for
     \emph{all} pairs of operations is too strong. Rather, the commutation property is only required
     to hold for operations that are concurrent.\<close>
  
definition concurrent_ops_commute :: "'a list \<Rightarrow> bool" where
  "concurrent_ops_commute xs \<equiv>
    \<forall>x y. {x, y} \<subseteq> set xs \<longrightarrow> concurrent x y \<longrightarrow> \<langle>x\<rangle>\<rhd>\<langle>y\<rangle> = \<langle>y\<rangle>\<rhd>\<langle>x\<rangle>"

lemma concurrent_ops_commute_empty [intro!]: "concurrent_ops_commute []"
  by(auto simp: concurrent_ops_commute_def)

lemma concurrent_ops_commute_singleton [intro!]: "concurrent_ops_commute [x]"
  by(auto simp: concurrent_ops_commute_def)

lemma concurrent_ops_commute_appendD [dest]:
  assumes "concurrent_ops_commute (xs@ys)"
    shows "concurrent_ops_commute xs"
using assms by (auto simp: concurrent_ops_commute_def)

lemma concurrent_ops_commute_rearrange:
  "concurrent_ops_commute (xs@x#ys) = concurrent_ops_commute (xs@ys@[x])"
  by (clarsimp simp: concurrent_ops_commute_def)

lemma concurrent_ops_commute_concurrent_set:
  assumes "concurrent_ops_commute (prefix@suffix@[x])"
          "concurrent_set x suffix"
          "distinct (prefix @ x # suffix)"
  shows   "apply_operations (prefix @ suffix @ [x]) = apply_operations (prefix @ x # suffix)"
using assms proof(induction suffix arbitrary: rule: rev_induct, force)
  fix a xs
  assume IH: "concurrent_ops_commute (prefix @ xs @ [x]) \<Longrightarrow>
              concurrent_set x xs \<Longrightarrow> distinct (prefix @ x # xs) \<Longrightarrow> 
              apply_operations (prefix @ xs @ [x]) = apply_operations (prefix @ x # xs)"
  assume assms: "concurrent_ops_commute (prefix @ (xs @ [a]) @ [x])"
                "concurrent_set x (xs @ [a])" "distinct (prefix @ x # xs @ [a])"
  hence ac_comm: "\<langle>a\<rangle> \<rhd> \<langle>x\<rangle> = \<langle>x\<rangle> \<rhd> \<langle>a\<rangle>"
    by (clarsimp simp: concurrent_ops_commute_def) blast
  have copc: "concurrent_ops_commute (prefix @ xs @ [x])"
    using assms by (clarsimp simp: concurrent_ops_commute_def) blast
  have "apply_operations ((prefix @ x # xs) @ [a]) = (apply_operations (prefix @ x # xs)) \<rhd> \<langle>a\<rangle>"
    by (simp del: append_assoc)
  also have "... = (apply_operations (prefix @ xs @ [x])) \<rhd> \<langle>a\<rangle>"
    using IH assms copc by auto
  also have "... = ((apply_operations (prefix @ xs)) \<rhd> \<langle>x\<rangle>) \<rhd> \<langle>a\<rangle>"
    by (simp add: append_assoc[symmetric] del: append_assoc)
  also have "... = (apply_operations (prefix @ xs)) \<rhd> (\<langle>a\<rangle> \<rhd> \<langle>x\<rangle>)"
    using ac_comm kleisli_comm_cong kleisli_assoc by simp
  finally show "apply_operations (prefix @ (xs @ [a]) @ [x]) = apply_operations (prefix @ x # xs @ [a])"
    by (metis Cons_eq_appendI append_assoc apply_operations_Snoc kleisli_assoc)
qed

(*************************************************************************)
subsection\<open>Abstract convergence theorem\<close>
(*************************************************************************)
  
text\<open>We can now state and prove our main theorem, $\isa{convergence}$.
     This theorem states that two hb-consistent lists of distinct operations, which are permutations
     of each other and in which concurrent operations commute, have the same interpretation.\<close>
  
theorem  convergence:
  assumes "set xs = set ys"
          "concurrent_ops_commute xs"
          "concurrent_ops_commute ys"
          "distinct xs"
          "distinct ys"
          "hb_consistent xs"
          "hb_consistent ys"
  shows   "apply_operations xs = apply_operations ys"
using assms proof(induction xs arbitrary: ys rule: rev_induct, simp)
  case assms: (snoc x xs)
  then obtain prefix suffix where ys_split: "ys = prefix @ x # suffix \<and> concurrent_set x suffix"
    using hb_consistent_prefix_suffix_exists by fastforce
  moreover hence *: "distinct (prefix @ suffix)" "hb_consistent xs"
    using assms by auto
  moreover {
    have "hb_consistent prefix" "hb_consistent suffix"
      using ys_split assms hb_consistent_append_D2 hb_consistent_append_elim_ConsD by blast+
    hence "hb_consistent (prefix @ suffix)"
      by (metis assms(8) hb_consistent_append hb_consistent_append_porder list.set_intros(2) ys_split)
  }
  moreover have **: "concurrent_ops_commute (prefix @ suffix @ [x])"
    using assms ys_split by (clarsimp simp: concurrent_ops_commute_def)
  moreover hence "concurrent_ops_commute (prefix @ suffix)"
    by (force simp del: append_assoc simp add: append_assoc[symmetric])
  ultimately have "apply_operations xs = apply_operations (prefix@suffix)"
    using assms by simp (metis Diff_insert_absorb Un_iff * concurrent_ops_commute_appendD set_append)
  moreover have "apply_operations (prefix@suffix @ [x]) = apply_operations (prefix@x # suffix)"
    using ys_split assms ** concurrent_ops_commute_concurrent_set by force
  ultimately show ?case
    using ys_split by (force simp: append_assoc[symmetric] simp del: append_assoc)
qed

corollary convergence_ext:
  assumes "set xs = set ys"
          "concurrent_ops_commute xs"
          "concurrent_ops_commute ys"
          "distinct xs"
          "distinct ys"
          "hb_consistent xs"
          "hb_consistent ys"
  shows   "apply_operations xs s = apply_operations ys s"
  using convergence assms by metis
end

subsection\<open>Convergence and progress\<close>
  
text\<open>Besides convergence, another required property of SEC is \emph{progress}: if a valid operation
     was issued on one node, then applying that operation on other nodes must also succeed---that is,
     the execution must not become stuck in an error state.
     Although the type signature of the interpretation function allows operations to fail, we need to
     prove that in all $\isa{hb-consistent}$ network behaviours such failure never actually occurs.
     We capture the combined requirements in the $\isa{strong-eventual-consistency}$ locale,
     which extends $\isa{happens-before}$.\<close>

locale strong_eventual_consistency = happens_before +
  fixes op_history :: "'a list \<Rightarrow> bool"
    and initial_state :: "'b"
  assumes causality:     "op_history xs \<Longrightarrow> hb_consistent xs"
  assumes distinctness:  "op_history xs \<Longrightarrow> distinct xs"
  assumes commutativity: "op_history xs \<Longrightarrow> concurrent_ops_commute xs"
  assumes no_failure:    "op_history(xs@[x]) \<Longrightarrow> apply_operations xs initial_state = Some state \<Longrightarrow> \<langle>x\<rangle> state \<noteq> None"
  assumes trunc_history: "op_history(xs@[x]) \<Longrightarrow> op_history xs"
begin

theorem sec_convergence:
  assumes "set xs = set ys"
          "op_history xs"
          "op_history ys"
  shows   "apply_operations xs = apply_operations ys"
  by (meson assms convergence causality commutativity distinctness)

theorem sec_progress:
  assumes "op_history xs"
  shows   "apply_operations xs initial_state \<noteq> None"
using assms proof(induction xs rule: rev_induct, simp)
  case (snoc x xs)
  have "apply_operations xs initial_state \<noteq> None"
    using snoc.IH snoc.prems trunc_history kleisli_def bind_def by blast
  moreover have "apply_operations (xs @ [x]) = apply_operations xs \<rhd> \<langle>x\<rangle>"
    by simp
  ultimately show ?case
    using no_failure snoc.prems by (clarsimp simp add: kleisli_def split: bind_splits)
qed


end
end
