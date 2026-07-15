;;
;; SPDX-FileCopyrightText: 2023 - 2026 Leapsight
;; SPDX-License-Identifier: Apache-2.0
;;
;; Jepsen test entrypoint for bondy_mst. Modelled on
;; jepsen.rakvstore: a `db/DB` lifecycle that installs the Erlang
;; release on each node, renders sys.config + vm.args with the
;; cluster's peer list, boots the node, and tears down at the end;
;; an HTTP client (delegates to io.leapsight.jepsen.Utils); and the
;; standard suite of partition / kill nemeses.
;;
;; Workloads:
;;   - `register`  LWW register + CAS — a timeline stress/shape probe.
;;   - `set`       set-convergence: add-only under nemesis, `set-full`
;;                 asserts every acked add reaches every replica. The
;;                 CRDT under test is chosen with `--crdt-module`
;;                 (aw_set | rw_set | two_p_set | g_set).
;;   - `counter`   pn_counter convergence: increments + reads under
;;                 nemesis, `checker/counter` asserts the bounds and the
;;                 healed total. Use `--crdt-module pn_counter`.
;;

(ns jepsen.bondymst
  (:require [clojure.tools.logging :refer :all]
            [slingshot.slingshot :refer [try+]]
            [jepsen [cli :as cli]
                    [checker :as checker]
                    [control :as c]
                    [db :as db]
                    [client :as client]
                    [nemesis :as nemesis]
                    [independent :as independent]
                    [generator :as gen]
                    [util :as util]
                    [tests :as tests]]
            [jepsen.checker.timeline :as timeline]
            [jepsen.control.util :as cu]
            [jepsen.history :as h]
            [jepsen.os.debian :as debian]))

;; -----------------------------------------------------------------------
;; Operation constructors
;; -----------------------------------------------------------------------

(defn r   [_ _] {:type :invoke, :f :read, :value nil})
(defn w   [_ _] {:type :invoke, :f :write, :value (rand-int 5)})
(defn cas [_ _] {:type :invoke, :f :cas, :value [(rand-int 5) (rand-int 5)]})

;; Set workload op constructors. `:add` writes an integer; `:read`
;; returns the full set so `checker/set-full` can compare add-history
;; vs final-state. The underlying CRDT (aw_set / rw_set / two_p_set /
;; g_set) is selected per run via `--crdt-module`; this add-only
;; workload checks that *every* acked add converges on *every* replica
;; under nemesis — the convergence property all of them share. The
;; add-wins vs remove-wins *conflict* semantics are pinned exhaustively
;; by the per-type PropEr suites in the lib, not re-derived here.
(defn add-op  [_ _] {:type :invoke, :f :add,  :value (rand-int 10000)})
(defn read-op [_ _] {:type :invoke, :f :read, :value nil})

;; Counter workload op constructors. `:add` increments by a small
;; positive delta; `:read` returns the counter value. Convergence (not
;; real-time linearizability) is what a CRDT pn_counter promises, so the
;; verdict is decided by the post-heal `:final?` reads — see
;; `counter-convergence-checker`. Mid-run reads may be stale under
;; partition and are not failures.
(defn counter-add-op   [_ _] {:type :invoke, :f :add,  :value (inc (rand-int 5))})
(defn counter-read-op  [_ _] {:type :invoke, :f :read, :value nil})
(defn counter-final-op [_ _] {:type :invoke, :f :read, :value nil, :final? true})

(defn parse-long-nil
  "Parse a string to a Long; pass through `nil`."
  [s]
  (when s (parse-long s)))

;; -----------------------------------------------------------------------
;; Client
;; -----------------------------------------------------------------------

(defn- parse-set
  "Parse the space-separated set body returned by GET /sets/...  into a
   sorted set of Longs. Empty body → empty set."
  [body]
  (if (or (nil? body) (= "" body))
    #{}
    (->> (clojure.string/split body #"\s+")
         (remove empty?)
         (map parse-long)
         (into (sorted-set)))))

(defrecord Client [conn]
  client/Client
  (open! [this _test node]
    (assoc this :conn (io.leapsight.jepsen.Utils/createClient node)))

  (setup! [_ _test])

  (invoke! [_ _test op]
    (try+
      (case (:f op)
        ;; --- LWW register workload (paired with `independent`) ---
        :read  (let [[k _] (:value op)]
                 (if (number? k)
                   (assoc op
                          :type :ok,
                          :value (independent/tuple
                                  k
                                  (parse-long-nil
                                   (io.leapsight.jepsen.Utils/get conn k))))
                   ;; OR-set read (single-key workload, no independent
                   ;; wrapping). `:value` is `nil` on invoke; on :ok it
                   ;; becomes the full set as a sorted-set of Longs so
                   ;; `checker/set-full` can compare with the ack-history.
                   (assoc op
                          :type :ok,
                          :value (parse-set
                                  (io.leapsight.jepsen.Utils/setRead
                                   conn 0)))))
        :write (let [[k v] (:value op)
                     result (io.leapsight.jepsen.Utils/write conn k v)]
                 (assoc op
                        :type :ok
                        :error (str (io.leapsight.jepsen.Utils/node conn)
                                    " "
                                    (.getHeaders result))))
        :cas   (let [[k [old new]] (:value op)
                     result (io.leapsight.jepsen.Utils/cas
                              conn k old new)]
                 (assoc op
                        :type  (if (.isOk result) :ok :fail)
                        :error (str (io.leapsight.jepsen.Utils/node conn)
                                    " "
                                    (.getHeaders result))))

        ;; --- OR-set workload ---
        ;; A single shared key (0) under one table — the OR-set fold
        ;; absorbs every add and converges across nodes via the disterl
        ;; sync. `:value` on invoke is the integer being added; on :ok
        ;; it stays unchanged so the checker can pair the ack with the
        ;; final read.
        :add   (let [v (:value op)
                     result (io.leapsight.jepsen.Utils/setAdd conn 0 v)]
                 (assoc op
                        :type :ok
                        :error (str (io.leapsight.jepsen.Utils/node conn)
                                    " "
                                    (.getHeaders result)))))
      (catch io.leapsight.jepsen.BondyTimeoutException _
        (assoc op :type :info, :error :timeout))
      (catch io.leapsight.jepsen.BondyNodeDownException _
        (assoc op :type :info,
                  :error (str :nodedown " "
                              (io.leapsight.jepsen.Utils/node conn))))
      (catch java.lang.Exception _
        (assoc op
               :type  (if (= :read (:f op)) :fail :info)
               :error :exception))))

  (teardown! [_ _test])

  (close! [_ _test]))

;; A dedicated client for the counter workload. Keeps `:add`/`:read`
;; semantics distinct from the set/register `Client` (jepsen's
;; `checker/counter` requires exactly those op `:f` values, which would
;; otherwise collide with the set workload's add/read).
(defrecord CounterClient [conn]
  client/Client
  (open! [this _test node]
    (assoc this :conn (io.leapsight.jepsen.Utils/createClient node)))

  (setup! [_ _test])

  (invoke! [_ _test op]
    (try+
      (case (:f op)
        ;; Increment the single shared counter (key 0) by :value.
        :add  (let [_ (io.leapsight.jepsen.Utils/counterAdd conn 0 (:value op))]
                (assoc op :type :ok))
        ;; Read the counter value back as a Long.
        :read (assoc op
                     :type :ok
                     :value (parse-long
                             (io.leapsight.jepsen.Utils/counterRead conn 0))))
      (catch io.leapsight.jepsen.BondyTimeoutException _
        (assoc op :type :info, :error :timeout))
      (catch io.leapsight.jepsen.BondyNodeDownException _
        (assoc op :type :info,
                  :error (str :nodedown " "
                              (io.leapsight.jepsen.Utils/node conn))))
      (catch java.lang.Exception _
        (assoc op
               :type  (if (= :read (:f op)) :fail :info)
               :error :exception))))

  (teardown! [_ _test])

  (close! [_ _test]))

;; -----------------------------------------------------------------------
;; DB lifecycle
;; -----------------------------------------------------------------------

(def dir "/opt/bondy_mst_jepsen")
(def log-dir "/opt/bondy_mst_jepsen/log")
(def configuration-file
  "/opt/bondy_mst_jepsen/releases/0.4.0/sys.config")
(def vm-args-file
  "/opt/bondy_mst_jepsen/releases/0.4.0/vm.args")
(def env-variables
  "ERL_CRASH_DUMP=/opt/bondy_mst_jepsen/log/erl_crash.dump")
(def binary
  "/opt/bondy_mst_jepsen/bin/bondy_mst_jepsen_release")

(defn db
  "Install + boot the bondy_mst_jepsen release on each Jepsen node."
  []
  (reify db/DB
    (setup! [_ test node]
      (info node "installing bondy_mst")
      (c/su
        (c/exec :rm :-rf "/var/lib/bondy_mst_jepsen")
        (c/exec :rm :-rf dir)
        (c/exec :mkdir :-p log-dir)
        (cu/install-archive! (str (:erlang-distribution-url test)) dir)
        (let [configuration
              (io.leapsight.jepsen.Utils/configuration test node)]
          (c/exec :echo configuration :| :tee configuration-file))
        (let [vm-args (io.leapsight.jepsen.Utils/vmArgs node)]
          (c/exec :echo vm-args :| :tee vm-args-file))
        (c/exec* "chmod u+x /opt/bondy_mst_jepsen/erts*/bin/*")
        (info node "starting bondy_mst" binary)
        (c/exec* env-variables binary "daemon")
        (Thread/sleep 5000)))

    (teardown! [_ _test node]
      (info node "tearing down bondy_mst")
      (c/su
        (c/exec :mkdir :-p log-dir)
        (if (not= "" (try
                       (c/exec :pgrep :beam)
                       (catch RuntimeException _ "")))
          (do
            ;; PR-J4 audit: dump WAL + MST state to a per-node ETF
            ;; under log-dir BEFORE stopping the daemon so the on-disk
            ;; state at heal-time is captured. `release eval` returns
            ;; the result printed; failures here are non-fatal (don't
            ;; block the teardown).
            (try
              (c/exec* env-variables binary "eval"
                       "'bondy_mst_jepsen_audit:dump_all().'")
              (info node "audit dump_all completed")
              (catch Exception e
                (info node "audit dump_all failed:" (.getMessage e))))
            (c/exec* env-variables binary "stop"))
          (info node "bondy_mst already stopped"))))

    db/LogFiles
    (log-files [_ _test _node]
      (c/su
        (c/exec* (str "chmod o+r " log-dir "/*")))
      (->> (jepsen.control.util/ls log-dir)
           (map #(str log-dir "/" %))))))

;; -----------------------------------------------------------------------
;; Workloads
;; -----------------------------------------------------------------------

(defn set-workload
  "OR-set workload: adds integers to a single shared set, then on the
   final-generator phase reads from every worker (and therefore every
   node) and feeds the ack-history + final-state union into
   `checker/set-full`.

   Convergence semantics: an OR-set is a CRDT — any acknowledged add
   from any replica should be present in *every* replica's eventual
   read once the cluster heals. `set-full` checks exactly that.

   `gen/each-thread` produces one final read per worker — with 10
   workers round-robinned over 3 nodes that's ≥3 reads per node, so
   the checker sees the union of every replica's view."
  [opts]
  {:client          (Client. nil)
   :checker         (checker/set-full {:linearizable? false})
   :generator       (->> (gen/mix [add-op])
                         (gen/stagger (/ (:rate opts))))
   :final-generator (gen/each-thread (gen/once read-op))})

(defn counter-convergence-checker
  "Convergence checker for a CRDT pn_counter.

   jepsen's stock `checker/counter` models a *linearizable* counter: each
   read must be ≥ the sum of every increment acked (in real time) before
   the read began. A partition-tolerant CRDT cannot promise that — a node
   on one side of a partition simply has not yet observed the other side's
   increments. So stale mid-partition reads are expected, not anomalies.

   This mirrors `set-full`: tolerate the stale window, then assert that
   after the heal every replica's `:final?` read is (a) equal to the
   others (the replicas converged) and (b) within
   [acked-total, attempted-total] — no acked increment lost, none
   fabricated beyond the in-flight (unacked) uncertainty window."
  []
  (reify checker/Checker
    (check [_ _test history _opts]
      (let [ops       (h/client-ops history)
            add?      (fn [t op] (and (= t (:type op)) (= :add (:f op))))
            acked     (->> ops (filter (partial add? :ok))
                           (map :value) (reduce + 0))
            attempted (->> ops (filter (partial add? :invoke))
                           (map :value) (reduce + 0))
            finals    (->> ops
                           (filter #(and (= :ok (:type %))
                                         (= :read (:f %))
                                         (:final? %)))
                           (map :value))
            distinct-finals (vec (distinct finals))
            converged? (<= (count distinct-finals) 1)
            v          (first distinct-finals)
            in-bounds? (boolean (and v (<= acked v attempted)))]
        {:valid?          (and (seq finals) converged? in-bounds?)
         :acked-total     acked
         :attempted-total attempted
         :final-reads     (vec finals)
         :distinct-finals distinct-finals
         :converged-value v
         :converged?      converged?
         :in-bounds?      in-bounds?}))))

(defn counter-workload
  "PN-Counter convergence workload: a single shared counter incremented
   from every node, interleaved with reads, under nemesis. After the
   cluster heals, every worker (hence every node) does a final read and
   `counter-convergence-checker` asserts the replicas converged on one
   value within the acked/attempted increment bounds.

   Provision the run with `--crdt-module pn_counter`."
  [opts]
  {:client          (CounterClient. nil)
   :checker         (counter-convergence-checker)
   :generator       (->> (gen/mix [counter-add-op counter-read-op])
                         (gen/stagger (/ (:rate opts))))
   :final-generator (gen/each-thread (gen/once counter-final-op))})

(defn register-workload
  "Register-shaped workload over independent keys: read, write, CAS.

   The Jepsen `independent` wrapper drives many keys in parallel; the
   Java client deterministically maps each integer key onto one of the
   10 bondy_mst tables, so this single workload also exercises the
   table sharding across the 16 shared leveled shards per node.

   Checker: timeline + per-op stats only. The bondy_mst register fold
   is `lww_register` (LWW by HLC) — a CRDT, not a linearizable
   register. Earlier revisions wired this into
   `checker/linearizable {:model (model/cas-register) :algorithm :linear}`
   but Knossos cannot find a serialisable history through CRDT reads
   and the search cost blows up exponentially (observed 1.36E+20 on a
   30s 10-key run before timing out). The right correctness story for
   this workload is the OR-set `set-full` checker (see
   `set-workload`); this one stays as a stress + shape probe."
  [opts]
  {:client    (Client. nil)
   :checker   (independent/checker
                (checker/compose
                  {:timeline (timeline/html)}))
   :generator (independent/concurrent-generator
                10
                (repeatedly #(rand-int 75))
                (fn [_k]
                  (->> (gen/mix [r w cas])
                       (gen/limit (:ops-per-key opts)))))})

;; -----------------------------------------------------------------------
;; Nemeses
;; -----------------------------------------------------------------------

(defn start-erlang-vm!
  [_test node]
  (c/su
    (if (not= "" (try
                   (c/exec :pgrep :beam)
                   (catch RuntimeException _ "")))
      (info node "bondy_mst already running.")
      (do (info node "Starting bondy_mst...")
          (c/exec* env-variables binary "start")
          (info node "bondy_mst started"))))
  :started)

(defn kill-erlang-vm!
  [_test node]
  (util/meh (c/su (c/exec* "killall -9 beam.smp")))
  (info node "bondy_mst killed.")
  :killed)

(defn kill-erlang-vm-nemesis
  [n]
  (nemesis/node-start-stopper
    (fn [nodes] ((comp (partial take n) shuffle) nodes))
    kill-erlang-vm!
    start-erlang-vm!))

(def nemesises
  {"kill-erlang-vm"            ""
   "random-partition-halves"   ""
   "partition-halves"          ""
   "partition-majorities-ring" ""
   "partition-random-node"     ""
   "combined"                  ""})

(def network-partition-nemesises
  {"random-partition-halves"   ""
   "partition-halves"          ""
   "partition-majorities-ring" ""
   "partition-random-node"     ""})

(defn init-network-partition-nemesis
  [opts]
  (case (:network-partition-nemesis opts)
    "random-partition-halves"   (nemesis/partition-random-halves)
    "partition-halves"          (nemesis/partition-halves)
    "partition-majorities-ring" (nemesis/partition-majorities-ring)
    "partition-random-node"     (nemesis/partition-random-node)))

(defn init-nemesis
  [opts]
  (case (:nemesis opts)
    "kill-erlang-vm"            (kill-erlang-vm-nemesis (:random-nodes opts))
    "random-partition-halves"   (nemesis/partition-random-halves)
    "partition-halves"          (nemesis/partition-halves)
    "partition-majorities-ring" (nemesis/partition-majorities-ring)
    "partition-random-node"     (nemesis/partition-random-node)
    "combined"
    (nemesis/compose
      {{:split-start :start, :split-stop  :stop}
         (init-network-partition-nemesis opts)
       {:kill-erlang-vm-start :start, :kill-erlang-vm-stop :stop}
         (kill-erlang-vm-nemesis (:random-nodes opts))})))

(def workloads
  {"register" register-workload
   "set"      set-workload
   "counter"  counter-workload})

(defn combined-nemesis-generator
  [opts]
  {:generator (cycle [(gen/sleep (:time-before-disruption opts))
                      {:type :info :f :split-start}
                      (gen/stagger (/ (:disruption-duration opts) 8)
                                   (gen/mix
                                     [{:type :info, :f :kill-erlang-vm-start}]))
                      (gen/stagger (/ (:disruption-duration opts) 6)
                                   (gen/phases
                                     {:type :info :f :kill-erlang-vm-stop}))
                      (gen/sleep (:disruption-duration opts))
                      {:type :info :f :split-stop}])
   :stop-generator [(gen/once {:type :info, :f :kill-erlang-vm-stop})
                    (gen/nemesis (gen/once {:type :info, :f :split-stop}))]})

(defn single-nemesis-generator
  [opts]
  {:generator (cycle [(gen/sleep (:time-before-disruption opts))
                      {:type :info :f :start}
                      (gen/sleep (:disruption-duration opts))
                      {:type :info :f :stop}])
   :stop-generator (gen/once {:type :info, :f :stop})})

(def nemesis-generators
  {"combined"                  combined-nemesis-generator
   "kill-erlang-vm"            single-nemesis-generator
   "random-partition-halves"   single-nemesis-generator
   "partition-halves"          single-nemesis-generator
   "partition-majorities-ring" single-nemesis-generator
   "partition-random-node"     single-nemesis-generator})

;; -----------------------------------------------------------------------
;; CLI
;; -----------------------------------------------------------------------

(def cli-opts
  [["-r" "--rate HZ" "Approximate number of requests per second, per thread."
    :default  10
    :parse-fn read-string
    :validate [#(and (number? %) (pos? %)) "Must be a positive number"]]
   [nil "--ops-per-key NUM" "Maximum number of operations on any given key."
    :default  100
    :parse-fn parse-long
    :validate [pos? "Must be a positive integer."]]
   ["-w" "--workload NAME" "What workload should we run?"
    :missing  (str "--workload " (cli/one-of workloads))
    :validate [workloads (cli/one-of workloads)]]
   [nil "--nemesis NAME" "What nemesis should we use?"
    :missing  (str "--nemesis " (cli/one-of nemesises))
    :validate [nemesises (cli/one-of nemesises)]]
   [nil "--network-partition-nemesis NAME" "Partition nemesis for combined."
    :default  "random-partition-halves"
    :validate [network-partition-nemesises (cli/one-of network-partition-nemesises)]]
   [nil "--random-nodes NUM" "Nodes disrupted by kill nemeses."
    :default  1
    :parse-fn parse-long
    :validate [pos? "Must be a positive integer."]]
   [nil "--disruption-duration NUM" "Duration of disruption (seconds)."
    :default  5
    :parse-fn parse-long
    :validate [pos? "Must be a positive integer."]]
   [nil "--time-before-disruption NUM" "Sleep before nemesis fires."
    :default  5
    :parse-fn parse-long
    :validate [pos? "Must be a positive integer."]]
   [nil "--sync-interval-ms NUM" "bondy_mst sync scheduler tick (ms)."
    :default  200
    :parse-fn parse-long
    :validate [pos? "Must be a positive integer."]]
   [nil "--shard-count NUM" "Shards per table."
    :default  16
    :parse-fn parse-long
    :validate [pos? "Must be a positive integer."]]
   [nil "--fold-module NAME" "Fold module (lww_register, strict_register, ...)."
    :default  "lww_register"]
   [nil "--crdt-module NAME" "Native CRDT under test: aw_set, rw_set, two_p_set, g_set, pn_counter. Unset → fold_module drives selection."]
   [nil "--erlang-distribution-url URL" "URL of the Erlang release tarball."
    :default "file:///root/jepsen.bondymst/bondy_mst_jepsen_release-0.4.0.tar.gz"
    :parse-fn read-string]])

(defn bondymst-test
  [opts]
  (let [workload          ((get workloads (:workload opts)) opts)
        nemesis           (init-nemesis opts)
        nemesis-generator ((get nemesis-generators (:nemesis opts)) opts)]
    (merge tests/noop-test
           opts
           {:pure-generators true
            :name (str (name (:workload opts)))
            :os   debian/os
            :db   (db)
            :checker (checker/compose
                       {:perf     (checker/perf)
                        :workload (:checker workload)})
            :client     (:client workload)
            :nemesis    nemesis
            :generator
            (gen/phases
              (->> (:generator workload)
                   (gen/stagger (/ (:rate opts)))
                   (gen/nemesis (:generator nemesis-generator))
                   (gen/time-limit (:time-limit opts)))
              (gen/log "Healing cluster")
              (gen/nemesis (:stop-generator nemesis-generator))
              (gen/log "Waiting for recovery")
              ;; 10s — empirically 50× the sync_interval_ms tick, with
              ;; per-batch convergence under random-partition-halves
              ;; observed in <1s and post-kill-vm restart + first
              ;; sync ack at ~2s. 30s padded sync latency out of the
              ;; reported `stable-latency` — at 10s the metric reflects
              ;; the substrate's true convergence shape. Bump it if a
              ;; checker run flips to `valid? false` for a reason that
              ;; looks like "didn't have time to sync".
              (gen/sleep 10)
              (gen/clients (:final-generator workload)))})))

(defn -main
  [& args]
  (cli/run! (cli/single-test-cmd {:test-fn  bondymst-test
                                  :opt-spec cli-opts})
            args))
