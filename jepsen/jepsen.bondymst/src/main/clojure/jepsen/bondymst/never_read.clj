;;
;; SPDX-FileCopyrightText: 2023 - 2026 Leapsight
;; SPDX-License-Identifier: Apache-2.0
;;
;; Triage helper for `checker/set-full`'s `:never-read` bucket.
;;
;; A `valid? true` result from the set-full checker still reports a
;; `:never-read` count for every value that was acked (`:type :ok` add)
;; but absent from the final reads. Two underlying causes are conflated:
;;
;;   - Client-side failure: the `:add` op resolved `:info`/`:fail`
;;     (timeout, node-down) so the substrate never saw the request.
;;     Benign.
;;   - Ack-but-never-converged: the `:add` op resolved `:ok` on some
;;     node, but the value never reached the projections sampled by the
;;     final reads. Substrate-side sync gap.
;;
;; Usage from the jepsen.bondymst project root:
;;
;;   lein run -m jepsen.bondymst.never-read \
;;     /path/to/store/.../history.edn
;;
;; Prints a per-category summary and a sample of ack-but-never-read
;; values with their per-node ack time, so the substrate-side cases
;; are immediately visible.
;;

(ns jepsen.bondymst.never-read
  (:gen-class)
  (:require [clojure.edn :as edn]
            [clojure.set :as set]
            [clojure.pprint :refer [pprint]]))

;; -----------------------------------------------------------------------
;; History loading
;; -----------------------------------------------------------------------

(defn- load-history
  "Reads an EDN history file produced by Jepsen. Accepts both the
   serialised vector form (`[{...} {...}]`) and the streaming form
   (one map per line) — sniffs the first non-blank char."
  [path]
  (let [t (clojure.string/triml (slurp path))]
    (if (.startsWith t "[")
      (edn/read-string t)
      (->> (clojure.string/split-lines t)
           (remove clojure.string/blank?)
           (mapv edn/read-string)))))

;; -----------------------------------------------------------------------
;; Categorisation
;; -----------------------------------------------------------------------

(defn- read-ops [history]
  (filter #(= :read (:f %)) history))

(defn- ack-time-by-value
  "For each value that appeared in an `:ok :add`, the (process, time,
   error-tagged node string) of its ack."
  [history]
  (reduce
    (fn [acc op]
      (if (and (= :add (:f op))
               (= :ok  (:type op))
               (some? (:value op)))
        (update acc (:value op) (fnil conj [])
                {:time (:time op) :process (:process op)
                 :node (:error op)})
        acc))
    {}
    history))

(defn- terminal-add-status
  "Most relevant final status for each added value: :ok > :info > :fail.
   Multiple submits of the same value get the strongest outcome."
  [history]
  (let [rank {:ok 3 :info 2 :fail 1 :invoke 0}]
    (reduce
      (fn [acc op]
        (if (and (= :add (:f op)) (some? (:value op)))
          (let [v (:value op) t (:type op)]
            (update acc v (fn [old]
                            (if (or (nil? old) (> (rank t 0) (rank old 0)))
                              t
                              old))))
          acc))
      {}
      history)))

(defn- final-read-values
  "Union of values across all `:ok :read` ops in the back third of the
   history — approximates the `final-generator` reads issued post-
   recovery without a dedicated marker."
  [history]
  (let [reads (->> history
                   read-ops
                   (filter #(= :ok (:type %))))]
    (if (empty? reads)
      #{}
      (let [n (count reads)
            tail-count (max 1 (int (* 1/3 n)))
            tail (->> reads (drop (- n tail-count)))]
        (reduce
          (fn [acc op] (into acc (:value op)))
          #{}
          tail)))))

(defn classify
  "Returns a map describing each unique :add value's lifecycle.

   Keys:
     :acked              count of values that resolved :ok
     :info               count of values that resolved :info (timeout/down)
     :failed             count of values that resolved :fail
     :stable             #{values} present in the final reads (any type)
     :ack-but-not-read   #{values} acked :ok but absent from final reads
     :info-but-read      #{values} client got :info but value made it
     :never-acked-never-read  #{values} :info/:fail and absent from finals"
  [history]
  (let [status     (terminal-add-status history)
        ack-times  (ack-time-by-value history)
        all-values (->> status keys (filter some?) set)
        finals     (final-read-values history)
        acked     (set (for [[v s] status :when (= :ok s)] v))
        info-set  (set (for [[v s] status :when (= :info s)] v))
        fail-set  (set (for [[v s] status :when (= :fail s)] v))]
    {:total-distinct        (count all-values)
     :acked                 (count acked)
     :info                  (count info-set)
     :failed                (count fail-set)
     :stable-distinct       (count (set/intersection acked finals))
     :ack-but-not-read      (sort (set/difference acked finals))
     :info-but-read         (sort (set/intersection info-set finals))
     :never-acked-never-read (sort (set/difference
                                     (set/union info-set fail-set)
                                     finals))
     :ack-times             ack-times}))

;; -----------------------------------------------------------------------
;; Report
;; -----------------------------------------------------------------------

(defn- summarise [c]
  (let [ack-times (:ack-times c)
        sample    (->> (:ack-but-not-read c) (take 10) vec)
        sample-detail (mapv (fn [v]
                              {:value v
                               :acked-at (get ack-times v)})
                            sample)]
    {:totals {:distinct-values     (:total-distinct c)
              :ok-adds             (:acked c)
              :info-adds           (:info c)
              :fail-adds           (:failed c)
              :stable              (:stable-distinct c)
              :ack-but-never-read  (count (:ack-but-not-read c))
              :info-but-read       (count (:info-but-read c))
              :never-acked-or-read (count (:never-acked-never-read c))}
     :diagnosis
     (cond
       (pos? (count (:ack-but-not-read c)))
       (str "SUBSTRATE GAP: " (count (:ack-but-not-read c))
            " value(s) acked :ok but missing from final reads. "
            "Either sync lag (recovery sleep too short) or a real "
            "convergence bug.")

       (pos? (count (:info-but-read c)))
       (str "BENIGN NEVER-READ: " (count (:info-but-read c))
            " value(s) client got :info for but substrate persisted; "
            "the rest of `never-read` is genuine client-side failure.")

       :else
       "Clean: no acked values missing, no recovered :info values.")
     :ack-but-never-read-sample sample-detail}))

(defn -main [& [path & _]]
  (when-not path
    (binding [*out* *err*]
      (println "usage: lein run -m jepsen.bondymst.never-read <history.edn>"))
    (System/exit 2))
  (let [history (load-history path)
        result  (-> history classify summarise)]
    (pprint result)))
