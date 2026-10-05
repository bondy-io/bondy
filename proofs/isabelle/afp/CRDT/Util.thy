(* Victor B. F. Gomes, University of Cambridge
   Martin Kleppmann, University of Cambridge
   Dominic P. Mulligan, University of Cambridge
   Alastair R. Beresford, University of Cambridge
*)

section\<open>Technical Lemmas\<close>

text\<open>This section contains a list of helper definitions and lemmas about sets, lists and
     the option monad.\<close>

theory
  Util
imports
  Main
  "HOL-Library.Monad_Syntax"
begin

subsection\<open>Kleisli arrow composition\<close>

definition kleisli :: "('b \<Rightarrow> 'b option) \<Rightarrow> ('b \<Rightarrow> 'b option) \<Rightarrow> ('b \<Rightarrow> 'b option)" (infixr \<open>\<rhd>\<close> 65) where
  "f \<rhd> g \<equiv> \<lambda>x. (f x \<bind> (\<lambda>y. g y))"

lemma kleisli_comm_cong:
  assumes "x \<rhd> y = y \<rhd> x"
  shows   "z \<rhd> x \<rhd> y = z \<rhd> y \<rhd> x"
  using assms by(clarsimp simp add: kleisli_def)

lemma kleisli_assoc:
  shows "(z \<rhd> x) \<rhd> y = z \<rhd> (x \<rhd> y)"
  by(auto simp add: kleisli_def)

subsection\<open>Lemmas about sets\<close>

lemma distinct_set_notin [dest]:
  assumes "distinct (x#xs)"
  shows   "x \<notin> set xs"
  using assms by(induction xs, auto)

lemma set_membership_equality_technicalD [dest]:
  assumes "{x} \<union> (set xs) = {y} \<union> (set ys)"
  shows "x = y \<or> y \<in> set xs"
  using assms by(induction xs, auto)

lemma set_equality_technical:
  assumes "{x} \<union> (set xs) = {y} \<union> (set ys)"
      and "x \<notin> set xs"
      and "y \<notin> set ys"
      and "y \<in> set xs"
    shows "{x} \<union> (set xs - {y}) = set ys"
  using assms by (induction xs) auto
    
lemma set_elem_nth:
  assumes "x \<in> set xs"
  shows   "\<exists>m. m < length xs \<and> xs ! m = x"
  using assms by(induction xs, simp) (meson in_set_conv_nth)
    
subsection\<open>Lemmas about list\<close>

lemma list_nil_or_snoc:
  shows "xs = [] \<or> (\<exists>y ys. xs = ys@[y])"
  by (induction xs, auto)

lemma suffix_eq_distinct_list:
  assumes "distinct xs"
      and "ys@suf1 = xs"
      and "ys@suf2 = xs"
    shows "suf1 = suf2"
  using assms by(induction xs arbitrary: suf1 suf2 rule: rev_induct, simp) (metis append_eq_append_conv)

lemma pre_suf_eq_distinct_list:
  assumes "distinct xs"
      and "ys \<noteq> []"
      and "pre1@ys@suf1 = xs"
      and "pre2@ys@suf2 = xs"
    shows "pre1 = pre2 \<and> suf1 = suf2"
using assms
  apply(induction xs arbitrary: pre1 pre2 ys, simp)
  apply(case_tac "pre1"; case_tac "pre2"; clarify)
   apply(metis suffix_eq_distinct_list append_Nil)
  apply(metis Un_iff append_eq_Cons_conv distinct.simps(2) list.set_intros(1) set_append suffix_eq_distinct_list)
  apply(metis Un_iff append_eq_Cons_conv distinct.simps(2) list.set_intros(1) set_append suffix_eq_distinct_list)
  apply(metis distinct.simps(2) hd_append2 list.sel(1) list.sel(3) list.simps(3) tl_append2)
  done

lemma list_head_unaffected:
  assumes "hd (x @ [y, z]) = v"
    shows "hd (x @ [y   ]) = v"
  using assms by (metis hd_append list.sel(1))

lemma list_head_butlast:
  assumes "hd xs = v"
  and "length xs > 1"
  shows "hd (butlast xs) = v"
  using assms by (metis hd_conv_nth length_butlast length_greater_0_conv less_trans nth_butlast zero_less_diff zero_less_one)

lemma list_head_length_one:
  assumes "hd xs = x"
    and "length xs = 1"
  shows "xs = [x]"
  using assms by(metis One_nat_def Suc_length_conv hd_Cons_tl length_0_conv list.sel(3))

lemma list_two_at_end:
  assumes "length xs > 1"
  shows "\<exists>xs' x y. xs = xs' @ [x, y]"
  using assms
  apply(induction xs rule: rev_induct, simp)
  apply(case_tac "length xs = 1", simp)
   apply(metis append_self_conv2 length_0_conv length_Suc_conv)
  apply(rule_tac x="butlast xs" in exI, rule_tac x="last xs" in exI, simp)
  done

lemma list_nth_split_technical:
  assumes "m < length cs"
      and "cs \<noteq> []"
    shows "\<exists>xs ys. cs = xs@(cs!m)#ys"
  using assms
  apply(induction m arbitrary: cs)
   apply(meson in_set_conv_decomp nth_mem)
  apply(metis in_set_conv_decomp length_list_update set_swap set_update_memI)
  done

lemma list_nth_split:
  assumes "m < length cs"
      and "n < m"
      and "1 < length cs"
    shows "\<exists>xs ys zs. cs = xs@(cs!n)#ys@(cs!m)#zs"
using assms proof(induction n arbitrary: cs m)
  case 0 thus ?case
    apply(case_tac cs; clarsimp)
    apply(rule_tac x="[]" in exI, clarsimp)
    apply(rule list_nth_split_technical, simp, force)
    done
next
  case (Suc n)
  thus ?case
  proof (cases cs)
    case Nil
    then show ?thesis
      using Suc.prems by auto
  next
    case (Cons a as)
    hence "m-1 < length as" "n < m-1"
      using Suc by force+
    then obtain xs ys zs where "as = xs @ as ! n # ys @ as ! (m-1) # zs"
      using Suc by force
    thus ?thesis
      apply(rule_tac x="a#xs" in exI) 
      using Suc Cons apply force
      done
   qed
qed

lemma list_split_two_elems:
  assumes "distinct cs"
      and "x \<in> set cs"
      and "y \<in> set cs"
      and "x \<noteq> y"
    shows "\<exists>pre mid suf. cs = pre @ x # mid @ y # suf \<or> cs = pre @ y # mid @ x # suf"
proof -
  obtain xi yi where *: "xi < length cs \<and> x = cs ! xi" "yi < length cs \<and> y = cs ! yi" "xi \<noteq> yi"
    using set_elem_nth linorder_neqE_nat assms by metis
  thus ?thesis
    by (metis list_nth_split One_nat_def less_Suc_eq linorder_neqE_nat not_less_zero)
qed

lemma split_list_unique_prefix:
  assumes "x \<in> set xs"
  shows "\<exists>pre suf. xs = pre @ x # suf \<and> (\<forall>y \<in> set pre. x \<noteq> y)"
using assms proof(induction xs)
  case Nil thus ?case by clarsimp
next
  case (Cons y ys)
  then show ?case
    proof (cases "y=x")
      case True
      then show ?thesis by force
    next
      case False
      then obtain pre suf where "ys = pre @ x # suf \<and> (\<forall>y\<in>set pre. x \<noteq> y)"
        using assms Cons by auto
      thus ?thesis
        using split_list_first by force
    qed
qed

lemma map_filter_append:
  shows "List.map_filter P (xs @ ys) = List.map_filter P xs @ List.map_filter P ys"
  by(auto simp add: List.map_filter_def)

end
