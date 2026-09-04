;;
;; SPDX-FileCopyrightText: 2016 - 2026 Leapsight
;; SPDX-License-Identifier: Apache-2.0
;;
;; Jepsen test entrypoint for the Bondy router. Modelled on jepsen.bondymst:
;; a `db/DB` lifecycle that installs the Bondy release on each node, renders
;; `bondy.conf` + `security_config.json` with the cluster's peer list, boots
;; the node and waits for its readiness probe; an HTTP client over the Admin
;; API (delegates to io.leapsight.jepsen.bondy.Utils); and the standard suite
;; of partition / kill nemeses.
;;
;; Workloads:
;;   - `users`  durable-object convergence: `POST /realms/:r/users` from
;;              every node under nemesis, then after the heal a final
;;              `GET /realms/:r/users` from every worker; `checker/set-full`
;;              asserts every acknowledged add is present in every replica's
;;              final read. Users are session-independent, replicated through
;;              bondy_db -> bondy_oplog -> anti-entropy across Partisan, so
;;              this is the whole durable path under partition and crash,
;;              with Bondy's real add-wins semantics rather than a shim's.
;;
;; What this slice does NOT check: anything session-bound (registrations,
;; subscriptions) — a killed node's sessions die and their registrations must
;; NOT converge, so a set model over them would call correct behaviour a
;; failure. Those need the checkers of the harness design's correctness tier.
;;

(ns jepsen.bondy
  (:require [clojure.tools.logging :refer :all]
            [clojure.string :as str]
            [cheshire.core :as json]
            [slingshot.slingshot :refer [try+]]
            [jepsen [cli :as cli]
                    [checker :as checker]
                    [control :as c]
                    [db :as db]
                    [client :as client]
                    [nemesis :as nemesis]
                    [generator :as gen]
                    [util :as util]
                    [tests :as tests]]
            [jepsen.control.util :as cu]
            [jepsen.history :as h]
            [jepsen.os.debian :as debian])
  (:import [io.leapsight.jepsen.bondy
            Utils
            BondyNodeDownException
            BondyTimeoutException]))

;; -----------------------------------------------------------------------
;; Operation constructors
;; -----------------------------------------------------------------------

;; `:add` carries the integer whose user (`u<int>`) is created; on `:ok` the
;; value stays as-is so `set-full` can pair the ack with the final read.
;; `:read` carries `nil` on invoke and the sorted set of integers on `:ok`.
(defn add-op  [_ _] {:type :invoke, :f :add,  :value (rand-int 100000)})
(defn read-op [_ _] {:type :invoke, :f :read, :value nil})
;; The post-heal reads the verdict is decided on; `:final?` survives into
;; the completion op so `every-replica-checker` can pick them out.
(defn final-read-op [_ _] {:type :invoke, :f :read, :value nil, :final? true})

;; -----------------------------------------------------------------------
;; Users <-> integers
;; -----------------------------------------------------------------------

(defn username
  "The username for an integer. `u` + digits satisfies bondy_rbac_user's
   validator (3..254 bytes, not a reserved name) and casefolds to itself."
  [v]
  (str "u" v))

(defn parse-users
  "The integers behind the usernames in a `GET /realms/:r/users` body.
   Users that are not ours (none are expected: the realm is created empty
   by the security config) are ignored."
  [body]
  (->> (json/parse-string body)
       (keep (fn [user]
               (when-let [[_ digits] (re-matches #"u(\d+)" (get user "username" ""))]
                 (Long/parseLong digits))))
       (into (sorted-set))))

(defn error-code
  "The `code` of an Admin API error body (`bondy.error.*`), or nil."
  [body]
  (try
    (get (json/parse-string body) "code")
    (catch Exception _ nil)))

;; -----------------------------------------------------------------------
;; Client
;; -----------------------------------------------------------------------

;; Status -> Jepsen op type, the correctness-relevant decision:
;;
;;   2xx                          :ok    the user is stored on this node
;;   already_exists               :ok    the element IS in the set (an earlier
;;                                       add of the same integer succeeded, on
;;                                       this or any node) — reporting :fail
;;                                       would tell set-full an element is
;;                                       absent when the read will show it
;;   other 4xx                    :fail  rejected; nothing was written
;;   5xx                          :info  the server may have written it
;;   connection refused           :fail  the request never reached a server
;;   connect / read timeout       :info  indeterminate
;;   any other I/O failure        :info  indeterminate
;;
;; Reads are never :info — a read that did not answer has no value to
;; report and is simply :fail.
(defn add-type [{:keys [status body]}]
  (cond
    (<= 200 status 299)                                  :ok
    (= "bondy.error.already_exists" (error-code body))   :ok
    (<= 400 status 499)                                  :fail
    :else                                                :info))

(defrecord Client [conn realm]
  client/Client
  (open! [this _test node]
    (assoc this :conn (Utils/createClient node)))

  (setup! [_ _test])

  ;; Every completion carries `:node`, the replica this client talks to.
  ;; The checkers group by it; deriving the node from the op's `:process`
  ;; would have to replicate jepsen's process -> thread -> node arithmetic,
  ;; which changes when a process crashes and is re-numbered.
  (invoke! [_ _test op]
    (let [node (Utils/node conn)
          op   (assoc op :node node)]
      (try+
        (case (:f op)
          :add
          (let [v    (:value op)
                r    (Utils/userAdd conn realm (username v))
                type (add-type {:status (.-status r) :body (.-body r)})]
            (cond-> (assoc op :type type)
              (not= :ok type)
              (assoc :error (str node " " (.-status r) " " (.-body r)))))

          :read
          (let [r (Utils/usersRead conn realm)]
            (if (<= 200 (.-status r) 299)
              (assoc op :type :ok, :value (parse-users (.-body r)))
              (assoc op :type :fail,
                        :error (str node " " (.-status r) " " (.-body r))))))
        (catch BondyNodeDownException _
          (assoc op :type :fail, :error (str :nodedown " " node)))
        (catch BondyTimeoutException _
          (assoc op :type (if (= :read (:f op)) :fail :info),
                    :error (str :timeout " " node)))
        (catch java.lang.Exception e
          (assoc op :type (if (= :read (:f op)) :fail :info),
                    :error (str :exception " " node " " (.getMessage e)))))))

  (teardown! [_ _test])

  (close! [_ _test]))

;; -----------------------------------------------------------------------
;; DB lifecycle
;; -----------------------------------------------------------------------

(def dir Utils/INSTALL_DIR)
(def log-dir (str dir "/log"))
(def conf-file (str dir "/etc/bondy.conf"))
(def security-config-file (str dir "/etc/security_config.json"))
(def binary (str dir "/bin/bondy"))

(defn env-variables
  "The environment `bin/bondy` needs: relx expands `${BONDY_ERL_NODENAME}`
   and `${BONDY_ERL_DISTRIBUTED_COOKIE}` in vm.args only when
   RELX_REPLACE_OS_VARS is set (config/prod/vm.args), and wires the
   epmd-less distribution port only when ERL_DIST_PORT is set
   (`Utils/DIST_PORT`)."
  [node]
  (str "RELX_REPLACE_OS_VARS=true"
       " BONDY_ERL_NODENAME=" (Utils/erlangNodeName node)
       " BONDY_ERL_DISTRIBUTED_COOKIE=jepsen"
       " ERL_DIST_PORT=" Utils/DIST_PORT
       " ERL_CRASH_DUMP=" log-dir "/erl_crash.dump"))

;; relx's `daemon` polls the node until it answers a ping and never gives
;; up, so a VM that dies at boot would hang setup (and the kill nemesis's
;; restart) forever. `timeout` turns that into a prompt failure; a healthy
;; `daemon` returns within seconds, well inside the bound.
(def daemon-timeout-s 90)

(defn beam-running? []
  (not= "" (try (c/exec :pgrep :beam)
                (catch RuntimeException _ ""))))

(defn start-bondy!
  "Starts the release daemon unless a beam is already running on the node."
  [node]
  (c/su
    (if (beam-running?)
      (info node "bondy already running")
      (do (info node "starting bondy")
          ;; `env` rather than a bare `VAR=x` prefix: after `timeout` a
          ;; prefix would be taken as the command to run.
          (c/exec* "timeout" daemon-timeout-s "env" (env-variables node) binary "daemon")
          (info node "bondy started")))))

(defn await-ready!
  "Blocks until the node's `/ready` answers 204, i.e. the durable store
   opened and both listener phases are up (bondy_app:is_ready/0), or fails
   after `timeout-s`. A node that boots degraded answers 503 and must fail
   setup rather than take part in a run it cannot serve."
  [node timeout-s]
  (let [client   (Utils/createClient node)
        deadline (+ (System/currentTimeMillis) (* 1000 timeout-s))]
    (loop []
      (let [status (try (.-status (Utils/ready client))
                        (catch Exception _ nil))]
        (cond
          (= 204 status) (info node "ready")
          (> (System/currentTimeMillis) deadline)
          (throw (ex-info "bondy did not become ready"
                          {:node node :last-status status :timeout-s timeout-s}))
          :else (do (Thread/sleep 500) (recur)))))))

(defn db
  "Install + boot the Bondy release on each Jepsen node."
  []
  (reify db/DB
    (setup! [_ test node]
      (info node "installing bondy")
      (c/su
        (c/exec :rm :-rf dir)
        (c/exec :mkdir :-p dir)
        (cu/install-archive! (str (:erlang-distribution-url test)) dir)
        (c/exec :mkdir :-p (str dir "/etc") log-dir)
        (let [conf (Utils/configuration test node)]
          (c/exec :echo conf :| :tee conf-file))
        (let [security (Utils/securityConfig (:realm test))]
          (c/exec :echo security :| :tee security-config-file))
        (c/exec* (str "chmod u+x " dir "/erts*/bin/*")))
      (start-bondy! node)
      (await-ready! node (:ready-timeout test)))

    (teardown! [_ _test node]
      (info node "tearing down bondy")
      (c/su
        (c/exec :mkdir :-p log-dir)
        (if (beam-running?)
          (c/exec* (env-variables node) binary "stop")
          (info node "bondy already stopped"))))

    db/LogFiles
    (log-files [_ _test _node]
      (c/su
        (c/exec* (str "chmod -R o+r " log-dir " || true")))
      (->> (cu/ls log-dir)
           (map #(str log-dir "/" %))))))

;; -----------------------------------------------------------------------
;; Workloads
;; -----------------------------------------------------------------------

(defn every-replica-checker
  "The convergence claim this test makes, checked on every replica.

   `checker/set-full` decides `lost` against ONE read — the most final one —
   so a replica that is permanently missing acknowledged elements is
   reported as merely `stale` whenever the last read happened to land on a
   converged node (observed: n1 missing 1 and n3 missing 5 acknowledged
   users in every one of their final reads, `set-full` green). The property
   is per replica: after the heal and the recovery wait, EVERY final read —
   one per worker, hence several per node — must contain EVERY acknowledged
   add. A final read that failed is not a witness either way; a node with no
   successful final read is reported as such rather than silently passing.

   Acknowledged means `:ok`; `:info` adds (indeterminate) are not required
   to be present, as in `set-full`. The replica a read came from is the
   `:node` the client stamped on it."
  [nodes]
  (reify checker/Checker
    (check [_ _test history _opts]
      (let [ops     (h/client-ops history)
            acked   (->> ops
                         (filter #(and (= :ok (:type %)) (= :add (:f %))))
                         (map :value)
                         (into (sorted-set)))
            finals  (->> ops
                         (filter #(and (= :ok (:type %))
                                       (= :read (:f %))
                                       (:final? %))))
            missing (->> finals
                         (map (fn [op]
                                {:node    (:node op)
                                 :process (:process op)
                                 :missing (into (sorted-set)
                                                (remove (:value op) acked))}))
                         (filter #(seq (:missing %))))
            read-nodes (into (sorted-set) (map :node finals))
            unread     (remove read-nodes nodes)]
        {:valid?          (and (seq finals) (empty? missing) (empty? unread))
         :acked-count     (count acked)
         :final-read-count (count finals)
         :nodes-without-final-read (vec unread)
         :diverged-count  (count missing)
         :diverged        (vec missing)}))))

(defn users-workload
  "Durable-user convergence: adds under nemesis, then one final read per
   worker (10 workers round-robinned over 3 nodes = >= 3 reads per node, so
   the checker sees every replica's view). `set-full` with
   `:linearizable? false`: a read during a partition may legitimately miss
   adds from the other side; what must hold is that after the heal every
   acknowledged add is in every final read."
  [opts]
  {:client          (Client. nil (:realm opts))
   :checker         (checker/compose
                      {:set-full      (checker/set-full {:linearizable? false})
                       :every-replica (every-replica-checker (:nodes opts))})
   :generator       (->> (gen/mix [add-op])
                         (gen/stagger (/ (:rate opts))))
   :final-generator (gen/each-thread (gen/once final-read-op))})

(def workloads
  {"users" users-workload})

;; -----------------------------------------------------------------------
;; Nemeses (as in jepsen.bondymst, plus `none` for smoke runs)
;; -----------------------------------------------------------------------

(defn kill-bondy!
  [_test node]
  (util/meh (c/su (c/exec* "killall -9 beam.smp")))
  (info node "bondy killed")
  :killed)

(defn restart-bondy!
  [_test node]
  (start-bondy! node)
  :started)

(defn kill-erlang-vm-nemesis
  [n]
  (nemesis/node-start-stopper
    (fn [nodes] ((comp (partial take n) shuffle) nodes))
    kill-bondy!
    restart-bondy!))

(def nemesises
  {"none"                      ""
   "kill-erlang-vm"            ""
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
    "none"                      nemesis/noop
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

(defn none-nemesis-generator
  [_opts]
  {:generator      nil
   :stop-generator nil})

(def nemesis-generators
  {"none"                      none-nemesis-generator
   "combined"                  combined-nemesis-generator
   "kill-erlang-vm"            single-nemesis-generator
   "random-partition-halves"   single-nemesis-generator
   "partition-halves"          single-nemesis-generator
   "partition-majorities-ring" single-nemesis-generator
   "partition-random-node"     single-nemesis-generator})

;; -----------------------------------------------------------------------
;; CLI
;; -----------------------------------------------------------------------

(def archive-dir "/root/jepsen.bondy")

(defn default-archive-url
  "The release tarball `just rel-jepsen-bondy` wrote into the project dir,
   which docker compose mounts at the same path on every container. Picked
   up by name so the release version is not hard-coded here."
  []
  (let [files (->> (.listFiles (java.io.File. ^String archive-dir))
                   (filter (fn [^java.io.File f]
                             (re-matches #"bondy-.*\.tar\.gz" (.getName f))))
                   (sort-by (fn [^java.io.File f] (.lastModified f))))]
    (when-let [^java.io.File f (last files)]
      (str "file://" (.getAbsolutePath f)))))

(def cli-opts
  [["-r" "--rate HZ" "Approximate number of requests per second, per thread."
    :default  10
    :parse-fn read-string
    :validate [#(and (number? %) (pos? %)) "Must be a positive number."]]
   ["-w" "--workload NAME" "What workload should we run?"
    :missing  (str "--workload " (cli/one-of workloads))
    :validate [workloads (cli/one-of workloads)]]
   [nil "--nemesis NAME" "What nemesis should we use?"
    :default  "none"
    :validate [nemesises (cli/one-of nemesises)]]
   [nil "--network-partition-nemesis NAME" "Partition nemesis for combined."
    :default  "random-partition-halves"
    :validate [network-partition-nemesises (cli/one-of network-partition-nemesises)]]
   [nil "--random-nodes NUM" "Nodes disrupted by kill nemeses."
    :default  1
    :parse-fn parse-long
    :validate [pos? "Must be a positive integer."]]
   [nil "--disruption-duration NUM" "Duration of disruption (seconds)."
    :default  10
    :parse-fn parse-long
    :validate [pos? "Must be a positive integer."]]
   [nil "--time-before-disruption NUM" "Sleep before nemesis fires (seconds)."
    :default  10
    :parse-fn parse-long
    :validate [pos? "Must be a positive integer."]]
   ;; What has to happen between the heal and the final reads: Partisan
   ;; rediscovers peers (polling_interval 2s), a killed node replays its WAL
   ;; and rejoins, and anti-entropy catches every shard up. MEASURED on the
   ;; compose cluster (2026-09-03): after a partition alone or a kill alone,
   ;; every replica had converged within 15s. After `combined` faults (a
   ;; node killed while partitioned) two replicas were still missing
   ;; acknowledged users at 30s AND at 60s, and all had converged at 120s.
   ;; The node logs show why: the lagging replica's sync sessions report a
   ;; frontier gap against the restarted node, the scheduler flags a
   ;; catalogue re-bootstrap only after that repeats across two complete
   ;; rounds plus a settle (bondy_oplog_sync_scheduler:maybe_flag_rebootstrap/3),
   ;; and the re-bootstrap itself then completes in well under 30s — the
   ;; wait is detection pacing, not repair. 120s is therefore the default;
   ;; a shorter value is how to measure the convergence tail, not a verdict.
   [nil "--recovery-wait NUM" "Seconds between the heal and the final reads."
    :default  120
    :parse-fn parse-long
    :validate [#(>= % 0) "Must be a non-negative integer."]]
   [nil "--ready-timeout NUM" "Seconds a node has to answer /ready = 204 at setup."
    :default  120
    :parse-fn parse-long
    :validate [pos? "Must be a positive integer."]]
   [nil "--aae-interval-ms NUM" "bondy_db anti-entropy interval (db.aae.interval)."
    :default  500
    :parse-fn parse-long
    :validate [pos? "Must be a positive integer."]]
   [nil "--realm URI" "The realm the workload writes users into."
    :default  "com.jepsen.bondy"]
   [nil "--erlang-distribution-url URL"
    "URL of the Bondy release tarball. Defaults to the newest bondy-*.tar.gz under /root/jepsen.bondy."]])

(defn bondy-test
  [opts]
  (let [archive           (or (:erlang-distribution-url opts) (default-archive-url))
        workload          ((get workloads (:workload opts)) opts)
        nemesis           (init-nemesis opts)
        nemesis-generator ((get nemesis-generators (:nemesis opts)) opts)]
    (when-not archive
      (throw (ex-info "no release tarball: run `just rel-jepsen-bondy` or pass --erlang-distribution-url"
                      {:archive-dir archive-dir})))
    (merge tests/noop-test
           opts
           {:erlang-distribution-url archive
            :pure-generators true
            :name (str (:workload opts) "-" (:nemesis opts))
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
              (gen/log (str "Waiting " (:recovery-wait opts) "s for recovery"))
              (gen/sleep (:recovery-wait opts))
              (gen/clients (:final-generator workload)))})))

(defn -main
  [& args]
  (cli/run! (cli/single-test-cmd {:test-fn  bondy-test
                                  :opt-spec cli-opts})
            args))
